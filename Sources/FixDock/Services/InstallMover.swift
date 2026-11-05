// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import AppKit
import Darwin
import Foundation
import Security

/// Offers to move a release copy opened straight from the disk image (or
/// translocated by Gatekeeper) into /Applications, the only place it updates
/// itself and keeps its login item. Runs first in
/// `applicationDidFinishLaunching`, before anything registers, so a copy that
/// moves leaves nothing behind.
///
/// It never deletes: a copy already in /Applications goes to the Trash, and
/// comes back if the new one cannot be put in its place. The new copy is
/// opened only after it passed the same identity check the updater uses.
enum InstallMover {
    static let installFolder = "/Applications"

    enum Placement: Equatable {
        /// Leave it alone: installed, developer, self-built or elsewhere.
        case stay
        case offer
    }

    /// Pure: the bundle id, the realpath of the running bundle, whether its
    /// volume is read-only (a mounted disk image is), and whether it carries the
    /// release's Developer ID. An ad-hoc or foreign-signed copy never replaces
    /// the installed one, the same rule that keeps the updater inert for them.
    static func placement(bundleID: String?, bundlePath: String, volumeIsReadOnly: Bool,
                          releaseSigned: Bool) -> Placement {
        guard bundleID == AppInfo.bundleID, releaseSigned else { return .stay }
        if (bundlePath as NSString).deletingLastPathComponent == installFolder { return .stay }
        if bundlePath.contains("/AppTranslocation/") { return .offer }
        if bundlePath.hasPrefix("/Volumes/"), volumeIsReadOnly { return .offer }
        return .stay
    }

    /// true when this process moved itself and is quitting; the caller then
    /// starts nothing else.
    static func offerIfNeeded() -> Bool {
        let source = Bundle.main.bundleURL
        let path = UpdateWorkspace.realPath(source.path) ?? source.path
        let readOnly = (try? source.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly ?? false
        let signing = SigningIdentity.ofRunningApp()
        let releaseSigned = signing.map { $0.isDeveloperIDApplication && $0.teamID == AppInfo.signingTeamID } ?? false
        guard placement(bundleID: Bundle.main.bundleIdentifier, bundlePath: path,
                        volumeIsReadOnly: readOnly, releaseSigned: releaseSigned) == .offer,
              let signing
        else { return false }

        let strings = L10n.shared.s
        let destination = URL(fileURLWithPath: installFolder, isDirectory: true)
            .appendingPathComponent("\(AppInfo.name).app", isDirectory: true)
        let existing = FileManager.default.fileExists(atPath: destination.path)

        if existing, let installed = SemanticVersion(version(of: destination)),
           let own = SemanticVersion(AppInfo.version), installed > own {
            // A newer copy is already installed: open that one instead.
            guard ask(strings.installMoveNewerTitle,
                      String(format: strings.installMoveNewerMessageFormat, installed.description),
                      confirm: strings.installMoveOpenInstalled, cancel: strings.installMoveLater)
            else { return false }
            if let running = copies(runningFrom: destination).first {
                _ = running.activate(options: [])
                NSApp.terminate(nil)
                return true
            }
            return launchAndQuit(destination)
        }

        guard ask(strings.installMoveTitle,
                  existing ? strings.installMoveMessageReplacing : strings.installMoveMessage,
                  confirm: strings.installMoveConfirm, cancel: strings.installMoveLater)
        else { return false }

        guard access(installFolder, W_OK) == 0 else {
            inform(strings.installMoveNotWritableTitle, strings.installMoveNotWritableMessage)
            NSWorkspace.shared.activateFileViewerSelecting([source])
            return false
        }

        switch move(from: source, to: destination, signing: signing) {
        case .moved:
            return launchAndQuit(destination)
        case .unchanged(let detail):
            inform(strings.installMoveFailedTitle,
                   String(format: strings.installMoveFailedMessageFormat, detail))
            return false
        case .changed(let detail):
            inform(strings.installMoveFailedTitle,
                   String(format: strings.installMoveChangedMessageFormat, detail))
            return false
        }
    }

    // MARK: Private

    private enum MoveResult {
        case moved
        /// The install path is as it was before the move started.
        case unchanged(String)
        /// The old copy could not be put back and is still in the Trash.
        case changed(String)
    }

    private static func move(from source: URL, to destination: URL, signing: SigningIdentity) -> MoveResult {
        let files = FileManager.default
        // A scratch folder on the /Applications volume, so the last step is a
        // rename and the install path never holds a half-copied bundle.
        let scratch: URL
        do {
            scratch = try files.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                    appropriateFor: URL(fileURLWithPath: installFolder, isDirectory: true),
                                    create: true)
        } catch {
            return .unchanged(error.localizedDescription)
        }
        defer { try? files.removeItem(at: scratch) }
        let staged = scratch.appendingPathComponent(destination.lastPathComponent, isDirectory: true)

        guard run("/usr/bin/ditto", [source.path, staged.path]) else { return .unchanged("ditto") }

        // The same check the updater makes before a swap: this copy's own
        // designated requirement, and notarization.
        let status = signing.checkReplacement(at: staged)
        guard status == errSecSuccess else { return .unchanged("codesign \(status)") }

        // This copy already passed Gatekeeper to be running. Without this the
        // copy keeps the disk image's quarantine and is translocated on launch.
        _ = run("/usr/bin/xattr", ["-d", "-r", "com.apple.quarantine", staged.path])

        guard quitOtherCopies(of: destination) else { return .unchanged(L10n.shared.s.installMoveStillRunning) }

        var trashedURL: NSURL?
        if files.fileExists(atPath: destination.path) {
            do {
                try files.trashItem(at: destination, resultingItemURL: &trashedURL)
            } catch {
                return .unchanged(error.localizedDescription)
            }
        }
        let trashed = trashedURL as URL?

        /// Puts the old copy back once the install path is empty again.
        func restore(_ detail: String) -> MoveResult {
            guard !files.fileExists(atPath: destination.path) else { return .changed(detail) }
            guard let trashed else { return .unchanged(detail) }
            do {
                try files.moveItem(at: trashed, to: destination)
                return .unchanged(detail)
            } catch {
                return .changed(detail)
            }
        }

        do {
            try files.moveItem(at: staged, to: destination)
        } catch {
            return restore(error.localizedDescription)
        }

        // Nothing stays at the install path unless it passed the check there.
        let installed = signing.checkReplacement(at: destination)
        guard installed == errSecSuccess else {
            // Aside into the scratch folder, then the old copy goes back.
            guard (try? files.moveItem(at: destination, to: staged)) != nil
            else { return .changed("codesign \(installed)") }
            return restore("codesign \(installed)")
        }
        return .moved
    }

    /// Asks a FixDock already running from the install path to quit, and
    /// waits for it. false if it is still running.
    private static func quitOtherCopies(of destination: URL) -> Bool {
        let others = copies(runningFrom: destination)
        guard !others.isEmpty else { return true }
        others.forEach { $0.terminate() }
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if others.allSatisfy(\.isTerminated) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return others.allSatisfy(\.isTerminated)
    }

    /// Other FixDock processes whose bundle is `bundle` (realpath compared).
    private static func copies(runningFrom bundle: URL) -> [NSRunningApplication] {
        guard let target = UpdateWorkspace.realPath(bundle.path) else { return [] }
        return NSRunningApplication.runningApplications(withBundleIdentifier: AppInfo.bundleID)
            .filter { app in
                app.processIdentifier != getpid()
                    && app.bundleURL.flatMap { UpdateWorkspace.realPath($0.path) } == target
            }
    }

    private static func launchAndQuit(_ bundle: URL) -> Bool {
        let configuration = NSWorkspace.OpenConfiguration()
        // This process has the same bundle id; without this LaunchServices
        // would bring it to the front instead of starting the installed copy.
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: bundle, configuration: configuration) { _, error in
            DispatchQueue.main.async {
                if let error {
                    // The copy is in place; only the launch failed.
                    InstallMover.inform(L10n.shared.s.installMoveOpenFailedTitle,
                                        String(format: L10n.shared.s.installMoveOpenFailedMessageFormat,
                                               error.localizedDescription))
                    NSWorkspace.shared.activateFileViewerSelecting([bundle])
                }
                NSApp.terminate(nil)
            }
        }
        return true
    }

    private static func version(of bundle: URL) -> String? {
        // Read from the file, never through Bundle, which caches by path.
        NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String
    }

    private static func ask(_ title: String, _ message: String, confirm: String, cancel: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: cancel)
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func inform(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.shared.s.installMoveOK)
        NSApp.activate()
        alert.runModal()
    }

    private static func run(_ executable: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
