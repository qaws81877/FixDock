// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import AppKit
import Carbon.HIToolbox
import CoreGraphics
import os

/// What the keyboard taps behind quit protection and text snippets cannot
/// report themselves.
///
/// While any process holds Secure Event Input, macOS stops showing keys to
/// event taps, so a tap callback never learns about it. Both reasons the
/// features go quiet, secure input and a tap that could not be created, are
/// therefore watched from here on a timer and written to the log (category
/// `keyTaps`, kept on disk so a failure can be read afterwards).
final class KeyTapHealth: ObservableObject {
    static let shared = KeyTapHealth()

    enum Client: String {
        case quitProtection = "quit protection"
        case textSnippets = "text snippets"
    }

    enum TapState: Equatable {
        case off
        case running
        /// `tapCreate` returned nil although the tap is wanted.
        case failed
    }

    /// Who macOS reports as holding Secure Event Input. The window server
    /// records the app that was frontmost when it was enabled, which is not
    /// always the process that enabled it, so the name is a hint.
    struct SecureInput: Equatable {
        let processIdentifier: pid_t?
        let applicationName: String?
        /// The reported process is gone. Secure input left on by a process
        /// that exited stays on until logout.
        let holderExited: Bool
    }

    static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "io.github.qaws81877.fixdock",
                            category: "keyTaps")

    @Published private(set) var secureInput: SecureInput?
    @Published private(set) var states: [Client: TapState] = [:]

    private var poll: Timer?
    private var secureInputSince: Date?

    func state(of client: Client) -> TapState { states[client] ?? .off }

    /// Called by the services on the main thread whenever their tap starts,
    /// stops or fails to start. Logs transitions only.
    func report(_ client: Client, _ state: TapState) {
        let old = self.state(of: client)
        guard old != state else { return }
        states[client] = state
        switch state {
        case .running: Self.note("\(client.rawValue): tap running")
        case .off: Self.note("\(client.rawValue): tap stopped")
        case .failed:
            Self.note("\(client.rawValue): tapCreate failed with Accessibility granted; retrying",
                      error: true)
        }
        updatePoll()
    }

    /// One health event: the unified log (kept on disk) and the journal the
    /// feedback report reads. Any thread.
    private static func note(_ message: String, error: Bool = false) {
        if error {
            log.error("\(message, privacy: .public)")
        } else {
            log.notice("\(message, privacy: .public)")
        }
        DiagnosticsJournal.shared.record(message)
    }

    /// Called from the tap callbacks, on any thread.
    static func logTapDisabled(_ client: Client, type: CGEventType, rearmed: Bool) {
        let reason = type == .tapDisabledByTimeout ? "timeout" : "user input"
        note("\(client.rawValue): tap disabled by \(reason); re-armed \(rearmed)", error: true)
    }

    // MARK: Secure input

    /// Polls only while a tap is wanted. Two cheap reads every two seconds.
    private func updatePoll() {
        let wanted = states.values.contains { $0 != .off }
        guard wanted else {
            poll?.invalidate()
            poll = nil
            setSecureInput(nil)
            return
        }
        guard poll == nil else { return }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            self?.refreshSecureInput()
        }
        poll = timer
        RunLoop.main.add(timer, forMode: .common)
        refreshSecureInput()
    }

    func refreshSecureInput() {
        guard states.values.contains(where: { $0 != .off }), IsSecureEventInputEnabled() else {
            setSecureInput(nil)
            return
        }
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        let pid = (session?["kCGSSessionSecureInputPID"] as? NSNumber).map { pid_t($0.int32Value) }
        let app = pid.flatMap { NSRunningApplication(processIdentifier: $0) }
        let exited = pid.map { kill($0, 0) != 0 && errno == ESRCH } ?? false
        setSecureInput(SecureInput(processIdentifier: pid,
                                   applicationName: app?.localizedName ?? pid.flatMap(Self.processName),
                                   holderExited: exited))
    }

    private func setSecureInput(_ value: SecureInput?) {
        guard value != secureInput else { return }
        if let value {
            if secureInput == nil { secureInputSince = Date() }
            let pid = value.processIdentifier.map(String.init) ?? "unknown"
            let name = value.applicationName ?? "unknown"
            Self.note("secure input on: reported pid \(pid) (\(name))\(value.holderExited ? ", process gone" : ""); keys do not reach the taps")
        } else if secureInput != nil {
            let seconds = secureInputSince.map { Int(Date().timeIntervalSince($0)) } ?? 0
            Self.note("secure input off after \(seconds) s")
            secureInputSince = nil
        }
        secureInput = value
    }

    /// The executable name of a process that is not an app (no
    /// `NSRunningApplication`), such as `loginwindow`.
    private static func processName(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return URL(fileURLWithPath: String(cString: buffer)).lastPathComponent
    }
}
