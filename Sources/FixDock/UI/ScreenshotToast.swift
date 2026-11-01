// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import AppKit
import SwiftUI

/// What a preview action confirms with a toast.
enum ScreenshotToast {
    case copied, saved

    var text: String {
        let s = L10n.shared.s
        switch self {
        case .copied: return s.screenshotToastCopied
        case .saved: return s.screenshotToastSaved
        }
    }
}

/// A short line at the bottom centre of a display after Copy or Save in the
/// preview. It outlives the preview, which Save closes. It never takes key
/// status or clicks, so the preview keeps Command-C and Command-S while it
/// shows. A new toast replaces the one on screen.
final class ScreenshotToastController {
    static let shared = ScreenshotToastController()

    private static let duration: TimeInterval = 1.5
    private static let fade: TimeInterval = 0.18
    private static let bottomInset: CGFloat = 80

    private var panel: OverlayPanel?
    private var hideWork: DispatchWorkItem?

    private init() {}

    func show(_ toast: ScreenshotToast, on screen: NSScreen?) {
        hideWork?.cancel()
        panel?.orderOut(nil)

        let host = NSHostingController(rootView: ScreenshotToastView(text: toast.text))
        host.view.layoutSubtreeIfNeeded()
        let size = host.view.fittingSize
        let panel = OverlayPanel(contentRect: CGRect(origin: .zero, size: size),
                                 styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        panel.contentViewController = host
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]

        let visible = (screen ?? NSScreen.main)?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = CGPoint(x: (visible.midX - size.width / 2).rounded(),
                             y: visible.minY + Self.bottomInset)
        panel.setFrame(CGRect(origin: origin, size: size), display: false)
        panel.alphaValue = 0
        self.panel = panel
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fade
            panel.animator().alphaValue = 1
        }

        let work = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = Self.fade
                panel.animator().alphaValue = 0
            }, completionHandler: {
                panel.orderOut(nil)
                if self?.panel === panel { self?.panel = nil }
            })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.duration, execute: work)
    }
}

private struct ScreenshotToastView: View {
    let text: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(text)
        }
        .font(.system(size: 13, weight: .semibold))
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
        .fixedSize()
    }
}
