// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

/// State the bottom bar on every display shares.
final class ScreenshotOverlayOptions: ObservableObject {
    @Published var tool: ScreenCaptureTool = .screenshot
    @Published var loupe = false
    @Published var scrolling = false
    @Published var hasLastRegion = false
    /// A short line under the bar: a copied colour, or why a key did nothing.
    @Published var notice: String?
}

/// One capture session: a frozen image of every display under a dim panel
/// per display. A drag picks a region, a click the window under the pointer,
/// Enter the whole display. The bar and keys switch tools and modes.
/// Rewritten for FixDock from the upstream selection controller; the frozen
/// backdrop, window highlight, loupe and key map follow upstream.
final class ScreenshotOverlayController {
    enum Result {
        case cancelled
        /// `anchor` is the captured area in Cocoa screen points.
        case image(CGImage, anchor: CGRect)
        /// A region for scrolling capture, in the display's own points.
        case scrolling(displayID: CGDirectDisplayID, localRect: CGRect)
        case failed
    }

    var onFinish: ((Result) -> Void)?
    let options = ScreenshotOverlayOptions()

    private let frozen: [CGDirectDisplayID: CGImage]
    private let windows: [ScreenshotSupport.PickableWindow]
    private var panels: [ScreenshotOverlayPanel] = []
    private var keyMonitor: Any?
    private var globalKeyMonitor: Any?
    private var finished = false
    private var noticeWork: DispatchWorkItem?
    fileprivate var spaceIsDown = false

    init(frozen: [CGDirectDisplayID: CGImage], windows: [ScreenshotSupport.PickableWindow]) {
        self.frozen = frozen
        self.windows = windows
    }

    func present() {
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        for screen in NSScreen.screens {
            guard let image = frozen[screen.displayID] else { continue }
            let panel = ScreenshotOverlayPanel(screen: screen, frozenImage: image,
                                               windows: windows, mainScreenHeight: mainHeight,
                                               controller: self)
            panels.append(panel)
            panel.orderFrontRegardless()
        }
        guard !panels.isEmpty else {
            finish(.failed)
            return
        }
        options.hasLastRegion = lastRegion(for: panelUnderMouse()?.displayID ?? 0) != nil
        panelUnderMouse()?.makeKey()
        NSCursor.crosshair.set()
        installKeyMonitors()
        panels.forEach { $0.overlayView.pointerMoved(to: $0.mouseLocationInView) }
    }

    func cancel() {
        finish(.cancelled)
    }

    // MARK: - From the views

    fileprivate func pointerEntered(_ panel: ScreenshotOverlayPanel) {
        for other in panels where other !== panel {
            other.overlayView.clearPointer()
        }
        if !panel.isKeyWindow { panel.makeKey() }
        options.hasLastRegion = lastRegion(for: panel.displayID) != nil
    }

    fileprivate func pickWindow(_ window: ScreenshotSupport.PickableWindow) {
        guard !finished else { return }
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        let anchor = ScreenshotSupport.flipped(window.frame, mainScreenHeight: mainHeight)
        closePanels()
        Task { @MainActor in
            let image = await ScreenshotCaptureEngine.captureWindow(window.id)
            self.finish(image.map { Result.image($0, anchor: anchor) } ?? .failed)
        }
    }

    fileprivate func pickRegion(_ localRect: CGRect, on panel: ScreenshotOverlayPanel) {
        guard !finished, localRect.width >= 1, localRect.height >= 1 else { return }
        rememberRegion(localRect, for: panel.displayID)
        if options.scrolling {
            finish(.scrolling(displayID: panel.displayID, localRect: localRect))
            return
        }
        guard let image = panel.crop(localRect) else {
            finish(.failed)
            return
        }
        finish(.image(image, anchor: panel.screenRect(for: localRect)))
    }

    fileprivate func pickWholeDisplay(_ panel: ScreenshotOverlayPanel) {
        guard !finished else { return }
        finish(.image(panel.frozenImage, anchor: panel.screenFrame))
    }

    // MARK: - Keys

    private func installKeyMonitors() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self, event.window is ScreenshotOverlayPanel else { return event }
            return self.handle(event) ? nil : event
        }
        // A panel that lost key status still hears Esc.
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == UInt16(kVK_Escape) else { return }
            self?.cancel()
        }
    }

    /// True when the event was used.
    private func handle(_ event: NSEvent) -> Bool {
        if event.type == .keyUp {
            guard event.keyCode == UInt16(kVK_Space), spaceIsDown else { return false }
            spaceIsDown = false
            return true
        }
        let panel = panelUnderMouse()
        switch Int(event.keyCode) {
        case kVK_Escape:
            cancel()
            return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if let panel { pickWholeDisplay(panel) }
            return true
        case kVK_Space:
            // Holding Space while dragging moves the selection.
            guard panel?.overlayView.isDragging == true else { return false }
            spaceIsDown = true
            return true
        default:
            break
        }
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        if let tool = ScreenCaptureTool.matchingShortcut(event.charactersIgnoringModifiers)
            ?? Self.digitTool(keyCode: Int(event.keyCode)) {
            select(tool)
            return true
        }
        if Self.matches(event, "r", kVK_ANSI_R) {
            repeatLastRegion()
            return true
        }
        if Self.matches(event, "z", kVK_ANSI_Z) {
            toggleLoupe()
            return true
        }
        if Self.matches(event, "c", kVK_ANSI_C) {
            copyColor()
            return true
        }
        if Self.matches(event, "s", kVK_ANSI_S) {
            toggleScrolling()
            return true
        }
        if let delta = Self.nudge(keyCode: Int(event.keyCode)) {
            guard options.loupe, panel?.overlayView.isDragging == false else { return false }
            nudgePointer(by: delta, fast: event.modifierFlags.contains(.shift))
            return true
        }
        return false
    }

    func select(_ tool: ScreenCaptureTool) {
        guard ScreenCaptureTool.shown().contains(tool) else { return }
        guard tool.isImplemented else {
            showNotice(L10n.shared.s.screenshotRecordingLater)
            return
        }
        options.tool = tool
    }

    func toggleLoupe() {
        options.loupe.toggle()
        panels.forEach { $0.overlayView.needsDisplay = true }
    }

    func toggleScrolling() {
        options.scrolling.toggle()
    }

    func repeatLastRegion() {
        guard let panel = panelUnderMouse(), let rect = lastRegion(for: panel.displayID) else {
            showNotice(L10n.shared.s.screenshotNoLastRegion)
            return
        }
        pickRegion(rect, on: panel)
    }

    func copyColor() {
        guard options.loupe else {
            showNotice(L10n.shared.s.screenshotColorNeedsLoupe)
            return
        }
        guard let panel = panelUnderMouse(), let hex = panel.overlayView.colorUnderPointer() else { return }
        ScreenshotService.copyText(hex)
        showNotice(String(format: L10n.shared.s.screenshotColorCopied, hex))
    }

    /// One device pixel per press, ten with Shift. The pointer may cross onto
    /// a neighbouring display.
    private func nudgePointer(by delta: CGPoint, fast: Bool) {
        let scale = panelUnderMouse()?.pixelScale ?? 2
        let step = (fast ? 10 : 1) / scale
        let location = NSEvent.mouseLocation
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        let target = CGPoint(x: location.x + delta.x * step, y: mainHeight - (location.y + delta.y * step))
        CGWarpMouseCursorPosition(target)
        CGAssociateMouseAndMouseCursorPosition(1)
        panels.forEach { $0.overlayView.pointerMoved(to: $0.mouseLocationInView) }
        if let panel = panelUnderMouse() { pointerEntered(panel) }
    }

    private func showNotice(_ text: String) {
        options.notice = text
        noticeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.options.notice = nil }
        noticeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    private static func matches(_ event: NSEvent, _ character: String, _ keyCode: Int) -> Bool {
        event.charactersIgnoringModifiers?.lowercased() == character || Int(event.keyCode) == keyCode
    }

    /// The physical digit row, for layouts whose digit keys type something else.
    private static func digitTool(keyCode: Int) -> ScreenCaptureTool? {
        switch keyCode {
        case kVK_ANSI_1, kVK_ANSI_Keypad1: return .screenshot
        case kVK_ANSI_2, kVK_ANSI_Keypad2: return .recording
        default: return nil
        }
    }

    private static func nudge(keyCode: Int) -> CGPoint? {
        switch keyCode {
        case kVK_LeftArrow: return CGPoint(x: -1, y: 0)
        case kVK_RightArrow: return CGPoint(x: 1, y: 0)
        case kVK_UpArrow: return CGPoint(x: 0, y: 1)
        case kVK_DownArrow: return CGPoint(x: 0, y: -1)
        default: return nil
        }
    }

    // MARK: - Last region

    private func lastRegion(for displayID: CGDirectDisplayID) -> CGRect? {
        let saved = UserDefaults.standard.dictionary(forKey: DefaultsKey.screenshotLastRegions) as? [String: String]
        return saved?[String(displayID)].flatMap(ScreenshotSupport.decodeRegion)
    }

    private func rememberRegion(_ rect: CGRect, for displayID: CGDirectDisplayID) {
        var saved = UserDefaults.standard.dictionary(forKey: DefaultsKey.screenshotLastRegions) as? [String: String] ?? [:]
        saved[String(displayID)] = ScreenshotSupport.encodeRegion(rect)
        UserDefaults.standard.set(saved, forKey: DefaultsKey.screenshotLastRegions)
    }

    // MARK: - Ending

    private func panelUnderMouse() -> ScreenshotOverlayPanel? {
        let location = NSEvent.mouseLocation
        return panels.first { NSMouseInRect(location, $0.screenFrame, false) } ?? panels.first
    }

    private func closePanels() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let globalKeyMonitor { NSEvent.removeMonitor(globalKeyMonitor) }
        keyMonitor = nil
        globalKeyMonitor = nil
        noticeWork?.cancel()
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
        NSCursor.arrow.set()
    }

    private func finish(_ result: Result) {
        guard !finished else { return }
        finished = true
        closePanels()
        onFinish?(result)
    }
}

/// Full-screen borderless panel for one display. It never activates the app;
/// it becomes key so the keys reach it.
final class ScreenshotOverlayPanel: OverlayPanel {
    let screenFrame: CGRect
    let displayID: CGDirectDisplayID
    let frozenImage: CGImage
    /// Image pixels per point on this display.
    let pixelScale: CGFloat
    private(set) var overlayView: ScreenshotOverlayView!

    init(screen: NSScreen, frozenImage: CGImage, windows: [ScreenshotSupport.PickableWindow],
         mainScreenHeight: CGFloat, controller: ScreenshotOverlayController) {
        screenFrame = screen.frame
        displayID = screen.displayID
        self.frozenImage = frozenImage
        pixelScale = screen.frame.width > 0 ? CGFloat(frozenImage.width) / screen.frame.width : 1
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        animationBehavior = .none
        level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        acceptsMouseMovedEvents = true
        ignoresMouseEvents = false

        let bounds = CGRect(origin: .zero, size: screen.frame.size)
        let container = NSView(frame: bounds)
        let imageView = NSImageView(frame: bounds)
        imageView.image = NSImage(cgImage: frozenImage, size: screen.frame.size)
        imageView.imageScaling = .scaleAxesIndependently
        imageView.autoresizingMask = [.width, .height]
        container.addSubview(imageView)

        // Window frames in this display's own points, top-left origin.
        let displayOrigin = ScreenshotSupport.flipped(screen.frame, mainScreenHeight: mainScreenHeight).origin
        let localWindows = windows.compactMap { window -> ScreenshotSupport.PickableWindow? in
            let local = window.frame.offsetBy(dx: -displayOrigin.x, dy: -displayOrigin.y)
            guard local.intersects(bounds) else { return nil }
            return ScreenshotSupport.PickableWindow(id: window.id, ownerPID: window.ownerPID, frame: local)
        }
        let view = ScreenshotOverlayView(frame: bounds, frozenImage: frozenImage,
                                         pixelScale: pixelScale, windows: localWindows,
                                         controller: controller)
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
        overlayView = view
        view.panel = self

        let bar = NSHostingView(rootView: ScreenshotOverlayBar(options: controller.options,
                                                               controller: controller))
        bar.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            bar.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -40),
        ])
        contentView = container
    }

    override var canBecomeKey: Bool { true }

    /// A rect in this display's flipped local points, in Cocoa screen points.
    func screenRect(for localRect: CGRect) -> CGRect {
        CGRect(x: screenFrame.minX + localRect.minX, y: screenFrame.maxY - localRect.maxY,
               width: localRect.width, height: localRect.height)
    }

    /// The pointer in the overlay view's flipped coordinates.
    var mouseLocationInView: CGPoint {
        let location = NSEvent.mouseLocation
        return CGPoint(x: location.x - screenFrame.minX, y: screenFrame.maxY - location.y)
    }

    func crop(_ localRect: CGRect) -> CGImage? {
        let pixels = ScreenshotSupport.pixelRect(localRect, scale: pixelScale,
                                                 imageSize: CGSize(width: frozenImage.width,
                                                                   height: frozenImage.height))
        guard pixels.width >= 1, pixels.height >= 1 else { return nil }
        return frozenImage.cropping(to: pixels)
    }
}

/// Dim, selection, window highlight, size label and loupe for one display.
/// Flipped: the origin is the display's top left, in points.
final class ScreenshotOverlayView: NSView {
    weak var panel: ScreenshotOverlayPanel?
    private unowned let controller: ScreenshotOverlayController
    private let frozenImage: CGImage
    private let pixelScale: CGFloat
    private let windows: [ScreenshotSupport.PickableWindow]
    private var pointer: CGPoint?
    private var hoverWindow: ScreenshotSupport.PickableWindow?
    private var dragStart: CGPoint?
    private var dragEnd: CGPoint?
    private var lastDragPoint: CGPoint?
    private var options: ScreenshotOverlayOptions { controller.options }
    private var optionsWatch: AnyCancellable?

    var isDragging: Bool { dragStart != nil }

    init(frame: CGRect, frozenImage: CGImage, pixelScale: CGFloat,
         windows: [ScreenshotSupport.PickableWindow], controller: ScreenshotOverlayController) {
        self.frozenImage = frozenImage
        self.pixelScale = pixelScale
        self.windows = windows
        self.controller = controller
        super.init(frame: frame)
        optionsWatch = controller.options.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.needsDisplay = true }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    // MARK: Pointer

    func pointerMoved(to point: CGPoint) {
        guard bounds.contains(point) else {
            clearPointer()
            return
        }
        pointer = point
        if !isDragging {
            hoverWindow = options.scrolling ? nil : ScreenshotSupport.window(at: point, in: windows)
        }
        needsDisplay = true
    }

    func clearPointer() {
        guard pointer != nil || hoverWindow != nil else { return }
        pointer = nil
        hoverWindow = nil
        needsDisplay = true
    }

    override func mouseEntered(with event: NSEvent) {
        if let panel { controller.pointerEntered(panel) }
        NSCursor.crosshair.set()
    }

    override func mouseMoved(with event: NSEvent) {
        if let panel { controller.pointerEntered(panel) }
        pointerMoved(to: convert(event.locationInWindow, from: nil))
        NSCursor.crosshair.set()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        dragStart = point
        dragEnd = point
        lastDragPoint = point
        pointer = point
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if controller.spaceIsDown, let last = lastDragPoint, let start = dragStart, let end = dragEnd {
            let dx = point.x - last.x
            let dy = point.y - last.y
            dragStart = CGPoint(x: start.x + dx, y: start.y + dy)
            dragEnd = CGPoint(x: end.x + dx, y: end.y + dy)
        } else {
            dragEnd = point
        }
        lastDragPoint = point
        pointer = point
        hoverWindow = nil
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let start = dragStart, let panel else { return }
        let end = dragEnd ?? start
        dragStart = nil
        dragEnd = nil
        lastDragPoint = nil
        if ScreenshotSupport.isClick(from: start, to: end) {
            let point = convert(event.locationInWindow, from: nil)
            if !options.scrolling, let window = ScreenshotSupport.window(at: point, in: windows) {
                controller.pickWindow(window)
            } else {
                pointerMoved(to: point)
            }
            return
        }
        let rect = ScreenshotSupport.clamp(ScreenshotSupport.rect(from: start, to: end), to: bounds)
        controller.pickRegion(rect, on: panel)
    }

    override func rightMouseDown(with event: NSEvent) {
        controller.cancel()
    }

    // MARK: Drawing

    private var selection: CGRect? {
        guard let start = dragStart, let end = dragEnd, !ScreenshotSupport.isClick(from: start, to: end)
        else { return nil }
        return ScreenshotSupport.clamp(ScreenshotSupport.rect(from: start, to: end), to: bounds)
    }

    override func draw(_ dirtyRect: NSRect) {
        let highlight = selection ?? hoverWindow?.frame.intersection(bounds)
        let dim = NSBezierPath(rect: bounds)
        if let highlight {
            dim.append(NSBezierPath(rect: highlight))
            dim.windingRule = .evenOdd
        }
        NSColor.black.withAlphaComponent(0.35).setFill()
        dim.fill()

        if let highlight {
            let border = NSBezierPath(rect: highlight.insetBy(dx: 0.5, dy: 0.5))
            border.lineWidth = 1
            (selection == nil ? NSColor.controlAccentColor : NSColor.white).setStroke()
            border.stroke()
            if let selection { drawSizeLabel(for: selection) }
        }
        if options.loupe, let pointer, bounds.contains(pointer) {
            drawLoupe(at: pointer)
        }
    }

    private func drawSizeLabel(for rect: CGRect) {
        let text = "\(Int((rect.width * pixelScale).rounded())) × \(Int((rect.height * pixelScale).rounded()))"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        var origin = CGPoint(x: rect.minX, y: rect.maxY + 6)
        if origin.y + size.height + 6 > bounds.maxY { origin.y = rect.minY - size.height - 10 }
        origin.y = max(4, origin.y)
        let box = CGRect(x: origin.x, y: origin.y, width: size.width + 10, height: size.height + 4)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
        (text as NSString).draw(at: CGPoint(x: box.minX + 5, y: box.minY + 2), withAttributes: attributes)
    }

    /// Pixels on each side of the centre pixel the loupe shows.
    private static let loupeRadius = 7
    private static let loupeCell: CGFloat = 9

    private var pointerPixel: (x: Int, y: Int)? {
        guard let pointer else { return nil }
        let x = Int((pointer.x * pixelScale).rounded(.down))
        let y = Int((pointer.y * pixelScale).rounded(.down))
        guard x >= 0, y >= 0, x < frozenImage.width, y < frozenImage.height else { return nil }
        return (x, y)
    }

    private func drawLoupe(at point: CGPoint) {
        guard let pixel = pointerPixel, let context = NSGraphicsContext.current?.cgContext else { return }
        let radius = Self.loupeRadius
        let span = radius * 2 + 1
        let side = CGFloat(span) * Self.loupeCell
        var origin = CGPoint(x: point.x + 24, y: point.y + 24)
        if origin.x + side > bounds.maxX { origin.x = point.x - 24 - side }
        if origin.y + side + 24 > bounds.maxY { origin.y = point.y - 24 - side - 22 }
        let frame = CGRect(origin: origin, size: CGSize(width: side, height: side))

        let source = CGRect(x: pixel.x - radius, y: pixel.y - radius, width: span, height: span)
        context.saveGState()
        let clip = NSBezierPath(roundedRect: frame, xRadius: 6, yRadius: 6)
        clip.addClip()
        NSColor.black.setFill()
        frame.fill()
        if let crop = frozenImage.cropping(to: source.intersection(
            CGRect(x: 0, y: 0, width: frozenImage.width, height: frozenImage.height))) {
            // Cells off the image edge stay black; the crop sits where its
            // pixels belong in the grid.
            let offsetX = CGFloat(max(0, -source.minX)) * Self.loupeCell
            let offsetY = CGFloat(max(0, -source.minY)) * Self.loupeCell
            let drawRect = CGRect(x: frame.minX + offsetX, y: frame.minY + offsetY,
                                  width: CGFloat(crop.width) * Self.loupeCell,
                                  height: CGFloat(crop.height) * Self.loupeCell)
            context.interpolationQuality = .none
            // The view is flipped; draw the image upright.
            context.translateBy(x: 0, y: drawRect.minY + drawRect.maxY)
            context.scaleBy(x: 1, y: -1)
            context.draw(crop, in: drawRect)
        }
        context.restoreGState()

        let center = CGRect(x: frame.minX + CGFloat(radius) * Self.loupeCell,
                            y: frame.minY + CGFloat(radius) * Self.loupeCell,
                            width: Self.loupeCell, height: Self.loupeCell)
        NSColor.white.setStroke()
        let ring = NSBezierPath(rect: center)
        ring.lineWidth = 1.5
        ring.stroke()
        NSColor.white.withAlphaComponent(0.8).setStroke()
        let edge = NSBezierPath(roundedRect: frame, xRadius: 6, yRadius: 6)
        edge.lineWidth = 1
        edge.stroke()

        if let hex = colorUnderPointer() {
            let label = "\(hex)  \(pixel.x), \(pixel.y)"
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .medium),
                .foregroundColor: NSColor.white,
            ]
            let box = CGRect(x: frame.minX, y: frame.maxY + 4, width: side, height: 18)
            NSColor.black.withAlphaComponent(0.75).setFill()
            NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
            (label as NSString).draw(at: CGPoint(x: box.minX + 6, y: box.minY + 3), withAttributes: attributes)
        }
    }

    /// The frozen pixel under the pointer as `#RRGGBB`.
    func colorUnderPointer() -> String? {
        guard let pixel = pointerPixel,
              let crop = frozenImage.cropping(to: CGRect(x: pixel.x, y: pixel.y, width: 1, height: 1))
        else { return nil }
        var bytes = [UInt8](repeating: 0, count: 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8,
                                      bytesPerRow: 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return ScreenshotSupport.hexColor(red: bytes[0], green: bytes[1], blue: bytes[2])
    }
}

/// The bar at the bottom of every display: tools, then the mode keys.
struct ScreenshotOverlayBar: View {
    @ObservedObject var options: ScreenshotOverlayOptions
    let controller: ScreenshotOverlayController
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        let s = l10n.s
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                ForEach(ScreenCaptureTool.shown()) { tool in
                    toolButton(tool, s)
                }
                Divider().frame(height: 22)
                keyButton("R", s.screenshotKeyRepeat, on: false, enabled: options.hasLastRegion) {
                    controller.repeatLastRegion()
                }
                keyButton("Z", s.screenshotKeyLoupe, on: options.loupe) { controller.toggleLoupe() }
                keyButton("C", s.screenshotKeyColor, on: false, enabled: options.loupe) { controller.copyColor() }
                keyButton("S", s.screenshotKeyScroll, on: options.scrolling) { controller.toggleScrolling() }
                Divider().frame(height: 22)
                keyButton("esc", s.screenshotKeyCancel, on: false) { controller.cancel() }
            }
            Text(options.notice ?? (options.scrolling ? s.screenshotHintScrolling : s.screenshotHint))
                .font(.caption)
                .foregroundStyle(.white.opacity(0.85))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.78)))
        .environment(\.colorScheme, .dark)
        .fixedSize()
    }

    private func toolButton(_ tool: ScreenCaptureTool, _ s: Strings) -> some View {
        let selected = options.tool == tool
        return Button {
            controller.select(tool)
        } label: {
            HStack(spacing: 5) {
                KeyCap(label: tool.shortcutKey)
                Image(systemName: tool.symbolName)
                Text(tool == .screenshot ? s.screenshotToolScreenshot : s.screenshotToolRecording)
                    .font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Color.accentColor.opacity(0.85) : .clear))
            .opacity(tool.isImplemented ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
    }

    private func keyButton(_ key: String, _ title: String, on: Bool, enabled: Bool = true,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                KeyCap(label: key)
                Text(title).font(.system(size: 11))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(on ? Color.accentColor.opacity(0.7) : .clear))
            .opacity(enabled ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
    }
}
