// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import Foundation

/// Identity of this unofficial fork. The upstream name, site, update feed,
/// and signing identity are intentionally absent.
enum AppInfo {
    static let name = "FixDock"
    static let bundleID = "io.github.qaws81877.fixdock"
    static let developerBundleID = "io.github.qaws81877.fixdock.dev"
    static let copyright = "© 2026 Vorssaint. FixDock is a modified unofficial fork."
    static let repositoryURL = URL(string: "https://github.com/qaws81877/FixDock")!
    static let upstreamURL = URL(string: "https://github.com/vorssaint/vorssaint-utils")!
    static let licenseURL = URL(string: "https://www.gnu.org/licenses/gpl-3.0.en.html")!

    /// The bundle version. The fallback applies to a bare binary, never the
    /// shipped app, which reads its Info.plist.
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    static var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    /// The local "FixDock (Developer)" build (bundle id ends in `.dev`).
    static var isDeveloperBuild: Bool {
        (Bundle.main.bundleIdentifier ?? "").hasSuffix(".dev")
    }
}
