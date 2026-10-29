// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import AppKit
import SwiftUI

/// The recorder's short on-screen messages and countdown digits. Upstream
/// used its shared quick-tool HUD; FixDock has no such surface (the
/// screenshot tool reports in the panel row, which is closed while recording),
/// so this is a minimal stand-in: one non-activating capsule that never takes
/// clicks, centred near the top of a screen. The recorder leaves its window
/// out of the video.
final class RecorderHUD {
    static let shared = RecorderHUD()

    private final class Model: ObservableObject {
        @Published var symbol: String?
        @Published var text = ""
        @Published var isCountdown = false
    }

    private let model = Model()
    private var panel: OverlayPanel?
    private var hideWork: DispatchWorkItem?

    private init() {}

    /// The HUD's window while it is up, for the capture filter.
    var windowNumber: Int? {
        guard let panel, panel.isVisible, panel.windowNumber > 0 else { return nil }
        return panel.windowNumber
    }

    /// A message that disappears on its own.
    func show(symbol: String, message: String, on screen: NSScreen? = nil) {
        model.symbol = symbol
        model.text = message
        model.isCountdown = false
        present(on: screen)
        scheduleHide(after: 2.5)
    }

    /// One countdown step; stays until the next step or `hide()`.
    func showCountdown(_ seconds: Int, on screen: NSScreen? = nil) {
        model.symbol = nil
        model.text = "\(seconds)"
        model.isCountdown = true
        present(on: screen)
        scheduleHide(after: 1.5)
    }

    func hide() {
        hideWork?.cancel()
        hideWork = nil
        panel?.orderOut(nil)
    }

    private func scheduleHide(after seconds: Double) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func present(on screen: NSScreen?) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let host = screen
            ?? NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main
        guard let host else { return }
        let size = model.isCountdown ? CGSize(width: 120, height: 120) : CGSize(width: 360, height: 44)
        let visible = host.visibleFrame
        let origin = model.isCountdown
            ? CGPoint(x: (visible.midX - size.width / 2).rounded(), y: (visible.midY - size.height / 2).rounded())
            : CGPoint(x: (visible.midX - size.width / 2).rounded(), y: (visible.maxY - size.height - 56).rounded())
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
    }

    private func makePanel() -> OverlayPanel {
        let panel = OverlayPanel(contentRect: CGRect(x: 0, y: 0, width: 360, height: 44),
                                 styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        panel.contentView = NSHostingView(rootView: HUDView(model: model))
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        return panel
    }

    private struct HUDView: View {
        @ObservedObject var model: Model

        var body: some View {
            Group {
                if model.isCountdown {
                    Text(model.text)
                        .font(.system(size: 64, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .frame(width: 112, height: 112)
                        .background(Circle().fill(Color.black.opacity(0.72)))
                } else {
                    HStack(spacing: 8) {
                        if let symbol = model.symbol {
                            Image(systemName: symbol)
                        }
                        Text(model.text)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Color.black.opacity(0.78)))
                }
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .environment(\.colorScheme, .dark)
        }
    }
}
