// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import AppKit
import Carbon.HIToolbox
import UniformTypeIdentifiers

/// Captures pinned above other windows while working. Drag to move, resize
/// from the edges keeping proportions, arrows nudge (Shift: 12 points),
/// double click or Esc closes, and the right-click menu offers copy, save,
/// opacity and click-through. A monitor exists only while a click-through
/// pin needs its Option-click way back. Adapted from upstream.
final class ScreenshotPinController {
    static let shared = ScreenshotPinController()

    private var pins: [ScreenshotPinWindow] = []
    private var escapeMonitor: Any?

    private init() {}

    func pin(image: CGImage, scale: CGFloat) {
        let window = ScreenshotPinWindow(image: image, scale: scale, controller: self)
        pins.append(window)
        // Cascade so consecutive pins never stack invisibly.
        let offset = CGFloat((pins.count - 1) % 5) * 26
        window.setFrameOrigin(CGPoint(x: window.frame.origin.x + offset, y: window.frame.origin.y - offset))
        window.orderFrontRegardless()
    }

    func closeAll() {
        pins.forEach { $0.orderOut(nil) }
        pins.removeAll()
        refreshEscapeMonitor()
    }

    fileprivate func remove(_ pin: ScreenshotPinWindow) {
        pins.removeAll { $0 === pin }
        refreshEscapeMonitor()
    }

    /// While any pin ignores clicks, Option-click inside it restores it;
    /// without this a click-through pin could never be caught again.
    fileprivate func refreshEscapeMonitor() {
        let needed = pins.contains { $0.ignoresMouseEvents }
        if needed, escapeMonitor == nil {
            escapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                guard let self, event.modifierFlags.contains(.option) else { return }
                let location = NSEvent.mouseLocation
                for pin in self.pins where pin.ignoresMouseEvents && pin.frame.contains(location) {
                    pin.setClickThrough(false)
                }
                self.refreshEscapeMonitor()
            }
        } else if !needed, let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
            self.escapeMonitor = nil
        }
    }
}

/// One pinned capture.
private final class ScreenshotPinWindow: OverlayPanel {
    private let image: CGImage
    private unowned let controller: ScreenshotPinController

    init(image: CGImage, scale: CGFloat, controller: ScreenshotPinController) {
        self.image = image
        self.controller = controller
        let pointer = NSEvent.mouseLocation
        let screen = (NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main)?
            .visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        var size = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        let cap = min(screen.width, screen.height) * 0.55
        let ratio = min(1, min(cap / max(size.width, 1), cap / max(size.height, 1)))
        size = CGSize(width: max(90, size.width * ratio), height: max(60, size.height * ratio))
        let rect = CGRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2,
                          width: size.width, height: size.height)
        super.init(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel, .resizable],
                   backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        contentAspectRatio = CGSize(width: CGFloat(max(1, image.width)), height: CGFloat(max(1, image.height)))
        minSize = CGSize(width: 90, height: 60)
        contentView = PinContentView(image: image, window: self)
    }

    override var canBecomeKey: Bool { true }

    func copyImage() {
        ScreenshotService.shared.copyImage(image)
    }

    /// The save panel asks before replacing a file the person picked.
    func saveImage() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.directoryURL = ScreenshotService.saveFolder
        panel.nameFieldStringValue = ScreenshotSupport.fileName(prefix: L10n.shared.s.screenshotFilePrefix,
                                                                date: Date())
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            guard let self, response == .OK, let url = panel.url,
                  let data = ScreenshotService.pngData(self.image)
            else { return }
            do {
                try data.write(to: url, options: .atomic)
                ScreenshotSupport.markAsScreenCapture(url)
            } catch {
                NSSound.beep()
            }
        }
    }

    func setClickThrough(_ enabled: Bool) {
        ignoresMouseEvents = enabled
        controller.refreshEscapeMonitor()
    }

    func closePin() {
        orderOut(nil)
        controller.remove(self)
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let step: CGFloat = flags.contains(.shift) ? 12 : 1
        switch Int(event.keyCode) {
        case kVK_Escape:
            closePin()
        case kVK_ANSI_W where flags.contains(.command):
            closePin()
        case kVK_ANSI_C where flags.contains(.command):
            copyImage()
        case kVK_LeftArrow:
            setFrameOrigin(CGPoint(x: frame.origin.x - step, y: frame.origin.y))
        case kVK_RightArrow:
            setFrameOrigin(CGPoint(x: frame.origin.x + step, y: frame.origin.y))
        case kVK_UpArrow:
            setFrameOrigin(CGPoint(x: frame.origin.x, y: frame.origin.y + step))
        case kVK_DownArrow:
            setFrameOrigin(CGPoint(x: frame.origin.x, y: frame.origin.y - step))
        default:
            super.keyDown(with: event)
        }
    }

    private final class PinContentView: NSView {
        /// Weak: closing a pin releases its window from inside this view's
        /// own event handling.
        private weak var pinWindow: ScreenshotPinWindow?

        init(image: CGImage, window: ScreenshotPinWindow) {
            pinWindow = window
            super.init(frame: .zero)
            wantsLayer = true
            layer?.contents = image
            layer?.contentsGravity = .resizeAspect
            layer?.cornerRadius = 7
            layer?.masksToBounds = true
            layer?.borderWidth = 1
            layer?.borderColor = CGColor(gray: 0.5, alpha: 0.4)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        override func mouseDown(with event: NSEvent) {
            guard let pinWindow else { return }
            if event.clickCount == 2 {
                pinWindow.closePin()
                return
            }
            pinWindow.makeKey()
            super.mouseDown(with: event)
        }

        override func menu(for event: NSEvent) -> NSMenu? {
            guard let pinWindow else { return nil }
            let s = L10n.shared.s
            let menu = NSMenu()
            menu.addItem(withTitle: s.screenshotPreviewCopy, action: #selector(menuCopy), keyEquivalent: "").target = self
            menu.addItem(withTitle: s.screenshotPinSaveAs, action: #selector(menuSave), keyEquivalent: "").target = self
            menu.addItem(.separator())
            let opacityItem = NSMenuItem(title: s.screenshotPinOpacity, action: nil, keyEquivalent: "")
            let opacityMenu = NSMenu()
            for percent in [100, 85, 70, 50] {
                let item = NSMenuItem(title: "\(percent)%", action: #selector(menuOpacity(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = percent
                item.state = Int((pinWindow.alphaValue * 100).rounded()) == percent ? .on : .off
                opacityMenu.addItem(item)
            }
            opacityItem.submenu = opacityMenu
            menu.addItem(opacityItem)
            let clickThrough = NSMenuItem(title: s.screenshotPinClickThrough,
                                          action: #selector(menuClickThrough), keyEquivalent: "")
            clickThrough.target = self
            clickThrough.state = pinWindow.ignoresMouseEvents ? .on : .off
            menu.addItem(clickThrough)
            menu.addItem(.separator())
            menu.addItem(withTitle: s.screenshotPinClose, action: #selector(menuClose), keyEquivalent: "").target = self
            menu.addItem(withTitle: s.screenshotPinCloseAll, action: #selector(menuCloseAll), keyEquivalent: "").target = self
            return menu
        }

        @objc private func menuCopy() { pinWindow?.copyImage() }
        @objc private func menuSave() { pinWindow?.saveImage() }
        @objc private func menuClose() { pinWindow?.closePin() }
        @objc private func menuCloseAll() { ScreenshotPinController.shared.closeAll() }

        @objc private func menuOpacity(_ sender: NSMenuItem) {
            guard let percent = sender.representedObject as? Int else { return }
            pinWindow?.alphaValue = CGFloat(percent) / 100
        }

        @objc private func menuClickThrough() {
            guard let pinWindow else { return }
            pinWindow.setClickThrough(!pinWindow.ignoresMouseEvents)
        }
    }
}
