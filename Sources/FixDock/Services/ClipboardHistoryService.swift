// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import AppKit
import Combine

/// Text-only clipboard history, restored from upstream and cut to text.
///
/// It runs its own poll on the shared pasteboard lane. FixDock's own writes
/// are left out two ways: the source mark every FixDock writer sets, and the
/// change count every writer reports through
/// `URLCleanerService.ignoreChanges(upTo:)`, which forwards here. The second
/// also covers `TransientPaste`, whose paste and restore carry no mark. Both
/// reports are enqueued on main from inside the writer's lane job, so they
/// run before the completion of any history read queued after that write.
final class ClipboardHistoryService: ObservableObject {
    static let shared = ClipboardHistoryService()

    /// True while the poll runs: installed, switched on, and the file read.
    @Published private(set) var isRecording = false

    var entries: [ClipboardHistoryEntry] { store.entries }
    var storeProblem: ClipboardHistoryStoreProblem? { store.problem }
    var storeFileURL: URL? { store.fileURL }

    /// What a Clear confirmation counts: only these go when it is confirmed.
    var unpinnedSnapshot: [UUID: Date] {
        Dictionary(uniqueKeysWithValues: entries.filter { !$0.isPinned }.map { ($0.id, $0.copiedAt) })
    }

    /// The service that exists, if any, so a FixDock write or quitting never
    /// creates it.
    private static var live: ClipboardHistoryService?
    private static let pasteboardTimeout: TimeInterval = 5
    private static let urlType = NSPasteboard.PasteboardType("public.url")

    private let store: ClipboardHistoryStore
    private var window: ClipboardHistoryWindow?
    /// The last change count accounted for: this service's reads and every
    /// FixDock write reported through `ownWriteSettled`.
    private var lastChangeCount = 0
    private var captureState = ClipboardHistoryCaptureState()
    private var timer: Timer?
    /// Entries age out with nothing new copied, so retention also runs on
    /// its own clock.
    private var retentionTimer: Timer?
    /// At most one write queued or running, even after its caller timed out,
    /// so a stuck provider cannot pile up choices.
    private var writeInFlight = false
    private var pasteTarget: NSRunningApplication?
    private var searchCache = ClipboardHistorySearchCache()
    private var filterCache: (query: String, revision: Int, result: [ClipboardHistoryEntry])?

    private init() {
        store = ClipboardHistoryStore(fileURL: PrivateFileStore.containerURL?
            .appendingPathComponent(ClipboardHistoryStore.fileName))
        Self.live = self
    }

    // MARK: Binding, funnel, quit

    func syncWithPreferences() {
        let hotkeys = HotkeyManager.shared
        if AppFeature.clipboardHistory.isAvailable,
           UserDefaults.standard.bool(forKey: DefaultsKey.clipboardHistoryEnabled) {
            hotkeys.actions[.clipboardHistory] = { [weak self] in self?.toggleWindow() }
            // An unreadable file leaves nothing to record into; the window
            // and Settings say why.
            if store.problem == nil { start() } else { stop() }
        } else {
            hotkeys.actions[.clipboardHistory] = nil
            stop()
            hideWindow()
        }
        hotkeys.sync()
    }

    /// Main thread. Raises the live service's watermark past a FixDock write.
    static func ownWriteSettled(upTo changeCount: Int) {
        guard let live else { return }
        live.lastChangeCount = max(live.lastChangeCount, changeCount)
    }

    static func flushIfLoaded() {
        live?.store.flush()
    }

    // MARK: Entries

    /// Ranked for the window. SwiftUI asks many times per render, so the last
    /// result is reused until the query or the history changes.
    func filteredEntries(matching query: String) -> [ClipboardHistoryEntry] {
        let revision = store.revision
        if let cache = filterCache, cache.query == query, cache.revision == revision { return cache.result }
        let entries = entries
        let result: [ClipboardHistoryEntry]
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || entries.isEmpty {
            if entries.isEmpty { searchCache.clear() }
            result = entries
        } else {
            let candidates = searchCache.candidates(for: entries, stamp: revision)
            result = ClipboardHistorySearch.rankedIndexes(candidates: candidates, matching: query)
                .compactMap { entries.indices.contains($0) ? entries[$0] : nil }
        }
        filterCache = (query, revision, result)
        return result
    }

    func togglePin(_ entry: ClipboardHistoryEntry) {
        let pinned = entries.first { $0.id == entry.id }?.isPinned ?? entry.isPinned
        let now = Date()
        var fits = true
        mutate { fits = $0.setPinned(!pinned, id: entry.id, now: now) }
        if !fits { NSSound.beep() }
    }

    func remove(_ entry: ClipboardHistoryEntry) {
        mutate { $0.remove(entry.id) }
    }

    func applyRetention() {
        let retention = retention
        let now = Date()
        mutate { $0.applyRetention(retention, now: now) }
    }

    func clearUnpinned(confirmed: [UUID: Date]) {
        mutate { $0.clearUnpinned(confirmed: confirmed) }
    }

    private func mutate(_ change: (inout ClipboardHistoryRecords) -> Void) {
        objectWillChange.send()
        store.mutate(change)
    }

    private var retention: ClipboardHistoryRetention {
        ClipboardHistoryRetention(storedDays: UserDefaults.standard.object(
            forKey: DefaultsKey.clipboardHistoryRetentionDays) as? Int)
    }

    // MARK: Capture

    private func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.8, repeats: true) { [weak self] _ in
            self?.captureIfChanged()
        }
        timer.tolerance = 0.25
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        let retentionTimer = Timer(timeInterval: 3_600, repeats: true) { [weak self] _ in
            self?.applyRetention()
        }
        retentionTimer.tolerance = 600
        RunLoop.main.add(retentionTimer, forMode: .common)
        self.retentionTimer = retentionTimer
        isRecording = true
        ClipboardIgnoredApps.shared.setHistoryRunning(true)
        captureState.restart()
        applyRetention()
        captureIfChanged()
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        retentionTimer?.invalidate()
        retentionTimer = nil
        if isRecording { isRecording = false }
        ClipboardIgnoredApps.shared.setHistoryRunning(false)
        captureState.invalidate()
    }

    /// `historyPanelClosing` is the window's last check as it closes, so a
    /// copy made in it is known as the window's.
    private func captureIfChanged(historyPanelClosing: Bool = false) {
        guard isRecording, let generation = captureState.begin() else { return }
        // On start, a fresh baseline before anything is recorded, so what was
        // on the clipboard before is not taken as a new copy.
        let baseline = captureState.needsBaseline
        let since = lastChangeCount
        // Taken before the read, which may answer only after the window took
        // the keys: a copy made before it opened came from the app behind.
        let historyPanelIsKey = historyPanelClosing || window?.isKey == true
        GeneralPasteboardAccess.shared.async(timeout: Self.pasteboardTimeout, { isExpired in
            Self.readPasteboard(since: since, baseline: baseline, isExpired: isExpired)
        }, then: { [weak self] read in
            guard let self else { return }
            guard let read else {
                // A deadline invalidates now; the in-flight slot is held
                // until the read really ends (didFinish).
                self.captureState.expire(generation)
                return
            }
            guard self.isRecording, self.captureState.accepts(generation) else { return }
            if baseline {
                self.lastChangeCount = max(self.lastChangeCount, read.changeCount)
                self.captureState.didBaseline()
                return
            }
            var mark: String?
            var remote = false
            if case .text(_, _, _, let sourceMark, let isRemote) = read {
                mark = sourceMark
                remote = isRemote
            }
            // Called on every check: it also closes the window of apps that
            // were in front since the last one.
            let source = ClipboardIgnoredApps.shared.sourceSinceLastCheck(
                declared: mark, remote: remote,
                historyPanelIsKey: historyPanelIsKey, historyPanelClosing: historyPanelClosing)
            guard let accepted = ClipboardHistoryChangeCount.accepted(
                read: read.changeCount, since: since, last: self.lastChangeCount) else { return }
            self.lastChangeCount = accepted
            guard case .text(_, let plain, let webURL, _, _) = read,
                  !ClipboardHistoryCapturePolicy.isOwnWrite(sourceMark: mark,
                                                            ownBundleID: Bundle.main.bundleIdentifier),
                  !source.fromHistoryPanel, !source.excluded,
                  // The tracked original stays in these locals; only the
                  // cleaned link reaches the records.
                  let text = ClipboardHistoryCapturePolicy.recordedText(plain: plain, webURL: webURL,
                                                                       cleanLink: Self.cleanerRule)
            else { return }
            let retention = self.retention
            let now = Date()
            self.mutate {
                $0.record(text, now: now)
                $0.applyRetention(retention, now: now)
            }
        }, didFinish: { [weak self] _ in
            self?.captureState.finish()
        })
    }

    /// Runs on the lane. A secret, transient or non-text copy is judged by
    /// its types and its content is never read.
    private static func readPasteboard(since: Int, baseline: Bool, isExpired: () -> Bool) -> ClipboardHistoryRead? {
        let pasteboard = NSPasteboard.general
        let changeCount = pasteboard.changeCount
        guard !isExpired() else { return nil }
        if baseline || changeCount == since { return .unchanged(changeCount: changeCount) }
        let types = (pasteboard.types ?? []).map(\.rawValue)
        if let skip = ClipboardHistoryCapturePolicy.skip(forTypes: types) {
            return .skipped(changeCount: changeCount, skip)
        }
        let plain = pasteboard.string(forType: .string)
        let webURL = webURLString(from: pasteboard)
        guard !isExpired() else { return nil }
        return .text(changeCount: changeCount, plain: plain, webURL: webURL,
                     sourceMark: pasteboard.string(forType: .source),
                     remote: types.contains(NSPasteboard.PasteboardType.remoteClipboard.rawValue))
    }

    /// The link as written first, as the URL cleaner reads it, so both clean
    /// the same spelling; the URL object only when there is no such text.
    private static func webURLString(from pasteboard: NSPasteboard) -> String? {
        for type in [urlType, NSPasteboard.PasteboardType("NSURLPboardType")] {
            if let value = pasteboard.string(forType: type), let url = URL(string: value), isWebURL(url) {
                return value
            }
        }
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]
        return urls?.first(where: isWebURL)?.absoluteString
    }

    private static func isWebURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return (scheme == "http" || scheme == "https") && url.host != nil
    }

    /// The URL cleaner's own rule while it runs; nil keeps the link as copied.
    private static func cleanerRule(_ text: String) -> String? {
        let cleaner = URLCleanerService.shared
        guard cleaner.isRunning, let result = cleaner.clean(text), !result.removed.isEmpty else { return nil }
        return result.url
    }

    // MARK: Window

    func toggleWindow() {
        if window?.isVisible == true {
            hideWindow()
        } else {
            showWindow()
        }
    }

    func hideWindow() {
        guard let window, window.isVisible else { return }
        // What was copied in the window is read now, as the window's, so a
        // copy made right after in the app behind is credited to that app.
        captureIfChanged(historyPanelClosing: true)
        window.orderOut()
    }

    /// Return or Command-Return. The window leaves at once; the paste waits
    /// for the write, or it would paste whatever was on the clipboard before.
    func choose(_ entry: ClipboardHistoryEntry, _ how: ClipboardHistoryChoice) {
        let target = pasteTarget
        pasteTarget = nil
        hideWindow()
        write(entry.text) { [weak self] changeCount in
            guard let self else { return }
            guard let changeCount else {
                NSSound.beep()
                return
            }
            let now = Date()
            self.mutate { $0.touch(entry.id, now: now) }
            // No target: the window opened over FixDock or an app without a
            // Dock icon, where a choice is only a copy.
            guard how == .paste, let target else { return }
            guard AXIsProcessTrusted() else {
                Self.toast(L10n.shared.s.clipboardHistoryToastNeedsAccessibility)
                return
            }
            self.paste(into: target, expecting: changeCount)
        }
    }

    private func showWindow() {
        rememberPasteTarget()
        let window = window ?? ClipboardHistoryWindow(service: self)
        self.window = window
        // A copy made just before opening is read while the window does not
        // hold the keys yet, so it keeps the app it came from.
        captureIfChanged()
        window.present()
    }

    private func rememberPasteTarget() {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier,
              app.activationPolicy == .regular,
              !app.isTerminated
        else {
            pasteTarget = nil
            return
        }
        pasteTarget = app
    }

    // MARK: Write and paste back

    /// Lane, clear, source mark, text, change count. `didFinish` runs even
    /// when the deadline already answered nil, and reports the count through
    /// the funnel every FixDock writer uses.
    private func write(_ text: String, completion: @escaping (Int?) -> Void) {
        guard !writeInFlight else {
            completion(nil)
            return
        }
        writeInFlight = true
        GeneralPasteboardAccess.shared.async(timeout: Self.pasteboardTimeout, { isExpired -> (changeCount: Int, written: Bool)? in
            guard !isExpired() else { return nil }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.declareAppSource()
            let written = pasteboard.setString(text, forType: .string)
            return (pasteboard.changeCount, written)
        }, then: { result in
            completion(result?.written == true ? result?.changeCount : nil)
        }, didFinish: { [weak self] result in
            self?.writeInFlight = false
            if let result { URLCleanerService.shared.ignoreChanges(upTo: result.changeCount) }
        })
    }

    /// The window never activates FixDock, so the target is normally still
    /// in front. It is asked to come forward only when it is not; macOS 14's
    /// cooperative activation may refuse that, and the gate then leaves the
    /// entry copied.
    private func paste(into target: NSRunningApplication, expecting changeCount: Int) {
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != target.processIdentifier {
            target.activate()
        }
        waitToPaste(into: target, expecting: changeCount, attempt: 0)
    }

    private func waitToPaste(into target: NSRunningApplication, expecting changeCount: Int, attempt: Int) {
        let decision = ClipboardHistoryPasteGate.decide(
            frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
            targetPID: target.processIdentifier,
            targetTerminated: target.isTerminated,
            ownWindowIsKey: NSApp.keyWindow != nil,
            attempt: attempt)
        switch decision {
        case .post:
            TransientPaste.postPaste(expectingChangeCount: changeCount) { posted in
                if !posted { Self.toast(L10n.shared.s.clipboardHistoryToastCopied) }
            }
        case .wait:
            DispatchQueue.main.asyncAfter(deadline: .now() + ClipboardHistoryPasteGate.pollInterval) { [weak self] in
                self?.waitToPaste(into: target, expecting: changeCount, attempt: attempt + 1)
            }
        case .giveUp:
            Self.toast(L10n.shared.s.clipboardHistoryToastCopied)
        }
    }

    private static func toast(_ text: String) {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) }
        ScreenshotToastController.shared.show(text: text, on: screen)
    }
}
