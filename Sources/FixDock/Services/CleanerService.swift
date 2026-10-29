// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import AppKit
import Combine

/// One thing the cleaner found.
struct CleanerItem: Identifiable, Equatable {
    /// The absolute path as scanned, also the exception key.
    let id: String
    let url: URL
    let category: CleanerCategory
    let size: Int64
    let title: String
    /// Device and date for a backup, the label for a launch agent.
    let detail: String?
    /// The app whose data this is; a running owner locks the item.
    let owner: String?
    let identity: FileIdentity?
    let recommended: Bool
}

struct FileIdentity: Equatable {
    let device: UInt64
    let inode: UInt64

    /// lstat, so a symlink is identified as itself and never followed.
    static func of(_ url: URL) -> FileIdentity? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return FileIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino))
    }

    /// The path with every symlink resolved, by realpath(3). Unlike
    /// `resolvingSymlinksInPath` it never drops a `/private` prefix, so
    /// "unchanged" really means no symlink anywhere on the path.
    static func realPath(_ url: URL) -> String? {
        guard let resolved = realpath(url.path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func isSymbolicLink(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFLNK
    }
}

/// Scan, review and permanent removal, adapted from upstream's JunkCleaner.
/// Main thread, except the scan and removal loops.
///
/// Deletion guard (`mayRemove`, run per item right before removal on the
/// removal queue): the home folder is usable; the path is not protected, is
/// at least four components deep and inside the home folder; it is still the
/// same file (device and inode from lstat) the scan found; neither it nor
/// any ancestor is a symlink; it is still a direct child of its category's
/// root, or exactly one of the category's fixed paths; it is not an
/// exception; its owner is not running now; a leftover still has no living
/// owner. Anything that fails is skipped and reported, never removed.
/// Removal is permanent (`FileManager.removeItem`); there is no sudo, no
/// Finder scripting and no Trash-wide empty.
final class CleanerService: ObservableObject {
    static let shared = CleanerService()

    enum Phase: Equatable {
        case idle, scanning, results, cleaning, done
    }

    struct Failure: Identifiable, Equatable {
        let id = UUID()
        let path: String
        let skipped: Bool
    }

    @Published private(set) var phase = Phase.idle
    @Published private(set) var items: [CleanerItem] = []
    @Published var selected: Set<String> = []
    @Published private(set) var runningOwners: Set<String> = []
    @Published private(set) var exceptions: Set<String>
    @Published private(set) var freedBytes: Int64 = 0
    @Published private(set) var removedCount = 0
    @Published private(set) var failures: [Failure] = []
    @Published private(set) var homeUnusable = false

    private let queue = DispatchQueue(label: "io.github.qaws81877.fixdock.cleaner", qos: .userInitiated)
    private var scanToken: CancelToken?

    private init() {
        exceptions = Set(UserDefaults.standard.stringArray(forKey: DefaultsKey.cleanerExceptions) ?? [])
    }

    /// Feature binding. Uninstalling stops a scan; a removal already running
    /// finishes its current item and the rest of its checked list.
    func syncWithPreferences() {
        if !AppFeature.cleaner.isAvailable {
            scanToken?.cancel()
            reset()
        }
    }

    func reset() {
        guard phase != .cleaning else { return }
        phase = .idle
        items = []
        selected = []
        failures = []
        freedBytes = 0
        removedCount = 0
    }

    // MARK: - Review state

    func isLocked(_ item: CleanerItem) -> Bool {
        guard let owner = item.owner else { return false }
        return CleanerRules.isOwned(candidate: owner, byInstalled: runningOwners)
    }

    func isException(_ item: CleanerItem) -> Bool { exceptions.contains(item.id) }

    func isSelectable(_ item: CleanerItem) -> Bool { !isLocked(item) && !isException(item) }

    func toggleException(_ item: CleanerItem) {
        if exceptions.contains(item.id) {
            exceptions.remove(item.id)
        } else {
            exceptions.insert(item.id)
            selected.remove(item.id)
        }
        UserDefaults.standard.set(Array(exceptions).sorted(), forKey: DefaultsKey.cleanerExceptions)
    }

    func setSelected(_ on: Bool, _ item: CleanerItem) {
        guard isSelectable(item) else { return }
        if on { selected.insert(item.id) } else { selected.remove(item.id) }
    }

    var selectedItems: [CleanerItem] { items.filter { selected.contains($0.id) && isSelectable($0) } }

    // MARK: - Scan

    /// Full Disk Access and a usable home folder are both required.
    func scan() {
        guard AppFeature.cleaner.isAvailable, phase != .scanning, phase != .cleaning else { return }
        Permissions.shared.refresh()
        guard Permissions.shared.fullDiskAccess else {
            Permissions.shared.request(.fullDiskAccess)
            return
        }
        let home = NSHomeDirectory()
        guard CleanerRules.isUsableHome(home) else {
            homeUnusable = true
            return
        }
        homeUnusable = false
        scanToken?.cancel()
        let token = CancelToken()
        scanToken = token
        phase = .scanning
        items = []
        selected = []
        failures = []
        runningOwners = Self.runningBundleIDs()
        let exceptions = self.exceptions

        queue.async { [weak self] in
            let found = CleanerScanner(home: home).scanAll(isCancelled: { token.isCancelled })
            DispatchQueue.main.async {
                guard let self, self.scanToken === token else { return }
                self.scanToken = nil
                guard !token.isCancelled else {
                    self.phase = .idle
                    return
                }
                self.items = found
                self.runningOwners = Self.runningBundleIDs()
                self.selected = Set(found.filter { $0.recommended && !exceptions.contains($0.id) && !self.isLocked($0) }
                    .map(\.id))
                self.phase = .results
            }
        }
    }

    func cancelScan() {
        scanToken?.cancel()
    }

    // MARK: - Removal

    /// Removes the checked, selectable items permanently.
    func clean() {
        guard phase == .results else { return }
        let targets = selectedItems
        guard !targets.isEmpty else { return }
        phase = .cleaning
        let home = NSHomeDirectory()
        queue.async { [weak self] in
            var freed: Int64 = 0
            var removed = 0
            var failures: [Failure] = []
            let installed = CleanerScanner.installedBundleIDs()
            for item in targets {
                // Fresh on every item: an app launched since the scan locks it.
                let running = DispatchQueue.main.sync { Self.runningBundleIDs() }
                let exceptions = Set(UserDefaults.standard.stringArray(forKey: DefaultsKey.cleanerExceptions) ?? [])
                guard Self.mayRemove(item, home: home, installed: installed, running: running,
                                     exceptions: exceptions) else {
                    failures.append(Failure(path: item.id, skipped: true))
                    continue
                }
                if item.category == .loginItems { Self.bootoutUserAgent(item.url, home: home) }
                do {
                    try FileManager.default.removeItem(at: item.url)
                    freed += item.size
                    removed += 1
                } catch {
                    failures.append(Failure(path: item.id, skipped: false))
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.freedBytes = freed
                self.removedCount = removed
                self.failures = failures
                self.phase = .done
            }
        }
    }

    static func mayRemove(_ item: CleanerItem, home: String, installed: Set<String>,
                          running: Set<String>, exceptions: Set<String>) -> Bool {
        guard CleanerRules.isUsableHome(home) else { return false }
        let url = item.url
        let path = url.path
        guard path == item.id,
              path.hasPrefix(home + "/"),
              !url.pathComponents.contains(".."), !url.pathComponents.contains("."),
              !CleanerRules.protectedPaths(home: home).contains(path),
              url.pathComponents.count >= 4,
              !exceptions.contains(path),
              let expected = item.identity, FileIdentity.of(url) == expected,
              !FileIdentity.isSymbolicLink(url),
              FileIdentity.realPath(url) == path
        else { return false }
        if let owner = item.owner, CleanerRules.isOwned(candidate: owner, byInstalled: running) { return false }
        guard CleanerScanner.isInsideRoot(path, category: item.category, home: home) else { return false }
        if item.category == .leftovers {
            guard let owner = item.owner,
                  CleanerRules.isAttributableBundleID(owner),
                  !CleanerRules.isProtectedBundleID(owner),
                  !CleanerScanner.hasLivingOwner(owner, installed: installed) else { return false }
        }
        return true
    }

    /// Unloads a user launch agent before its plist goes, so the job does
    /// not keep running until logout. Best effort.
    private static func bootoutUserAgent(_ plistURL: URL, home: String) {
        guard plistURL.path.hasPrefix(home + "/" + CleanerRules.launchAgentsPath + "/"),
              let plist = NSDictionary(contentsOf: plistURL) as? [String: Any],
              let label = plist["Label"] as? String, !label.isEmpty,
              !label.contains("/"), !label.contains("..") else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["bootout", "gui/\(getuid())/\(label)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    static func runningBundleIDs() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier?.lowercased() })
    }
}

/// The category scanners. Every item is a direct child of a category root
/// or one of its fixed paths; nothing else can be produced.
struct CleanerScanner {
    let home: String

    func scanAll(isCancelled: () -> Bool) -> [CleanerItem] {
        let installed = Self.installedBundleIDs()
        var items: [CleanerItem] = []
        var claimed = Set<String>()
        let steps: [() -> [CleanerItem]] = [
            { browserCaches() },
            { developer(CleanerRules.developerPaths, category: .developer, recommended: true) },
            { downloads() },
            { leftovers(installed: installed) },
            { caches(excluding: claimed) },
            { logs(excluding: claimed) },
            { loginItems(installed: installed) },
            { deviceBackups() },
            { developer(CleanerRules.largeDeveloperPaths, category: .largeDeveloper, recommended: false) },
            { trash() },
        ]
        for step in steps {
            guard !isCancelled() else { return [] }
            let found = step()
            claimed.formUnion(found.map(\.id))
            items += found
        }
        return items
    }

    // MARK: Roots

    static func isInsideRoot(_ path: String, category: CleanerCategory, home: String) -> Bool {
        func fixed(_ list: [String]) -> Bool { list.contains { path == home + "/" + $0 } }
        func child(_ root: String) -> Bool { CleanerRules.isDirectChild(path, of: home + "/" + root) }
        switch category {
        case .caches: return child("Library/Caches")
        case .logs: return child("Library/Logs") || child("Library/Logs/DiagnosticReports")
        case .developer: return fixed(CleanerRules.developerPaths.map(\.path))
        case .largeDeveloper: return fixed(CleanerRules.largeDeveloperPaths.map(\.path))
        case .browserCaches: return fixed(CleanerRules.browserCachePaths.map(\.path))
        case .downloads: return child("Downloads") && CleanerRules.isUnfinishedDownload((path as NSString).lastPathComponent)
        case .leftovers: return CleanerRules.leftoverRoots.contains { child("Library/" + $0.path) }
        case .loginItems: return child(CleanerRules.launchAgentsPath) && path.hasSuffix(".plist")
        case .deviceBackups: return child(CleanerRules.deviceBackupPath)
        case .trash: return child(".Trash")
        }
    }

    // MARK: Scanners

    private func browserCaches() -> [CleanerItem] {
        CleanerRules.browserCachePaths.compactMap { entry in
            item(home + "/" + entry.path, .browserCaches, title: entry.name, owner: entry.owner, recommended: true)
        }
    }

    private func developer(_ paths: [(path: String, owner: String)], category: CleanerCategory,
                           recommended: Bool) -> [CleanerItem] {
        paths.compactMap { entry in
            item(home + "/" + entry.path, category, title: (entry.path as NSString).lastPathComponent,
                 owner: entry.owner, recommended: recommended)
        }
    }

    private func downloads() -> [CleanerItem] {
        children(of: home + "/Downloads").compactMap { url in
            let name = url.lastPathComponent
            guard CleanerRules.isUnfinishedDownload(name),
                  let modified = Self.modified(url), Date().timeIntervalSince(modified) > CleanerRules.downloadAge
            else { return nil }
            return item(url.path, .downloads, title: name, owner: nil, recommended: true)
        }
    }

    private func caches(excluding claimed: Set<String>) -> [CleanerItem] {
        children(of: home + "/Library/Caches").compactMap { url in
            let name = url.lastPathComponent
            guard !CleanerRules.isExcludedCacheEntry(name),
                  !claimed.contains(url.path),
                  !CleanerRules.browserCachePaths.contains(where: { (home + "/" + $0.path).hasPrefix(url.path + "/") })
            else { return nil }
            let owner = CleanerRules.looksLikeBundleID(name) ? name : nil
            return item(url.path, .caches, title: name, owner: owner,
                        recommended: CleanerRules.precheckCacheEntry(name))
        }
    }

    /// Logs whose newest file is older than the age limit.
    private func logs(excluding claimed: Set<String>) -> [CleanerItem] {
        let root = home + "/Library/Logs"
        let reports = root + "/DiagnosticReports"
        let entries = children(of: root).filter { $0.path != reports } + children(of: reports)
        return entries.compactMap { url in
            let name = url.lastPathComponent
            guard !CleanerRules.isExcludedCacheEntry(name), !claimed.contains(url.path) else { return nil }
            let measured = Self.measure(url)
            guard measured.size > 0, let newest = measured.newest,
                  Date().timeIntervalSince(newest) > CleanerRules.logAge else { return nil }
            return item(url.path, .logs, title: name,
                        owner: CleanerRules.bundleIDCandidate(fromEntryName: name),
                        recommended: true, measured: measured.size)
        }
    }

    private func leftovers(installed: Set<String>) -> [CleanerItem] {
        var found: [CleanerItem] = []
        for root in CleanerRules.leftoverRoots {
            for url in children(of: home + "/Library/" + root.path) {
                let name = url.lastPathComponent
                guard !name.lowercased().hasSuffix(".localized") else { continue }
                var owner: String?
                if root.usesContainerMetadata { owner = Self.containerOwner(at: url) }
                if owner == nil, !CleanerRules.hasSharedContainerWrapper(name) {
                    owner = CleanerRules.bundleIDCandidate(fromEntryName: name)
                }
                guard let owner, !CleanerRules.isProtectedBundleID(owner),
                      !Self.hasLivingOwner(owner, installed: installed) else { continue }
                if let made = item(url.path, .leftovers, title: name, detail: owner, owner: owner, recommended: false) {
                    found.append(made)
                }
            }
        }
        return found
    }

    private func loginItems(installed: Set<String>) -> [CleanerItem] {
        children(of: home + "/" + CleanerRules.launchAgentsPath).compactMap { url in
            guard url.pathExtension == "plist",
                  let plist = NSDictionary(contentsOf: url) as? [String: Any] else { return nil }
            let label = plist["Label"] as? String
            guard CleanerRules.launchPlistIsRemovableOrphan(
                    label: label, executables: CleanerRules.executablePaths(inLaunchPlist: plist),
                    executableExists: { $0.hasPrefix("/Volumes/") || FileManager.default.fileExists(atPath: $0) }),
                  !(label.map { Self.hasLivingOwner($0, installed: installed) } ?? false)
            else { return nil }
            return item(url.path, .loginItems, title: url.lastPathComponent, detail: label, owner: nil,
                        recommended: false)
        }
    }

    private func deviceBackups() -> [CleanerItem] {
        children(of: home + "/" + CleanerRules.deviceBackupPath).compactMap { url in
            let info = NSDictionary(contentsOf: url.appendingPathComponent("Info.plist"))
            let device = info?["Device Name"] as? String ?? info?["Display Name"] as? String
            let date = (info?["Last Backup Date"] as? Date).map {
                DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .short)
            }
            return item(url.path, .deviceBackups, title: device ?? url.lastPathComponent,
                        detail: date, owner: nil, recommended: false)
        }
    }

    /// Each entry as it is now; nothing added later is in the list.
    private func trash() -> [CleanerItem] {
        children(of: home + "/.Trash").compactMap { url in
            item(url.path, .trash, title: url.lastPathComponent, owner: nil, recommended: false)
        }
    }

    // MARK: Helpers

    /// Direct children, hidden entries and symlinks left out.
    private func children(of directory: String) -> [URL] {
        let url = URL(fileURLWithPath: directory, isDirectory: true)
        guard !FileIdentity.isSymbolicLink(url),
              let entries = try? FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [.skipsHiddenFiles])
        else { return [] }
        return entries.filter { !FileIdentity.isSymbolicLink($0) }
    }

    private func item(_ path: String, _ category: CleanerCategory, title: String, detail: String? = nil,
                      owner: String?, recommended: Bool, measured: Int64? = nil) -> CleanerItem? {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path), !FileIdentity.isSymbolicLink(url),
              Self.isInsideRoot(url.path, category: category, home: home) else { return nil }
        let size = measured ?? Self.measure(url).size
        guard size > 0 else { return nil }
        return CleanerItem(id: url.path, url: url, category: category, size: size, title: title,
                           detail: detail, owner: owner?.lowercased(), identity: FileIdentity.of(url),
                           recommended: recommended)
    }

    /// Allocated size and newest modification, symlinks never followed.
    static func measure(_ url: URL) -> (size: Int64, newest: Date?) {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
                                      .contentModificationDateKey, .isSymbolicLinkKey, .isRegularFileKey]
        func values(_ u: URL) -> (Int64, Date?) {
            let v = try? u.resourceValues(forKeys: Set(keys))
            return (Int64(v?.totalFileAllocatedSize ?? v?.fileAllocatedSize ?? 0), v?.contentModificationDate)
        }
        var (size, newest) = values(url)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue,
              let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys)
        else { return (size, newest) }
        size = 0
        for case let child as URL in enumerator {
            let v = try? child.resourceValues(forKeys: Set(keys))
            if v?.isSymbolicLink == true { enumerator.skipDescendants(); continue }
            size += Int64(v?.totalFileAllocatedSize ?? v?.fileAllocatedSize ?? 0)
            if let date = v?.contentModificationDate, date > (newest ?? .distantPast) { newest = date }
        }
        return (size, newest)
    }

    private static func modified(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    private static func containerOwner(at url: URL) -> String? {
        let metadata = url.appendingPathComponent(".com.apple.containermanagerd.metadata.plist")
        guard let dict = NSDictionary(contentsOf: metadata),
              let owner = dict["MCMMetadataIdentifier"] as? String,
              !CleanerRules.hasSharedContainerWrapper(owner) else { return nil }
        return CleanerRules.bundleIDCandidate(fromEntryName: owner)
    }

    // MARK: Installed apps (upstream)

    static func installedBundleIDs() -> Set<String> {
        var ids = Set<String>()
        let fm = FileManager.default
        func remember(_ url: URL) {
            if let id = Bundle(url: url)?.bundleIdentifier { ids.insert(id.lowercased()) }
        }
        func collect(_ url: URL, depth: Int) {
            guard depth > 0,
                  let entries = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey],
                                                            options: [.skipsHiddenFiles]) else { return }
            for entry in entries where !FileIdentity.isSymbolicLink(entry) {
                guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                if entry.pathExtension.caseInsensitiveCompare("app") == .orderedSame {
                    remember(entry)
                    collect(entry.appendingPathComponent("Contents/Library/LoginItems"), depth: 1)
                } else {
                    collect(entry, depth: depth - 1)
                }
            }
        }
        for root in ["/Applications", "/System/Applications", NSHomeDirectory() + "/Applications"] {
            collect(URL(fileURLWithPath: root), depth: 3)
        }
        for app in NSWorkspace.shared.runningApplications {
            if let id = app.bundleIdentifier { ids.insert(id.lowercased()) }
            if let url = app.bundleURL { remember(url) }
        }
        return ids
    }

    static func hasLivingOwner(_ candidate: String, installed: Set<String>) -> Bool {
        if CleanerRules.isOwned(candidate: candidate, byInstalled: installed) { return true }
        if CleanerRules.sharesVendorNamespace(candidate: candidate, withInstalled: installed) { return true }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: candidate) != nil
    }
}
