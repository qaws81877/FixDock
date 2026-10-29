// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import AppKit
import ApplicationServices
import Combine
import CoreGraphics

/// Permissions the shell can explain and request. The shell itself needs
/// neither. Later capture and shortcut features will.
enum PermissionKind: String, CaseIterable, Identifiable {
    case accessibility
    case screenRecording
    case fullDiskAccess

    var id: String { rawValue }

    func title(_ strings: Strings) -> String {
        switch self {
        case .accessibility: return strings.permissionAccessibility
        case .screenRecording: return strings.permissionScreenRecording
        case .fullDiskAccess: return strings.permissionFullDiskAccess
        }
    }

    func detail(_ strings: Strings) -> String {
        switch self {
        case .accessibility: return strings.permissionAccessibilityDetail
        case .screenRecording: return strings.permissionScreenRecordingDetail
        case .fullDiskAccess: return strings.permissionFullDiskAccessDetail
        }
    }
}

/// Reads Accessibility and Screen Recording, and opens the System Settings
/// pane that grants them. Adapted from the upstream permission portal, reduced
/// to the two grants the planned tools use.
final class Permissions: ObservableObject {
    static let shared = Permissions()

    @Published private(set) var accessibility = false
    @Published private(set) var screenRecording = false
    @Published private(set) var fullDiskAccess = false

    private var pollTimer: Timer?
    private var pageVisible = false
    private var guideVisible = false

    private init() {}

    func isGranted(_ kind: PermissionKind) -> Bool {
        switch kind {
        case .accessibility: return accessibility
        case .screenRecording: return screenRecording
        case .fullDiskAccess: return fullDiskAccess
        }
    }

    func refresh() {
        accessibility = AXIsProcessTrusted()
        screenRecording = CGPreflightScreenCaptureAccess()
        fullDiskAccess = Self.probeFullDiskAccess()
    }

    /// There is no API to ask. A file only Full Disk Access can read
    /// answers it; failing that, folders TCC guards the same way. Adapted
    /// from upstream.
    static func probeFullDiskAccess() -> Bool {
        if let handle = FileHandle(forReadingAtPath: "/Library/Application Support/com.apple.TCC/TCC.db") {
            defer { try? handle.close() }
            if (try? handle.read(upToCount: 1))?.isEmpty == false { return true }
        }
        let home = NSHomeDirectory()
        return ["/Library/Safari", "/Library/Mail", "/Library/Messages"].contains {
            (try? FileManager.default.contentsOfDirectory(atPath: home + $0)) != nil
        }
    }

    /// Shows the system prompt when one exists, then floats the guide.
    func request(_ kind: PermissionKind) {
        switch kind {
        case .accessibility:
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
        case .screenRecording:
            CGRequestScreenCaptureAccess()
        case .fullDiskAccess:
            break
        }
        refresh()
        if !isGranted(kind) {
            openSettings(for: kind)
            PermissionGuideOverlay.shared.show(for: kind)
        }
    }

    /// Drops this app's TCC entry and asks again. The entry is tied to the
    /// code signature, so a differently signed build can show a switch that
    /// does nothing until the entry is removed. `tccutil` does that for the
    /// current user's own entries.
    func startOver(_ kind: PermissionKind) {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let service: String
        switch kind {
        case .accessibility: service = "Accessibility"
        case .screenRecording: service = "ScreenCapture"
        case .fullDiskAccess: service = "SystemPolicyAllFiles"
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            task.arguments = ["reset", service, bundleID]
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            try? task.run()
            task.waitUntilExit()
            DispatchQueue.main.async {
                self?.refresh()
                self?.request(kind)
            }
        }
    }

    func openSettings(for kind: PermissionKind) {
        let pane: String
        switch kind {
        case .accessibility: pane = "Privacy_Accessibility"
        case .screenRecording: pane = "Privacy_ScreenCapture"
        case .fullDiskAccess: pane = "Privacy_AllFiles"
        }
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
        NSWorkspace.shared.open(url)
    }

    /// The guide and the permissions page ask for a short poll. With nothing
    /// on screen the app does not keep waking to re-read TCC. Each caller
    /// sets its own flag, so a repeated onAppear cannot leave the timer stuck.
    func setPageVisible(_ visible: Bool) {
        pageVisible = visible
        updatePoll()
    }

    func setGuideVisible(_ visible: Bool) {
        guideVisible = visible
        updatePoll()
    }

    private func updatePoll() {
        if pageVisible || guideVisible {
            guard pollTimer == nil else { return }
            let timer = Timer(timeInterval: 2.5, repeats: true) { _ in
                Permissions.shared.refresh()
            }
            pollTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        } else {
            pollTimer?.invalidate()
            pollTimer = nil
        }
    }
}
