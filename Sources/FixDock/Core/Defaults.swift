// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import Foundation

/// Preference keys for the shell. Feature availability keeps the upstream
/// `featureAvailable.<id>` form so a later module can read the same choice.
enum DefaultsKey {
    static let language = "appLanguage"
    static let onboardingComplete = "onboardingComplete"
    static let launchAtLoginWanted = "launchAtLoginWanted"
    static let panelShortcut = "panelShortcut"

    static func featureAvailable(_ id: String) -> String { "featureAvailable.\(id)" }
}

enum Defaults {
    static func register() {
        UserDefaults.standard.register(defaults: [
            DefaultsKey.onboardingComplete: false,
            DefaultsKey.launchAtLoginWanted: false,
        ])
    }
}
