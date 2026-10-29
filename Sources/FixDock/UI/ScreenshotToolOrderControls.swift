// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import AppKit
import SwiftUI

/// The rail order, the keys 1 to 9 and each tool's own key, shown in the
/// editor's rail popover and on the screenshot settings tab. Both read and
/// write the same defaults, so a change in one shows in the other. Adapted
/// from upstream's `ScreenshotToolOrderControls`; a recorded key is checked
/// only against the editor's own keys and the other tools'.
struct ScreenshotToolOrderControls: View {
    @ObservedObject private var l10n = L10n.shared
    @AppStorage(DefaultsKey.screenshotToolOrder) private var orderRaw =
        ScreenshotSupport.Tool.defaultOrderStorage
    @AppStorage(DefaultsKey.screenshotToolShortcutsEnabled) private var shortcutsEnabled = true
    @AppStorage(DefaultsKey.screenshotToolShortcuts) private var bindingsRaw = ""
    @StateObject private var recorder = ScreenshotToolKeyRecorder()
    @State private var errorText: String?
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

            Text(errorText ?? (recorder.tool == nil ? " " : s.screenshotToolKeyRecordingHint))
                .font(.caption)
                .foregroundStyle(errorText == nil ? Color.secondary : .orange)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .topLeading)
                .accessibilityHidden(errorText == nil && recorder.tool == nil)

            HStack {
                Spacer()
                Button(s.screenshotToolOrderReset) {
                    recorder.cancel()
                    orderRaw = ScreenshotSupport.Tool.defaultOrderStorage
                    bindingsRaw = ""
                    errorText = nil
                }
                .disabled(orderedTools == ScreenshotSupport.Tool.editorTools && bindingsRaw.isEmpty)
            }
        }
        .onChange(of: l10n.language) { _, _ in errorText = nil }
        .onDisappear { recorder.cancel() }
    }

    private func toolRow(_ tool: ScreenshotSupport.Tool) -> some View {
        let index = orderedTools.firstIndex(of: tool) ?? 0
        let title = tool.railTitle(s)
        let hasOwnKey = ScreenshotSupport.Tool.bindings(from: bindingsRaw)[tool] != nil
        return HStack(spacing: 7) {
            Image(systemName: tool.railSymbol)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            Text(title)
                .lineLimit(1)
            Spacer(minLength: 4)
            Group {
                if hasOwnKey {
                    Button {
                        assign(nil, digit: nil, to: tool, keepingSlot: true)
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 20, height: 22)
                    }
                    .buttonStyle(.borderless)
                    .help(s.screenshotToolKeyRemove)
                    .accessibilityLabel(title + ": " + s.screenshotToolKeyRemove)
                } else {
                    Color.clear.frame(width: 20, height: 22)
                }
            }
            keyButton(for: tool, title: title)
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

    /// Shows the tool's key (its own, or its slot digit); a click records a
    /// new one.
    private func keyButton(for tool: ScreenshotSupport.Tool, title: String) -> some View {
        let recording = recorder.tool == tool
        let label = ScreenshotSupport.Tool.shortcutLabel(for: tool, orderRaw: orderRaw,
                                                         bindingsRaw: bindingsRaw, enabled: true)
        return Button {
            if recording {
                recorder.cancel()
            } else {
                errorText = nil
                recorder.start(for: tool) { result in handle(result, for: tool) }
            }
        } label: {
            Text(recording ? s.screenshotToolKeyPress : (label ?? s.screenshotToolKeyNone))
                .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                .lineLimit(1)
                .frame(width: 78, height: 20)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(recording ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.06)))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(recording ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(label ?? s.screenshotToolKeyNone)
    }

    private func handle(_ result: ScreenshotToolKeyRecorder.Result, for tool: ScreenshotSupport.Tool) {
        switch result {
        case .cleared:
            assign(nil, digit: nil, to: tool, keepingSlot: false)
        case .digit(let digit):
            assign(nil, digit: digit, to: tool, keepingSlot: false)
        case .key(let key):
            switch ScreenshotSupport.Tool.bindingRejection(for: key, excluding: tool, bindingsRaw: bindingsRaw) {
            case .reserved:
                errorText = tool.railTitle(s) + " · " + key.displayString + "\n" + s.screenshotToolKeyReserved
            case .tool(let other):
                errorText = tool.railTitle(s) + " · " + key.displayString + "\n"
                    + String(format: s.screenshotToolKeyTaken, other.railTitle(s))
            case nil:
                assign(key, digit: nil, to: tool, keepingSlot: false)
            }
        }
    }

    /// `keepingSlot` drops only the own key; otherwise this is upstream's
    /// assignment: a digit moves the tool, clearing moves it below the
    /// first nine.
    private func assign(_ key: GlobalShortcut?, digit: Int?, to tool: ScreenshotSupport.Tool,
                        keepingSlot: Bool) {
        errorText = nil
        withAnimation(.easeInOut(duration: 0.14)) {
            if keepingSlot {
                var bindings = ScreenshotSupport.Tool.bindings(from: bindingsRaw)
                bindings[tool] = nil
                bindingsRaw = ScreenshotSupport.Tool.bindingsStorage(bindings)
                return
            }
            let assignment = ScreenshotSupport.Tool.assigningBinding(key, digit: digit, to: tool,
                                                                     orderRaw: orderRaw, bindingsRaw: bindingsRaw)
            orderRaw = assignment.orderRaw
            bindingsRaw = assignment.bindingsRaw
        }
    }

    private func move(_ tool: ScreenshotSupport.Tool, by offset: Int) {
        withAnimation(.easeInOut(duration: 0.14)) {
            orderRaw = ScreenshotSupport.Tool.storage(
                ScreenshotSupport.Tool.moving(tool, by: offset, orderRaw: orderRaw))
        }
    }
}

/// Listens for one key for one tool, in whichever window shows the
/// controls; the key never reaches anything else. Escape cancels, Delete
/// clears, a digit names a rail slot.
final class ScreenshotToolKeyRecorder: ObservableObject {
    enum Result {
        case cleared
        case digit(Int)
        case key(GlobalShortcut)
    }

    @Published private(set) var tool: ScreenshotSupport.Tool?
    private var monitor: Any?

    func start(for tool: ScreenshotSupport.Tool, completion: @escaping (Result) -> Void) {
        cancel()
        self.tool = tool
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let keyCode = Int64(event.keyCode)
            let modifiers = GlobalShortcutModifiers(eventFlags: event.modifierFlags)
            if GlobalShortcut.cancelsRecording(keyCode: keyCode) {
                self.cancel()
                return nil
            }
            let result: Result
            if GlobalShortcut.clearsShortcut(keyCode: keyCode, modifiers: modifiers) {
                result = .cleared
            } else if !modifiers.hasPrimaryModifier,
                      let digit = ScreenshotSupport.Tool.shortcutDigit(keyCode: keyCode, typed: event.characters) {
                result = .digit(digit)
            } else {
                result = .key(GlobalShortcut(keyCode: keyCode, modifiers: modifiers))
            }
            self.cancel()
            completion(result)
            return nil
        }
    }

    func cancel() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if tool != nil { tool = nil }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
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
        case .highlight: return "highlighter"
        case .sticker: return "face.smiling"
        case .counter: return "1.circle"
        case .pixelate: return "aqi.medium"
        case .redact: return "rectangle.fill"
        case .crop: return "crop"
        case .spotlight: return "viewfinder"
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
        case .highlight: return s.screenshotEditorToolHighlight
        case .sticker: return s.screenshotEditorToolSticker
        case .counter: return s.screenshotEditorToolCounter
        case .pixelate: return s.screenshotEditorToolBlur
        case .redact: return s.screenshotEditorToolRedact
        case .crop: return s.screenshotEditorToolCrop
        case .spotlight: return s.screenshotEditorToolSpotlight
        case .expandCanvas: return s.screenshotEditorToolExpandCanvas
        case .image: return s.screenshotEditorPastedImage
        }
    }
}
