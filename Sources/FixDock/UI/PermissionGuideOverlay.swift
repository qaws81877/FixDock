// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import AppKit
import Combine
import SwiftUI

/// A small non-activating card shown after a permission request sends the
/// person to System Settings. It walks the three steps and notices the grant.
/// Onboarding uses its own page, so the card stays hidden while that window
/// is up. Adapted from the upstream guide and limited to Accessibility and
/// Screen Recording.
final class PermissionGuideOverlay {
    static let shared = PermissionGuideOverlay()
    static var suppressed = false

    private var panel: NSPanel?
    private var grantWatcher: AnyCancellable?
    private var dismissWork: DispatchWorkItem?
    private var staleWork: DispatchWorkItem?
    private var holdingSurface = false
    private static let staleAfter: TimeInterval = 12

    private init() {}

    func show(for kind: PermissionKind) {
        guard !Self.suppressed else { return }
        dismissWork?.cancel()
        dismissWork = nil
        staleWork?.cancel()
        staleWork = nil
        grantWatcher = nil
        panel?.orderOut(nil)
        panel = nil

        let strings = L10n.shared.s
        let model = PermissionGuideModel()
        let view = PermissionGuideCard(
            permissionName: kind.title(strings),
            kind: kind,
            model: model,
            onStartOver: { Permissions.shared.startOver(kind) },
            onRelaunch: { appDelegate()?.relaunch() }
        ) { [weak self] in
            self?.dismiss()
        }
        let stale = DispatchWorkItem { model.stale = true }
        staleWork = stale
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.staleAfter, execute: stale)

        let host = NSHostingView(rootView: view)
        host.frame.size = NSSize(width: 340, height: 240)
        let fitted = host.fittingSize
        let size = NSSize(width: max(fitted.width, 320), height: max(fitted.height, 180))
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
        let frame = NSRect(x: visible.maxX - size.width - 20,
                           y: visible.maxY - size.height - 20,
                           width: size.width,
                           height: size.height)
        let panel = OverlayPanel(contentRect: frame,
                                 styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered,
                                 defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = host
        panel.orderFrontRegardless()
        self.panel = panel
        if !holdingSurface {
            Permissions.shared.setGuideVisible(true)
            holdingSurface = true
        }

        let publisher: Published<Bool>.Publisher = kind == .accessibility
            ? Permissions.shared.$accessibility
            : Permissions.shared.$screenRecording
        grantWatcher = publisher
            .removeDuplicates()
            .filter { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                model.granted = true
                model.stale = false
                self?.staleWork?.cancel()
                if kind == .accessibility { self?.scheduleDismiss() }
            }
    }

    private func scheduleDismiss() {
        dismissWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.dismiss() }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
    }

    func dismiss() {
        dismissWork?.cancel()
        dismissWork = nil
        staleWork?.cancel()
        staleWork = nil
        grantWatcher = nil
        panel?.orderOut(nil)
        panel = nil
        if holdingSurface {
            Permissions.shared.setGuideVisible(false)
            holdingSurface = false
        }
    }
}

private final class PermissionGuideModel: ObservableObject {
    @Published var granted = false
    @Published var stale = false
}

private struct PermissionGuideCard: View {
    let permissionName: String
    let kind: PermissionKind
    @ObservedObject var model: PermissionGuideModel
    let onStartOver: () -> Void
    let onRelaunch: () -> Void
    let onClose: () -> Void
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        let guide = l10n.s
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(Color.accentColor)
                Text(guide.guideTitle)
                    .font(.system(size: 13, weight: .semibold))
                Text(permissionName)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help(guide.guideClose)
            }
            VStack(alignment: .leading, spacing: 6) {
                stepRow(1, guide.guideStepOpen)
                stepRow(2, guide.guideStepToggle)
                stepRow(3, guide.guideStepReturn)
            }
            HStack(spacing: 7) {
                if model.granted {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(guide.guideGranted)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.green)
                    if kind == .screenRecording {
                        Spacer(minLength: 8)
                        Button(guide.guideRelaunch, action: onRelaunch)
                            .controlSize(.small)
                    }
                } else {
                    ProgressView().controlSize(.small)
                    Text(guide.guideWaiting)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            if model.stale, !model.granted {
                VStack(alignment: .leading, spacing: 6) {
                    Text(guide.guideStaleHint)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(guide.guideStartOver, action: onStartOver)
                        .controlSize(.small)
                }
            }
        }
        .padding(14)
        .frame(width: 320, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                )
        )
    }

    private func stepRow(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number)")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 16, height: 16)
                .background(Circle().fill(Color.accentColor))
            Text(text)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
