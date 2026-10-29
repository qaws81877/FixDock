// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Shows what a scanned code holds before anything is copied, with Copy and,
/// for a plain web link, Open. Esc or a click elsewhere closes it. Adapted
/// from the upstream QR result panel.
final class ScreenshotQRResultController {
    static let shared = ScreenshotQRResultController()

    private var panel: QRResultPanel?
    private var keyMonitor: Any?
    private var localMonitor: Any?
    private var globalMonitor: Any?

    private init() {}

    func show(_ reading: ScreenshotRecognition.CodeReading) {
        close()
        let content = QRResultView(reading: reading,
                                   copy: { [weak self] in self?.copy(reading.payload) },
                                   open: { [weak self] in reading.url.map { self?.open($0) } })
        let host = NSHostingController(rootView: content)
        host.view.layoutSubtreeIfNeeded()
        let size = host.view.fittingSize
        let panel = QRResultPanel(contentRect: CGRect(origin: .zero, size: size),
                                  styleMask: [.borderless, .nonactivatingPanel],
                                  backing: .buffered, defer: false)
        panel.contentViewController = host
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]

        let pointer = NSEvent.mouseLocation
        let visible = (NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main)?
            .visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        // Just below the pointer, kept fully on screen.
        var origin = CGPoint(x: pointer.x - size.width / 2, y: pointer.y - size.height - 18)
        origin.x = min(max(origin.x, visible.minX + 12), visible.maxX - size.width - 12)
        origin.y = min(max(origin.y, visible.minY + 12), visible.maxY - size.height - 12)
        panel.setFrame(CGRect(origin: origin, size: size), display: false)
        self.panel = panel
        installMonitors(for: panel)
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    var isShown: Bool { panel != nil }

    func close() {
        for monitor in [keyMonitor, localMonitor, globalMonitor].compactMap({ $0 }) {
            NSEvent.removeMonitor(monitor)
        }
        keyMonitor = nil
        localMonitor = nil
        globalMonitor = nil
        panel?.orderOut(nil)
        panel = nil
    }

    private func copy(_ payload: String) {
        ScreenshotService.copyText(payload)
        close()
    }

    private func open(_ url: URL) {
        close()
        NSWorkspace.shared.open(url)
    }

    private func installMonitors(for panel: NSPanel) {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.window === panel, Int(event.keyCode) == kVK_Escape else { return event }
            self?.close()
            return nil
        }
        // A click outside closes it: other apps through the global monitor,
        // FixDock's own windows (the preview) through the local one.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            if event.window !== self?.panel { self?.close() }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.close()
        }
    }
}

private final class QRResultPanel: OverlayPanel {
    override var canBecomeKey: Bool { true }
}

private struct QRResultView: View {
    let reading: ScreenshotRecognition.CodeReading
    let copy: () -> Void
    let open: () -> Void
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        let s = l10n.s
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: "qrcode")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text(s.screenshotQRTitle)
                    .font(.system(size: 13, weight: .semibold))
            }
            ScrollView(.vertical) {
                Text(reading.payload)
                    .font(.system(size: 12.5))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
            }
            .frame(maxHeight: 132)
            .fixedSize(horizontal: false, vertical: true)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                if reading.url != nil {
                    Button(s.screenshotQRCopy, action: copy)
                        .buttonStyle(.bordered)
                    Button(s.screenshotQROpen, action: open)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(s.screenshotQRCopy, action: copy)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(16)
        .frame(width: 320)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))
    }
}
