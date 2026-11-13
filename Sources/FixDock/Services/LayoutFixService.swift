// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import AppKit
import Combine

/// The Korean/English layout fix: a word typed on the wrong layout is typed
/// again in the other one when it is finished. This service turns the
/// preferences and what it can see of the Mac into a mode, loads the word
/// lists while the tool is on, and hands the shared typing tap what it
/// judges with. It reads no key and posts none; `TypingTap` does both.
/// Requires Accessibility (the tap).
final class LayoutFixService: ObservableObject {
    static let shared = LayoutFixService()

    /// What the settings page and the panel row show.
    @Published private(set) var mode = LayoutFixMode.off
    /// Apps the person turned the tool off for, by bundle identifier.
    @Published private(set) var ignoredApps: [String] = []

    private var lists: (latin: Lexicon, hangul: Lexicon)?
    private var listsState = LayoutFixListsState.notLoaded
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var permissionWatch: AnyCancellable?

    private init() {
        // The other fixer starting or quitting, and a change of input source.
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            let token = workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                if app?.bundleIdentifier == LayoutFixPolicy.otherFixerBundleID { self?.syncWithPreferences() }
            }
            observers.append((workspace, token))
        }
        let distributed = DistributedNotificationCenter.default()
        let token = distributed.addObserver(
            forName: InputSwitchCapsLock.sourceChangedNotification, object: nil, queue: .main
        ) { [weak self] _ in
            TypingTap.shared.inputSourceChanged()
            self?.syncWithPreferences()
        }
        observers.append((distributed, token))
        permissionWatch = Permissions.shared.$accessibility
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.syncWithPreferences() }
    }

    /// Main thread.
    func syncWithPreferences() {
        let defaults = UserDefaults.standard
        let stored = defaults.stringArray(forKey: DefaultsKey.layoutFixIgnoredApps) ?? []
        if stored != ignoredApps { ignoredApps = stored }

        let wanted = AppFeature.layoutFix.isAvailable && defaults.bool(forKey: DefaultsKey.layoutFixEnabled)
        if wanted, listsState == .notLoaded {
            loadLists()
        } else if !wanted, listsState != .loading {
            // Off means nothing lives: the lists are a few megabytes.
            lists = nil
            listsState = .notLoaded
        }

        let otherFixer = NSRunningApplication
            .runningApplications(withBundleIdentifier: LayoutFixPolicy.otherFixerBundleID).first
        let facts = LayoutFixFacts(
            installed: AppFeature.layoutFix.isAvailable,
            enabled: defaults.bool(forKey: DefaultsKey.layoutFixEnabled),
            accessibility: AXIsProcessTrusted(),
            mayRun: !AppInfo.isDeveloperBuild || defaults.bool(forKey: DefaultsKey.layoutFixDeveloperClaim),
            otherFixer: otherFixer.map { $0.localizedName ?? LayoutFixPolicy.otherFixerBundleID },
            layoutKnown: InputSwitchCapsLock.currentSourceID().map(LayoutFixPolicy.knownSourceIDs.contains) ?? false,
            lists: listsState)
        let newMode = LayoutFixPolicy.mode(facts)
        if newMode != mode { mode = newMode }

        if newMode == .active, let lists {
            TypingTap.shared.setLayoutFix(LayoutFixConsumer.Config(
                rules: LayoutFixRules(latin: lists.latin, hangul: lists.hangul),
                ignoredApps: Set(stored)))
        } else {
            TypingTap.shared.setLayoutFix(nil)
        }
    }

    func ignore(_ bundleID: String) {
        guard !ignoredApps.contains(bundleID) else { return }
        UserDefaults.standard.set(ignoredApps + [bundleID], forKey: DefaultsKey.layoutFixIgnoredApps)
        syncWithPreferences()
    }

    func stopIgnoring(_ bundleID: String) {
        UserDefaults.standard.set(ignoredApps.filter { $0 != bundleID }, forKey: DefaultsKey.layoutFixIgnoredApps)
        syncWithPreferences()
    }

    /// Reads and sorts both lists off the main thread; until it is done the
    /// tool rests.
    private func loadLists() {
        listsState = .loading
        let whileTypingMaxRank = LayoutFixThresholds().whileTypingMaxRank
        DispatchQueue.global(qos: .utility).async { [weak self] in
            func list(_ name: String, _ language: TypedSource) -> Lexicon? {
                guard let url = Bundle.main.url(forResource: name, withExtension: "txt", subdirectory: "Lexicon"),
                      let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                return Lexicon.load(text, as: language, whileTypingMaxRank: whileTypingMaxRank)
            }
            let latin = list("en", .latin)
            let hangul = list("ko", .hangul2)
            DispatchQueue.main.async {
                guard let self, self.listsState == .loading else { return }
                if let latin, let hangul {
                    self.lists = (latin, hangul)
                    self.listsState = .ready
                } else {
                    self.listsState = .missing
                }
                self.syncWithPreferences()
            }
        }
    }
}
