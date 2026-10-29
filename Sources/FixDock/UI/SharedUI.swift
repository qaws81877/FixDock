// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import SwiftUI

/// A single keyboard key drawn like a keycap. Used by the shortcut settings.
struct KeyCap: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .frame(minWidth: 20, minHeight: 22)
            .padding(.horizontal, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.07))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.14), lineWidth: 1)
            )
    }
}

/// A disclosure header where the whole row toggles the group and the chevron
/// sits on the trailing side. Adapted from the upstream settings rows.
struct DisclosureHeaderRow<Label: View>: View {
    @ObservedObject private var l10n = L10n.shared
    private let isExpanded: Binding<Bool>
    private let label: () -> Label

    init(isExpanded: Binding<Bool>, @ViewBuilder label: @escaping () -> Label) {
        self.isExpanded = isExpanded
        self.label = label
    }

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                isExpanded.wrappedValue.toggle()
            }
        } label: {
            HStack(spacing: 8) {
                label()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded.wrappedValue ? 90 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(isExpanded.wrappedValue
            ? l10n.s.disclosureExpanded : l10n.s.disclosureCollapsed)
    }
}

extension View {
    /// Child rows sit inset under their group's header row.
    func disclosureIndent() -> some View {
        padding(.leading, 25)
    }
}

struct ShortcutCaps: View {
    let keys: [String]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                KeyCap(label: key)
            }
        }
    }
}
