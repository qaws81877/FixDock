// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors
// Portions adapted from gksdud, Copyright (c) 2026 CodingNoye, MIT License (full text in NOTICE).

import AppKit
import Combine
import CoreGraphics

/// Fast Korean/English switch (`docs/input-switch.md`). Computes what macOS
/// should look like, asks `InputSwitchSystem` for it, and owns the session
/// tap that turns the remapped key's F-key press into an immediate pulse.
/// Never writes system state itself.
final class InputSwitchService: ObservableObject {
    static let shared = InputSwitchService()

    @Published private(set) var report = InputSwitchReport.off
    /// Wanted but Accessibility is missing, so nothing is applied.
    @Published private(set) var isWaitingForAccessibility = false

    private var router = InputSwitchKeyRouter()
    private var liveKeyCode: Int64?
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var repairTimer: Timer?
    private var repairInterval: TimeInterval = 0
    private var permissionPoll: Timer?
    private var permissionWatch: AnyCancellable?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var terminateObserver: NSObjectProtocol?
    private var termSource: DispatchSourceSignal?
    private var syncing = false

    // Long press (phase 5). The option is cached here: the tap never
    // reads UserDefaults or the input source itself.
    private var longPressEnabled = true
    private var longPress = InputSwitchLongPress()
    private var longPressInitialCaps = false
    /// Bumped on every cancel; a timer from an older press does nothing.
    private var generation = 0
    /// The Caps Lock a transition sets once the source is English.
    private var pendingCaps: Bool?
    private var sentPulse: InputSwitchSentPulse?
    /// Kept by the source-change notification, so a press costs no TIS call.
    private var cachedLanguage: String?

    private init() {
        SessionActivity.shared.onChange { [weak self] _ in self?.syncWithPreferences() }
        permissionWatch = Permissions.shared.$accessibility
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.syncWithPreferences() }

        let distributed = DistributedNotificationCenter.default()
        for name in ["com.apple.screenIsLocked", "com.apple.screenIsUnlocked"] {
            observe(distributed, Notification.Name(name))
        }
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.didWakeNotification)
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observe(workspace, name) { note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                return InputSwitchPolicy.otherSwitcherBundleIDs.contains(app?.bundleIdentifier ?? "")
            }
        }
        InputSwitchSystem.shared.onReportChange = { [weak self] _ in self?.syncWithPreferences() }
        let token = DistributedNotificationCenter.default().addObserver(
            forName: InputSwitchCapsLock.sourceChangedNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.sourceChanged() }
        observers.append((DistributedNotificationCenter.default(), token))
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         when relevant: @escaping (Notification) -> Bool = { _ in true }) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
            if relevant(note) { self?.syncWithPreferences() }
        }
        observers.append((center, token))
    }

    // MARK: Sync

    func syncWithPreferences() {
        guard !syncing else { return }
        syncing = true
        defer { syncing = false }

        let installed = AppFeature.inputSwitch.isAvailable
        let enabled = UserDefaults.standard.bool(forKey: DefaultsKey.inputSwitchEnabled)
        let trusted = AXIsProcessTrusted()
        let defaults = UserDefaults.standard
        // The repair timer re-syncs every second: cancel only when long press
        // is just turned off.
        let longPressWasEnabled = longPressEnabled
        longPressEnabled = defaults.bool(forKey: DefaultsKey.inputSwitchLongPressCapsLock)
        if longPressWasEnabled && !longPressEnabled { cancelTransition() }
        updatePermissionPoll(waiting: installed && enabled && !trusted)

        let other = NSWorkspace.shared.runningApplications.first {
            InputSwitchPolicy.otherSwitcherBundleIDs.contains($0.bundleIdentifier ?? "")
        }
        let want = InputSwitchPolicy.want(
            installed: installed, enabled: enabled, accessibility: trusted,
            onConsole: SessionActivity.shared.isActive,
            screenLocked: SessionActivitySupport.isScreenLocked(CGSessionCopyCurrentDictionary() as? [String: Any]),
            otherSwitcherRunning: other != nil, config: config)
        var next = InputSwitchSystem.shared.converge(to: want)
        if let other, installed, enabled, next.problem == nil {
            next.problem = .otherSwitcherRunning(other.localizedName ?? "gksdud")
        }
        if next != report { report = next }
        liveKeyCode = next.liveKeyCode

        updateTap(trusted: trusted)
        updateRepairTimer(want: want)
        updateExitHooks()
    }

    private var config: InputSwitchConfig {
        let key = UserDefaults.standard.string(forKey: DefaultsKey.inputSwitchKey).flatMap(SwitchKey.init(rawValue:))
        // A FixDock shortcut on a bare F13–F19 is stepped around.
        let reserved = HotkeyRole.allCases
            .filter { $0.wantsRegistration && $0.saved.modifiers.isEmpty }
            .map { Int($0.saved.keyCode) }
        return InputSwitchConfig(key: key ?? .default, appReservedKeyCodes: Set(reserved))
    }

    /// A grant made in System Settings sends no notification.
    private func updatePermissionPoll(waiting: Bool) {
        if isWaitingForAccessibility != waiting { isWaitingForAccessibility = waiting }
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

    /// Re-applies after reconnects, wake and Karabiner re-creating its
    /// keyboard: 1 s while anything of ours is wanted or on the system,
    /// 5 s while another process owns it, nothing when off.
    private func updateRepairTimer(want: SystemWant) {
        let interval: TimeInterval
        switch report.state {
        case .inert(.ownedBy): interval = 5
        case .inert, .off: interval = want == .restored ? 0 : 5
        default: interval = 1
        }
        guard interval != repairInterval else { return }
        repairTimer?.invalidate()
        repairTimer = nil
        repairInterval = interval
        guard interval > 0 else { return }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.syncWithPreferences() }
        repairTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Only while something of ours is on the system: quit restores it, and
    /// SIGTERM (`pkill`, `Tools/uninstall.sh`) becomes a quit (owner, O5).
    private func updateExitHooks() {
        let holds = InputSwitchSystem.shared.holdsSystemState
        if holds, terminateObserver == nil {
            terminateObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification, object: nil, queue: .main
            ) { _ in
                InputSwitchSystem.log.info("will terminate: restoring")
                _ = InputSwitchSystem.shared.restoreBeforeExit(timeout: 3)
            }
            signal(SIGTERM, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            termSource = source
            ProcessInfo.processInfo.disableSuddenTermination()
        } else if !holds, let observer = terminateObserver {
            NotificationCenter.default.removeObserver(observer)
            terminateObserver = nil
            termSource?.cancel()
            termSource = nil
            signal(SIGTERM, SIG_DFL)
            ProcessInfo.processInfo.enableSuddenTermination()
        }
    }

    // MARK: Tap

    private func updateTap(trusted: Bool) {
        let shouldRun = SessionActivitySupport.tapShouldRun(
            featureWanted: liveKeyCode != nil, accessibilityGranted: trusted,
            sessionIsActive: SessionActivity.shared.isActive)
        if shouldRun, tap == nil { installTap() }
        if !shouldRun, tap != nil { removeTap() }
    }

    private func installTap() {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let service = Unmanaged<InputSwitchService>.fromOpaque(userInfo).takeUnretainedValue()
                return service.handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return }
        self.tap = tap
        cachedLanguage = InputSwitchCapsLock.currentLanguage()
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func removeTap() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        tap = nil
        runLoopSource = nil
        router.reset()
        cancelTransition()
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            router.reset()
            cancelTransition()
            if let tap, liveKeyCode != nil, SessionActivity.shared.isActive { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown || type == .keyUp,
              event.getIntegerValueField(.eventSourceUserData) != OwnKeyEvent.inputSwitchMarker
        else { return Unmanaged.passUnretained(event) }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        if type == .keyUp, longPress.key == keyCode { finishLongPress(keyCode: keyCode) }

        let decision = router.decide(down: type == .keyDown, keyCode: keyCode, isRepeat: isRepeat,
                                     liveKeyCode: liveKeyCode)
        switch decision {
        case .pass:
            return Unmanaged.passUnretained(event)
        case .consume:
            return nil
        case .consumeAndSwitch:
            // Cleaning mode's HID tap already eats the physical key; this covers
            // cleaning starting between that tap and this one.
            if cleaningModeIsActive { return nil }
            guard let pulse = makePulse(from: event) else {
                router.reset()
                return Unmanaged.passUnretained(event)
            }
            // Re-entering at the HID level reaches the system shortcut before
            // the key's release: the switch happens on press (gksdud).
            post(pulse)
            if longPressEnabled { startLongPress(keyCode: keyCode, capsOn: event.flags.contains(.maskAlphaShift)) }
            return nil
        }
    }

    private func post(_ pulse: (down: CGEvent, up: CGEvent)) {
        pulse.down.post(tap: .cghidEventTap)
        pulse.up.post(tap: .cghidEventTap)
        sentPulse = cachedLanguage.map { InputSwitchSentPulse(fromLanguage: $0, at: ProcessInfo.processInfo.systemUptime) }
    }

    /// A pulse with no physical event to copy (a long press after its key's
    /// release). A new F-key event carries the flags macOS gives F-keys.
    private func postGeneratedPulse() -> Bool {
        guard let liveKeyCode,
              let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(liveKeyCode), keyDown: true),
              let pulse = makePulse(from: event) else { return false }
        post(pulse)
        return true
    }

    // MARK: Long press

    private func startLongPress(keyCode: Int64, capsOn: Bool) {
        cancelTransition()
        longPress.begin(key: keyCode, now: ProcessInfo.processInfo.systemUptime)
        longPressInitialCaps = capsOn
        let current = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + InputSwitchLongPress.delay) { [weak self] in
            guard let self, self.generation == current,
                  self.longPress.claimLong(now: ProcessInfo.processInfo.systemUptime) else { return }
            self.beginCapsTransition(!self.longPressInitialCaps)
        }
    }

    private func finishLongPress(keyCode: Int64) {
        // Called from the tap: the transition reads the source, so it runs after.
        if longPress.release(key: keyCode, now: ProcessInfo.processInfo.systemUptime).long {
            let desired = !longPressInitialCaps
            DispatchQueue.main.async { [weak self] in self?.beginCapsTransition(desired) }
        }
    }

    /// Reach English, then set Caps Lock to `desired`. Only the pulse
    /// switches; gives up after 0.5 s if English never comes.
    private func beginCapsTransition(_ desired: Bool) {
        guard liveKeyCode != nil, let language = InputSwitchCapsLock.currentLanguage() else { return cancelTransition() }
        cachedLanguage = language
        let inFlight = sentPulse?.inFlight(now: ProcessInfo.processInfo.systemUptime, language: language) ?? false
        pendingCaps = desired
        switch InputSwitchEnglishRoute.from(language: language, inFlight: inFlight) {
        case .now:
            completeCapsTransition(language: language)
            return
        case .awaitSwitch:
            break
        case .sendSwitch:
            guard postGeneratedPulse() else { return cancelTransition() }
            // Two are on their way back here, so neither is in flight from this source.
            if inFlight { sentPulse = nil }
        }
        let current = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + InputSwitchSentPulse.window) { [weak self] in
            guard let self, self.generation == current, self.pendingCaps != nil else { return }
            InputSwitchSystem.log.info("caps transition: English did not come")
            self.cancelTransition()
        }
    }

    private func completeCapsTransition(language: String) {
        guard let desired = pendingCaps, InputSwitchLanguage.isEnglish(language) else { return }
        pendingCaps = nil
        generation += 1
        if !InputSwitchCapsLock.set(desired) { InputSwitchSystem.log.info("caps transition: set failed") }
    }

    private func sourceChanged() {
        guard tap != nil else { return }
        let language = InputSwitchCapsLock.currentLanguage()
        cachedLanguage = language
        if let language, pendingCaps != nil { completeCapsTransition(language: language) }
    }

    private func cancelTransition() {
        generation += 1
        pendingCaps = nil
        longPress.cancel()
    }

    /// Two copies of the F-key event. Held modifiers are stripped but the
    /// F-key identity flags kept, or the shortcut would not match; Caps Lock
    /// rides along as the physical event had it.
    private func makePulse(from event: CGEvent) -> (down: CGEvent, up: CGEvent)? {
        guard let down = event.copy(), let up = event.copy() else { return nil }
        down.type = .keyDown
        up.type = .keyUp
        var flags = event.flags.intersection([.maskSecondaryFn, .maskNumericPad])
        if event.flags.contains(.maskAlphaShift) { flags.insert(.maskAlphaShift) }
        for pulse in [down, up] {
            pulse.flags = flags
            pulse.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
            pulse.setIntegerValueField(.eventSourceUserData, value: OwnKeyEvent.inputSwitchMarker)
        }
        return (down, up)
    }

    /// Read only when cleaning mode is installed, so this never creates its manager.
    private var cleaningModeIsActive: Bool {
        AppFeature.cleaningMode.isAvailable && CleaningModeManager.shared.isActive
    }
}
