// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import SwiftUI
import UniformTypeIdentifiers

// Edit mode of the panel cards, ported from upstream's PanelLayout.swift:
// the card header's edit and reset buttons, drag reorder, hide and show.
// Upstream's collapsible sections are not part of FixDock's panel.

/// A card's title with its edit button, and the reset button while editing.
struct PanelCardHeader: View {
    @ObservedObject private var l10n = L10n.shared
    let title: String
    let isEditing: Bool
    var editButtonVisible = true
    let toggleEditing: () -> Void
    let reset: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            sectionTitle(title)
            Spacer(minLength: 0)
            if editButtonVisible {
                if isEditing {
                    resetButton
                }
                editButton
            }
        }
        .frame(minHeight: 24)
    }

    private var editButton: some View {
        Button(action: toggleEditing) {
            if isEditing {
                Label(l10n.s.panelEditDone, systemImage: "checkmark")
                    .font(.system(size: 10.5, weight: .bold))
                    .labelStyle(.titleAndIcon)
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 22, height: 18)
                    .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(isEditing ? Color.white : Color.secondary)
        .background(
            RoundedRectangle(cornerRadius: isEditing ? 8 : 6, style: .continuous)
                .fill(isEditing ? Color.accentColor : Color.clear)
        )
        .help(isEditing ? l10n.s.panelEditDone : l10n.s.panelEditCard)
        .accessibilityLabel(isEditing ? l10n.s.panelEditDone : l10n.s.panelEditCard)
    }

    private var resetButton: some View {
        Button(action: reset) {
            Image(systemName: "arrow.counterclockwise")
                .font(.system(size: 10.5, weight: .semibold))
                .frame(width: 22, height: 22)
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.07))
        )
        .help(l10n.s.panelResetCard)
        .accessibilityLabel(l10n.s.panelResetCard)
    }
}

struct PanelDragHandle: View {
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.tertiary)
            .frame(width: PanelRowMetrics.dragHandleWidth, height: 22)
            .contentShape(Rectangle())
            .help(l10n.s.panelDragHint)
    }
}

/// A row that can be dragged onto another row of the same card while the
/// card is being edited. Outside edit mode it is the plain row.
struct PanelReorderableItem<Item, Content: View>: View
where Item: RawRepresentable & Hashable, Item.RawValue == String {
    let item: Item
    var isEnabled = true
    @Binding var order: [Item]
    @Binding var dragging: Item?
    let content: () -> Content

    var body: some View {
        if isEnabled {
            content()
                .onDrag {
                    dragging = item
                    return NSItemProvider(object: item.rawValue as NSString)
                } preview: {
                    // Rows have no card of their own, so the dragged one gets
                    // a card and stays readable over what sits under it.
                    content()
                        .frame(minWidth: 220, alignment: .leading)
                        .panelCard(padded: false)
                }
                .onDrop(of: [UTType.text], delegate: PanelItemDropDelegate(item: item,
                                                                           order: $order,
                                                                           dragging: $dragging))
        } else {
            content()
        }
    }
}

private struct PanelItemDropDelegate<Item: Hashable>: DropDelegate {
    let item: Item
    @Binding var order: [Item]
    @Binding var dragging: Item?

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != item,
              let from = order.firstIndex(of: dragging),
              let to = order.firstIndex(of: item) else { return }
        var moved = order
        moved.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        order = moved
    }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}

struct PanelInlineHideButton: View {
    @ObservedObject private var l10n = L10n.shared
    @Binding var isVisible: Bool

    var body: some View {
        Button {
            isVisible.toggle()
        } label: {
            Image(systemName: isVisible ? "eye.slash.fill" : "eye.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(isVisible ? Color.secondary : Color.accentColor)
                .frame(width: 24, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill((isVisible ? Color.primary : Color.accentColor).opacity(0.10))
                )
        }
        .buttonStyle(.plain)
        .help(isVisible ? l10n.s.panelHideItem : l10n.s.panelShowItem)
        .accessibilityLabel(isVisible ? l10n.s.panelHideItem : l10n.s.panelShowItem)
    }
}

struct PanelHiddenBadge: View {
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        Label(l10n.s.panelHiddenItem, systemImage: "eye.slash.fill")
            .font(.system(size: 9.5, weight: .bold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(Color.primary.opacity(0.08))
            )
    }
}
