// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import AppKit
import Carbon.HIToolbox
import SwiftUI
import UniformTypeIdentifiers

/// Every capture lands here as a pin over the place it was taken, selected,
/// with its bar. Owns the stack (order and phase), each pin's window or
/// record, which pin is selected, and the round trip to the editor.
/// Main thread only. The pure decisions are in `Core/ScreenshotPinSupport.swift`.
final class ScreenshotPinController: ObservableObject {
    static let shared = ScreenshotPinController()

    /// Published so the bar's badge derives `hiddenCount` from it.
    @Published fileprivate private(set) var stack = ScreenshotPinStack()
    /// Materialized from `stack` by `reconcile`; nothing else adds or removes.
    private var pins: [ScreenshotPinID: Pin] = [:]
    private var focus = ScreenshotPinFocus()
    /// Alive exactly while a pin is selected.
    private var focusWatch: FocusWatch?
    /// Alive exactly while the stack is non-empty.
    private var stackWatch: StackWatch?

    /// Only the visible top has a window. Measured (M1): 19 ordered-out pin
    /// windows kept about 8 MB of window-server backing store each, 151 MB in
    /// all, so a hidden pin is a record and its window is dismantled.
    private enum Pin {
        case window(PinWindow)
        case record(PinRecord)
    }

    private init() {}

    // MARK: Entry points

    /// `ScreenshotService.deliver`'s pin step. `anchor` is the captured area
    /// in Cocoa screen points, nil when no screen was known.
    func pin(png: Data, scale: CGFloat, capturedAt anchor: CGRect?) {
        guard let picture = ScreenshotPinPicture(png: png, scale: scale) else {
            NSSound.beep()
            return
        }
        let pointer = NSEvent.mouseLocation
        let centre = anchor.map { CGPoint(x: $0.midX, y: $0.midY) } ?? pointer
        let visible = (Self.screen(containing: centre) ?? Self.screen(containing: pointer) ?? NSScreen.main)?
            .visibleFrame ?? Self.fallbackVisibleFrame
        let frame = ScreenshotPinLayout.pinFrame(naturalSize: picture.naturalSize, anchor: anchor,
                                                 pointer: pointer, visibleFrame: visible)
        let (id, _) = stack.push()
        pins[id] = .record(PinRecord(capture: ScreenshotPinCapture(display: picture), frame: frame))
        scanForCode(id, picture)
        reconcile(selectVisible: true)
    }

    /// Uninstall. Idempotent, and a no-op on an empty stack (it also runs at
    /// launch when the tool is absent). Runs before `ScreenshotService`
    /// closes editors, so their `.cancelled` finds no entry and does nothing.
    func tearDown() {
        _ = stack.removeAll()
        reconcile(selectVisible: false)
        focus = ScreenshotPinFocus()
        syncFocusWatch()
    }

    // MARK: Called by this file's windows

    /// The only place an action has an effect. No `default:`.
    fileprivate func perform(_ action: ScreenshotPinAction, on id: ScreenshotPinID, anchor: NSView?) {
        guard let pin = window(id), stack.presence(of: id) == .shown,
              action.availability(pin.barModel.context) == .ready
        else { return }
        switch action {
        case .save:
            guard ScreenshotService.shared.saveToFolder(pin.capture.output.png) else { return }
            ScreenshotToastController.shared.show(.saved, on: pin.screen)
        case .copy:
            let output = pin.capture.output
            guard ScreenshotService.shared.copyCapture(output.image, png: output.png) else { return }
            ScreenshotToastController.shared.show(.copied, on: pin.screen)
        case .share:
            pin.share(from: anchor)
        case .extractText:
            pin.extractText()
        case .edit:
            beginEdit(id)
        case .showCode:
            pin.showCode()
        case .saveAs:
            pin.runSaveAs()
        case .openSettings:
            if let page = AppFeature.screenshot.settingsPage {
                SettingsNavigator.shared.open(.feature(page))
            }
            appDelegate()?.openSettings()
        case .closeAll:
            _ = stack.removeAllResting()
            reconcile(selectVisible: false)
        case .close:
            stack.remove(id)
            reconcile(selectVisible: true)
        }
    }

    fileprivate func report(_ event: ScreenshotPinFocus.Event) {
        apply(focus.apply(event))
    }

    fileprivate func isSelected(_ id: ScreenshotPinID) -> Bool {
        focus.selected == id
    }

    fileprivate var hiddenCount: Int { stack.hiddenCount }

    private func window(_ id: ScreenshotPinID) -> PinWindow? {
        guard case .window(let window)? = pins[id] else { return nil }
        return window
    }

    // MARK: Reconcile

    /// Makes the pins match the stack. A second run changes nothing. The
    /// only place a window is made or dismantled, so the frame has one owner
    /// at a time: the window while it exists, the record from the moment it
    /// is dismantled. The visible top goes first so key moves pin to pin:
    /// FixDock never passes through "no key window", which would post
    /// didResignActive and race the new selection.
    private func reconcile(selectVisible: Bool) {
        if let top = stack.visible, let pin = pins[top] {
            let window: PinWindow
            switch pin {
            case .window(let shown):
                window = shown
            case .record(let record):
                window = PinWindow(id: top, record: record, controller: self)
                pins[top] = .window(window)
                window.orderFrontRegardless()
            }
            if selectVisible {
                window.makeKey()
                // Already key (a stale key flag after focus left): AppKit
                // posts nothing, so the reducer hears it from here.
                if window.isKeyWindow { report(.keyGained(top)) }
            }
        }
        for (id, pin) in pins where stack.presence(of: id) != .shown {
            report(.gone(id))
            let record: PinRecord
            switch pin {
            case .window(let window): record = window.dismantle()
            case .record(let stored): record = stored
            }
            guard stack.presence(of: id) == .absent else {
                pins[id] = .record(record)
                continue
            }
            if record.showedCode, ScreenshotQRResultController.shared.isShown {
                ScreenshotQRResultController.shared.close()
            }
            pins[id] = nil
        }
        syncStackWatch()
    }

    private func apply(_ changes: [ScreenshotPinFocus.Change]) {
        for change in changes {
            switch change {
            case .select(let id, let emphasize):
                window(id)?.showSelection(emphasize: emphasize)
            case .deselect(let id):
                window(id)?.hideSelection()
            case .restoreKey(let id):
                DispatchQueue.main.async { [weak self] in self?.window(id)?.restoreKeyIfAway() }
            }
        }
        syncFocusWatch()
    }

    /// Derived from `focus.selected`: built on select, dropped on deselect.
    private func syncFocusWatch() {
        guard let id = focus.selected, let pin = window(id) else {
            focusWatch = nil
            return
        }
        guard focusWatch?.selected != id else { return }
        focusWatch = FocusWatch(selected: id,
                                isFamily: { [weak pin] window in pin?.isFamily(window) ?? false },
                                report: { [weak self] event in self?.report(event) })
    }

    /// Derived from the stack: the key monitor and the display-change
    /// observer exist while any pin exists.
    private func syncStackWatch() {
        guard !stack.entries.isEmpty else {
            stackWatch = nil
            return
        }
        guard stackWatch == nil else { return }
        stackWatch = StackWatch(key: { [weak self] event in self?.route(event) ?? event },
                                screensChanged: { [weak self] in self?.screensChanged() })
    }

    /// The selected pin's chords, before any window sees the key. Only an
    /// event addressed to the pin window: keys in a key text panel go on to
    /// the main menu (Edit ▸ Copy copies the selection).
    private func route(_ event: NSEvent) -> NSEvent? {
        guard let id = focus.selected, let pin = window(id), event.window === pin else { return event }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard let action = ScreenshotPinAction.forKey(keyCode: Int(event.keyCode), command: flags.contains(.command),
                                                      shift: flags.contains(.shift), option: flags.contains(.option),
                                                      control: flags.contains(.control), isRepeat: event.isARepeat)
        else { return event }
        perform(action, on: id, anchor: nil)
        return nil
    }

    /// Risk R9: a hidden pin on a display that was unplugged or rearranged
    /// would otherwise reveal off screen.
    private func screensChanged() {
        let visibleFrames = NSScreen.screens.map(\.visibleFrame)
        for (id, pin) in pins {
            switch pin {
            case .window(let window):
                window.clamp(intoAnyOf: visibleFrames)
            case .record(var record):
                record.frame = ScreenshotPinLayout.clamp(record.frame, intoAnyOf: visibleFrames)
                pins[id] = .record(record)
            }
        }
    }

    // MARK: Editor round trip

    /// The pin leaves the screen (and, as the editing top, so does the stack
    /// under it) while the editor has it. Its record keeps the original
    /// capture and frame: that is what Cancel restores, so Cancel needs no
    /// code of its own.
    private func beginEdit(_ id: ScreenshotPinID) {
        guard let display = window(id)?.capture.display, stack.beginEdit(id) else { return }
        reconcile(selectVisible: false)
        ScreenshotService.shared.openEditor(image: display.image, scale: display.scale) { [weak self] outcome in
            self?.finishEdit(id, outcome)
        }
    }

    private func finishEdit(_ id: ScreenshotPinID, _ outcome: ScreenshotEditOutcome) {
        guard stack.endEdit(id), case .record(var record)? = pins[id] else { return }
        if case .edited(let display, let output) = outcome {
            if let shown = Self.picture(display) {
                // Same top-left corner and zoom.
                record.frame = ScreenshotPinLayout.frameAfterEdit(
                    previous: record.frame, previousNatural: record.capture.display.naturalSize,
                    newNatural: shown.naturalSize, visibleFrame: Self.visibleFrame(around: record.frame))
                record.capture = ScreenshotPinCapture(display: shown, backdropped: output.flatMap(Self.picture))
                record.code = nil
                record.recognizedText = nil
                pins[id] = .record(record)
                scanForCode(id, shown)
            } else {
                NSSound.beep()
            }
        }
        // windowWillClose runs while AppKit still picks the next key window;
        // keying the pin one turn later keeps the closing editor from winning.
        DispatchQueue.main.async { [weak self] in self?.reconcile(selectVisible: true) }
    }

    /// Once per picture, off the main thread. The result goes to whichever
    /// holds the pin by then, so a pin hidden mid-scan still gets its QR button.
    private func scanForCode(_ id: ScreenshotPinID, _ picture: ScreenshotPinPicture) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let reading = ScreenshotRecognition.readCodes(picture.image) else { return }
            DispatchQueue.main.async { self?.found(reading, in: picture, for: id) }
        }
    }

    private func found(_ reading: ScreenshotRecognition.CodeReading, in picture: ScreenshotPinPicture,
                       for id: ScreenshotPinID) {
        switch pins[id] {
        case .window(let window)?:
            window.found(reading, in: picture)
        case .record(var record)? where record.capture.display === picture:
            record.code = reading
            pins[id] = .record(record)
        case .record?, nil:
            break
        }
    }

    /// Boundary: encode once, parse back into a picture that decodes on demand.
    private static func picture(_ export: ScreenshotRenderer.Export) -> ScreenshotPinPicture? {
        ScreenshotRenderer.pngData(from: export.image, scale: export.scale)
            .flatMap { ScreenshotPinPicture(png: $0, scale: export.scale) }
    }

    fileprivate static let fallbackVisibleFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)

    fileprivate static func screen(containing point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }
    }

    /// The visible frame of the screen holding `frame`'s centre.
    fileprivate static func visibleFrame(around frame: CGRect, fallback: NSScreen? = nil) -> CGRect {
        (screen(containing: CGPoint(x: frame.midX, y: frame.midY)) ?? fallback ?? NSScreen.main)?.visibleFrame
            ?? fallbackVisibleFrame
    }
}

/// What a pin keeps while it has no window: everything a reveal needs to
/// rebuild it as it was.
private struct PinRecord {
    var capture: ScreenshotPinCapture
    var frame: CGRect
    var opacity: ScreenshotPinOpacity = .full
    var code: ScreenshotRecognition.CodeReading?
    /// OCR result for `capture.display`.
    var recognizedText: String?
    /// Its QR result may be up; closing the pin closes it.
    var showedCode = false
}

// MARK: - Watches

/// Focus-loss sources, alive only while a pin is selected. All feed the
/// reducer, which ignores them while a transient is up.
///   1. Global mouse-down: a click another app received. Global monitors
///      never see FixDock's own windows, so no hit test and no grant.
///   2. NSWorkspace didActivateApplication for another bundle id. Our own
///      id is ignored: Save As activates FixDock.
///   3. NSApplication didResignActive, honored only if FixDock is still
///      inactive one turn later (a reveal or an editor return re-keys a pin
///      within that turn).
///   4. NSWindow didResignKey on the pin or a satellite, judged one turn
///      later against NSApp.keyWindow (measured: nil during the notification).
private final class FocusWatch {
    let selected: ScreenshotPinID
    private var mouseMonitor: Any?
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []

    init(selected: ScreenshotPinID, isFamily: @escaping (NSWindow?) -> Bool,
         report: @escaping (ScreenshotPinFocus.Event) -> Void) {
        self.selected = selected
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in
            report(.focusLeft)
        }
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append((workspace, workspace.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if app?.bundleIdentifier != Bundle.main.bundleIdentifier { report(.focusLeft) }
        }))
        let center = NotificationCenter.default
        observers.append((center, center.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            DispatchQueue.main.async { if !NSApp.isActive { report(.focusLeft) } }
        }))
        observers.append((center, center.addObserver(
            forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { note in
            guard isFamily(note.object as? NSWindow) else { return }
            DispatchQueue.main.async { report(.keySettled(selected, keyIsFamily: isFamily(NSApp.keyWindow))) }
        }))
    }

    deinit {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        for observer in observers { observer.center.removeObserver(observer.token) }
    }
}

/// What exists while any pin exists: the local key monitor that routes the
/// selected pin's chords, and the display-change observer (risk R9).
private final class StackWatch {
    private var keyMonitor: Any?
    private var observer: NSObjectProtocol?

    init(key: @escaping (NSEvent) -> NSEvent?, screensChanged: @escaping () -> Void) {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: key)
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            screensChanged()
        }
    }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}

// MARK: - Pin window

/// The visible pin: the picture at its own frame, an accent border while
/// selected, edge resize keeping proportions, and the right-click menu. Owns
/// its bar and extracted-text panel as child windows. Its own delegate, so
/// the controller exposes no delegate methods. Made from a `PinRecord` on
/// reveal and turned back into one by `dismantle`.
private final class PinWindow: OverlayPanel, NSWindowDelegate, NSSharingServicePickerDelegate {
    let id: ScreenshotPinID
    let capture: ScreenshotPinCapture
    /// Per-pin bar state (QR reading, OCR busy, opacity). One owner.
    let barModel = BarModel()
    private unowned let controller: ScreenshotPinController
    private let content: PinContentView
    /// Made on first selection; attached as a child only while selected.
    private var bar: BarPanel?
    private var barEdge = ScreenshotPinLayout.BarEdge.below
    private var textPanel: TextPanel?
    private var textModel: TextPanelModel?
    /// OCR result for `capture.display`.
    private var recognizedText: String?
    private var picker: NSSharingServicePicker?
    private var showedCode: Bool

    init(id: ScreenshotPinID, record: PinRecord, controller: ScreenshotPinController) {
        self.id = id
        capture = record.capture
        recognizedText = record.recognizedText
        showedCode = record.showedCode
        self.controller = controller
        content = PinContentView(picture: record.capture.display.image)
        super.init(contentRect: record.frame, styleMask: [.borderless, .nonactivatingPanel, .resizable],
                   backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        applyPictureLimits()
        contentView = content
        delegate = self
        content.menuProvider = { [weak self] in self?.contextMenu() }
        barModel.code = record.code
        opacity = record.opacity
    }

    override var canBecomeKey: Bool { true }

    private var visibleFrame: CGRect {
        ScreenshotPinController.visibleFrame(around: frame, fallback: screen)
    }

    private func applyPictureLimits() {
        let pixels = capture.display.pixelSize
        contentAspectRatio = CGSize(width: max(1, pixels.width), height: max(1, pixels.height))
        let limits = ScreenshotPinLayout.resizeLimits(naturalSize: capture.display.naturalSize,
                                                      visibleFrame: visibleFrame)
        minSize = limits.min
        maxSize = limits.max
    }

    // MARK: NSWindowDelegate (itself)

    func windowDidMove(_ notification: Notification) {
        layoutSatellites()
    }

    func windowDidResize(_ notification: Notification) {
        layoutSatellites()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        controller.report(.keyGained(id))
    }

    /// A press reports `clicked` before AppKit keys the pin, so the focus
    /// knows a person clicked (pulse) rather than a reveal. Keys it by hand:
    /// a click does not key a nonactivating panel on its own.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown || event.type == .rightMouseDown {
            controller.report(.clicked(id))
            if !isKeyWindow { makeKey() }
        }
        super.sendEvent(event)
    }

    /// Every chord is routed by the controller's monitor before the window
    /// sees it; what reaches here is not a pin key and must not beep.
    override func keyDown(with event: NSEvent) {}

    var opacity: ScreenshotPinOpacity {
        get { barModel.opacity }
        set {
            barModel.opacity = newValue
            alphaValue = newValue.alpha
        }
    }

    /// The pin and the windows that may hold key without deselecting it:
    /// its bar, its text panel, the QR result. The Save As panel and the
    /// share picker are transients instead, which suspend focus loss.
    func isFamily(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        return window === self || window === bar || window === textPanel
            || ScreenshotQRResultController.shared.owns(window)
    }

    /// After the last transient ended: if key went nowhere of ours, take it back.
    func restoreKeyIfAway() {
        guard isVisible, controller.isSelected(id), !isFamily(NSApp.keyWindow) else { return }
        makeKey()
    }

    // MARK: Driven by reconcile

    /// Closes the window and hands back what outlives it; the record owns the
    /// frame from here. An open Save As panel keeps running and writes the
    /// PNG it captured.
    func dismantle() -> PinRecord {
        hideSelection(animated: false)
        closeTextPanel()
        bar?.orderOut(nil)
        bar = nil
        delegate = nil
        close()
        return PinRecord(capture: capture, frame: frame, opacity: opacity, code: barModel.code,
                         recognizedText: recognizedText, showedCode: showedCode)
    }

    func clamp(intoAnyOf visibleFrames: [CGRect]) {
        let target = ScreenshotPinLayout.clamp(frame, intoAnyOf: visibleFrames)
        guard target != frame else { return }
        setFrame(target, display: isVisible)
    }

    // MARK: Driven by focus changes

    func showSelection(emphasize: Bool) {
        content.isSelected = true
        if emphasize { content.pulse() }
        let bar = self.bar ?? makeBar()
        self.bar = bar
        // Measured: a child does not inherit it, and its level follows the parent.
        bar.collectionBehavior = collectionBehavior
        let attached = bar.parent != nil
        if !attached { addChildWindow(bar, ordered: .above) }
        layoutSatellites()
        if emphasize, !attached {
            let target = bar.frame
            let away: CGFloat = barEdge == .above ? 6 : -6
            bar.alphaValue = 0
            bar.setFrameOrigin(CGPoint(x: target.minX, y: target.minY + away))
            bar.orderFront(nil)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                bar.animator().alphaValue = 1
                bar.animator().setFrame(target, display: true)
            }
        } else {
            bar.alphaValue = 1
            if !bar.isVisible { bar.orderFront(nil) }
        }
    }

    /// Detaching matters: a child still attached comes back with the pin's
    /// next orderFront (measured).
    func hideSelection(animated: Bool = true) {
        content.isSelected = false
        closeTextPanel()
        bar?.dismissTooltip()
        guard let bar, bar.parent != nil else { return }
        let detach = { [weak self, weak bar] in
            guard let self, let bar else { return }
            // Selected again during the fade: keep it.
            guard !self.controller.isSelected(self.id) else {
                bar.alphaValue = 1
                return
            }
            self.removeChildWindow(bar)
            bar.orderOut(nil)
        }
        if animated {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.12
                bar.animator().alphaValue = 0
            }, completionHandler: detach)
        } else {
            bar.alphaValue = 0
            detach()
        }
    }

    /// Bar and text panel from the pure layout, against the visible frame of
    /// the screen holding the pin's centre.
    func layoutSatellites() {
        let visible = visibleFrame
        if let bar, bar.parent != nil {
            let placed = ScreenshotPinLayout.barFrame(pinFrame: frame, barSize: bar.fittingSize, visibleFrame: visible)
            barEdge = placed.edge
            bar.setFrame(placed.frame, display: true)
        }
        if let textPanel {
            let placed = ScreenshotPinLayout.textPanelFrame(pinFrame: frame, barFrame: bar?.parent != nil ? bar?.frame : nil,
                                                            panelSize: TextPanel.size, visibleFrame: visible)
            textPanel.setFrame(placed, display: true)
        }
    }

    // MARK: Actions with window-local effects

    /// Writes the output PNG as of the click, even if an edit lands meanwhile.
    func runSaveAs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.directoryURL = ScreenshotService.saveFolder
        panel.nameFieldStringValue = ScreenshotSupport.fileName(prefix: L10n.shared.s.screenshotFilePrefix,
                                                                date: Date())
        let png = capture.output.png
        controller.report(.transientBegan(.savePanel))
        // A save panel needs an active app.
        NSApp.activate()
        panel.begin { [weak self] response in
            self?.controller.report(.transientEnded(.savePanel))
            guard response == .OK, let url = panel.url else { return }
            do {
                // The panel already asked about replacing.
                try png.write(to: url, options: .atomic)
            } catch {
                NSSound.beep()
                return
            }
            ScreenshotSupport.markAsScreenCapture(url)
            ScreenshotService.shared.noteSaved(url)
            ScreenshotToastController.shared.show(.saved, on: self?.screen)
        }
    }

    /// The bar's Share button, or the pin itself from the right-click menu.
    /// The pin stays whatever is chosen.
    func share(from anchor: NSView?) {
        guard picker == nil else { return }
        let view = anchor ?? content
        let output = capture.output
        let picker = NSSharingServicePicker(items: [NSImage(cgImage: output.image, size: output.naturalSize)])
        picker.delegate = self
        self.picker = picker
        controller.report(.transientBegan(.sharePicker))
        picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }

    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker,
                              didChoose service: NSSharingService?) {
        picker = nil
        controller.report(.transientEnded(.sharePicker))
    }

    /// OCR once per display picture, then the text panel beside the pin. The
    /// panel opens at its final size in a progress state and is not keyed:
    /// ⌘C keeps copying the image until the person clicks into the text.
    func extractText() {
        if let text = recognizedText {
            showText(text)
            return
        }
        guard !barModel.readingText else { return }
        barModel.readingText = true
        showText(nil)
        let picture = capture.display
        let languages = ScreenshotRecognition.preferredLanguages(for: L10n.shared.language)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let text = ScreenshotRecognition.readText(picture.image, languages: languages)
            DispatchQueue.main.async {
                guard let self else { return }
                self.barModel.readingText = false
                self.recognizedText = text
                if self.textPanel != nil { self.showText(text) }
            }
        }
    }

    private func showText(_ text: String?) {
        if let textModel, textPanel != nil {
            textModel.text = text
            return
        }
        let model = TextPanelModel(text: text)
        let panel = TextPanel(model: model,
                              copyAll: { [weak self] text in
                                  ScreenshotService.copyText(text)
                                  ScreenshotToastController.shared.show(.copied, on: self?.screen)
                              },
                              onClose: { [weak self] in self?.closeTextPanel() })
        textModel = model
        textPanel = panel
        panel.collectionBehavior = collectionBehavior
        addChildWindow(panel, ordered: .above)
        layoutSatellites()
        panel.orderFront(nil)
    }

    private func closeTextPanel() {
        guard let textPanel else { return }
        removeChildWindow(textPanel)
        textPanel.orderOut(nil)
        self.textPanel = nil
        textModel = nil
    }

    func showCode() {
        guard let code = barModel.code else { return }
        showedCode = true
        ScreenshotQRResultController.shared.show(code)
    }

    /// The controller's scan of `picture`; the QR button appears. A scan of
    /// the picture before an edit is stale.
    func found(_ reading: ScreenshotRecognition.CodeReading, in picture: ScreenshotPinPicture) {
        guard capture.display === picture else { return }
        barModel.code = reading
        // The bar is wider now; SwiftUI lays it out on the next turn.
        DispatchQueue.main.async { [weak self] in self?.layoutSatellites() }
    }

    private func contextMenu() -> NSMenu? {
        menu(ScreenshotPinMenus.context(barModel.context), anchor: content)
    }

    private func menu(_ nodes: [ScreenshotPinMenuNode], anchor: NSView?) -> NSMenu {
        MenuBuilder.menu(nodes, strings: L10n.shared.s,
                         perform: { [weak self] action in
                             guard let self else { return }
                             self.controller.perform(action, on: self.id, anchor: anchor)
                         },
                         setOpacity: { [weak self] in self?.opacity = $0 },
                         transient: { [weak self] open in
                             self?.controller.report(open ? .transientBegan(.menu) : .transientEnded(.menu))
                         })
    }

    private func makeBar() -> BarPanel {
        BarPanel(model: barModel, pins: controller,
                 perform: { [weak self] action, anchor in
                     guard let self else { return }
                     self.controller.perform(action, on: self.id, anchor: anchor)
                 },
                 openMenu: { [weak self] which, view in
                     guard let self else { return }
                     let nodes: [ScreenshotPinMenuNode]
                     switch which {
                     case .button(let action): nodes = ScreenshotPinMenus.button(action, self.barModel.context)
                     case .settings: nodes = ScreenshotPinMenus.settings(self.barModel.context)
                     }
                     let menu = self.menu(nodes, anchor: view)
                     menu.popUp(positioning: nil, at: CGPoint(x: 0, y: view.bounds.maxY + 4), in: view)
                 },
                 dragWriter: { [weak self] in
                     guard let self else { return nil }
                     let name = ScreenshotSupport.fileName(prefix: L10n.shared.s.screenshotFilePrefix, date: Date())
                     return ScreenshotPromiseProvider(png: self.capture.output.png, fileName: name)
                 },
                 dragImage: { [weak self] in self?.capture.display.image })
    }
}

/// The picture, its border, the pulse, and the right-click menu.
private final class PinContentView: NSView {
    private static let selectedBorder: CGFloat = 2
    private static let cornerRadius: CGFloat = 7
    private static let pulseKey = "pulse"
    private let imageLayer = CALayer()
    /// The pulse's accent glow along the inside of the border: the shadow of
    /// a frame-shaped fill that lies wholly outside the clipped bounds.
    private let glowLayer = CAShapeLayer()

    var isSelected = false {
        didSet {
            if !isSelected { removePulse() }
            layer?.borderWidth = isSelected ? Self.selectedBorder : 1
            layer?.borderColor = isSelected ? NSColor.controlAccentColor.cgColor : CGColor(gray: 0.5, alpha: 0.4)
        }
    }

    var menuProvider: (() -> NSMenu?)?

    init(picture: CGImage) {
        super.init(frame: .zero)
        imageLayer.contents = picture
        wantsLayer = true
        layer?.cornerRadius = Self.cornerRadius
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = CGColor(gray: 0.5, alpha: 0.4)
        imageLayer.contentsGravity = .resizeAspect
        imageLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer?.addSublayer(imageLayer)
        glowLayer.fillRule = .evenOdd
        glowLayer.fillColor = CGColor(gray: 0, alpha: 1)
        glowLayer.shadowOffset = .zero
        glowLayer.shadowRadius = 12
        glowLayer.shadowOpacity = 0
        layer?.addSublayer(glowLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Bounds and position, not frame: a layer's frame is undefined while the
    /// pulse scales it, and a drag-resize can start on the pulsing click.
    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let centre = CGPoint(x: bounds.midX, y: bounds.midY)
        for sublayer in [imageLayer, glowLayer] {
            sublayer.bounds = bounds
            sublayer.position = centre
        }
        let frame = CGMutablePath()
        frame.addRect(bounds.insetBy(dx: -20, dy: -20))
        let radius = min(Self.cornerRadius, bounds.width / 2, bounds.height / 2)
        frame.addRoundedRect(in: bounds, cornerWidth: radius, cornerHeight: radius)
        glowLayer.path = frame
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if isSelected { layer?.borderColor = NSColor.controlAccentColor.cgColor }
    }

    /// Reselect pulse, led by the border: it swells to 6 pt and settles at
    /// the selected width with an accent glow inside, while the picture
    /// swells 4.5 % and back. All inside the window's frame, so a drag that
    /// starts on the same click is never fought. Call after `isSelected`:
    /// the layers already hold the selected values, so nothing snaps at the end.
    func pulse() {
        guard let layer, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let easeOut = CAMediaTimingFunction(name: .easeOut)
        func swell(_ keyPath: String, _ values: [CGFloat]) -> CAKeyframeAnimation {
            let animation = CAKeyframeAnimation(keyPath: keyPath)
            animation.values = values
            animation.keyTimes = [0, 0.35, 1]
            animation.timingFunctions = [easeOut, easeOut]
            animation.duration = 0.26
            return animation
        }
        layer.add(swell("borderWidth", [Self.selectedBorder, 6, Self.selectedBorder]), forKey: Self.pulseKey)
        glowLayer.shadowColor = NSColor.controlAccentColor.cgColor
        glowLayer.add(swell("shadowOpacity", [0, 1, 0]), forKey: Self.pulseKey)
        imageLayer.add(swell("transform.scale", [1, 1.045, 1]), forKey: Self.pulseKey)
    }

    private func removePulse() {
        for target in [layer, imageLayer, glowLayer] { target?.removeAnimation(forKey: Self.pulseKey) }
    }

    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }
}

// MARK: - Bar

/// Per-pin bar state. The badge is not here: it derives from the controller's stack.
private final class BarModel: ObservableObject {
    @Published var code: ScreenshotRecognition.CodeReading?
    @Published var readingText = false
    @Published var opacity: ScreenshotPinOpacity = .full

    var context: ScreenshotPinContext {
        ScreenshotPinContext(hasCode: code != nil, isReadingText: readingText, opacity: opacity)
    }
}

private enum BarMenu {
    case button(ScreenshotPinAction)
    case settings
}

/// The bar's window: a child of its pin, never key, so a click on it keeps
/// key status, and with it the shortcuts, on the pin.
private final class BarPanel: OverlayPanel {
    private let tooltip = BarTooltip()

    override var canBecomeKey: Bool { false }

    init(model: BarModel, pins: ScreenshotPinController,
         perform: @escaping (ScreenshotPinAction, NSView?) -> Void,
         openMenu: @escaping (BarMenu, NSView) -> Void,
         dragWriter: @escaping () -> NSPasteboardWriting?,
         dragImage: @escaping () -> CGImage?) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        let view = BarView(model: model, pins: pins, anchors: BarAnchors(), tooltip: tooltip, perform: perform,
                           openMenu: openMenu, dragWriter: dragWriter, dragImage: dragImage)
        contentView = FirstMouseHostingView(rootView: view)
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        tooltip.bar = self
    }

    /// A press hides the tooltip until the pointer enters an item again.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown || event.type == .rightMouseDown { tooltip.dismiss() }
        super.sendEvent(event)
    }

    override func orderOut(_ sender: Any?) {
        tooltip.dismiss()
        super.orderOut(sender)
    }

    func dismissTooltip() {
        tooltip.dismiss()
    }

    /// The bar's size for its current slots (QR adds one).
    var fittingSize: CGSize {
        contentView?.layoutSubtreeIfNeeded()
        return contentView?.fittingSize ?? .zero
    }
}

/// A never-key window's first click must still press a SwiftUI button.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The views a picker or menu opens beside.
private final class BarAnchors {
    let share = ShareAnchor()
    let saveMenu = ShareAnchor()
    let settings = ShareAnchor()
}

private struct BarView: View {
    @ObservedObject var model: BarModel
    /// For the badge only (`pins.hiddenCount`, derived from the stack).
    @ObservedObject var pins: ScreenshotPinController
    let anchors: BarAnchors
    let tooltip: BarTooltip
    let perform: (ScreenshotPinAction, NSView?) -> Void
    let openMenu: (BarMenu, NSView) -> Void
    let dragWriter: () -> NSPasteboardWriting?
    let dragImage: () -> CGImage?
    @ObservedObject private var l10n = L10n.shared

    private static let side: CGFloat = 26

    var body: some View {
        HStack(spacing: 2) {
            ForEach(ScreenshotPinBarSlot.bar(model.context), id: \.self) { slot in
                view(for: slot)
                    .background(TooltipAnchor(text: slot.tooltip(l10n.s), tooltip: tooltip))
            }
        }
        .padding(5)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))
        .fixedSize()
    }

    @ViewBuilder
    private func view(for slot: ScreenshotPinBarSlot) -> some View {
        switch slot {
        case .action(let action):
            actionView(action)
        case .dragHandle:
            icon(slot.symbol)
                .overlay(DragSourceView(writer: dragWriter, image: dragImage))
        case .settings:
            iconButton(slot.symbol) { if let view = anchors.settings.view { openMenu(.settings, view) } }
                .background(ShareAnchorView(anchor: anchors.settings))
        }
    }

    @ViewBuilder
    private func actionView(_ action: ScreenshotPinAction) -> some View {
        let busy = action.availability(model.context) == .busy
        let button = iconButton(busy ? "ellipsis" : action.symbol, enabled: !busy) { perform(action, nil) }
        switch action {
        case .share:
            button.background(ShareAnchorView(anchor: anchors.share))
        case .close:
            button.overlay(alignment: .topTrailing) {
                if pins.hiddenCount > 0 {
                    Text("\(pins.hiddenCount)")
                        .font(.system(size: 9, weight: .bold))
                        .monospacedDigit()
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.accentColor, in: Capsule())
                        .foregroundStyle(.white)
                        .offset(x: 4, y: -4)
                        .accessibilityLabel(String(format: l10n.s.screenshotPinHiddenFormat, pins.hiddenCount))
                }
            }
        case .save, .copy, .extractText, .edit, .showCode, .saveAs, .openSettings, .closeAll:
            if action.menuActions.isEmpty {
                button
            } else {
                HStack(spacing: 0) {
                    button
                    Button {
                        if let view = anchors.saveMenu.view { openMenu(.button(action), view) }
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                            .frame(width: 12, height: Self.side)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(ShareAnchorView(anchor: anchors.saveMenu))
                }
            }
        }
    }

    private func iconButton(_ symbol: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) { icon(symbol) }
            .buttonStyle(.plain)
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.45)
    }

    private func icon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .medium))
            .frame(width: Self.side, height: Self.side)
            .contentShape(Rectangle())
    }
}

// MARK: - Bar tooltip

/// Risk R6: SwiftUI `.help` took 8 to 10 s to appear in the never-key bar of
/// an inactive app (owner test), so the bar shows its own tooltip. Hover
/// comes from `.activeAlways` tracking areas, which fire whichever app is
/// active. The timing rules are `ScreenshotPinTooltipTiming`.
private final class BarTooltip {
    weak var bar: NSWindow?
    private var timing = ScreenshotPinTooltipTiming<ObjectIdentifier>()
    private weak var hovered: TooltipAnchorNSView?
    private var panel: TooltipPanel?

    func entered(_ anchor: TooltipAnchorNSView) {
        hovered = anchor
        run(timing.enter(ObjectIdentifier(anchor), at: Self.now))
    }

    func exited(_ anchor: TooltipAnchorNSView) {
        run(timing.exit(ObjectIdentifier(anchor)))
    }

    func textChanged(_ anchor: TooltipAnchorNSView) {
        if timing.isShown, timing.item == ObjectIdentifier(anchor) { show() }
    }

    func dismiss() {
        timing.dismiss()
        hide()
    }

    private func run(_ effect: ScreenshotPinTooltipTiming<ObjectIdentifier>.Effect) {
        switch effect {
        case .none:
            break
        case .show:
            show()
        case .hide:
            hide()
        case .wait(let seconds):
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                guard let self else { return }
                self.run(self.timing.tick(at: Self.now))
            }
        }
    }

    /// A child of the bar, so it follows a dragged pin and the bar's level.
    private func show() {
        guard let bar, bar.isVisible, let anchor = hovered, anchor.window === bar else { return }
        let panel = self.panel ?? TooltipPanel()
        self.panel = panel
        // Measured: a child does not inherit it; without it the tooltip is missing in full-screen Spaces.
        panel.collectionBehavior = bar.collectionBehavior
        panel.text = anchor.text
        let item = bar.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let visible = (bar.screen ?? NSScreen.main)?.visibleFrame ?? item
        let pinIsAbove = bar.parent.map { $0.frame.midY > bar.frame.midY } ?? true
        panel.setFrame(ScreenshotPinLayout.tooltipFrame(itemFrame: item, size: panel.fittingSize,
                                                        preferAbove: !pinIsAbove, visibleFrame: visible),
                       display: true)
        if panel.parent == nil { bar.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
    }

    private func hide() {
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
}

/// One bar item's hover area: behind the item and never hit, so it takes
/// no click from it.
private struct TooltipAnchor: NSViewRepresentable {
    let text: String
    let tooltip: BarTooltip

    func makeNSView(context: Context) -> TooltipAnchorNSView {
        TooltipAnchorNSView(tooltip: tooltip)
    }

    func updateNSView(_ nsView: TooltipAnchorNSView, context: Context) {
        nsView.text = text
    }
}

private final class TooltipAnchorNSView: NSView {
    private weak var tooltip: BarTooltip?

    var text = "" {
        didSet { if text != oldValue { tooltip?.textChanged(self) } }
    }

    init(tooltip: BarTooltip) {
        self.tooltip = tooltip
        super.init(frame: .zero)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func mouseEntered(with event: NSEvent) {
        tooltip?.entered(self)
    }

    override func mouseExited(with event: NSEvent) {
        tooltip?.exited(self)
    }

    /// A slot that goes away under the pointer (the QR button, a language
    /// change) never gets its exit event.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { tooltip?.exited(self) }
    }
}

/// The system tooltip look: tooltip material, tooltip font, rounded by a mask.
private final class TooltipPanel: OverlayPanel {
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        let background = NSVisualEffectView()
        background.material = .toolTip
        background.state = .active
        let radius: CGFloat = 5
        let mask = NSImage(size: CGSize(width: radius * 2 + 1, height: radius * 2 + 1), flipped: false) { rect in
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        mask.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        mask.resizingMode = .stretch
        background.maskImage = mask
        label.font = .toolTipsFont(ofSize: 0)
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 7),
            label.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -7),
            label.topAnchor.constraint(equalTo: background.topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -3),
        ])
        contentView = background
    }

    override var canBecomeKey: Bool { false }

    var text: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }

    var fittingSize: CGSize {
        contentView?.layoutSubtreeIfNeeded()
        return contentView?.fittingSize ?? .zero
    }
}

// MARK: - Text panel

private final class TextPanelModel: ObservableObject {
    /// nil while OCR runs.
    @Published var text: String?

    init(text: String?) {
        self.text = text
    }
}

/// The extracted text beside its pin, at a fixed size so it never jumps
/// when the text arrives: a progress state, then the text, selectable with
/// Copy All. A child of the pin, so it moves with it. It can be key, so a
/// selection and ⌘C (the main menu's Edit ▸ Copy) work; the pin treats that
/// as staying selected. Esc or its close button closes it.
private final class TextPanel: OverlayPanel {
    static let size = CGSize(width: 320, height: 300)
    private let onClose: () -> Void

    init(model: TextPanelModel, copyAll: @escaping (String) -> Void, onClose: @escaping () -> Void) {
        self.onClose = onClose
        super.init(contentRect: CGRect(origin: .zero, size: Self.size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        contentView = FirstMouseHostingView(rootView: TextPanelView(model: model, copyAll: copyAll, close: onClose))
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
    }

    override var canBecomeKey: Bool { true }

    /// A click into the text keys the panel by hand, so ⌘C reaches the
    /// selection rather than the pin.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, !isKeyWindow { makeKey() }
        super.sendEvent(event)
    }

    override func keyDown(with event: NSEvent) {
        if Int(event.keyCode) == kVK_Escape { onClose() } else { super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) {
        onClose()
    }
}

private struct TextPanelView: View {
    @ObservedObject var model: TextPanelModel
    let copyAll: (String) -> Void
    let close: () -> Void
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        let s = l10n.s
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "text.viewfinder")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text(s.screenshotPinTextTitle)
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
                Button(s.screenshotPinTextCopyAll) { model.text.map(copyAll) }
                    .controlSize(.small)
                    .disabled(model.text?.isEmpty ?? true)
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 20, height: 20)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(s.screenshotPinClose + "  (⎋)")
            }
            Group {
                if let text = model.text {
                    if text.isEmpty {
                        Text(s.screenshotPreviewNoText)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView(.vertical) {
                            Text(text)
                                .font(.system(size: 12.5))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                        }
                    }
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))
        }
        .padding(14)
        .frame(width: TextPanel.size.width, height: TextPanel.size.height)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))
    }
}

// MARK: - Menu adapter

/// The one adapter from menu nodes to `NSMenu`: Save menu, Settings menu,
/// right-click menu. The root menu brackets its open and close as a `.menu`
/// transient through its delegate.
private enum MenuBuilder {
    static func menu(_ nodes: [ScreenshotPinMenuNode], strings: Strings,
                     perform: @escaping (ScreenshotPinAction) -> Void,
                     setOpacity: @escaping (ScreenshotPinOpacity) -> Void,
                     transient: @escaping (Bool) -> Void) -> NSMenu {
        let handler = MenuHandler(perform: perform, setOpacity: setOpacity, transient: transient)
        let menu = build(nodes, strings: strings, handler: handler)
        menu.delegate = handler
        return menu
    }

    private static func build(_ nodes: [ScreenshotPinMenuNode], strings: Strings, handler: MenuHandler) -> PinMenu {
        let menu = PinMenu(handler: handler)
        for node in nodes {
            switch node {
            case .action(let action, let enabled):
                let chord = action.shortcuts.first
                let item = NSMenuItem(title: strings[keyPath: action.title], action: #selector(MenuHandler.run(_:)),
                                      keyEquivalent: chord.map(Self.keyEquivalent) ?? "")
                item.keyEquivalentModifierMask = chord.map(Self.modifiers) ?? []
                item.target = handler
                item.isEnabled = enabled
                item.representedObject = MenuPayload.action(action)
                menu.addItem(item)
            case .opacity(let opacity, let checked):
                let item = NSMenuItem(title: opacity.label, action: #selector(MenuHandler.run(_:)), keyEquivalent: "")
                item.target = handler
                item.state = checked ? .on : .off
                item.representedObject = MenuPayload.opacity(opacity)
                menu.addItem(item)
            case .submenu(let submenu, let children):
                let item = NSMenuItem(title: strings[keyPath: submenu.title], action: nil, keyEquivalent: "")
                item.submenu = build(children, strings: strings, handler: handler)
                menu.addItem(item)
            case .separator:
                menu.addItem(.separator())
            }
        }
        return menu
    }

    private static func keyEquivalent(_ chord: ScreenshotPinChord) -> String {
        switch chord.keyCode {
        case kVK_Escape: return "\u{1b}"
        case kVK_ANSI_S: return "s"
        case kVK_ANSI_C: return "c"
        case kVK_ANSI_E: return "e"
        case kVK_ANSI_T: return "t"
        case kVK_ANSI_W: return "w"
        default: return ""
        }
    }

    private static func modifiers(_ chord: ScreenshotPinChord) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if chord.command { flags.insert(.command) }
        if chord.shift { flags.insert(.shift) }
        return flags
    }
}

private enum MenuPayload {
    case action(ScreenshotPinAction)
    case opacity(ScreenshotPinOpacity)
}

/// Retained by its menus; every item's target and the root menu's delegate.
private final class MenuHandler: NSObject, NSMenuDelegate {
    private let perform: (ScreenshotPinAction) -> Void
    private let setOpacity: (ScreenshotPinOpacity) -> Void
    private let transient: (Bool) -> Void

    init(perform: @escaping (ScreenshotPinAction) -> Void, setOpacity: @escaping (ScreenshotPinOpacity) -> Void,
         transient: @escaping (Bool) -> Void) {
        self.perform = perform
        self.setOpacity = setOpacity
        self.transient = transient
    }

    @objc func run(_ sender: NSMenuItem) {
        switch sender.representedObject as? MenuPayload {
        case .action(let action): perform(action)
        case .opacity(let opacity): setOpacity(opacity)
        case nil: break
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        transient(true)
    }

    func menuDidClose(_ menu: NSMenu) {
        transient(false)
    }
}

private final class PinMenu: NSMenu {
    private let handler: MenuHandler

    init(handler: MenuHandler) {
        self.handler = handler
        super.init(title: "")
        autoenablesItems = false
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

// MARK: - Drag-out and file promise

/// A transparent view that starts an AppKit drag, since a file promise needs
/// a dragging session rather than SwiftUI's item provider. Drag only: a
/// click on the handle does nothing.
private struct DragSourceView: NSViewRepresentable {
    let writer: () -> NSPasteboardWriting?
    let image: () -> CGImage?

    func makeNSView(context: Context) -> DragSourceNSView {
        let view = DragSourceNSView()
        update(view)
        return view
    }

    func updateNSView(_ nsView: DragSourceNSView, context: Context) {
        update(nsView)
    }

    private func update(_ view: DragSourceNSView) {
        view.writer = writer
        view.image = image
    }
}

private final class DragSourceNSView: NSView, NSDraggingSource {
    var writer: (() -> NSPasteboardWriting?)?
    var image: (() -> CGImage?)?
    private var downAt: CGPoint?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        downAt = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = downAt, let writer = writer?(), let image = image?() else { return }
        let point = event.locationInWindow
        guard hypot(point.x - start.x, point.y - start.y) > 3 else { return }
        downAt = nil
        let item = NSDraggingItem(pasteboardWriter: writer)
        let ratio = CGFloat(image.width) / CGFloat(max(1, image.height))
        let side: CGFloat = 120
        let size = ratio >= 1 ? CGSize(width: side, height: side / ratio) : CGSize(width: side * ratio, height: side)
        let local = convert(point, from: nil)
        item.setDraggingFrame(CGRect(x: local.x - size.width / 2, y: local.y - size.height / 2,
                                     width: size.width, height: size.height),
                              contents: NSImage(cgImage: image, size: size))
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        downAt = nil
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : []
    }
}

/// A dragged capture: a file promise for Finder and folders, plus PNG data
/// for apps that take an image.
private final class ScreenshotPromiseProvider: NSFilePromiseProvider, NSFilePromiseProviderDelegate {
    private let png: Data
    private let name: String

    init(png: Data, fileName: String) {
        self.png = png
        self.name = fileName
        super.init()
        fileType = UTType.png.identifier
        delegate = self
    }

    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        super.writableTypes(for: pasteboard) + [.png]
    }

    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        type == .png ? png : super.pasteboardPropertyList(forType: type)
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        name
    }

    /// Writes a new file only. When the name is taken in the drop folder, the
    /// next free ` (2)` name is used instead of replacing anything.
    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL,
                             completionHandler: @escaping (Error?) -> Void) {
        let folder = url.deletingLastPathComponent()
        let manager = FileManager.default
        let target: URL
        if manager.fileExists(atPath: url.path) {
            guard let free = ScreenshotSupport.uniqueFileName(url.lastPathComponent, exists: {
                manager.fileExists(atPath: folder.appendingPathComponent($0).path)
            }) else {
                completionHandler(CocoaError(.fileWriteFileExists))
                return
            }
            target = folder.appendingPathComponent(free)
        } else {
            target = url
        }
        do {
            try png.write(to: target, options: .withoutOverwriting)
            ScreenshotSupport.markAsScreenCapture(target)
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
    }
}
