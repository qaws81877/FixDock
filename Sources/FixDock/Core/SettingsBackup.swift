// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import Foundation

/// Settings › Advanced › Settings backup: which keys travel, the file format,
/// and parsing a file someone picked. Pure; the panels, alerts and the writes
/// to UserDefaults live in `AdvancedSettings.swift`.
///
/// The file is an XML property list because the domain holds Data
/// (`textSnippets`), dates and reals, which JSON cannot carry as they are.
enum SettingsBackup {
    static let format = "fixdock-settings"
    static let formatVersion = 1

    /// State of this install or this Mac, not a choice someone made.
    static let excludedKeys: Set<String> = [
        // First-run state of this install.
        DefaultsKey.onboardingComplete,
        // Mirrors the login item macOS registered on this Mac.
        DefaultsKey.launchAtLoginWanted,
        // Update bookkeeping.
        DefaultsKey.updateLastCheckedAt,
        DefaultsKey.updateQuietVersion,
        // Stands in for a system audio grant that belongs to this Mac.
        DefaultsKey.recorderSystemAudioTapVerified,
        // Keyed by this Mac's display ids.
        DefaultsKey.screenshotLastRegions,
        // Developer-run arguments.
        DefaultsKey.airdropAutoZipFolderOverride,
        DefaultsKey.inputSwitchDeveloperClaim,
        DefaultsKey.permissionListNamesLegacy,
    ]

    /// AppKit and other system frameworks write window frames, panel sizes
    /// and last folders into the app's own domain (`NSWindow Frame …`,
    /// `NSNavPanelExpandedSizeForOpenMode`, `NSOSPLastRootDirectory`).
    static let excludedPrefixes = ["NS", "Apple", "com.apple."]

    private static let availabilityPrefix = DefaultsKey.featureAvailable("")

    static func isPortable(_ key: String) -> Bool {
        !excludedKeys.contains(key) && !excludedPrefixes.contains { key.hasPrefix($0) }
    }

    /// The part of the app's persistent domain a backup carries.
    static func portableSettings(_ domain: [String: Any]) -> [String: Any] {
        domain.filter { isPortable($0.key) }
    }

    static func exportData(settings: [String: Any], appVersion: String, exportedAt: Date) throws -> Data {
        let document: [String: Any] = [
            "format": format,
            "formatVersion": formatVersion,
            "appVersion": appVersion,
            "exportedAt": exportedAt,
            "settings": settings,
        ]
        return try PropertyListSerialization.data(fromPropertyList: document, format: .xml, options: 0)
    }

    /// "FixDock-Settings-2026-11-06.plist", for the save panel.
    static func exportFileName(on date: Date) -> String {
        "FixDock-Settings-\(stamp(date, "yyyy-MM-dd")).plist"
    }

    /// The automatic copy written before an import, one per second at most.
    static func safetyFileName(at date: Date) -> String {
        "FixDock-Settings-before-import-\(stamp(date, "yyyy-MM-dd-HHmmss")).plist"
    }

    private static func stamp(_ date: Date, _ pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }

    /// A parsed backup, already split so plain keys and tool availability
    /// cannot be written the same way: availability goes only through
    /// `FeatureRuntime.setAvailable`.
    struct Contents {
        /// Portable keys other than availability, as they were in the file.
        let plain: [String: Any]
        /// `AppFeature` raw value to installed.
        let availability: [String: Bool]
    }

    enum ParseError: Error, Equatable {
        case notPropertyList
        case notFixDockSettings
        case unsupportedVersion
    }

    static func parse(_ data: Data) -> Result<Contents, ParseError> {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let document = plist as? [String: Any]
        else { return .failure(.notPropertyList) }
        guard document["format"] as? String == format,
              let settings = document["settings"] as? [String: Any]
        else { return .failure(.notFixDockSettings) }
        guard document["formatVersion"] as? Int == formatVersion else {
            return .failure(.unsupportedVersion)
        }
        var plain: [String: Any] = [:]
        var availability: [String: Bool] = [:]
        for (key, value) in settings where isPortable(key) {
            if key.hasPrefix(availabilityPrefix) {
                if let installed = value as? Bool {
                    availability[String(key.dropFirst(availabilityPrefix.count))] = installed
                }
            } else {
                plain[key] = value
            }
        }
        return .success(Contents(plain: plain, availability: availability))
    }
}
