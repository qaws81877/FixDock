// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import AppKit
import SwiftUI

/// The editor footer's backdrop and watermark buttons, each opening its
/// popover. The backdrop button previews the fill it paints; the watermark
/// button lights up while a mark draws. Adapted from upstream's editor view.
struct ScreenshotEditorDecorButtons: View {
    @ObservedObject var decor: ScreenshotEditorDecor
    @ObservedObject private var l10n = L10n.shared
    @State private var backdropShown = false
    @State private var watermarkShown = false

    private var s: Strings { l10n.s }

    var body: some View {
        HStack(spacing: 4) {
            Button {
                backdropShown.toggle()
            } label: {
                HStack(spacing: 6) {
                    backdropPreview
                    Text(s.screenshotEditorBackdrop)
                }
                .padding(.horizontal, 6)
                .frame(height: 24)
            }
            .buttonStyle(.borderless)
            .help(s.screenshotEditorBackdrop)
            .accessibilityLabel(s.screenshotEditorBackdrop)
            .popover(isPresented: $backdropShown, arrowEdge: .top) {
                ScreenshotBackdropPopover(decor: decor)
            }
            Divider().frame(height: 16)
            Button {
                watermarkShown.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "signature")
                        .foregroundStyle(decor.showsWatermark ? Color.accentColor : Color.secondary)
                    Text(s.screenshotEditorWatermark)
                }
                .padding(.horizontal, 6)
                .frame(height: 24)
            }
            .buttonStyle(.borderless)
            .help(s.screenshotEditorWatermark)
            .accessibilityLabel(s.screenshotEditorWatermark)
            .accessibilityAddTraits(decor.showsWatermark ? .isSelected : [])
            .popover(isPresented: $watermarkShown, arrowEdge: .top) {
                ScreenshotWatermarkPopover(decor: decor)
            }
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule(style: .continuous))
        .overlay(Capsule(style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.16), radius: 12, y: 3)
    }

    @ViewBuilder
    private var backdropPreview: some View {
        let style = decor.backdropStyle.sanitized()
        switch style.kind {
        case .none:
            Image(systemName: "rectangle.dashed")
                .foregroundStyle(.secondary)
        case .image:
            Image(systemName: "photo")
                .foregroundStyle(decor.showsBackdrop ? Color.accentColor : Color.secondary)
        case .preset, .solid, .gradient:
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(LinearGradient(colors: BackdropPickerAssets.previewColors(for: style),
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 18, height: 13)
                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.2), lineWidth: 0.5))
        }
    }
}

/// The footer while Expand canvas is the tool: what fills the new space and
/// the canvas size the drag would make.
struct ScreenshotCanvasExpansionControls: View {
    @ObservedObject var model: ScreenshotEditorModel
    @ObservedObject private var l10n = L10n.shared
    /// 0 white, 1 transparent, 2 the custom colour.
    @State private var choice = 0
    @State private var customColor = Color.white

    private var s: Strings { l10n.s }

    var body: some View {
        let size = model.expansionDraft?.size ?? model.imageSize
        HStack(spacing: 10) {
            Picker(s.screenshotEditorCanvasFill, selection: $choice) {
                Text(s.screenshotEditorCanvasFillWhite).tag(0)
                Text(s.screenshotEditorCanvasFillClear).tag(1)
                Text(s.screenshotEditorCanvasFillCustom).tag(2)
            }
            .fixedSize()
            .onChange(of: choice) { _, _ in updateFill() }
            if choice == 2 {
                ColorPicker(s.screenshotEditorCanvasFillCustom, selection: $customColor, supportsOpacity: false)
                    .labelsHidden()
                    .onChange(of: customColor) { _, _ in updateFill() }
            }
            Divider().frame(height: 16)
            Text("\(Int(size.width)) × \(Int(size.height)) px")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(model.expansionRejected ? Color.orange : Color.secondary)
                .fixedSize()
                .help(s.screenshotEditorCanvasHint)
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule(style: .continuous))
        .overlay(Capsule(style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.16), radius: 12, y: 3)
        .onAppear(perform: seed)
    }

    private func seed() {
        switch model.expansionFill {
        case .white: choice = 0
        case .transparent: choice = 1
        case let .color(red, green, blue):
            customColor = Color(.sRGB, red: red, green: green, blue: blue, opacity: 1)
            choice = 2
        }
    }

    private func updateFill() {
        switch choice {
        case 1:
            model.expansionFill = .transparent
        case 2:
            let color = NSColor(customColor).usingColorSpace(.sRGB) ?? .white
            model.expansionFill = .color(red: Double(color.redComponent), green: Double(color.greenComponent),
                                         blue: Double(color.blueComponent))
        default:
            model.expansionFill = .white
        }
    }
}
