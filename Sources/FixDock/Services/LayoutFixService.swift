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
    /// Chromium and Electron apps give their text to Accessibility only when
    /// asked to, and a field that does not answer is never erased in. While
    /// the tool is active, such an app in front is asked (owner decision,
    /// 2026-11-13, after Discord); the attribute set, by process, is set
    /// back when the tool stops being active or FixDock quits.
    private var textAccess: [pid_t: CFString] = [:]
    /// Apps asked once already, switched on or not: never asked again.
    private var textAsked: Set<pid_t> = []
    /// The attribute that switches a bundle's text on, nil for an app that
    /// gives it anyway.
    private var textSwitches: [URL: CFString?] = [:]

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
        let workspace = NSWorkspace.shared.notificationCenter
        let activated = workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil,
                                              queue: .main) { [weak self] note in
            guard let self, self.mode == .active,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self.openTextAccess(app)
        }
        let terminated = workspace.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil,
                                               queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.textAccess[app.processIdentifier] = nil
            self?.textAsked.remove(app.processIdentifier)
        }
        observers += [(workspace, activated), (workspace, terminated)]
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
        closeLeftTextAccess()
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

        if newMode == .active {
            if let front = NSWorkspace.shared.frontmostApplication { openTextAccess(front) }
        } else {
            closeTextAccess()
        }

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

    /// Main thread. Asks a Chromium or Electron app for its text, once.
    private func openTextAccess(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard !textAsked.contains(pid), !ignoredApps.contains(app.bundleIdentifier ?? ""),
              let bundle = app.bundleURL, let attribute = textSwitch(bundle) else { return }
        textAsked.insert(pid)
        let element = AXUIElementCreateApplication(pid)
        // A stuck app must not hold the main thread, where the plans run.
        AXUIElementSetMessagingTimeout(element, 0.15)
        // Already on (an assistive app turned it on): left alone, and left on.
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, attribute, &value) == .success, (value as? Bool) == true { return }
        // Electron takes its switch but always reads it back as off; Chrome
        // answers "not implemented" and switches it on all the same. Either
        // one counts.
        let set = AXUIElementSetAttributeValue(element, attribute, kCFBooleanTrue)
        var after: CFTypeRef?
        let readOn = AXUIElementCopyAttributeValue(element, attribute, &after) == .success && (after as? Bool) == true
        guard set == .success || readOn else { return }
        textAccess[pid] = attribute
        rememberTextAccess()
    }

    /// Main thread. Sets back what `openTextAccess` set, in the apps still running.
    func closeTextAccess() {
        for (pid, attribute) in textAccess {
            let element = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(element, 0.15)
            AXUIElementSetAttributeValue(element, attribute, kCFBooleanFalse)
        }
        textAccess = [:]
        textAsked = []
        rememberTextAccess()
    }

    /// What is switched on, by process and launch time, so that a FixDock
    /// that crashed sets it back on its next start.
    private func rememberTextAccess() {
        let running = NSWorkspace.shared.runningApplications
        let entries: [String] = textAccess.compactMap { pid, attribute in
            guard let launched = running.first(where: { $0.processIdentifier == pid })?.launchDate else { return nil }
            return "\(pid) \(launched.timeIntervalSinceReferenceDate) \(attribute)"
        }
        UserDefaults.standard.set(entries, forKey: DefaultsKey.layoutFixTextAccess)
    }

    /// At start: sets back what an earlier run left on in apps still running.
    private func closeLeftTextAccess() {
        let entries = UserDefaults.standard.stringArray(forKey: DefaultsKey.layoutFixTextAccess) ?? []
        let running = NSWorkspace.shared.runningApplications
        for entry in entries {
            let parts = entry.split(separator: " ")
            guard parts.count == 3, let pid = pid_t(parts[0]), let launched = Double(parts[1]),
                  let app = running.first(where: { $0.processIdentifier == pid }),
                  let started = app.launchDate?.timeIntervalSinceReferenceDate,
                  abs(started - launched) < 0.01 else { continue }
            let element = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(element, 0.15)
            AXUIElementSetAttributeValue(element, String(parts[2]) as CFString, kCFBooleanFalse)
        }
        UserDefaults.standard.removeObject(forKey: DefaultsKey.layoutFixTextAccess)
    }

    /// Electron's own switch for an Electron app; the one assistive apps
    /// use for a Chromium browser, which does not take Electron's back. A
    /// Chromium browser is told by its framework, not its name: it keeps its
    /// renderer helper inside, as Chrome's "Google Chrome Framework" and
    /// Aside's "Aside Framework" do (owner, 2026-11-14: Aside was never
    /// asked, so nothing was fixed there).
    private func textSwitch(_ bundle: URL) -> CFString? {
        if let known = textSwitches[bundle] { return known }
        let folder = bundle.appendingPathComponent("Contents/Frameworks")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let frameworks = names.filter { $0.hasSuffix(" Framework.framework") }
        let found: CFString?
        if frameworks.contains(where: { $0.contains("Electron") }) {
            found = "AXManualAccessibility" as CFString
        } else if frameworks.contains(where: { name in
            ["Chrom", "Edge", "Brave"].contains { name.contains($0) }
                || ((try? FileManager.default.contentsOfDirectory(
                    atPath: folder.appendingPathComponent("\(name)/Versions/Current/Helpers").path)) ?? [])
                    .contains { $0.hasSuffix(" Helper (Renderer).app") }
        }) {
            found = "AXEnhancedUserInterface" as CFString
        } else {
            found = nil
        }
        textSwitches[bundle] = found
        return found
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
