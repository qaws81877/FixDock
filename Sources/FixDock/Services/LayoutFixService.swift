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
    /// Words undone often enough to be left as typed (5.8), in the order
    /// they were learned.
    @Published private(set) var learnedWords: [LearnedKey] = []

    private let learnedStore = LayoutFixLearnedStore(
        fileURL: PrivateFileStore.containerURL?.appendingPathComponent(LayoutFixLearnedStore.fileName))

    private var lists: (latin: Lexicon, hangul: Lexicon)?
    private var listsState = LayoutFixListsState.notLoaded
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var permissionWatch: AnyCancellable?
    private var otherFixerWatch: AnyCancellable?

    private init() {
        TypingTap.shared.layoutFixNotices = { [weak self] notices in
            guard let self else { return }
            for case .reverted(let key) in notices {
                self.learnedStore.mutate { $0.countRevert(key, now: Date()) }
            }
            self.syncWithPreferences()
        }
        // The other fixer starting or quitting. The launch and terminate
        // notices skip menu bar (LSUIElement) apps, so the running list
        // itself is watched (owner list A, 2026-11-13).
        otherFixerWatch = NSWorkspace.shared.publisher(for: \.runningApplications)
            .map { $0.contains { $0.bundleIdentifier == LayoutFixPolicy.otherFixerBundleID } }
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.syncWithPreferences() }
        // A change of input source.
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

        var learned: [LearnedKey] = []
        if case .ready(let records) = learnedStore.state {
            let threshold = LayoutFixThresholds().learnAfterReverts
            learned = records.entries.filter { $0.reverts >= threshold }.sorted { $0.updatedAt < $1.updatedAt }
                .map { LearnedKey(keys: $0.keys, source: $0.source) }
        }
        if learned != learnedWords { learnedWords = learned }

        if newMode == .active, let lists {
            var rules = LayoutFixRules(latin: lists.latin, hangul: lists.hangul)
            rules.learned = Set(learned)
            TypingTap.shared.setLayoutFix(LayoutFixConsumer.Config(rules: rules, ignoredApps: Set(stored)))
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

    /// The word is fixed again, and has to be undone as often again to be
    /// learned. Does nothing while the store is unavailable.
    func forget(_ key: LearnedKey) {
        learnedStore.mutate { $0.forget(key) }
        syncWithPreferences()
    }

    /// Every count, learned or not. Does nothing while the store is unavailable.
    func forgetAll() {
        learnedStore.mutate { $0.forgetAll() }
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
