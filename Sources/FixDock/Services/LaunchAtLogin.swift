// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import Foundation
import ServiceManagement

/// Launch at login. The stored choice and the Service Management record are
/// updated together so Settings does not drift from what the next login does.
enum LaunchAtLogin {
    private static let operationQueue = DispatchQueue(
        label: "io.github.qaws81877.fixdock.launch-at-login", qos: .userInitiated)

    enum Registration {
        case enabled, needsApproval, off
    }

    struct UnstableLocationError: LocalizedError {
        var errorDescription: String? { L10n.shared.s.launchAtLoginNeedsApplications }
    }

    struct NeedsApprovalError: LocalizedError {
        var errorDescription: String? { L10n.shared.s.launchAtLoginNeedsApproval }
    }

    static var registration: Registration {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .needsApproval
        default: return .off
        }
    }

    static var isEnabled: Bool { registration == .enabled }

    /// A registration made from a build folder does not survive the next
    /// rebuild. Only a copy in /Applications is a stable login item.
    static var locationIsUnstable: Bool {
        !Bundle.main.bundlePath.hasPrefix("/Applications/")
    }

    static func refresh(_ completion: @escaping (Registration) -> Void) {
        operationQueue.async {
            let current = registration
            DispatchQueue.main.async { completion(current) }
        }
    }

    static func setEnabled(_ enabled: Bool,
                           completion: @escaping (Registration, Error?) -> Void) {
        operationQueue.async {
            let failure: Error?
            do {
                try setEnabledNow(enabled)
                failure = nil
            } catch {
                failure = error
            }
            let current = registration
            DispatchQueue.main.async { completion(current, failure) }
        }
    }

    /// Restores a registration the system dropped, and adopts an enable the
    /// person made in System Settings. Called once at startup.
    static func repairAtStartup() {
        operationQueue.async {
            let defaults = UserDefaults.standard
            let wanted = defaults.bool(forKey: DefaultsKey.launchAtLoginWanted)
            let current = registration
            if current == .enabled, !wanted {
                defaults.set(true, forKey: DefaultsKey.launchAtLoginWanted)
                return
            }
            if wanted, current == .off, !locationIsUnstable {
                try? SMAppService.mainApp.register()
            }
        }
    }

    private static func setEnabledNow(_ enabled: Bool) throws {
        if enabled, locationIsUnstable { throw UnstableLocationError() }
        UserDefaults.standard.set(enabled, forKey: DefaultsKey.launchAtLoginWanted)
        var failure: Error?
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            failure = error
        }
        if enabled, registration == .needsApproval { throw NeedsApprovalError() }
        if let failure, isEnabled != enabled {
            UserDefaults.standard.set(isEnabled, forKey: DefaultsKey.launchAtLoginWanted)
            throw failure
        }
    }
}
