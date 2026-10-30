// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import Darwin
import Foundation
import Security

/// The one way FixDock restarts itself. The app spawns its own executable with
/// `helperFlag` (detached, so it leaves the app's session) and quits;
/// main.swift hands that process here before Defaults or NSApplication exist.
///
///     plain:   wait for the app to exit, then open the bundle
///     update:  wait for the app to exit, RENAME_SWAP(target, staged), open,
///              wait for the new version's `confirmed` marker; if the new
///              version is gone without it, RENAME_SWAP back and open the old one
///
/// The helper never downloads or parses an archive: the app did that before it
/// quit. It does check the staged signature and version once more right before
/// the swap, because any process of this user can write the stage and start
/// this same-team helper, which App Management lets change the installed app.
/// It uses no AppKit, so it never registers as a running app;
/// it launches through /usr/bin/open and watches processes through libproc.
/// RENAME_SWAP is atomic, so the installed path is never missing, and the same
/// call restores exactly what was there.
enum Relauncher {
    static let helperFlag = "--fixdock-relaunch-helper"

    // MARK: App side (the caller quits right after)

    /// Settings › Relaunch: Screen Recording applies to a new process only.
    static func relaunch() {
        guard let executable = Bundle.main.executablePath else { return }
        _ = try? DetachedProcess.spawn(executable, [helperFlag, String(getpid())])
    }

    /// Writes the handoff record and spawns the helper. Throws only before
    /// anything was spawned; the app then keeps running and shows the failure.
    static func replaceAndRelaunch(with update: VerifiedUpdate, workspace: UpdateWorkspace) throws {
        guard let from = update.running.version,
              let staged = UpdateWorkspace.realPath(update.attempt.stagedApp.path),
              let executable = Bundle.main.executablePath
        else { throw InstallFailure.handoffFailed(EINVAL) }
        let record = HandoffRecord(token: update.attempt.token, from: from, to: update.offer.version,
                                   appPID: getpid(), targetPath: update.running.bundleURL.path,
                                   stagedPath: staged, createdAt: Date())
        try workspace.writeHandoff(record, in: update.attempt)
        do {
            try DetachedProcess.spawn(executable, [helperFlag, String(getpid()), record.token.uuidString])
        } catch {
            throw InstallFailure.handoffFailed(Int32((error as NSError).code))
        }
    }

    // MARK: Helper side

    /// First statement in main.swift. Returns at once unless this process is
    /// the helper; otherwise runs it and exits.
    static func runIfHelper(_ arguments: [String]) {
        guard arguments.count >= 3, arguments[1] == helperFlag,
              let pid = pid_t(arguments[2]) else { return }
        if arguments.count >= 4, let token = UUID(uuidString: arguments[3]) {
            exit(runUpdate(appPID: pid, token: token))
        }
        exit(runPlain(appPID: pid))
    }

    private static func runPlain(appPID: pid_t) -> Int32 {
        guard let own = UpdateWorkspace.runningBundlePath(),
              waitForExit(appPID, within: UpdatePolicy.quitDeadline)
        else { return 1 }
        return open(own) ? 0 : 1
    }

    private static func runUpdate(appPID: pid_t, token: UUID) -> Int32 {
        // Read before the swap: afterwards this process's own bundle sits in
        // the attempt, and nothing below asks Bundle.main again.
        guard let own = UpdateWorkspace.runningBundlePath(),
              let workspace = UpdateWorkspace.forRunningApp(),
              let attempt = workspace.attempt(token),
              let record = workspace.readHandoff(in: attempt)
        else { return runPlain(appPID: appPID) }

        func report(_ ending: HelperReport.Ending, _ reason: HelperReport.Reason?) {
            workspace.writeReport(HelperReport(token: token, ending: ending, reason: reason, at: Date()),
                                  in: attempt)
        }

        // Guards for the swap (D1). Each failure touches nothing.
        let staged = UpdateWorkspace.realPath(attempt.stagedApp.path)
        guard record.token == token, record.appPID == appPID,
              record.targetPath == own,
              let staged, staged == attempt.stagedApp.path, record.stagedPath == staged,
              let ownID = bundleIdentifier(of: own), bundleIdentifier(of: staged) == ownID
        else {
            report(.notSwapped, .recordRejected)
            return runPlain(appPID: appPID)
        }
        guard waitForExit(appPID, within: UpdatePolicy.quitDeadline) else {
            report(.notSwapped, .appDidNotQuit)
            return 1
        }
        guard stagedMayReplace(own, with: staged) else {
            report(.notSwapped, .stagedRejected)
            _ = open(own)
            return 1
        }
        guard swap(own, staged) == 0 else {
            report(.notSwapped, .swapFailed)
            _ = open(own)
            return 1
        }

        // `own` now holds the new version and `staged` the old one. Rollback
        // (D2) runs only when the new version is gone without confirming.
        func rollBack(_ reason: HelperReport.Reason) -> Int32 {
            if workspace.isConfirmed(attempt) {
                report(.confirmed, nil)
                return 0
            }
            if swap(own, staged) == 0 {
                report(.rolledBack, reason)
                _ = open(own)
            } else {
                report(.rollbackFailed, reason)
                _ = open(staged)
            }
            return 1
        }

        let executable = executablePath(of: own)
        if processes(running: executable).isEmpty, !open(own) { return rollBack(.launchFailed) }
        var seenAlive = false
        let deadline = Date().addingTimeInterval(UpdatePolicy.launchConfirmDeadline)
        while Date() < deadline {
            if workspace.isConfirmed(attempt) {
                report(.confirmed, nil)
                return 0
            }
            let alive = !processes(running: executable).isEmpty
            if seenAlive, !alive { return rollBack(.newVersionExited) }
            seenAlive = seenAlive || alive
            usleep(250_000)
        }
        if workspace.isConfirmed(attempt) {
            report(.confirmed, nil)
            return 0
        }
        if processes(running: executable).isEmpty { return rollBack(.newVersionExited) }
        report(.launchedUnconfirmed, nil)
        return 0
    }

    /// Immediately before the swap: the staged copy satisfies the installed
    /// copy's own designated requirement plus notarization (the verifier's
    /// check, shared), and its version is strictly newer, so a genuine older
    /// build cannot be swapped in.
    private static func stagedMayReplace(_ own: String, with staged: String) -> Bool {
        guard let pin = SigningIdentity.ofBundle(at: URL(fileURLWithPath: own, isDirectory: true)),
              pin.checkReplacement(at: URL(fileURLWithPath: staged, isDirectory: true)) == errSecSuccess,
              let installed = SemanticVersion(infoPlist(of: own)?["CFBundleShortVersionString"] as? String),
              let incoming = SemanticVersion(infoPlist(of: staged)?["CFBundleShortVersionString"] as? String)
        else { return false }
        return incoming > installed
    }

    /// kill(pid, 0) fails with ESRCH once the process is gone.
    private static func waitForExit(_ pid: pid_t, within seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if kill(pid, 0) == -1 && errno == ESRCH { return true }
            usleep(100_000)
        }
        return kill(pid, 0) == -1 && errno == ESRCH
    }

    /// 0 or errno. The only RENAME_SWAP in the app.
    private static func swap(_ a: String, _ b: String) -> Int32 {
        renamex_np(a, b, UInt32(RENAME_SWAP)) == 0 ? 0 : errno
    }

    /// The same launch as the old relaunch script: LaunchServices opens the
    /// bundle as if the person had, with no AppKit in this process.
    private static func open(_ bundlePath: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [bundlePath]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    /// Other processes whose executable is `path` (realpath compared), found
    /// with libproc, so a copy the person opened by hand counts too.
    private static func processes(running path: String) -> [pid_t] {
        guard let target = UpdateWorkspace.realPath(path) else { return [] }
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return [] }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        return pids.prefix(Int(count)).filter { pid in
            guard pid > 0, pid != getpid(),
                  proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0
            else { return false }
            return UpdateWorkspace.realPath(String(cString: buffer)) == target
        }
    }

    /// Read from the file, never through Bundle, which caches by path.
    private static func infoPlist(of bundlePath: String) -> NSDictionary? {
        NSDictionary(contentsOfFile: (bundlePath as NSString).appendingPathComponent("Contents/Info.plist"))
    }

    private static func bundleIdentifier(of bundlePath: String) -> String? {
        infoPlist(of: bundlePath)?["CFBundleIdentifier"] as? String
    }

    private static func executablePath(of bundlePath: String) -> String {
        let name = infoPlist(of: bundlePath)?["CFBundleExecutable"] as? String ?? UpdatePolicy.releaseExecutableName
        return (bundlePath as NSString).appendingPathComponent("Contents/MacOS/\(name)")
    }
}
