// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import AppKit
import Carbon.HIToolbox
import Combine
import CoreGraphics

/// Text snippets: typing a trigger replaces it with its expansion, with
/// {{date}}, {{time}}, {{datetime}} and {{clipboard}} filled in. The key tap,
/// the observers and the snippet cache only exist while the feature is on;
/// off means nothing lives. Requires Accessibility (the tap).
///
/// Adapted from upstream without its snippet library, command bar, expansion
/// sound and Accessibility Keyboard handling.
final class TextSnippetService {
    static let shared = TextSnippetService()

    /// Marks our own synthetic events so the tap never re-processes them.
    private static let syntheticMarker = OwnKeyEvent.textSnippetMarker

    // The tap callback and its mutable text state live off the main thread so
    // demanding foreground apps cannot turn a main-thread stall into queued
    // keyboard input for the whole session.
    private let tapLifecycleLock = NSLock()
    private var tap: CFMachPort?
    private var tapRunLoop: CFRunLoop?
    private var tapThread: Thread?
    private var shouldStopTapThread = false
    private var pendingTapRestart = false
    private var activationObserver: NSObjectProtocol?
    private let inputLock = NSLock()
    private var buffer = ""
    private var permissionWatch: AnyCancellable?
    private var permissionPoll: Timer?
    /// Split by expansion mode at load time; the tap callback only scans.
    private var immediateSnippets: [TextSnippet] = []
    private var delimiterSnippets: [TextSnippet] = []

    private init() {
        SessionActivity.shared.onChange { [weak self] _ in self?.syncWithPreferences() }
        permissionWatch = Permissions.shared.$accessibility
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.syncWithPreferences() }
    }

    var isRunning: Bool { tapLifecycleLock.withLock { tap != nil } }

    func syncWithPreferences() {
        let enabled = AppFeature.textSnippets.isAvailable
            && UserDefaults.standard.bool(forKey: DefaultsKey.textSnippetsEnabled)
        reloadSnippets()
        let hasWork = inputLock.withLock {
            !(immediateSnippets.isEmpty && delimiterSnippets.isEmpty)
        }
        let trusted = AXIsProcessTrusted()
        updatePermissionPoll(waiting: enabled && hasWork && !trusted)
        if SessionActivitySupport.tapShouldRun(featureWanted: enabled && hasWork,
                                               accessibilityGranted: trusted,
                                               sessionIsActive: SessionActivity.shared.isActive) {
            start()
        } else {
            stop()
        }
    }

    /// A grant made in System Settings sends no notification. While the tap
    /// is wanted and cannot run, re-read the grant every few seconds.
    private func updatePermissionPoll(waiting: Bool) {
        guard waiting else {
            permissionPoll?.invalidate()
            permissionPoll = nil
            return
        }
        guard permissionPoll == nil else { return }
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            guard AXIsProcessTrusted() else { return }
            Permissions.shared.refresh()
            self?.syncWithPreferences()
        }
        permissionPoll = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Reloads the stored snippets; called by the settings page after edits.
    private func reloadSnippets() {
        let all = TextSnippetSupport.decode(
            UserDefaults.standard.data(forKey: DefaultsKey.textSnippets))
        inputLock.withLock {
            immediateSnippets = all.filter { $0.enabled && $0.expansion == .immediate }
            delimiterSnippets = all.filter { $0.enabled && $0.expansion == .afterDelimiter }
        }
    }

    private func start() {
        let thread = tapLifecycleLock.withLock { () -> Thread? in
            if tapThread != nil {
                if shouldStopTapThread { pendingTapRestart = true }
                return nil
            }
            shouldStopTapThread = false
            pendingTapRestart = false
            let thread = Thread { [weak self] in self?.runEventTap() }
            thread.name = "FixDock Text Expansion"
            thread.qualityOfService = .userInteractive
            tapThread = thread
            return thread
        }
        thread?.start()
    }

    private func stop() {
        let snapshot = tapLifecycleLock.withLock {
            () -> (runLoop: CFRunLoop?, tap: CFMachPort?, threadExists: Bool) in
            shouldStopTapThread = true
            pendingTapRestart = false
            return (tapRunLoop, tap, tapThread != nil)
        }
        if let tap = snapshot.tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoop = snapshot.runLoop {
            CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) {
                CFRunLoopStop(runLoop)
            }
            CFRunLoopWakeUp(runLoop)
        } else if !snapshot.threadExists {
            tapLifecycleLock.withLock {
                shouldStopTapThread = false
                tapThread = nil
            }
        }
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
            self.activationObserver = nil
        }
        resetBuffer()
    }

    private func runEventTap() {
        autoreleasepool {
            let runLoop = CFRunLoopGetCurrent()
            tapLifecycleLock.withLock { tapRunLoop = runLoop }
            guard !tapLifecycleLock.withLock({ shouldStopTapThread }) else {
                if clearEventTapThread() { startOnMain() }
                return
            }

            let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
                | (1 << CGEventType.leftMouseDown.rawValue)
                | (1 << CGEventType.rightMouseDown.rawValue)
            guard let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: { _, type, event, userInfo in
                    guard let userInfo else { return Unmanaged.passUnretained(event) }
                    let service = Unmanaged<TextSnippetService>.fromOpaque(userInfo)
                        .takeUnretainedValue()
                    return service.handle(type: type, event: event)
                },
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            ) else {
                _ = clearEventTapThread()
                return
            }

            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            tapLifecycleLock.withLock { self.tap = tap }
            CFRunLoopAddSource(runLoop, source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            DispatchQueue.main.async { [weak self] in self?.tapDidStart(tap) }

            if tapLifecycleLock.withLock({ shouldStopTapThread }) {
                CGEvent.tapEnable(tap: tap, enable: false)
            } else {
                CFRunLoopRun()
            }

            CGEvent.tapEnable(tap: tap, enable: false)
            CFRunLoopRemoveSource(runLoop, source, .commonModes)
            CFMachPortInvalidate(tap)
            if clearEventTapThread() { startOnMain() }
        }
    }

    private func clearEventTapThread() -> Bool {
        tapLifecycleLock.withLock {
            let shouldRestart = pendingTapRestart
            tap = nil
            tapRunLoop = nil
            tapThread = nil
            shouldStopTapThread = false
            pendingTapRestart = false
            return shouldRestart
        }
    }

    private func startOnMain() {
        DispatchQueue.main.async { [weak self] in self?.start() }
    }

    private func tapDidStart(_ startedTap: CFMachPort) {
        let active = tapLifecycleLock.withLock {
            tap === startedTap && !shouldStopTapThread
        }
        guard active, activationObserver == nil else { return }
        // Switching apps invalidates whatever was half-typed there.
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.resetBuffer()
        }
    }

    private func resetBuffer() {
        inputLock.withLock { buffer = "" }
    }

    // MARK: - Tap

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // stop() switches the tap off itself, and that is reported here
            // like a disable by the system. A stop under way has nothing to
            // recover.
            let currentTap = tapLifecycleLock.withLock { shouldStopTapThread ? nil : tap }
            if SessionActivity.shared.isActive, AXIsProcessTrusted(), let currentTap {
                CGEvent.tapEnable(tap: currentTap, enable: true)
            } else if currentTap != nil {
                DispatchQueue.main.async { [weak self] in self?.syncWithPreferences() }
            }
            return Unmanaged.passUnretained(event)
        }
        // Clicks move the caret somewhere unknown; the half-typed trigger is
        // no longer where the deletes would land.
        if type == .leftMouseDown || type == .rightMouseDown {
            resetBuffer()
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown else { return Unmanaged.passUnretained(event) }
        // Never react to our own synthetic typing.
        guard event.getIntegerValueField(.eventSourceUserData) != Self.syntheticMarker else {
            return Unmanaged.passUnretained(event)
        }
        // Password fields: the system enables secure input; typing there must
        // stay exactly as typed, and the buffer must not remember any of it.
        guard !IsSecureEventInputEnabled() else {
            resetBuffer()
            return Unmanaged.passUnretained(event)
        }
        // Shortcuts are commands, not text.
        if !event.flags.intersection([.maskCommand, .maskControl]).isEmpty {
            resetBuffer()
            return Unmanaged.passUnretained(event)
        }

        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        switch keyCode {
        case kVK_Delete:
            inputLock.withLock {
                if !buffer.isEmpty { buffer.removeLast() }
            }
            return Unmanaged.passUnretained(event)
        case kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow, kVK_Escape,
             kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown, kVK_ForwardDelete:
            resetBuffer()
            return Unmanaged.passUnretained(event)
        default:
            break
        }

        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &length, unicodeString: &characters)
        guard length > 0 else { return Unmanaged.passUnretained(event) }
        let typed = String(utf16CodeUnits: characters, count: length)

        if let first = typed.first, TextSnippetSupport.delimiters.contains(first) {
            // A delimiter can complete an afterDelimiter trigger. The typed
            // delimiter is swallowed and kept after the replacement, either
            // in the same paste or as the original key after typed injection.
            let matched = inputLock.withLock { () -> (snippet: TextSnippet, deleteCount: Int, typedTrigger: String)? in
                let match = TextSnippetSupport.expansionMatch(buffer: buffer,
                                                              expansion: .afterDelimiter,
                                                              snippets: delimiterSnippets,
                                                              swallowed: "")
                buffer = ""
                return match
            }
            if let matched {
                return expand(matched.snippet,
                              deleteCount: matched.deleteCount,
                              typedTrigger: matched.typedTrigger,
                              trailingKeyCode: CGKeyCode(keyCode),
                              trailingFlags: event.flags,
                              trailingText: typed,
                              failureKeyCode: CGKeyCode(keyCode))
                    ? nil
                    : Unmanaged.passUnretained(event)
            }
            return Unmanaged.passUnretained(event)
        }

        let matched = inputLock.withLock { () -> (snippet: TextSnippet, deleteCount: Int, typedTrigger: String)? in
            buffer = TextSnippetSupport.bufferAppending(buffer, typed: typed)
            let match = TextSnippetSupport.expansionMatch(buffer: buffer,
                                                          expansion: .immediate,
                                                          snippets: immediateSnippets,
                                                          swallowed: typed)
            if match != nil { buffer = "" }
            return match
        }
        if let matched {
            // Suppress the final trigger event once the replacement path has
            // accepted it. A busy transient paste fails open to normal typing.
            return expand(matched.snippet,
                          deleteCount: matched.deleteCount,
                          typedTrigger: matched.typedTrigger,
                          trailingKeyCode: nil,
                          trailingFlags: [],
                          trailingText: "",
                          failureKeyCode: CGKeyCode(keyCode),
                          failureFlags: event.flags)
                ? nil
                : Unmanaged.passUnretained(event)
        }
        return Unmanaged.passUnretained(event)
    }

    // MARK: - Expansion

    @discardableResult
    private func expand(_ snippet: TextSnippet,
                        deleteCount: Int,
                        typedTrigger: String,
                        trailingKeyCode: CGKeyCode?,
                        trailingFlags: CGEventFlags,
                        trailingText: String,
                        failureKeyCode: CGKeyCode?,
                        failureFlags: CGEventFlags = []) -> Bool {
        let post = { () -> Bool in
            // Variable expansion is decided while the triggering event still
            // belongs to this callback. Only an explicit clipboard variable
            // pays for a synchronous read; the multiline write itself runs on
            // the shared pasteboard lane.
            let clipboard = TextSnippetSupport.needsClipboard(snippet.replacement)
                ? NSPasteboard.general.string(forType: .string)
                : nil
            let text = TextSnippetSupport.expand(
                snippet.replacement,
                date: Date(),
                clipboard: clipboard
            )
            return Self.postExpansion(deleteCount: deleteCount,
                                      typedTrigger: typedTrigger,
                                      text: text,
                                      trailingKeyCode: trailingKeyCode,
                                      trailingFlags: trailingFlags,
                                      trailingText: trailingText,
                                      failureKeyCode: failureKeyCode,
                                      failureFlags: failureFlags)
        }
        return Thread.isMainThread ? post() : DispatchQueue.main.sync(execute: post)
    }

    /// Whether one of this app's windows takes the keys. A panel that never
    /// activates the app, like the island's scratchpad, is key while the app
    /// behind it stays frontmost, and that app's field is not where the
    /// backspaces land. AppKit is read on the main thread, where both
    /// expansion paths post their backspaces; anywhere else counts as ours,
    /// so no other app is asked.
    private static var ownWindowIsKey: Bool {
        guard Thread.isMainThread else { return true }
        return MainActor.assumeIsolated { NSApp.keyWindow != nil }
    }

    /// `typedTrigger` is the text the `deleteCount` backspaces clear.
    @discardableResult
    static func postExpansion(deleteCount: Int,
                              typedTrigger: String,
                              text: String,
                              trailingKeyCode: CGKeyCode?,
                              trailingFlags: CGEventFlags,
                              trailingText: String = "",
                              failureKeyCode: CGKeyCode? = nil,
                              failureFlags: CGEventFlags = []) -> Bool {
        let source = CGEventSource(stateID: .hidSystemState)
        source?.userData = syntheticMarker

        func post(_ event: CGEvent?) {
            event?.post(tap: .cghidEventTap)
        }
        func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags = []) {
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down)
                event?.flags = flags
                post(event)
            }
        }
        // Asked right before the backspaces go out, so the count covers a
        // completion the field shows by then. Typing waits while the field
        // answers, so every question, up to five for a selection that looks
        // like a completion, shares one short time limit. Runs on the main
        // thread on the typed and the pasted path alike.
        func postDeletes() {
            guard deleteCount > 0 else { return }
            let app = ownWindowIsKey ? nil : NSWorkspace.shared.frontmostApplication
            let selection = app.flatMap {
                SelectedTextReader.focusedTextSelection(processID: $0.processIdentifier, timeout: 0.15)
            }
            let count = TextSnippetSupport.triggerDeleteCount(
                deleteCount, typed: typedTrigger,
                focusedSelection: selection.map { (range: $0.range, textLength: $0.textLength) }
            ) { selection?.text(in: $0) }
            for _ in 0..<count { postKey(CGKeyCode(kVK_Delete)) }
        }

        if TextSnippetSupport.requiresPaste(text) {
            let payload = TextSnippetSupport.pastePayload(text: text, trailingText: trailingText)
            return TransientPaste.shared.paste(
                payload,
                willPostShortcut: { postDeletes() },
                didFail: {
                    if let failureKeyCode { postKey(failureKeyCode, flags: failureFlags) }
                }
            )
        }

        postDeletes()

        // Typed injection instead of pasting: the clipboard stays untouched.
        // Keystroke events carry at most ~20 UTF-16 units reliably.
        let units = Array(text.utf16)
        var index = 0
        while index < units.count {
            var end = min(index + 20, units.count)
            // Never split a surrogate pair across chunks: two lone halves in
            // separate events render as replacement characters in some apps.
            if end < units.count, UTF16.isLeadSurrogate(units[end - 1]) {
                end -= 1
            }
            let chunk = Array(units[index..<end])
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
                event.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                post(event)
            }
            index = end
        }

        if let trailingKeyCode {
            postKey(trailingKeyCode, flags: trailingFlags)
        }
        return true
    }
}
