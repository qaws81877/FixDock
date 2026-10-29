// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import SwiftUI

/// Shared surfaces for the panel and settings. The upstream notch and glass
/// variants are not part of this shell.
enum PanelSurface {
    static func cardFill(for scheme: ColorScheme) -> Color {
        scheme == .light ? Color.white.opacity(0.55) : Color.white.opacity(0.08)
    }

    static func border(for scheme: ColorScheme) -> Color {
        let raised = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        return scheme == .light
            ? Color.black.opacity(raised ? 0.28 : 0.10)
            : Color.white.opacity(raised ? 0.32 : 0.12)
    }
}

func sectionTitle(_ text: String) -> some View {
    Text(text.uppercased())
        .font(.system(size: 11, weight: .semibold))
        .kerning(0.4)
        .foregroundStyle(.secondary)
}

extension View {
    func settingsCard() -> some View {
        modifier(SettingsCardModifier())
    }

    /// The menu panel uses the same card as settings.
    func panelCard() -> some View {
        settingsCard()
    }
}

private struct SettingsCardModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(PanelSurface.cardFill(for: colorScheme))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(PanelSurface.border(for: colorScheme), lineWidth: 0.7)
            )
    }
}
