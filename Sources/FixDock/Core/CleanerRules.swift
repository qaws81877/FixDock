// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import Foundation

/// What the cleaner can find, in display order. Raw values are stored in
/// nothing, so they may change.
enum CleanerCategory: String, CaseIterable, Identifiable {
    case caches, logs, developer, browserCaches, downloads
    case leftovers, loginItems, deviceBackups, largeDeveloper, trash

    var id: String { rawValue }

    enum Section { case safe, review }

    var section: Section {
        switch self {
        case .caches, .logs, .developer, .browserCaches, .downloads: return .safe
        case .leftovers, .loginItems, .deviceBackups, .largeDeveloper, .trash: return .review
        }
    }
}

/// The pure rules of the cleaner, adapted from upstream's CleanerSupport and
/// CleanerPolicy. Browser cache folders, the age limits and the unfinished
/// download suffixes are informed by tw93/mole (GPL-3.0); no mole code is
/// used. Free of the file system so every rule can be checked on its own.
///
/// The promise: nothing outside the roots below can ever become an item, an
/// item is only removed while it is still the very file that was scanned,
/// and a running app's data is never touched.
enum CleanerRules {
    static let ownBundlePrefix = "io.github.qaws81877"

    /// Logs younger than this are kept: an app may still be writing them.
    static let logAge: TimeInterval = 7 * 24 * 3600
    /// An unfinished download touched within this time may still be running.
    static let downloadAge: TimeInterval = 24 * 3600
    static let downloadSuffixes = [".download", ".crdownload", ".part", ".partial"]

    // MARK: - Roots, relative to the home folder

    static let developerPaths: [(path: String, owner: String)] = [
        ("Library/Developer/Xcode/DerivedData", "com.apple.dt.Xcode"),
        ("Library/Developer/Xcode/DocumentationCache", "com.apple.dt.Xcode"),
        ("Library/Developer/CoreSimulator/Caches", "com.apple.iphonesimulator"),
        ("Library/Developer/Xcode/iOS DeviceSupport", "com.apple.dt.Xcode"),
        ("Library/Developer/Xcode/watchOS DeviceSupport", "com.apple.dt.Xcode"),
        ("Library/Developer/Xcode/tvOS DeviceSupport", "com.apple.dt.Xcode"),
    ]

    static let largeDeveloperPaths: [(path: String, owner: String)] = [
        ("Library/Developer/Xcode/Archives", "com.apple.dt.Xcode"),
        ("Library/Developer/CoreSimulator/Devices", "com.apple.iphonesimulator"),
    ]

    /// Cache folders only; profiles, history, cookies and passwords live
    /// elsewhere and are never listed.
    static let browserCachePaths: [(path: String, owner: String, name: String)] = [
        ("Library/Caches/com.apple.Safari", "com.apple.Safari", "Safari"),
        ("Library/Caches/Google/Chrome", "com.google.Chrome", "Chrome"),
        ("Library/Caches/com.microsoft.edgemac", "com.microsoft.edgemac", "Edge"),
        ("Library/Caches/BraveSoftware/Brave-Browser", "com.brave.Browser", "Brave"),
        ("Library/Caches/company.thebrowser.Browser", "company.thebrowser.Browser", "Arc"),
        ("Library/Caches/Firefox", "org.mozilla.firefox", "Firefox"),
    ]

    static let deviceBackupPath = "Library/Application Support/MobileSync/Backup"
    static let launchAgentsPath = "Library/LaunchAgents"

    /// Upstream's leftover roots, the user Library only: the root-owned
    /// `/Library` copies would need administrator rights.
    static let leftoverRoots: [(path: String, usesContainerMetadata: Bool)] = [
        ("Application Support", false), ("Caches", false), ("Preferences", false),
        ("Preferences/ByHost", false), ("Saved Application State", false), ("HTTPStorages", false),
        ("WebKit", false), ("Logs", false), ("Containers", true), ("Cookies", false),
        ("PreferencePanes", false), ("Internet Plug-Ins", false), ("Services", false),
        ("QuickLook", false), ("Spotlight", false), ("Input Methods", false),
        ("Screen Savers", false), ("ColorPickers", false), ("Widgets", false),
        ("Address Book Plug-Ins", false), ("Contextual Menu Items", false),
        ("Safari/Extensions", false), ("Automator", false), ("CoreImage", false),
        ("Dictionaries", false), ("Components", false), ("Audio/Plug-Ins", false),
    ]

    // MARK: - Home and protected paths

    /// The scan refuses to start on anything else: an empty or relative
    /// home would turn every root above into a system path.
    static func isUsableHome(_ home: String) -> Bool {
        home.hasPrefix("/") && home != "/" && URL(fileURLWithPath: home).pathComponents.count >= 3
    }

    /// Exact paths never removed, whatever a scanner produced.
    static func protectedPaths(home: String) -> Set<String> {
        let system = ["/", "/Applications", "/Library", "/System", "/Users", "/usr", "/bin", "/sbin",
                      "/etc", "/var", "/private", "/opt", "/Volumes"]
        let user = ["", "/Library", "/Documents", "/Desktop", "/Downloads", "/Pictures", "/Music",
                    "/Movies", "/Applications", "/.Trash", "/Library/Caches", "/Library/Logs",
                    "/Library/Developer", "/Library/Application Support",
                    "/Library/Application Support/MobileSync", "/" + deviceBackupPath,
                    "/" + launchAgentsPath, "/Library/Logs/DiagnosticReports"]
        return Set(system).union(user.map { home + $0 })
    }

    static func isDirectChild(_ path: String, of root: String) -> Bool {
        (path as NSString).deletingLastPathComponent == root
    }

    // MARK: - Caches

    /// Never listed: this app, and entries known to break things when
    /// removed (audio, Settings panels, sign-ins, plugin licences).
    private static let hiddenCachePrefixes = [
        ownBundlePrefix,
        "CloudKit", "com.apple.bird",
        "com.apple.coreaudio", "com.apple.audio.", "coreaudiod",
        "com.apple.systempreferences", "com.apple.controlcenter",
        "com.apple.finder", "com.apple.dock",
        "com.apple.FontRegistry", "com.apple.ATS",
        "com.apple.akd", "com.apple.AuthKit",
        "com.paceap.", "com.native-instruments", "com.fabfilter",
        "com.spotify.client",
    ]

    /// Shown, never pre-checked: content the person paid bandwidth for.
    private static let sensitiveCachePrefixes = ["ms-playwright"]

    /// Plain-named folders known to be pure downloads or build output.
    private static let safePlainNameCaches: Set<String> = [
        "homebrew", "pip", "node-gyp", "yarn", "npm",
        "electron", "cypress", "typescript", "puppeteer",
    ]

    static func isExcludedCacheEntry(_ name: String) -> Bool {
        let lowered = name.lowercased()
        if lowered.hasSuffix(".localized") { return true }
        return hiddenCachePrefixes.contains { lowered.hasPrefix($0.lowercased()) }
    }

    /// Apple caches rebuild eagerly, so they are listed but not pre-checked;
    /// third-party ones are, and plain names only when known to be safe.
    static func precheckCacheEntry(_ name: String) -> Bool {
        guard !isExcludedCacheEntry(name) else { return false }
        let lowered = name.lowercased()
        if sensitiveCachePrefixes.contains(where: { lowered.hasPrefix($0.lowercased()) }) { return false }
        if looksLikeBundleID(name) { return !lowered.hasPrefix("com.apple.") }
        return safePlainNameCaches.contains(lowered)
    }

    static func isUnfinishedDownload(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return !lowered.hasPrefix(".") && downloadSuffixes.contains { lowered.hasSuffix($0) }
    }

    // MARK: - Bundle identifiers (upstream CleanerSupport)

    static let sharedInfrastructurePrefixes = [
        "org.sparkle-project", "com.plausiblelabs", "com.crashlytics",
        "com.segment", "io.sentry", "com.amplitude", "com.rollbar",
        "com.google.keystone", "com.google.softwareupdate", "org.cups",
        "org.swift",
    ]

    /// Never a junk owner: the system's domains in any wrapping, this app,
    /// and infrastructure other vendors embed.
    static func isProtectedBundleID(_ id: String) -> Bool {
        let lowered = id.lowercased()
        let wrapped = "." + lowered + "."
        if wrapped.contains(".com.apple.") || wrapped.contains("." + ownBundlePrefix + ".")
            || wrapped.contains(".developer.apple.") || wrapped.contains(".is.workflow.") {
            return true
        }
        if lowered == "com.apple" || lowered == ownBundlePrefix { return true }
        return sharedInfrastructurePrefixes.contains { lowered == $0 || lowered.hasPrefix($0 + ".") }
    }

    static func looksLikeBundleID(_ name: String) -> Bool {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return false }
        for part in parts {
            guard !part.isEmpty else { return false }
            for scalar in part.unicodeScalars {
                let ok = (scalar >= "a" && scalar <= "z") || (scalar >= "A" && scalar <= "Z")
                    || (scalar >= "0" && scalar <= "9") || scalar == "-" || scalar == "_"
                guard ok else { return false }
            }
        }
        return true
    }

    static func isTeamIdentifier(_ raw: String) -> Bool {
        let value = raw.uppercased()
        guard raw == value, value.count == 10 else { return false }
        return value.unicodeScalars.allSatisfy { ($0 >= "A" && $0 <= "Z") || ($0 >= "0" && $0 <= "9") }
    }

    /// The owning bundle id in a Library entry name, nil when it does not
    /// clearly belong to one bundle.
    static func bundleIDCandidate(fromEntryName rawName: String) -> String? {
        var name = rawName
        let lowered = name.lowercased()
        if let suffix = [".plist", ".log", ".savedState", ".binarycookies", ".prefPane",
                         ".qlgenerator", ".mdimporter", ".service", ".appex",
                         ".plugin", ".webplugin", ".saver", ".colorPicker",
                         ".wdgt", ".app", ".framework", ".component", ".vst",
                         ".vst3", ".clap", ".dpm", ".aaxplugin", ".dictionary",
                         ".safariextz", ".mailbundle"].first(where: { lowered.hasSuffix($0.lowercased()) }) {
            name.removeLast(suffix.count)
        }
        name = strippingTrailingUUIDComponent(name)
        for prefix in ["group.", "systemgroup."] where name.hasPrefix(prefix) {
            name.removeFirst(prefix.count)
        }
        let parts = name.split(separator: ".")
        if parts.count >= 3, isTeamIdentifier(String(parts[0])) {
            name = parts.dropFirst().joined(separator: ".")
        }
        return isAttributableBundleID(name) ? name : nil
    }

    static func isAttributableBundleID(_ name: String) -> Bool {
        !containsUUIDComponent(name) && looksLikeBundleID(name)
            && name.split(separator: ".").allSatisfy { part in
                part.unicodeScalars.contains { ($0 >= "a" && $0 <= "z") || ($0 >= "A" && $0 <= "Z") }
            }
    }

    static func strippingTrailingUUIDComponent(_ name: String) -> String {
        guard let lastDot = name.lastIndex(of: ".") else { return name }
        let last = String(name[name.index(after: lastDot)...])
        guard last.count == 36, containsUUIDComponent(last) else { return name }
        return String(name[..<lastDot])
    }

    /// Shared containers need signed entitlement evidence the cleaner does
    /// not have, so it leaves them alone.
    static func hasSharedContainerWrapper(_ rawName: String) -> Bool {
        let lowered = rawName.lowercased()
        if lowered.hasPrefix("group.") || lowered.hasPrefix("systemgroup.") { return true }
        guard let first = rawName.split(separator: ".").first else { return false }
        return isTeamIdentifier(String(first))
    }

    static func containsUUIDComponent(_ name: String) -> Bool {
        let lengths = [8, 4, 4, 4, 12]
        let scalars = Array(name.unicodeScalars)
        func isHex(_ s: Unicode.Scalar) -> Bool {
            (s >= "0" && s <= "9") || (s >= "a" && s <= "f") || (s >= "A" && s <= "F")
        }
        var index = 0
        while index < scalars.count {
            var cursor = index
            var matched = true
            for (group, length) in lengths.enumerated() {
                for _ in 0..<length {
                    guard cursor < scalars.count, isHex(scalars[cursor]) else { matched = false; break }
                    cursor += 1
                }
                guard matched else { break }
                if group < lengths.count - 1 {
                    guard cursor < scalars.count, scalars[cursor] == "-" else { matched = false; break }
                    cursor += 1
                }
            }
            if matched { return true }
            index += 1
        }
        return false
    }

    private static let hostingNamespaces: Set<String> = ["github", "gitlab", "bitbucket", "sourceforge", "googlecode"]

    /// A vendor with anything installed keeps its whole namespace alive.
    static func sharesVendorNamespace(candidate: String, withInstalled installed: Set<String>) -> Bool {
        func namespace(_ id: String) -> String? {
            let parts = id.split(separator: ".")
            guard parts.count >= 2, !hostingNamespaces.contains(String(parts[1])) else { return nil }
            return parts[0] + "." + parts[1]
        }
        guard let candidateNamespace = namespace(candidate.lowercased()) else { return false }
        return installed.contains { namespace($0) == candidateNamespace }
    }

    /// The exact id, or a dot-separated prefix either way.
    static func isOwned(candidate: String, byInstalled installed: Set<String>) -> Bool {
        let lowered = candidate.lowercased()
        if installed.contains(lowered) { return true }
        return installed.contains { lowered.hasPrefix($0 + ".") || $0.hasPrefix(lowered + ".") }
    }

    // MARK: - Launch agents

    static func executablePaths(inLaunchPlist plist: [String: Any]) -> [String] {
        var paths: [String] = []
        if let program = plist["Program"] as? String, program.hasPrefix("/") { paths.append(program) }
        if let arguments = plist["ProgramArguments"] as? [Any],
           let first = arguments.first as? String, first.hasPrefix("/") { paths.append(first) }
        if let bundleProgram = plist["BundleProgram"] as? String, bundleProgram.hasPrefix("/") {
            paths.append(bundleProgram)
        }
        return paths
    }

    /// An orphan only when it names executables and every one is gone.
    static func launchPlistIsRemovableOrphan(label: String?, executables: [String],
                                             executableExists: (String) -> Bool) -> Bool {
        if let label, isProtectedBundleID(label) { return false }
        guard !executables.isEmpty else { return false }
        return !executables.contains(where: executableExists)
    }
}
