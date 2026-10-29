// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import SwiftUI

/// Full-screen overlay shown while the keyboard is locked for cleaning. It makes
/// the locked state unmistakable, shows live progress toward the unlock gesture,
/// and offers a mouse-clickable Unlock button so there is always an obvious way
/// out (the mouse is never locked).
struct CleaningOverlayView: View {
    @ObservedObject private var manager = CleaningModeManager.shared
    @ObservedObject private var l10n = L10n.shared
    @AppStorage(DefaultsKey.cleaningModeKeepScreenVisible) private var keepScreenVisible = false

    var body: some View {
        ZStack {
            if keepScreenVisible {
                Color.clear.ignoresSafeArea()
                compactCornerHUD
            } else {
                Color.black.ignoresSafeArea()
                fullBlackoutContent
            }
        }
    }

    private var fullBlackoutContent: some View {
        VStack(spacing: 18) {
            Image(systemName: "keyboard")
                .font(.system(size: 48, weight: .regular))
                .foregroundStyle(.white)

            Text(l10n.s.cleaningModeOverlayTitle)
                .font(.system(size: 23, weight: .semibold))
                .foregroundStyle(.white)

            Text(l10n.s.cleaningModeOverlaySubtitle)
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.75))
                .multilineTextAlignment(.center)

            fullProgressDots
                .padding(.top, 2)

            if manager.clickPolicy != .blockClicks {
                UnlockButton(compact: false)
                    .padding(.top, 6)
            }

            Text(mouseHint)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.5))
                .multilineTextAlignment(.center)
        }
        .padding(44)
        .frame(maxWidth: 460)
    }

    private var compactCornerHUD: some View {
        VStack {
            HStack(spacing: 12) {
                Image(systemName: "keyboard")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .background(
                        Circle()
                            .fill(Color.primary.opacity(0.08))
                    )

                VStack(alignment: .leading, spacing: 3) {
                    Text(l10n.s.cleaningModeOverlayTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.primary)

                    HStack(spacing: 8) {
                        Text(l10n.s.cleaningModeOverlaySubtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.secondary)

                        compactProgressDots
                    }
                }

                if manager.clickPolicy == .blockClicks {
                    Text(mouseHint)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.secondary)
                        .frame(maxWidth: 180, alignment: .leading)
                } else {
                    UnlockButton(compact: true)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.22), radius: 16, x: 0, y: 6)
            .padding(.top, 40)
            .padding(.trailing, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
    }

    private var mouseHint: String {
        manager.clickPolicy == .blockClicks
            ? l10n.s.cleaningModeOverlayAutoUnlockHint
            : l10n.s.cleaningModeOverlayMouseHint
    }

    private var fullProgressDots: some View {
        HStack(spacing: 11) {
            ForEach(0..<manager.unlockThreshold, id: \.self) { index in
                Circle()
                    .fill(index < manager.unlockProgress ? Color.white : Color.white.opacity(0.22))
                    .frame(width: 12, height: 12)
            }
        }
        .animation(.easeOut(duration: 0.15), value: manager.unlockProgress)
    }

    private var compactProgressDots: some View {
        HStack(spacing: 4) {
            ForEach(0..<manager.unlockThreshold, id: \.self) { index in
                Circle()
                    .fill(index < manager.unlockProgress ? Color.accentColor : Color.primary.opacity(0.2))
                    .frame(width: 6, height: 6)
            }
        }
        .animation(.easeOut(duration: 0.15), value: manager.unlockProgress)
    }
}

/// One click on `.allowClicks`; a held press on `.holdToUnlock`, so a cloth
/// brushing the trackpad cannot end the lock. Added in FixDock.
private struct UnlockButton: View {
    let compact: Bool
    @ObservedObject private var manager = CleaningModeManager.shared
    @ObservedObject private var l10n = L10n.shared
    @State private var holding = false

    var body: some View {
        if manager.clickPolicy == .holdToUnlock {
            label(l10n.s.cleaningModeOverlayHoldUnlock)
                .overlay(alignment: .leading) {
                    GeometryReader { proxy in
                        Capsule(style: .continuous)
                            .fill(Color.accentColor.opacity(0.45))
                            .frame(width: holding ? proxy.size.width : 0)
                            .animation(holding
                                       ? .linear(duration: CleaningClickPolicy.unlockHoldDuration)
                                       : .easeOut(duration: 0.15),
                                       value: holding)
                    }
                    .allowsHitTesting(false)
                }
                .contentShape(Capsule())
                .onLongPressGesture(minimumDuration: CleaningClickPolicy.unlockHoldDuration,
                                    maximumDistance: 24) {
                    holding = false
                    manager.deactivate()
                } onPressingChanged: { pressing in
                    holding = pressing
                }
        } else {
            Button(action: { manager.deactivate() }) {
                label(l10n.s.cleaningModeOverlayUnlock)
            }
            .buttonStyle(.plain)
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: compact ? 11 : 14, weight: .semibold))
            .foregroundStyle(.black)
            .frame(minWidth: compact ? 0 : 130)
            .padding(.vertical, compact ? 5 : 10)
            .padding(.horizontal, compact ? 10 : 18)
            .background(Capsule(style: .continuous).fill(Color.white))
            .clipShape(Capsule(style: .continuous))
    }
}
