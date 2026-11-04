// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import AppKit
import Combine

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

    @Published private(set) var pasteTargetName: String?

    var entries: [ClipboardHistoryEntry] { store.entries }
    var imageLocator: ClipboardImageLocator? { store.imageLocator }
    var storeProblem: ClipboardHistoryStoreProblem? { store.problem }
    var storeProblemItemURL: URL? { store.problemItemURL }

    /// What a Clear confirmation counts: only these go when it is confirmed.
    var unpinnedSnapshot: [UUID: Date] {
        Dictionary(uniqueKeysWithValues: entries.filter { !$0.isPinned }.map { ($0.id, $0.copiedAt) })
    }

    /// The service that exists, if any, so a FixDock write or quitting never
    /// creates it.
    private static var live: ClipboardHistoryService?
    private static let pasteboardTimeout: TimeInterval = 5
    private static let urlType = NSPasteboard.PasteboardType("public.url")
    private static let gifType = NSPasteboard.PasteboardType("com.compuserve.gif")

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
    private var pasteTarget: NSRunningApplication? {
        didSet { pasteTargetName = pasteTarget.map { $0.localizedName ?? $0.bundleIdentifier ?? "" } }
    }
    private var index = ClipboardHistoryIndex()
    private var resultsCache: (query: String, filter: ClipboardHistoryFilter, revision: Int,
                               items: [ClipboardHistoryItem])?
    private let mediaQueue = DispatchQueue(label: "io.github.qaws81877.fixdock.clipboard-history.media",
                                           qos: .utility)

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

    static func ownCopy(_ copy: ClipboardHistoryOwnCopy) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let live, live.isRecording, let own = Bundle.main.bundleIdentifier,
              !ClipboardIgnoredApps.shared.apps.contains(own) else { return }
        let observedAt = Date()
        switch copy {
        case .text(let raw):
            guard let text = ClipboardHistoryCapturePolicy.recordedText(plain: raw, webURL: nil,
                                                                        cleanLink: cleanerRule) else { return }
            live.record(.text(text), source: own, observedAt: observedAt)
        case .png(let bytes), .gif(let bytes):
            guard live.recordsMedia, bytes.count <= ClipboardImagePayload.maxBytes else { return }
            live.recordImage(bytes, source: own, observedAt: observedAt)
        }
    }

    // MARK: Entries

    /// Ranked for the window. SwiftUI asks many times per render, so the last
    func results(matching query: String, filter: ClipboardHistoryFilter) -> [ClipboardHistoryItem] {
        let revision = store.revision
        if let cache = resultsCache, cache.query == query, cache.filter == filter, cache.revision == revision {
            return cache.items
        }
        let entries = entries
        if entries.isEmpty { index.clear() }
        let items = index.results(entries, query: query, filter: filter, stamp: revision)
            .compactMap { position -> ClipboardHistoryItem? in
                guard entries.indices.contains(position) else { return nil }
                let entry = entries[position]
                return ClipboardHistoryItem(entry: entry, kind: index.kind(of: entry))
            }
        resultsCache = (query, filter, revision, items)
        return items
    }

    func perform(_ action: ClipboardHistoryAction, on item: ClipboardHistoryItem) {
        switch action {
        case .paste: choose(item.entry, .paste)
        case .copyOnly: choose(item.entry, .copyOnly)
        case .togglePin: togglePin(item.entry)
        case .showInFinder: showInFinder(item.entry)
        case .delete: remove(item.entry)
        }
    }

    private func togglePin(_ entry: ClipboardHistoryEntry) {
        let pinned = entries.first { $0.id == entry.id }?.isPinned ?? entry.isPinned
        let now = Date()
        var fits = true
        mutate { fits = $0.setPinned(!pinned, id: entry.id, now: now) }
        if !fits { NSSound.beep() }
    }

    private func remove(_ entry: ClipboardHistoryEntry) {
        mutate { $0.remove(entry.id) }
    }

    func applyRetention() {
        let policy = retentionPolicy
        let now = Date()
        mutate { $0.applyRetention(policy, now: now) }
    }

    func clearUnpinned(confirmed: [UUID: Date]) {
        mutate { $0.clearUnpinned(confirmed: confirmed) }
    }

    private func mutate(_ change: (inout ClipboardHistoryRecords) -> Void) {
        objectWillChange.send()
        store.mutate(change)
    }

    private var recordsMedia: Bool {
        UserDefaults.standard.bool(forKey: DefaultsKey.clipboardHistoryRecordsMedia)
    }

    private func record(_ capture: ClipboardHistoryCapture, source: String?, observedAt: Date) {
        let policy = retentionPolicy
        objectWillChange.send()
        store.record(capture, source: source, now: observedAt)
        let now = Date()
        store.mutate { $0.applyRetention(policy, now: now) }
    }

    private func recordImage(_ bytes: Data, source: String?, observedAt: Date) {
        mediaQueue.async { [weak self] in
            let payload = ClipboardImagePayload.prepare(bytes: bytes)
            DispatchQueue.main.async {
                guard let self, let payload, self.isRecording, self.recordsMedia else { return }
                self.record(.image(payload), source: source, observedAt: observedAt)
            }
        }
    }

    private var retentionPolicy: ClipboardHistoryRetentionPolicy {
        let defaults = UserDefaults.standard
        return ClipboardHistoryRetentionPolicy(
            period: ClipboardHistoryRetention(storedDays: defaults.object(
                forKey: DefaultsKey.clipboardHistoryRetentionDays) as? Int),
            imageBudget: ClipboardHistoryImageBudget(storedMegabytes: defaults.object(
                forKey: DefaultsKey.clipboardHistoryImageBudgetMB) as? Int))
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
        let recordsMedia = recordsMedia
        GeneralPasteboardAccess.shared.async(timeout: Self.pasteboardTimeout, { isExpired in
            Self.readPasteboard(since: since, baseline: baseline, recordsMedia: recordsMedia, isExpired: isExpired)
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
            let observedAt = Date()
            let origin = read.origin
            // Called on every check: it also closes the window of apps that
            // were in front since the last one.
            let source = ClipboardIgnoredApps.shared.sourceSinceLastCheck(
                declared: origin?.sourceMark, remote: origin?.remote ?? false,
                historyPanelIsKey: historyPanelIsKey, historyPanelClosing: historyPanelClosing)
            guard let accepted = ClipboardHistoryChangeCount.accepted(
                read: read.changeCount, since: since, last: self.lastChangeCount) else { return }
            self.lastChangeCount = accepted
            guard let origin,
                  !ClipboardHistoryCapturePolicy.isOwnWrite(sourceMark: origin.sourceMark,
                                                            ownBundleID: Bundle.main.bundleIdentifier),
                  !source.fromHistoryPanel, !source.excluded else { return }
            switch read {
            case .text(_, let plain, let webURL, _):
                guard let text = ClipboardHistoryCapturePolicy.recordedText(plain: plain, webURL: webURL,
                                                                           cleanLink: Self.cleanerRule)
                else { return }
                self.record(.text(text), source: source.bundleID, observedAt: observedAt)
            case .files(_, let refs, _):
                guard self.recordsMedia, !refs.isEmpty else { return }
                self.record(.files(refs), source: source.bundleID, observedAt: observedAt)
            case .image(_, let bytes, _):
                guard self.recordsMedia else { return }
                self.recordImage(bytes, source: source.bundleID, observedAt: observedAt)
            case .unchanged, .skipped:
                return
            }
        }, didFinish: { [weak self] _ in
            self?.captureState.finish()
        })
    }

    private static func readPasteboard(since: Int, baseline: Bool, recordsMedia: Bool,
                                       isExpired: () -> Bool) -> ClipboardHistoryRead? {
        let pasteboard = NSPasteboard.general
        let changeCount = pasteboard.changeCount
        guard !isExpired() else { return nil }
        if baseline || changeCount == since { return .unchanged(changeCount: changeCount) }
        let types = (pasteboard.types ?? []).map(\.rawValue)
        var plan = ClipboardHistoryCapturePolicy.plan(forTypes: types, recordsMedia: recordsMedia)
        if case .skip(let skip) = plan { return .skipped(changeCount: changeCount, skip) }
        let origin = ClipboardHistoryOrigin(
            sourceMark: pasteboard.string(forType: .source),
            remote: types.contains(NSPasteboard.PasteboardType.remoteClipboard.rawValue))
        if plan != .text, ClipboardHistoryCapturePolicy.isOwnWrite(sourceMark: origin.sourceMark,
                                                                    ownBundleID: Bundle.main.bundleIdentifier) {
            return .skipped(changeCount: changeCount, .ownWrite, origin: origin)
        }
        if plan == .files {
            let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                              options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            let refs = ClipboardHistoryCapturePolicy.fileRefs(urls.map { ($0.path, $0.hasDirectoryPath) },
                                                              home: NSHomeDirectory())
            guard !isExpired() else { return nil }
            if !refs.isEmpty { return .files(changeCount: changeCount, refs, origin: origin) }
            plan = ClipboardHistoryCapturePolicy.plan(forTypes: types, recordsMedia: recordsMedia, realFiles: false)
        }
        switch plan {
        case .image(let type):
            guard let bytes = pasteboard.data(forType: NSPasteboard.PasteboardType(type)) else {
                return .skipped(changeCount: changeCount, .notRecorded, origin: origin)
            }
            guard bytes.count <= ClipboardImagePayload.maxBytes else {
                return .skipped(changeCount: changeCount, .tooLarge, origin: origin)
            }
            guard !isExpired() else { return nil }
            return .image(changeCount: changeCount, bytes, origin: origin)
        case .text:
            let plain = pasteboard.string(forType: .string)
            let webURL = webURLString(from: pasteboard)
            guard !isExpired() else { return nil }
            return .text(changeCount: changeCount, plain: plain, webURL: webURL, origin: origin)
        case .skip(let skip):
            return .skipped(changeCount: changeCount, skip, origin: origin)
        case .files:
            return .skipped(changeCount: changeCount, .notRecorded, origin: origin)
        }
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
    private func choose(_ entry: ClipboardHistoryEntry, _ how: ClipboardHistoryChoice) {
        let target = pasteTarget
        pasteTarget = nil
        hideWindow()
        write(entry.content) { [weak self] outcome in
            guard let self else { return }
            let changeCount: Int
            switch outcome {
            case .written(let count):
                changeCount = count
            case .gone:
                NSSound.beep()
                Self.toast(L10n.shared.s.clipboardHistoryToastUnavailable)
                return
            case nil:
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

    private enum WriteOutcome {
        case written(changeCount: Int)
        case gone
    }

    private enum WritePayload {
        case text(String)
        case data(Data, NSPasteboard.PasteboardType, tiff: Data?)
        case file(URL)
    }

    private func write(_ content: ClipboardHistoryContent, completion: @escaping (WriteOutcome?) -> Void) {
        guard !writeInFlight else {
            completion(nil)
            return
        }
        writeInFlight = true
        if case .text(let text) = content {
            writeToPasteboard(.text(text), completion: completion)
            return
        }
        let locator = store.imageLocator
        mediaQueue.async { [weak self] in
            let payload = Self.payload(for: content, locator: locator)
            DispatchQueue.main.async {
                guard let self else { return }
                guard let payload else {
                    self.writeInFlight = false
                    completion(.gone)
                    return
                }
                self.writeToPasteboard(payload, completion: completion)
            }
        }
    }

    private static func payload(for content: ClipboardHistoryContent, locator: ClipboardImageLocator?) -> WritePayload? {
        switch content {
        case .text(let text):
            return .text(text)
        case .image(let ref):
            guard let bytes = locator?.verifiedBytes(ref.name) else { return nil }
            if ref.name.format == .gif { return .data(bytes, gifType, tiff: nil) }
            return .data(bytes, .png, tiff: NSBitmapImageRep(data: bytes)?.tiffRepresentation)
        case .file(let file):
            guard FileManager.default.fileExists(atPath: file.path) else { return nil }
            return .file(URL(fileURLWithPath: file.path, isDirectory: file.isDirectory))
        }
    }

    private func writeToPasteboard(_ payload: WritePayload, completion: @escaping (WriteOutcome?) -> Void) {
        GeneralPasteboardAccess.shared.async(timeout: Self.pasteboardTimeout, { isExpired -> (changeCount: Int, written: Bool)? in
            guard !isExpired() else { return nil }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            let written: Bool
            switch payload {
            case .text(let text):
                pasteboard.declareAppSource()
                written = pasteboard.setString(text, forType: .string)
            case .data(let bytes, let type, let tiff):
                pasteboard.declareAppSource()
                written = pasteboard.setData(bytes, forType: type)
                if written, let tiff { _ = pasteboard.setData(tiff, forType: .tiff) }
            case .file(let url):
                written = pasteboard.writeObjects([url as NSURL])
                pasteboard.declareAppSource()
            }
            return (pasteboard.changeCount, written)
        }, then: { result in
            completion(result?.written == true ? result.map { .written(changeCount: $0.changeCount) } : nil)
        }, didFinish: { [weak self] result in
            self?.writeInFlight = false
            if let result { URLCleanerService.shared.ignoreChanges(upTo: result.changeCount) }
        })
    }

    private func showInFinder(_ entry: ClipboardHistoryEntry) {
        let url: URL
        switch entry.content {
        case .text:
            return
        case .image(let ref):
            guard let locator = store.imageLocator else {
                NSSound.beep()
                return
            }
            url = locator.url(for: ref.name)
        case .file(let file):
            url = URL(fileURLWithPath: file.path, isDirectory: file.isDirectory)
        }
        mediaQueue.async {
            let exists = FileManager.default.fileExists(atPath: url.path)
            DispatchQueue.main.async {
                guard exists else {
                    NSSound.beep()
                    Self.toast(L10n.shared.s.clipboardHistoryToastUnavailable)
                    return
                }
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
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
