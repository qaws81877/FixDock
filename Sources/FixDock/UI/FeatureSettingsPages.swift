// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import SwiftUI

/// A feature's own Settings page. Holding one proves the page exists in this
/// build; only `AppFeature.settingsPage` can make one.
struct FeaturePage: Hashable {
    let feature: AppFeature
    private let makeBody: () -> AnyView

    fileprivate init<Body: View>(_ feature: AppFeature, @ViewBuilder _ body: @escaping () -> Body) {
        self.feature = feature
        self.makeBody = { AnyView(body()) }
    }

    func body() -> AnyView { makeBody() }

    static func == (lhs: FeaturePage, rhs: FeaturePage) -> Bool {
        lhs.feature == rhs.feature
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(feature)
    }
}

extension AppFeature {
    /// The one place a module gives itself a Settings page. `nil` = no page in
    /// this build, so no sidebar row. No `default:` arm: a new case must decide
    /// here (compiler locally, check-shell.py in CI).
    var settingsPage: FeaturePage? {
        switch self {
        case .urlCleaner:
            return page { URLCleanerSettings() }
        case .quitWindowProtection:
            return page { QuitProtectionSettings() }
        case .cleaningMode:
            return page { CleaningModeSettings() }
        case .textSnippets:
            return page { TextSnippetsSettings() }
        case .mediaTools:
            return page { MediaSettings() }
        case .airdropAutoZip:
            return page { AirDropAutoZipSettingsPage() }
        case .cleaner:
            return page { CleanerSettings() }
        case .screenshot:
            return page { ScreenCaptureSettingsPage() }
        case .screenRecorder:
            // Its tab lives on the screenshot tool's "Screen capture" page.
            return nil
        }
    }

    /// The sidebar and page title. Screenshot's page holds both capture tools.
    func pageTitle(_ strings: Strings) -> String {
        self == .screenshot ? strings.screenCapturePageTitle : title(strings)
    }

    /// Binds the page to `self` so an arm cannot attach a body to the wrong feature.
    private func page<Body: View>(@ViewBuilder _ body: @escaping () -> Body) -> FeaturePage {
        FeaturePage(self, body)
    }
}
