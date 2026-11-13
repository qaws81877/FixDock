// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import AppKit
import Carbon.HIToolbox
import Combine
import CoreGraphics

/// The one key tap the typing tools share. It turns each event into a
/// `RawKey` and hands it to `TypingGate` (`Core/TypingSupport.swift`), which
/// says what to do with it; the tools themselves hold no tap and post
/// nothing. A plan that comes back runs on the main thread while the gate
/// holds what is typed meanwhile, and its output and the held keys are
/// posted here, from the tap's own callback, so nothing overtakes anything.
/// The tap, the observers and the typed text only exist while a tool wants
/// them. Requires Accessibility.
///
/// Its tools are text snippets and the Korean/English layout fix; the tap
/// reports its health under the name of each one that is on.
final class TypingTap {
    static let shared = TypingTap()

    /// Marks our own synthetic events so the tap never re-processes them.
    private static let outputMarker = OwnKeyEvent.textSnippetMarker
    /// Marks a key given back after a hold that had to be given up, and the
    /// kick. Never put on the fast switch's key.
    private static let relayMarker = OwnKeyEvent.typingRelayMarker

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
    /// Guards `gate`, `kept` and `kickWaiters`, and every key event this
    /// file posts is posted while it is held, so the order of posts is the
    /// order of lock acquisitions. Nothing slow happens under it.
    private let stateLock = NSLock()
    private var gate = TypingGate()
    /// Copies of the events the gate said to keep, by ticket.
    private var kept: [Int: CGEvent] = [:]
    /// What the executor wants to hear once its output has been posted
    /// (true) or its hold is gone (false). Called on the main thread.
    private var kickWaiters: [(plan: PlanID, done: (Bool) -> Void)] = []
    private let watchdogQueue = DispatchQueue(label: "FixDock Typing Watchdog", qos: .userInteractive)
    private var permissionWatch: AnyCancellable?
    private var permissionPoll: Timer?
    private var tapRetry: Timer?

    private init() {
        SessionActivity.shared.onChange { [weak self] _ in self?.evaluate() }
        permissionWatch = Permissions.shared.$accessibility
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.evaluate() }
    }

    private var isRunning: Bool { tapLifecycleLock.withLock { tap != nil } }

    private var isWanted: Bool { !wantedClients.isEmpty }

    private var wantedClients: [KeyTapHealth.Client] {
        stateLock.withLock {
            (gate.snippets == nil ? [] : [.textSnippets]) + (gate.layoutFix == nil ? [] : [.layoutFix])
        }
    }

    /// The tap's state, told to the health log for each tool that is on;
    /// a tool that is off reads as off.
    private var tapState = KeyTapHealth.TapState.off
    private func report(_ state: KeyTapHealth.TapState? = nil) {
        if let state { tapState = state }
        let wanted = wantedClients
        for client in [KeyTapHealth.Client.textSnippets, .layoutFix] {
            KeyTapHealth.shared.report(client, wanted.contains(client) ? tapState : .off)
        }
    }

    /// nil when text snippets are off or have nothing to expand. What was
    /// half-typed stays.
    func setSnippets(_ config: SnippetConsumer.Config?) {
        stateLock.withLock { gate.snippets = config.map { SnippetConsumer(config: $0) } }
        evaluate()
        report()
    }

    /// Main thread: what the layout fix's plans tell its service.
    var layoutFixNotices: (([LayoutFixNotice]) -> Void)?

    /// nil when the layout fix is off or resting.
    func setLayoutFix(_ config: LayoutFixConsumer.Config?) {
        stateLock.withLock { gate.layoutFix = config.map { LayoutFixConsumer(config: $0) } }
        evaluate()
        report()
    }

    private func evaluate() {
        let wanted = isWanted
        let trusted = AXIsProcessTrusted()
        updatePermissionPoll(waiting: wanted && !trusted)
        if SessionActivitySupport.tapShouldRun(featureWanted: wanted,
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
            self?.evaluate()
        }
        permissionPoll = timer
        RunLoop.main.add(timer, forMode: .common)
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
        cancelTapRetry()
        report(.off)
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
        releaseHold()
    }

    private func runEventTap() {
        autoreleasepool {
            let runLoop = CFRunLoopGetCurrent()
            tapLifecycleLock.withLock { tapRunLoop = runLoop }
            guard !tapLifecycleLock.withLock({ shouldStopTapThread }) else {
                if clearEventTapThread() { startOnMain() }
                return
            }

            // flagsChanged is here for the kick alone; every other one passes.
            let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
                | (1 << CGEventType.flagsChanged.rawValue)
                | (1 << CGEventType.leftMouseDown.rawValue)
                | (1 << CGEventType.rightMouseDown.rawValue)
                | (1 << CGEventType.otherMouseDown.rawValue)
            guard let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: { proxy, type, event, userInfo in
                    guard let userInfo else { return Unmanaged.passUnretained(event) }
                    let typingTap = Unmanaged<TypingTap>.fromOpaque(userInfo)
                        .takeUnretainedValue()
                    return typingTap.handle(proxy: proxy, type: type, event: event)
                },
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            ) else {
                // Accessibility reads as granted, yet the window server
                // refused the tap. Say so and try again rather than staying
                // off silently.
                _ = clearEventTapThread()
                DispatchQueue.main.async { [weak self] in self?.tapDidFail() }
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

    private func tapDidFail() {
        // A stop or a new start since then owns the state.
        guard !isRunning, tapLifecycleLock.withLock({ tapThread == nil }) else { return }
        guard isWanted, AXIsProcessTrusted() else { return }
        report(.failed)
        guard tapRetry == nil else { return }
        let timer = Timer(timeInterval: 3, repeats: false) { [weak self] _ in
            self?.tapRetry = nil
            self?.evaluate()
        }
        tapRetry = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func cancelTapRetry() {
        tapRetry?.invalidate()
        tapRetry = nil
    }

    private func tapDidStart(_ startedTap: CFMachPort) {
        let active = tapLifecycleLock.withLock {
            tap === startedTap && !shouldStopTapThread
        }
        guard active else { return }
        cancelTapRetry()
        report(.running)
        guard activationObserver == nil else { return }
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        stateLock.withLock { gate.frontApp = front }
        // Switching apps invalidates whatever was half-typed there.
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.appChanged(to: app?.bundleIdentifier)
        }
    }

    /// Main thread: macOS says the input source changed. The keys that
    /// usually do it are caught as they arrive; this covers every other way
    /// (the menu, a shortcut the tap passes, another tool).
    func inputSourceChanged() {
        stateLock.withLock { gate.sourceDidChange() }
    }

    private func appChanged(to bundleID: String?) {
        stateLock.withLock {
            gate.frontApp = bundleID
            gate.reset()
        }
    }

    // MARK: - Tap

    private func handle(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // stop() switches the tap off itself, and that is reported here
            // like a disable by the system. A stop under way has nothing to
            // recover.
            let currentTap = tapLifecycleLock.withLock { shouldStopTapThread ? nil : tap }
            let rearm = currentTap != nil && SessionActivity.shared.isActive && AXIsProcessTrusted()
            if currentTap != nil {
                KeyTapHealth.logTapDisabled(.textSnippets, type: type, rearmed: rearm)
            }
            // Keys went by unseen: a hold cannot be kept in order any more.
            releaseHold()
            if rearm, let currentTap {
                CGEvent.tapEnable(tap: currentTap, enable: true)
            } else if currentTap != nil {
                DispatchQueue.main.async { [weak self] in self?.evaluate() }
            }
            return Unmanaged.passUnretained(event)
        }
        let userData = event.getIntegerValueField(.eventSourceUserData)
        let now = ProcessInfo.processInfo.systemUptime
        if type == .flagsChanged {
            // The executor's kick: its output is ready. Swallowed; a real
            // modifier change passes.
            guard userData == Self.relayMarker else {
                // Caps Lock and the Globe key can switch the input source.
                let modifier = event.getIntegerValueField(.keyboardEventKeycode)
                if modifier == Int64(kVK_CapsLock) || modifier == Int64(kVK_Function) {
                    let failed = stateLock.withLock { () -> [(Bool) -> Void] in
                        perform(gate.sourceMayChange(), proxy: proxy)
                        return waitersOfLostPlans()
                    }
                    if !failed.isEmpty { DispatchQueue.main.async { failed.forEach { $0(false) } } }
                }
                return Unmanaged.passUnretained(event)
            }
            let secureInput = IsSecureEventInputEnabled()
            let (start, failed, posted, notices) = stateLock.withLock {
                () -> (ClaimedPlan?, [(Bool) -> Void], [(Bool) -> Void], [LayoutFixNotice]) in
                // A kick that outlived its hold posts nothing.
                let failed = waitersOfLostPlans()
                let response = gate.kick(secureInput: secureInput, now: now)
                perform(response.commands, proxy: proxy)
                let posted = kickWaiters.map(\.done)
                kickWaiters = []
                return (response.start, failed, posted, response.notices)
            }
            if !failed.isEmpty || !posted.isEmpty || !notices.isEmpty {
                DispatchQueue.main.async { [weak self] in
                    failed.forEach { $0(false) }
                    posted.forEach { $0(true) }
                    if !notices.isEmpty { self?.layoutFixNotices?(notices) }
                }
            }
            if let start { self.start(start) }
            return nil
        }
        let raw: RawKey
        var secureInput = false
        switch type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            raw = RawKey(kind: .mouseDown, origin: .physical,
                         stroke: KeyStroke(keyCode: 0, rawFlags: 0), isRepeat: false, characters: "")
        case .keyDown:
            let origin = OwnKeyEvent.origin(ofUserData: userData)
            var length = 0
            var characters = [UniChar](repeating: 0, count: 4)
            if origin == .physical {
                secureInput = IsSecureEventInputEnabled()
                event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &length, unicodeString: &characters)
            }
            raw = RawKey(kind: .keyDown,
                         origin: origin,
                         stroke: KeyStroke(keyCode: UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode)),
                                           rawFlags: event.flags.rawValue),
                         isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
                         characters: String(utf16CodeUnits: characters, count: length))
        default:
            return Unmanaged.passUnretained(event)
        }
        let (response, failed) = stateLock.withLock { () -> (GateResponse, [(Bool) -> Void]) in
            let response = gate.receive(raw, secureInput: secureInput, now: now)
            if let ticket = response.keep, kept[ticket] == nil { kept[ticket] = event.copy() }
            perform(response.commands, proxy: proxy)
            return (response, waitersOfLostPlans())
        }
        if !failed.isEmpty { DispatchQueue.main.async { failed.forEach { $0(false) } } }
        if let start = response.start { self.start(start) }
        return response.pass ? Unmanaged.passUnretained(event) : nil
    }

    /// Hands a claimed plan to the executor and sets the watchdog on it.
    private func start(_ claimed: ClaimedPlan) {
        DispatchQueue.main.async { [weak self] in self?.run(claimed) }
        for limit in [TypingGate.pickUpLimit, TypingGate.finishLimit] {
            watchdogQueue.asyncAfter(deadline: .now() + limit + 0.05) { [weak self] in
                self?.releaseHold(onlyIfExpired: true)
            }
        }
    }

    /// Ends a hold without the executor. There is no tap callback to post
    /// from here, so the keys go back at the HID tap, marked, and may land
    /// behind keys typed after them: order is given up, no key is.
    private func releaseHold(onlyIfExpired: Bool = false) {
        let failed = stateLock.withLock { () -> [(Bool) -> Void] in
            if onlyIfExpired, !gate.expired(now: ProcessInfo.processInfo.systemUptime) { return [] }
            perform(gate.release(), proxy: nil)
            return waitersOfLostPlans()
        }
        if !failed.isEmpty { DispatchQueue.main.async { failed.forEach { $0(false) } } }
    }

    /// Under the state lock: the waiters whose hold no longer exists.
    private func waitersOfLostPlans() -> [(Bool) -> Void] {
        guard !kickWaiters.isEmpty else { return [] }
        let lost = kickWaiters.filter { !gate.isHolding($0.plan) }.map(\.done)
        kickWaiters.removeAll { !gate.isHolding($0.plan) }
        return lost
    }

    /// Under the state lock. With a proxy the events enter right behind the
    /// one being handled, ahead of everything the tap has not seen, and do
    /// not come back to it. Without one they go to the HID tap.
    private func perform(_ commands: [GateCommand], proxy: CGEventTapProxy?) {
        func post(_ event: CGEvent?) {
            guard let event else { return }
            if let proxy { event.tapPostEvent(proxy) } else { event.post(tap: .cghidEventTap) }
        }
        for command in commands {
            switch command {
            case .output(let output):
                let source = CGEventSource(stateID: .hidSystemState)
                source?.userData = Self.outputMarker
                func key(_ stroke: KeyStroke, down: Bool) {
                    let event = CGEvent(keyboardEventSource: source, virtualKey: stroke.keyCode, keyDown: down)
                    event?.flags = CGEventFlags(rawValue: stroke.rawFlags)
                    post(event)
                }
                switch output {
                case .key(let stroke):
                    key(stroke, down: true)
                    key(stroke, down: false)
                case .keyDown(let stroke):
                    key(stroke, down: true)
                case .keyUp(let stroke):
                    key(stroke, down: false)
                case .text(let text):
                    let units = Array(text.utf16)
                    for down in [true, false] {
                        guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
                        event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                        post(event)
                    }
                }
            case .sendOn(let ticket):
                // The person's own key, as it was, and a key up made from
                // it: the physical key up went by on its own.
                guard let down = kept.removeValue(forKey: ticket), let up = down.copy() else { continue }
                up.type = .keyUp
                if proxy == nil {
                    down.setIntegerValueField(.eventSourceUserData, value: Self.relayMarker)
                    up.setIntegerValueField(.eventSourceUserData, value: Self.relayMarker)
                }
                post(down)
                post(up)
            case .discard(let ticket):
                kept[ticket] = nil
            }
        }
    }

    // MARK: - Executor

    /// Main thread. Turns the plan into output and hands it to the gate;
    /// the tap posts it. Whatever happens, the plan ends with a last
    /// `submit` or finds its hold gone.
    private func run(_ claimed: ClaimedPlan) {
        let id = claimed.id
        guard stateLock.withLock({ gate.begin(id) }) else { return }
        guard case .snippet(let insert)? = claimed.plan.steps.first else {
            guard claimed.plan.steps.first == .waitForCommandUp else {
                runPlain(id, claimed.plan.steps)
                return
            }
            afterCommandUp { [weak self] up in
                // ⌘ held past the wait: the undo is dropped, its ⌘Z too.
                guard up else {
                    self?.submit(id, [], last: true)
                    return
                }
                self?.runPlain(id, Array(claimed.plan.steps.dropFirst()))
            }
            return
        }
        // Only an explicit clipboard variable pays for a synchronous read;
        // the multiline write itself runs on the shared pasteboard lane.
        let clipboard = TextSnippetSupport.needsClipboard(insert.template)
            ? NSPasteboard.general.string(forType: .string)
            : nil
        let text = TextSnippetSupport.expand(
            insert.template,
            date: Date(),
            clipboard: clipboard
        )

        if TextSnippetSupport.requiresPaste(text) {
            let payload = TextSnippetSupport.pastePayload(text: text, trailingText: insert.trailingText)
            let shortcut = KeyStroke(keyCode: UInt16(kVK_ANSI_V), rawFlags: CGEventFlags.maskCommand.rawValue)
            let accepted = TransientPaste.shared.paste(
                payload,
                didFail: { [weak self] in
                    // The paste gave up after it was accepted: the swallowed
                    // key is typed again, as it always was on this path.
                    self?.submit(id, insert.failure.map { [.key($0)] } ?? [], last: true)
                },
                postShortcut: { [weak self] done in
                    guard let self else { return done(false) }
                    // Backspaces and Command-V down in one batch, the key up
                    // 40 ms later, as the paste has always been spaced.
                    self.submit(id, Self.deletes(insert.deleteCount, typed: insert.typedTrigger) + [.keyDown(shortcut)],
                                last: false) { posted in
                        guard posted else { return done(false) }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
                            self.submit(id, [.keyUp(shortcut)], last: true) { postedUp in
                                // The hold went away between the two: the
                                // key up still has to follow its key down.
                                if !postedUp { self.stateLock.withLock { self.perform([.output(.keyUp(shortcut))], proxy: nil) } }
                                done(true)
                            }
                        }
                    }
                }
            )
            // A busy transient paste fails open to normal typing.
            if !accepted { submit(id, [], last: true, abandoned: true) }
            return
        }

        // Typed injection instead of pasting: the clipboard stays untouched.
        var events = Self.deletes(insert.deleteCount, typed: insert.typedTrigger) + Self.typed(text)
        if let trailing = insert.trailing { events.append(.key(trailing)) }
        submit(id, events, last: true)
    }

    /// Main thread. A plan of plain steps (the layout fix). It needs the
    /// field in front to be another app's: with a FixDock window key, the
    /// backspaces would not land where the word is.
    private func runPlain(_ id: PlanID, _ steps: [PlanStep]) {
        guard !Self.ownWindowIsKey else {
            submit(id, [], last: true, abandoned: true)
            return
        }
        // Fail closed: a field that does not say, or says something else,
        // keeps its text (owner's Discord, 2026-11-13: correct Korean was
        // erased because the keys had been read as Latin letters).
        if case .expect(let shown)? = steps.first {
            let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
            guard let front, SelectedTextReader.textBeforeCaret(processID: front, length: shown.utf16.count,
                                                                timeout: 0.15) == shown else {
                submit(id, [], last: true, abandoned: true)
                return
            }
        }
        var events: [OutputEvent] = []
        for step in steps {
            switch step {
            case .backspaces(let count, let completionCheck):
                events += Self.deletes(count, typed: completionCheck ?? "")
            case .text(let text):
                events += Self.typed(text)
            case .key(let stroke):
                events.append(.key(stroke))
            case .snippet, .waitForCommandUp, .expect:
                break
            }
        }
        // Safari's fields with the Korean input method drop text that
        // comes right behind the backspaces taking down an open
        // syllable (owner list A, 2026-11-13: the word went, the
        // English never came). The text follows 40 ms later, as the
        // paste's key up does; keys typed meanwhile stay held.
        guard let split = events.firstIndex(where: { if case .text = $0 { return true } else { return false } }),
              split > 0 else {
            submit(id, events, last: true)
            return
        }
        submit(id, Array(events[..<split]), last: false) { [weak self] posted in
            guard posted else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
                self?.submit(id, Array(events[split...]), last: true)
            }
        }
    }

    /// Main thread. `then(true)` once ⌘ is up, checked every 15 ms as the
    /// paste waits for modifiers; `then(false)` if it is still down after
    /// 1.5 s, well inside the hold's limit.
    private func afterCommandUp(tries: Int = 100, _ then: @escaping (Bool) -> Void) {
        guard CGEventSource.flagsState(.combinedSessionState).contains(.maskCommand) else { return then(true) }
        guard tries > 0 else { return then(false) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.015) { [weak self] in
            self?.afterCommandUp(tries: tries - 1, then)
        }
    }

    /// `text` as Unicode-string events. Keystroke events carry at most ~20
    /// UTF-16 units reliably.
    private static func typed(_ text: String) -> [OutputEvent] {
        var events: [OutputEvent] = []
        let units = Array(text.utf16)
        var index = 0
        while index < units.count {
            var end = min(index + 20, units.count)
            // Never split a surrogate pair across chunks: two lone halves in
            // separate events render as replacement characters in some apps.
            if end < units.count, UTF16.isLeadSurrogate(units[end - 1]) {
                end -= 1
            }
            events.append(.text(String(utf16CodeUnits: Array(units[index..<end]), count: end - index)))
            index = end
        }
        return events
    }

    /// Main thread. Gives output to the gate and kicks the tap to post it.
    /// `then` hears true once it is posted, false if the hold is gone.
    private func submit(_ id: PlanID, _ events: [OutputEvent], last: Bool, abandoned: Bool = false,
                        then: ((Bool) -> Void)? = nil) {
        let accepted = stateLock.withLock { () -> Bool in
            guard gate.submit(id, events, last: last, abandoned: abandoned) else { return false }
            if let then { kickWaiters.append((id, then)) }
            return true
        }
        guard accepted else {
            then?(false)
            return
        }
        // A modifier event that changes nothing: no app acts on it, and the
        // tap swallows it. Never a key, so never the fast switch's.
        guard let kick = CGEvent(source: CGEventSource(stateID: .hidSystemState)) else { return }
        kick.type = .flagsChanged
        kick.flags = CGEventSource.flagsState(.combinedSessionState)
        kick.setIntegerValueField(.eventSourceUserData, value: Self.relayMarker)
        kick.post(tap: .cghidEventTap)
    }

    /// Whether one of this app's windows takes the keys. A panel that never
    /// activates the app, like the island's scratchpad, is key while the app
    /// behind it stays frontmost, and that app's field is not where the
    /// backspaces land. AppKit is read on the main thread, where the
    /// backspaces are counted; anywhere else counts as ours, so no other app
    /// is asked.
    private static var ownWindowIsKey: Bool {
        guard Thread.isMainThread else { return true }
        return MainActor.assumeIsolated { NSApp.keyWindow != nil }
    }

    /// The backspaces that clear `deleteCount` characters, `typed` being the
    /// text they clear when it is known as typed. Asked right before they go
    /// out, so the count covers a completion the field shows by then. Typing
    /// waits while the field answers, so every question, up to five for a
    /// selection that looks like a completion, shares one short time limit.
    private static func deletes(_ deleteCount: Int, typed: String) -> [OutputEvent] {
        guard deleteCount > 0 else { return [] }
        // Without the text as typed there is nothing to check a selection
        // against, so the field is not asked.
        let app = ownWindowIsKey || typed.isEmpty ? nil : NSWorkspace.shared.frontmostApplication
        let selection = app.flatMap {
            SelectedTextReader.focusedTextSelection(processID: $0.processIdentifier, timeout: 0.15)
        }
        let count = TextSnippetSupport.triggerDeleteCount(
            deleteCount, typed: typed,
            focusedSelection: selection.map { (range: $0.range, textLength: $0.textLength) }
        ) { selection?.text(in: $0) }
        return Array(repeating: .key(KeyStroke(keyCode: UInt16(kVK_Delete), rawFlags: 0)), count: count)
    }
}
