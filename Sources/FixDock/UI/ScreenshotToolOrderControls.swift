// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import SwiftUI

/// The rail order and the keys 1 to 9, shown in the editor's rail popover
/// and on the screenshot settings tab. Both read and write the same two
/// defaults, so a change in one shows in the other. Adapted from upstream's
/// `ScreenshotToolOrderControls`: a number menu per tool takes the place of
/// its key recorder, since FixDock offers only the digit keys.
struct ScreenshotToolOrderControls: View {
    @ObservedObject private var l10n = L10n.shared
    @AppStorage(DefaultsKey.screenshotToolOrder) private var orderRaw =
        ScreenshotSupport.Tool.defaultOrderStorage
    @AppStorage(DefaultsKey.screenshotToolShortcutsEnabled) private var shortcutsEnabled = true
    var showsTitle = true

    private var s: Strings { l10n.s }

    private var orderedTools: [ScreenshotSupport.Tool] {
        ScreenshotSupport.Tool.ordered(from: orderRaw)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showsTitle {
                Text(s.screenshotToolKeysTitle)
                    .font(.headline)
            }
            Toggle(s.screenshotToolKeysToggle, isOn: $shortcutsEnabled)
            Text(s.screenshotToolKeysCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 2) {
                ForEach(orderedTools, id: \.self) { tool in
                    toolRow(tool)
                    if tool != orderedTools.last {
                        Divider().padding(.leading, 28)
                    }
                }
            }

            HStack {
                Spacer()
                Button(s.screenshotToolOrderReset) {
                    orderRaw = ScreenshotSupport.Tool.defaultOrderStorage
                }
                .disabled(orderedTools == ScreenshotSupport.Tool.editorTools)
            }
        }
    }

    private func toolRow(_ tool: ScreenshotSupport.Tool) -> some View {
        let index = orderedTools.firstIndex(of: tool) ?? 0
        let title = tool.railTitle(s)
        return HStack(spacing: 7) {
            Image(systemName: tool.railSymbol)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            Text(title)
                .lineLimit(1)
            Spacer(minLength: 4)
            numberMenu(for: tool, title: title)
                .opacity(shortcutsEnabled ? 1 : 0.48)
            Button {
                move(tool, by: -1)
            } label: {
                Image(systemName: "chevron.up").frame(width: 20, height: 22)
            }
            .buttonStyle(.borderless)
            .disabled(index == 0)
            .help(s.screenshotToolMoveUp)
            .accessibilityLabel(title + ": " + s.screenshotToolMoveUp)
            Button {
                move(tool, by: 1)
            } label: {
                Image(systemName: "chevron.down").frame(width: 20, height: 22)
            }
            .buttonStyle(.borderless)
            .disabled(index == orderedTools.count - 1)
            .help(s.screenshotToolMoveDown)
            .accessibilityLabel(title + ": " + s.screenshotToolMoveDown)
        }
        .frame(minHeight: 26)
    }

    /// Picking a number moves the tool into that rail slot; No key moves it
    /// just below the first nine.
    private func numberMenu(for tool: ScreenshotSupport.Tool, title: String) -> some View {
        let number = ScreenshotSupport.Tool.shortcutNumber(for: tool, orderRaw: orderRaw, enabled: true)
        let slots = min(ScreenshotSupport.Tool.shortcutLimit, orderedTools.count)
        return Menu {
            ForEach(1...slots, id: \.self) { slot in
                Button("\(slot)") { assign(slot, to: tool) }
            }
            Divider()
            Button(s.screenshotToolKeyNone) { assign(nil, to: tool) }
        } label: {
            Text(number.map(String.init) ?? s.screenshotToolKeyNone)
                .font(.system(size: 11.5, weight: .medium).monospacedDigit())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .frame(width: 70, alignment: .trailing)
        .accessibilityLabel(title)
    }

    private func assign(_ number: Int?, to tool: ScreenshotSupport.Tool) {
        withAnimation(.easeInOut(duration: 0.14)) {
            orderRaw = ScreenshotSupport.Tool.storage(
                ScreenshotSupport.Tool.assigningShortcut(number, to: tool, orderRaw: orderRaw))
        }
    }

    private func move(_ tool: ScreenshotSupport.Tool, by offset: Int) {
        withAnimation(.easeInOut(duration: 0.14)) {
            orderRaw = ScreenshotSupport.Tool.storage(
                ScreenshotSupport.Tool.moving(tool, by: offset, orderRaw: orderRaw))
        }
    }
}

/// What the rail, its tool order popover and the settings tab show for a
/// tool: one switch each, so a new tool needs one symbol and one title.
extension ScreenshotSupport.Tool {
    var railSymbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .arrow: return "arrow.up.right"
        case .text: return "textformat"
        case .rect: return "rectangle"
        case .freehand: return "scribble.variable"
        case .line: return "line.diagonal"
        case .ellipse: return "circle"
        case .expandCanvas: return "arrow.up.left.and.arrow.down.right"
        case .image: return "photo"
        }
    }

    func railTitle(_ s: Strings) -> String {
        switch self {
        case .select: return s.screenshotEditorToolSelect
        case .arrow: return s.screenshotEditorToolArrow
        case .text: return s.screenshotEditorToolText
        case .rect: return s.screenshotEditorToolRect
        case .freehand: return s.screenshotEditorToolFreehand
        case .line: return s.screenshotEditorToolLine
        case .ellipse: return s.screenshotEditorToolEllipse
        case .expandCanvas: return s.screenshotEditorToolExpandCanvas
        case .image: return s.screenshotEditorPastedImage
        }
    }
}
