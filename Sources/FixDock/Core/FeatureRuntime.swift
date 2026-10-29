// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import AppKit
import Combine

/// Bridges the feature catalog to live services.
///
/// A service is created only when its binding runs, and `syncAtLaunch` skips
/// anything that is not installed. URL cleaner, quit protection, cleaning
/// mode, text snippets, media, AirDrop auto-zip and the cleaner are wired.
/// The other catalog entries still only store the availability key.
final class FeatureRuntime: ObservableObject {
    static let shared = FeatureRuntime()

    /// Bumped on every availability change so observing views re-read the catalog.
    @Published private(set) var revision = 0

    /// Services that came to life in this process. Placeholders have no
    /// service, so they never enter the set and never ask for a restart.
    private var loadedThisSession = Set(AppFeature.allCases.filter { $0.isAvailable && $0.hasService })

    private init() {}

    /// True when a service that loaded this session is now uninstalled.
    var needsRestartToUnload: Bool {
        loadedThisSession.contains { !$0.isAvailable }
    }

    var installedFeatures: [AppFeature] {
        AppFeature.allCases.filter(\.isAvailable)
    }

    func syncAtLaunch() {
        for feature in AppFeature.allCases where feature.isAvailable && feature.hasService {
            loadedThisSession.insert(feature)
            Self.bindings[feature]?()
        }
    }

    /// Installs or uninstalls. Off tears a loaded service down immediately.
    /// On remembers the choice and, once a binding exists, starts the service.
    /// Saved choices are the availability keys themselves; there is no second copy.
    func setAvailable(_ features: [AppFeature], _ available: Bool) {
        var changed = false
        for feature in features where feature.isAvailable != available {
            UserDefaults.standard.set(available, forKey: feature.availabilityKey)
            if available {
                feature.enableOnFirstInstall()
                if feature.hasService { loadedThisSession.insert(feature) }
            }
            Self.bindings[feature]?()
            if available { requestMissingPermissions(for: feature) }
            changed = true
        }
        if changed { revision += 1 }
    }

    /// Only on install, never at launch: a tool someone chose not to grant
    /// yet should not prompt on every start. Settings keeps the request.
    private func requestMissingPermissions(for feature: AppFeature) {
        Permissions.shared.refresh()
        if let kind = feature.requiredPermissions.first(where: { !Permissions.shared.isGranted($0) }) {
            Permissions.shared.request(kind)
        }
    }

    /// Later steps add a closure per module, in catalog order.
    private static let bindings: [AppFeature: () -> Void] = [
        .urlCleaner: { URLCleanerService.shared.syncWithPreferences() },
        .quitWindowProtection: { QuitProtectionService.shared.syncWithPreferences() },
        .cleaningMode: { CleaningModeManager.shared.syncWithPreferences() },
        .textSnippets: { TextSnippetService.shared.syncWithPreferences() },
        .mediaTools: { MediaService.shared.syncWithPreferences() },
        .airdropAutoZip: { AirDropAutoZipService.shared.syncWithPreferences() },
        .cleaner: { CleanerService.shared.syncWithPreferences() },
    ]
}
