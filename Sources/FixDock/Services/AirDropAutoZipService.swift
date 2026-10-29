// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import AppKit
import Combine
import UserNotifications

/// Watches `~/Downloads` for photos received by AirDrop and hands each quiet
/// batch to `AirDropBatch`. New in FixDock. The watch, its timer and its
/// bookkeeping exist only while the tool is installed and on.
///
/// Files already in the folder when the watch starts are recorded and never
/// processed. A new name is looked at again for `recheckWindow`, because the
/// quarantine stamp can land after the file appears. A batch closes once
/// `quietPeriod` has passed without a new name and every member's size has
/// held still; files that arrive while a batch runs wait for the next one.
/// Main thread, except the batch itself.
final class AirDropAutoZipService: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = AirDropAutoZipService()

    @Published private(set) var isWatching = false
    /// The folder could not be read: usually the Downloads access prompt was declined.
    @Published private(set) var folderUnavailable = false
    @Published private(set) var isProcessing = false

    /// How long a new name that is not yet a candidate is looked at again.
    private static let recheckWindow: TimeInterval = 30
    private static let tickInterval: TimeInterval = 1

    let folder: URL
    private let queue = DispatchQueue(label: "io.github.qaws81877.fixdock.airdrop", qos: .utility)
    private var source: DispatchSourceFileSystemObject?
    private var known: Set<String> = []
    /// New names not yet a candidate → when first seen.
    private var arrived: [String: Date] = [:]
    /// Candidate name → size at the last look (nil before the first).
    private var pending: [String: Int64?] = [:]
    private var lastArrival = Date.distantPast
    private var tickWork: DispatchWorkItem?
    /// Only photos received after this are processed.
    private var watchStarted = Date()

    private override init() {
        // Developer runs only: `defaults write <bundle id> airdropAutoZipFolderOverride /path`
        // points the watch at a scratch folder instead of Downloads.
        if let override = UserDefaults.standard.string(forKey: DefaultsKey.airdropAutoZipFolderOverride),
           !override.isEmpty {
            folder = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
        }
        super.init()
    }

    func syncWithPreferences() {
        let wanted = AppFeature.airdropAutoZip.isAvailable
            && UserDefaults.standard.bool(forKey: DefaultsKey.airdropAutoZipEnabled)
        wanted ? start() : stop()
    }

    // MARK: - Watch

    private func start() {
        guard source == nil else { return }
        guard let names = currentNames() else {
            folderUnavailable = true
            return
        }
        let descriptor = open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else {
            folderUnavailable = true
            return
        }
        folderUnavailable = false
        watchStarted = Date()
        known = names
        arrived = [:]
        pending = [:]
        let watch = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                                                              eventMask: [.write, .rename, .delete],
                                                              queue: .main)
        watch.setEventHandler { [weak self] in self?.scan() }
        watch.setCancelHandler { close(descriptor) }
        watch.resume()
        source = watch
        isWatching = true
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Candidates not yet batched stay in the folder untouched. A batch
    /// already running finishes; its originals are only trashed if its zip
    /// verified.
    private func stop() {
        source?.cancel()
        source = nil
        tickWork?.cancel()
        tickWork = nil
        arrived = [:]
        pending = [:]
        known = []
        isWatching = false
    }

    private func currentNames() -> Set<String>? {
        (try? FileManager.default.contentsOfDirectory(atPath: folder.path)).map(Set.init)
    }

    /// New names wait in `arrived` for `tick` to judge them. Names that left
    /// are forgotten, so a photo arriving again under the same name is new.
    private func scan() {
        guard isWatching, let names = currentNames() else { return }
        let now = Date()
        for name in names.subtracting(known) { arrived[name] = now }
        if !names.subtracting(known).isEmpty { lastArrival = now }
        known = names
        arrived = arrived.filter { names.contains($0.key) }
        scheduleTick()
    }

    private func scheduleTick() {
        guard tickWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.tickWork = nil
            self?.tick()
        }
        tickWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.tickInterval, execute: work)
    }

    private func tick() {
        guard isWatching else { return }
        let now = Date()

        for (name, seen) in arrived {
            if isCandidate(name) {
                arrived[name] = nil
                pending[name] = .some(nil)
                lastArrival = max(lastArrival, seen)
            } else if now.timeIntervalSince(seen) > Self.recheckWindow {
                arrived[name] = nil
            }
        }

        var settled = true
        for (name, previous) in pending {
            let url = folder.appendingPathComponent(name)
            guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) else {
                pending[name] = nil // gone before it settled
                continue
            }
            if !AirDropAutoZipSupport.isSettled(previous: previous, current: size) {
                pending[name] = .some(size)
                settled = false
            }
        }

        if !pending.isEmpty, settled, !isProcessing,
           now.timeIntervalSince(lastArrival) >= AirDropAutoZipSupport.quietPeriod {
            runBatch()
        }
        if !arrived.isEmpty || !pending.isEmpty { scheduleTick() }
    }

    private func isCandidate(_ name: String) -> Bool {
        let url = folder.appendingPathComponent(name)
        let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
        return AirDropAutoZipSupport.isCandidate(name: name, contentType: type, quarantine: quarantine(of: url),
                                                 receivedAfter: watchStarted)
    }

    private func quarantine(of url: URL) -> String? {
        let length = getxattr(url.path, "com.apple.quarantine", nil, 0, 0, 0)
        guard length > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: length)
        guard getxattr(url.path, "com.apple.quarantine", &buffer, length, 0, 0) == length else { return nil }
        return String(decoding: buffer, as: UTF8.self)
    }

    private func runBatch() {
        let files = pending.keys.map { folder.appendingPathComponent($0) }
        pending = [:]
        isProcessing = true
        let options = AirDropAutoZipSettings.options
        let folder = self.folder
        queue.async { [weak self] in
            let outcome = AirDropBatch.run(files, in: folder, options: options)
            DispatchQueue.main.async {
                guard let self else { return }
                self.isProcessing = false
                self.notify(outcome)
                if !self.arrived.isEmpty || !self.pending.isEmpty { self.scheduleTick() }
            }
        }
    }

    // MARK: - Notifications

    private func notify(_ outcome: AirDropBatch.Outcome) {
        let s = L10n.shared.s
        let content = UNMutableNotificationContent()
        content.title = AppFeature.airdropAutoZip.title(s)
        if let zip = outcome.zip {
            content.body = String(format: s.airdropNotifyDoneFormat, outcome.count, zip.lastPathComponent)
            if !outcome.kept.isEmpty {
                content.body += " " + String(format: s.airdropKeptFormat, outcome.kept.count)
            }
        } else {
            content.body = s.airdropNotifyFailed
        }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// Shows the banner even while a FixDock window is in front.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

enum AirDropAutoZipSettings {
    /// Original format and size, location removed; only the level is a choice.
    static var options: ImageCompressionOptions {
        ImageCompressionOptions(
            quality: CompressionPreset.from(
                UserDefaults.standard.string(forKey: DefaultsKey.airdropAutoZipPreset)).percent,
            format: .original,
            maxDimension: nil,
            metadata: .removeLocation)
    }
}
