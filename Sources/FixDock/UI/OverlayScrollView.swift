// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import AppKit
import SwiftUI

/// A vertical scroll container that always uses an overlay scroller, so it
/// never reserves a legacy gutter on the right (which, with scroll bars set
/// to always show, would push the fixed-width panel content off-centre). The
/// content is pinned to the full width and reports its natural height after
/// every layout pass, so the popover sizes itself to fit and only scrolls
/// once the content is taller than the screen. Ported from upstream.
struct OverlayScrollView<Content: View>: NSViewRepresentable {
    @Binding var measuredHeight: CGFloat
    let content: Content

    init(measuredHeight: Binding<CGFloat>, @ViewBuilder content: () -> Content) {
        _measuredHeight = measuredHeight
        self.content = content()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        let host = HeightReportingHostingView(rootView: content)
        host.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = host
        let clip = scroll.contentView
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: clip.topAnchor),
            host.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            host.widthAnchor.constraint(equalTo: clip.widthAnchor),
        ])
        context.coordinator.host = host
        installReporter(on: host)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        scroll.scrollerStyle = .overlay
        guard let host = context.coordinator.host else { return }
        host.rootView = content
        installReporter(on: host)               // re-bind to the latest measuredHeight
        let height = host.fittingSize.height     // catch changes with no new layout pass
        if PanelLayoutSupport.shouldApply(measured: height, current: measuredHeight) {
            DispatchQueue.main.async { measuredHeight = height }
        }
    }

    /// Reports the natural height into `measuredHeight` after every AppKit
    /// layout pass, so the popover tracks the real content height. The
    /// 0.5 pt guard breaks the measure, resize, measure loop.
    private func installReporter(on host: HeightReportingHostingView<Content>) {
        let binding = $measuredHeight
        host.onLayout = { [weak host] in
            guard let host else { return }
            let height = host.fittingSize.height
            guard PanelLayoutSupport.shouldApply(measured: height, current: binding.wrappedValue) else { return }
            DispatchQueue.main.async { binding.wrappedValue = height }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var host: HeightReportingHostingView<Content>?
    }
}

/// An `NSHostingView` that fires `onLayout` after each AppKit layout pass.
/// A state change inside this view's own SwiftUI graph (opening a sub-view,
/// entering edit mode) never re-runs the surrounding `updateNSView`, so the
/// height has to be read here, where the change lands.
final class HeightReportingHostingView<Content: View>: NSHostingView<Content> {
    var onLayout: (() -> Void)?

    required init(rootView: Content) {
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        onLayout?()
    }
}
