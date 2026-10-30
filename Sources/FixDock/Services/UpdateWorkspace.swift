// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import Darwin
import Foundation

/// The app-owned folder for update attempts, and the only code that creates,
/// writes or removes anything in it:
///
///     <PrivateFileStore.containerURL>/Updates/     0700, owned by this user
///       attempt-<UUID>/                            0700, one per Download and install
///         archive.zip.partial -> archive.zip       0600, created O_EXCL, renamed RENAME_EXCL
///         stage/FixDock.app                        ditto output; after the swap, the OLD app
///         handoff.plist                            the old app writes it before the helper starts
///         report.plist                             the helper writes it at its end
///         confirmed                                the new app creates it, empty
///
/// One writer per file, merged at the read boundary by
/// `UpdatePolicy.launchOutcome`. The root comes from the running bundle id,
/// never from a record, so the developer build has its own workspace and the
/// helper cannot be pointed at another folder.
struct UpdateWorkspace {
    /// The real path of the root, resolved through its nearest existing
    /// ancestor while the folder does not exist yet.
    let root: URL

    /// nil when the root exists but is not a real directory owned by this user
    /// with no group or other access. Then nothing reads, writes or removes.
    static func forRunningApp() -> UpdateWorkspace? {
        guard let container = PrivateFileStore.containerURL else { return nil }
        return validated(root: container.appendingPathComponent("Updates", isDirectory: true))
    }

    /// Also the seam a harness uses to point the workspace at a scratch folder.
    static func validated(root: URL) -> UpdateWorkspace? {
        var info = stat()
        if lstat(root.path, &info) == 0 {
            guard isPrivateDirectory(info), let real = realPath(root.path) else { return nil }
            return UpdateWorkspace(root: URL(fileURLWithPath: real, isDirectory: true))
        }
        guard errno == ENOENT, let real = resolvedThroughAncestor(root.path) else { return nil }
        return UpdateWorkspace(root: URL(fileURLWithPath: real, isDirectory: true))
    }

    struct Attempt: Equatable {
        let token: UUID
        let directory: URL
        var partialArchive: URL { directory.appendingPathComponent("archive.zip.partial") }
        var archive: URL { directory.appendingPathComponent("archive.zip") }
        var stageDirectory: URL { directory.appendingPathComponent("stage") }
        var stagedApp: URL { stageDirectory.appendingPathComponent(UpdatePolicy.releaseBundleName) }
        var handoffFile: URL { directory.appendingPathComponent("handoff.plist") }
        var reportFile: URL { directory.appendingPathComponent("report.plist") }
        var confirmFile: URL { directory.appendingPathComponent("confirmed") }
    }

    /// Creates the root if needed and a fresh attempt folder. EEXIST is an
    /// error: an attempt never reuses a folder.
    func beginAttempt() throws -> Attempt {
        guard PrivateFileStore.createDirectory(at: root) else { throw InstallFailure.diskWrite(errno) }
        guard Self.validated(root: root)?.root == root else { throw InstallFailure.diskWrite(EPERM) }
        let token = UUID()
        let directory = root.appendingPathComponent(Self.attemptPrefix + token.uuidString, isDirectory: true)
        guard mkdir(directory.path, 0o700) == 0 else { throw InstallFailure.diskWrite(errno) }
        return Attempt(token: token, directory: directory)
    }

    /// The helper's lookup by token.
    func attempt(_ token: UUID) -> Attempt? {
        attempts().first { $0.token == token }
    }

    /// The newest attempt that reached the handoff.
    func pendingAttempt() -> (Attempt, HandoffRecord)? {
        attempts()
            .compactMap { attempt in readHandoff(in: attempt).map { (attempt, $0) } }
            .max { $0.1.createdAt < $1.1.createdAt }
    }

    // MARK: Files

    func writeHandoff(_ record: HandoffRecord, in attempt: Attempt) throws {
        guard let data = try? PropertyListEncoder().encode(record),
              PrivateFileStore.write(data, to: attempt.handoffFile)
        else { throw InstallFailure.handoffFailed(errno) }
    }

    func readHandoff(in attempt: Attempt) -> HandoffRecord? {
        Self.readRegularFile(attempt.handoffFile).flatMap { try? PropertyListDecoder().decode(HandoffRecord.self, from: $0) }
    }

    func writeReport(_ report: HelperReport, in attempt: Attempt) {
        guard let data = try? PropertyListEncoder().encode(report) else { return }
        PrivateFileStore.write(data, to: attempt.reportFile)
    }

    func readReport(in attempt: Attempt) -> HelperReport? {
        Self.readRegularFile(attempt.reportFile).flatMap { try? PropertyListDecoder().decode(HelperReport.self, from: $0) }
    }

    func confirmLaunch(of attempt: Attempt) {
        let descriptor = open(attempt.confirmFile.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
        if descriptor >= 0 { close(descriptor) }
    }

    func isConfirmed(_ attempt: Attempt) -> Bool {
        var info = stat()
        return lstat(attempt.confirmFile.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
    }

    // MARK: The only removal

    /// Called from the launch reconcile, before an install and after a failed
    /// or cancelled one. Each attempt is removed only when BOTH guards pass:
    /// `UpdatePolicy.attemptIsFinished` from its own files, and
    /// `UpdatePolicy.mayRemove` against the bundle this process runs from now
    /// and the install target. If either protected path cannot be derived, or
    /// the root no longer validates, nothing is removed. `removeItem` does not
    /// follow links, so a link planted inside an attempt removes only the link.
    func sweep(running: SemanticVersion?, installTarget: String, keeping active: UUID?, now: Date) {
        guard Self.validated(root: root)?.root == root,
              let me = Self.runningBundlePath(),
              let target = Self.realPath(installTarget)
        else { return }
        let protected = [me, target]
        for attempt in attempts() {
            guard UpdatePolicy.attemptIsFinished(record: readHandoff(in: attempt),
                                                 report: readReport(in: attempt),
                                                 confirmed: isConfirmed(attempt),
                                                 running: running,
                                                 isActive: attempt.token == active,
                                                 now: now),
                  UpdatePolicy.mayRemove(attempt.directory.path, workspaceRoot: root.path,
                                         protected: protected)
            else { continue }
            try? FileManager.default.removeItem(at: attempt.directory)
        }
    }

    /// The bundle that holds this process's executable now, from
    /// proc_pidpath, which follows the file after a rename.
    /// `Bundle.main.bundlePath` still names /Applications after a swap moved
    /// this very process's bundle into an attempt, so it is never used here.
    static func runningBundlePath() -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(getpid(), &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return bundlePath(ofExecutable: String(cString: buffer))
    }

    /// ".../X.app/Contents/MacOS/<exe>" -> real path of ".../X.app", else nil.
    static func bundlePath(ofExecutable executable: String) -> String? {
        let macOS = (executable as NSString).deletingLastPathComponent
        let contents = (macOS as NSString).deletingLastPathComponent
        let bundle = (contents as NSString).deletingLastPathComponent
        guard (macOS as NSString).lastPathComponent == "MacOS",
              (contents as NSString).lastPathComponent == "Contents",
              bundle.hasSuffix(".app")
        else { return nil }
        return realPath(bundle)
    }

    static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    // MARK: Private

    private static let attemptPrefix = "attempt-"

    /// Real directories directly under the root named attempt-<UUID>. Links,
    /// files and other names are skipped, so nothing above ever acts on them.
    private func attempts() -> [Attempt] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return [] }
        return names.compactMap { name in
            guard name.hasPrefix(Self.attemptPrefix),
                  let token = UUID(uuidString: String(name.dropFirst(Self.attemptPrefix.count)))
            else { return nil }
            let path = root.appendingPathComponent(name).path
            var info = stat()
            guard lstat(path, &info) == 0, Self.isPrivateDirectory(info),
                  Self.realPath(path) == path
            else { return nil }
            return Attempt(token: token, directory: URL(fileURLWithPath: path, isDirectory: true))
        }
    }

    private static func isPrivateDirectory(_ info: stat) -> Bool {
        (info.st_mode & S_IFMT) == S_IFDIR && info.st_uid == getuid() && (info.st_mode & 0o077) == 0
    }

    /// realpath of the nearest existing ancestor plus the missing components.
    private static func resolvedThroughAncestor(_ path: String) -> String? {
        var missing: [String] = []
        var current = path
        while realPath(current) == nil {
            let parent = (current as NSString).deletingLastPathComponent
            guard parent != current, !parent.isEmpty else { return nil }
            missing.insert((current as NSString).lastPathComponent, at: 0)
            current = parent
        }
        guard let base = realPath(current) else { return nil }
        return missing.reduce(base) { ($0 as NSString).appendingPathComponent($1) }
    }

    private static func readRegularFile(_ url: URL) -> Data? {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size <= 64 << 10
        else { return nil }
        return try? Data(contentsOf: url)
    }
}
