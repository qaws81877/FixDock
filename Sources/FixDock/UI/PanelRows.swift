// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import SwiftUI

// Row components of the menu bar panel, ported from upstream's
// MenuPanelView without the notch presentation, the beta badge and the
// per-tool shortcuts FixDock does not have.

/// One action row: an icon, a title and a chevron, the whole row one button.
/// A missing permission turns the icon and the caption orange and adds a
/// grant button under the title; an accessory adds a second small button.
struct UtilityActionButton: View {
    let title: String
    let caption: String
    let systemImage: String
    var isEditing = false
    var showsDragHandle = false
    var visibility: Binding<Bool>? = nil
    var needsAttention = false
    /// The caption reports something happening now (a recording's time) or
    /// why the row cannot work yet, so it stays on the row the way a
    /// permission note does. Any other caption only describes the tool.
    var captionStaysVisible = false
    var permissionButtonTitle: String? = nil
    var permissionAction: (() -> Void)? = nil
    /// The tool's registered global shortcut, shown as a quiet key hint.
    var shortcutHint: String? = nil
    var accessoryTitle: String? = nil
    var accessorySystemImage: String? = nil
    var accessoryAction: (() -> Void)? = nil
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Group {
            if isEditing {
                rowContent(showChevron: false)
                    .panelRowInsets()
            } else if permissionAction != nil || accessoryAction != nil {
                VStack(alignment: .leading, spacing: 7) {
                    if permissionAction != nil {
                        rowContent(showChevron: false)
                    } else {
                        mainButton
                    }
                    VStack(alignment: .leading, spacing: 7) {
                        if permissionAction != nil {
                            permissionButton
                        }
                        accessoryButton
                    }
                    .padding(.leading, PanelRowMetrics.iconWidth + PanelRowMetrics.iconSpacing)
                }
                .panelRowInsets()
            } else {
                Button(action: action) {
                    rowContent(showChevron: true)
                        .panelRowInsets()
                        .background(PanelRowHighlight(isVisible: hovering))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
            }
        }
        .panelRowDescription(showsCaption ? nil : caption)
    }

    /// A plain description waits in the tooltip, so the list stays one line
    /// per tool. It comes back in edit mode, where deciding what to keep is
    /// the point.
    private var showsCaption: Bool {
        needsAttention || captionStaysVisible || isEditing
    }

    private var mainButton: some View {
        Button(action: action) {
            rowContent(showChevron: true)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var accessoryButton: some View {
        if let accessoryTitle, let accessoryAction {
            Button(action: accessoryAction) {
                Label(accessoryTitle, systemImage: accessorySystemImage ?? "arrow.up.forward.square")
                    .font(.system(size: 9.5, weight: .semibold))
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
        }
    }

    private func rowContent(showChevron: Bool) -> some View {
        HStack(spacing: PanelRowMetrics.iconSpacing) {
            if isEditing && showsDragHandle {
                PanelDragHandle()
            }
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: PanelRowMetrics.iconWidth)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isHiddenInEditor ? Color.secondary : Color.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if showsCaption {
                    Text(caption)
                        .font(.system(size: 10))
                        .foregroundStyle(captionColor)
                        .monospacedDigit()
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            if isEditing, let visibility {
                if !visibility.wrappedValue {
                    PanelHiddenBadge()
                }
                PanelInlineHideButton(isVisible: visibility)
            } else {
                if let shortcutHint {
                    Text(shortcutHint)
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(Color.primary.opacity(0.06))
                        )
                }
                if showChevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var permissionButton: some View {
        Button {
            permissionAction?()
        } label: {
            Label(permissionButtonTitle ?? "", systemImage: "hand.raised.fill")
                .font(.system(size: 10, weight: .semibold))
        }
        .buttonStyle(.bordered)
        .controlSize(.mini)
    }

    private var iconColor: Color {
        if isHiddenInEditor { return .secondary }
        return needsAttention ? .orange : .accentColor
    }

    private var captionColor: Color {
        if isHiddenInEditor { return Color.secondary.opacity(0.55) }
        return needsAttention ? .orange : .secondary
    }

    private var isHiddenInEditor: Bool {
        isEditing && visibility?.wrappedValue == false
    }
}

/// A switch row: icon, title and a trailing switch.
struct PanelToggleRow: View {
    let title: String
    let caption: String
    let systemImage: String
    @Binding var isOn: Bool
    var isEditing = false
    var showsDragHandle = false
    var visibility: Binding<Bool>? = nil
    var isActive = false
    var activeText: String? = nil
    var needsAttention = false
    var permissionButtonTitle: String? = nil
    var permissionAction: (() -> Void)? = nil
    /// Optional inline action under the title, shown only outside edit mode.
    var accessoryTitle: String? = nil
    var accessoryAction: (() -> Void)? = nil

    var body: some View {
        rowContent
            .panelRowInsets()
            .panelRowDescription(showsCaption ? nil : caption)
    }

    /// Only a problem to fix is spelled out on the row, and every
    /// description in edit mode. Otherwise the description is the tooltip.
    private var showsCaption: Bool {
        needsAttention || isEditing
    }

    private var rowContent: some View {
        HStack(spacing: PanelRowMetrics.iconSpacing) {
            if isEditing && showsDragHandle {
                PanelDragHandle()
            }
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: PanelRowMetrics.iconWidth)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isHiddenInEditor ? Color.secondary : Color.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if showsCaption {
                    Text(caption)
                        .font(.system(size: 10))
                        .foregroundStyle(captionColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !isEditing, isActive, let activeText {
                    Label(activeText, systemImage: "checkmark.circle.fill")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.green)
                        .lineLimit(1)
                }
                if !isEditing, needsAttention, let permissionAction {
                    Button {
                        permissionAction()
                    } label: {
                        Label(permissionButtonTitle ?? "", systemImage: "hand.raised.fill")
                            .font(.system(size: 9.5, weight: .semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
                if !isEditing, let accessoryTitle, let accessoryAction {
                    Button {
                        accessoryAction()
                    } label: {
                        Label(accessoryTitle, systemImage: "arrow.up.forward.square")
                            .font(.system(size: 9.5, weight: .semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
            }
            Spacer(minLength: 0)
            trailingControl
        }
    }

    @ViewBuilder
    private var trailingControl: some View {
        if isEditing, let visibility {
            if !visibility.wrappedValue {
                PanelHiddenBadge()
            }
            PanelInlineHideButton(isVisible: visibility)
        } else {
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .controlSize(.small)
                .toggleStyle(.switch)
                .accessibilityHint(showsCaption ? "" : caption)
        }
    }

    private var iconColor: Color {
        if isHiddenInEditor { return .secondary }
        if needsAttention { return .orange }
        return isOn ? .accentColor : .secondary
    }

    private var captionColor: Color {
        if isHiddenInEditor { return Color.secondary.opacity(0.55) }
        return needsAttention ? .orange : .secondary
    }

    private var isHiddenInEditor: Bool {
        isEditing && visibility?.wrappedValue == false
    }
}

// MARK: - Grouped rows

/// Spacing shared by the rows inside a `PanelRowGroup`. Separators start
/// under the titles rather than the icons.
enum PanelRowMetrics {
    static let iconWidth: CGFloat = 22
    static let iconSpacing: CGFloat = 9
    static let dragHandleWidth: CGFloat = 16
    static let horizontalInset: CGFloat = 10
    static let verticalInset: CGFloat = 8

    static var separatorInset: CGFloat {
        horizontalInset + iconWidth + iconSpacing
    }
}

/// One card for a list of panel rows, split by hairlines: a list reads as
/// one block, and every row stays its own target.
struct PanelRowGroup<Item: Hashable, Row: View>: View {
    let items: [Item]
    /// Edit mode puts a drag handle before every icon, so the separators
    /// move over with the titles.
    var showsDragHandles = false
    @ViewBuilder let row: (Item) -> Row

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element) { index, item in
                    if index > 0 {
                        Divider()
                            .padding(.leading, PanelRowMetrics.separatorInset
                                        + (showsDragHandles ? PanelRowMetrics.dragHandleWidth + PanelRowMetrics.iconSpacing : 0))
                            .padding(.trailing, PanelRowMetrics.horizontalInset)
                            .accessibilityHidden(true)
                    }
                    row(item)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .panelCard(padded: false)
        }
    }
}

/// The hover fill of a tappable row, inset from the group's edges so it
/// never crosses the rounded corners of the card around it.
struct PanelRowHighlight: View {
    let isVisible: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(Color.primary.opacity(isVisible ? 0.06 : 0))
            .padding(3)
    }
}

private struct PanelRowInsets: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, PanelRowMetrics.horizontalInset)
            .padding(.vertical, PanelRowMetrics.verticalInset)
    }
}

extension View {
    /// The padding a row gets inside a `PanelRowGroup`.
    func panelRowInsets() -> some View {
        modifier(PanelRowInsets())
    }

    /// A row's description as its tooltip, and through it the VoiceOver
    /// help, whenever the row does not print it. An empty help keeps the
    /// row one view while its caption comes and goes.
    func panelRowDescription(_ description: String?) -> some View {
        help(description ?? "")
    }
}
