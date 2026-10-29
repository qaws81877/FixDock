// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import SwiftUI

/// The panel down the side of the editor: three looks to start from, then the
/// handful of things worth changing. Everything here changes the picture the
/// preview is already showing, so nothing has to be imagined.
struct RecorderInspector: View {
    @ObservedObject var model: RecorderEditorModel
    @ObservedObject private var l10n = L10n.shared
    @State private var showsBackdropPopover = false
    @State private var tab: Tab = .look
    @State private var hoveredLook: RecorderEditDocument.Look?
    /// Typing is one edit, landed when the field is let go. Without this the
    /// caption would only reach the preview on a Return, and this field takes
    /// several lines, so Return is a new line and not a commit.
    @FocusState private var textFieldFocused: Bool

    private var strings: Strings { l10n.s }

    private enum Tab: String, CaseIterable {
        case look, pointer, zoom
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // Selecting a zoom swaps the whole panel to that zoom. The
                // swap is what teaches the selection model, without a word.
                if let text = model.selectedText {
                    selectedTextSection(text)
                } else if let image = model.selectedImage {
                    selectedImageSection(image)
                } else if model.selectedBlur != nil {
                    selectedBlurSection
                } else if let selected = model.selectedZoom {
                    selectedZoomSection(selected)
                } else {
                    tabPicker
                    switch tab {
                    case .look:
                        lookSection
                        Divider().opacity(0.35)
                        backgroundSection
                    case .pointer:
                        if model.hasPointerTrack {
                            pointerSection
                        } else {
                            Text(strings.recorderEditorNoPointerNote)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    case .zoom:
                        zoomSection
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .scrollIndicators(.never)
        .frame(width: 272)
        .background(.ultraThinMaterial)
    }

    private var tabPicker: some View {
        Picker("", selection: $tab) {
            Text(strings.recorderEditorLookLabel).tag(Tab.look)
            Text(strings.recorderEditorPointerSectionLabel).tag(Tab.pointer)
            Text(strings.recorderEditorZoomSectionLabel).tag(Tab.zoom)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    // MARK: - Look

    private var lookSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle(strings.recorderEditorLookLabel)
            HStack(spacing: 7) {
                lookCard(.raw, title: strings.recorderEditorLookRaw, icon: "rectangle")
                lookCard(.clean, title: strings.recorderEditorLookClean,
                         icon: "cursorarrow.motionlines")
                lookCard(.studio, title: strings.recorderEditorLookStudio, icon: "sparkles")
            }
        }
    }

    private func lookCard(_ look: RecorderEditDocument.Look,
                          title: String,
                          icon: String) -> some View {
        let selected = model.document.matches(look)
        let hovered = hoveredLook == look
        return Button {
            withAnimation(.easeOut(duration: 0.16)) {
                model.applyLook(look)
            }
        } label: {
            VStack(spacing: 6) {
                lookPreview(look, icon: icon)
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 5)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.1)
                                   : Color.white.opacity(hovered ? 0.07 : 0.035))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor.opacity(0.72)
                                           : Color.white.opacity(hovered ? 0.14 : 0.07),
                                  lineWidth: selected ? 1.25 : 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(alignment: .topTrailing) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary.opacity(0.28))
                    .padding(6)
            }
        }
        .buttonStyle(.plain)
        .onHover { isInside in hoveredLook = isInside ? look : nil }
    }

    private func lookPreview(_ look: RecorderEditDocument.Look, icon: String) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(look == .studio
                      ? AnyShapeStyle(LinearGradient(colors: [Color.indigo.opacity(0.9),
                                                               Color.purple.opacity(0.55)],
                                                     startPoint: .topLeading,
                                                     endPoint: .bottomTrailing))
                      : AnyShapeStyle(Color.black.opacity(look == .raw ? 0.82 : 0.62)))
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color(white: look == .raw ? 0.55 : 0.78).opacity(0.82))
                .frame(width: 31, height: 20)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: icon)
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(3)
                }
                .shadow(color: .black.opacity(0.24), radius: 3, y: 2)
        }
        .frame(width: 48, height: 36)
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        }
    }

    // MARK: - Background

    private var backgroundSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(strings.recorderEditorBackgroundSectionLabel)
            Button {
                showsBackdropPopover = true
            } label: {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(LinearGradient(
                            colors: BackdropPickerAssets.previewColors(for: model.backdropStyle),
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 26, height: 20)
                        .overlay {
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
                        }
                    Text(model.showsBackdrop
                         ? strings.recorderEditorBackgroundSectionLabel
                         : l10n.s.screenshotEditorBackdropNone)
                        .font(.system(size: 12))
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .popover(isPresented: $showsBackdropPopover, arrowEdge: .trailing) {
                ScreenshotBackdropPopover(decor: model, showsAdjustments: false)
            }

            Picker(strings.recorderEditorShapeLabel, selection: aspectBinding) {
                Text(strings.recorderEditorShapeOriginal).tag(RecorderSupport.Aspect.original.rawValue)
                Text(strings.recorderEditorShapeWide).tag(RecorderSupport.Aspect.wide.rawValue)
                Text(strings.recorderEditorShapeSquare).tag(RecorderSupport.Aspect.square.rawValue)
                Text(strings.recorderEditorShapeVertical).tag(RecorderSupport.Aspect.vertical.rawValue)
            }
            .pickerStyle(.menu)

            if model.showsBackdrop {
                VStack(spacing: 7) {
                    backgroundSlider(title: l10n.s.screenshotEditorBackdropPadding,
                                     value: model.backdropStyle.padding,
                                     onChange: { updateBackdrop(\.padding, to: $0) },
                                     onReset: { updateBackdrop(\.padding, to: 0.5) })
                    backgroundSlider(title: l10n.s.screenshotEditorBackdropCorners,
                                     value: model.backdropStyle.cornerRadius,
                                     onChange: { updateBackdrop(\.cornerRadius, to: $0) },
                                     onReset: { updateBackdrop(\.cornerRadius, to: 0) })
                    backgroundSlider(title: l10n.s.screenshotEditorBackdropBlur,
                                     value: model.backdropStyle.blur,
                                     onChange: { updateBackdrop(\.blur, to: $0) },
                                     onReset: { updateBackdrop(\.blur, to: 0) })
                }
                .padding(9)
                .background(Color.white.opacity(0.04),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }

    private func updateBackdrop(
        _ keyPath: WritableKeyPath<ScreenshotSupport.BackdropStyle, Double>,
        to value: Double
    ) {
        var style = model.backdropStyle
        style[keyPath: keyPath] = value
        model.backdropStyle = style
    }

    private func backgroundSlider(title: String,
                                  value: Double,
                                  onChange: @escaping (Double) -> Void,
                                  onReset: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 10.5))
                .foregroundStyle(Color(white: 0.72))
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .frame(width: 50, alignment: .leading)
            Slider(value: Binding(get: { value }, set: onChange), in: 0...1)
                .controlSize(.mini)
                .onTapGesture(count: 2) { onReset() }
            Text(String(format: "%.0f%%", locale: .current, value * 100))
                .font(.system(size: 10.5, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Color(white: 0.86))
                .frame(width: 34, alignment: .trailing)
        }
    }

    // MARK: - One zoom

    /// Exactly four rows, and four is the ceiling. A zoom has more knobs than
    /// this in theory; showing them turns a timeline into a control panel.
    private func selectedZoomSection(_ segment: RecorderTimeline.ZoomSegment) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // The way back has to be a labelled thing, not a bare glyph:
            // otherwise selecting a zoom feels like a door that locks.
            Button {
                model.selectZoom(nil)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10, weight: .semibold))
                    Text(strings.recorderEditorBackToOptions)
                        .font(.system(size: 11, weight: .medium))
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Color.accentColor)
            .keyboardShortcut(.escape, modifiers: [])
            sectionTitle(strings.recorderEditorThisZoomLabel)
            valueSlider(title: strings.recorderEditorZoomAmountLabel,
                        value: segment.amount,
                        range: RecorderSupport.zoomAmountRange,
                        format: "%.1f×",
                        onChange: { model.setSelectedZoomAmount($0) },
                        onCommit: { model.commitZoomEdit() },
                        onReset: {
                            model.setSelectedZoomAmount(1.8)
                            model.commitZoomEdit()
                        })
            VStack(alignment: .leading, spacing: 5) {
                Text(strings.recorderEditorZoomWhereLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(Color(white: 0.72))
                Picker("", selection: Binding(
                    get: { segment.followsPointer },
                    set: { follows in
                        if follows {
                            model.setSelectedZoomFocus(nil)
                        } else {
                            model.beginAiming()
                        }
                    })) {
                        Text(strings.recorderEditorZoomFollowsPointer).tag(true)
                        Text(strings.recorderEditorZoomPickSpot).tag(false)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                if !segment.followsPointer {
                    Button(strings.recorderEditorZoomPickSpotHint) { model.beginAiming() }
                        .buttonStyle(.borderless)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.accentColor)
                }
            }
            Button(strings.recorderEditorRemoveZoom) { model.removeSelectedZoom() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .frame(maxWidth: .infinity)
        }
    }

    // MARK: - One text

    private func selectedTextSection(_ overlay: RecorderTextOverlay) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                model.selectLaneItem(.text, id: nil)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10, weight: .semibold))
                    Text(strings.recorderEditorBackToOptions)
                        .font(.system(size: 11, weight: .medium))
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Color.accentColor)
            .keyboardShortcut(.escape, modifiers: [])
            sectionTitle(strings.recorderEditorThisTextLabel)

            TextField(strings.recorderEditorTextPlaceholder, text: Binding(
                get: { overlay.text },
                set: { value in model.updateSelectedText { $0.text = value } }),
                      axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...3)
                .focused($textFieldFocused)
                .onSubmit { model.commitZoomEdit() }
                .onChange(of: textFieldFocused) { _, focused in
                    if !focused { model.commitZoomEdit() }
                }
                .onDisappear { model.commitZoomEdit() }

            valueSlider(title: strings.recorderEditorTextSizeLabel,
                        value: overlay.size,
                        range: RecorderTextOverlay.sizeRange,
                        format: "%.0f%%",
                        scale: 100,
                        onChange: { value in model.updateSelectedText { $0.size = value } },
                        onCommit: { model.commitZoomEdit() },
                        onReset: {
                            model.updateSelectedText { $0.size = 0.06 }
                            model.commitZoomEdit()
                        })

            VStack(alignment: .leading, spacing: 5) {
                Text(strings.recorderEditorTextPositionLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(Color(white: 0.72))
                anchorGrid(selected: overlay.anchor) { anchor in
                    model.updateSelectedText { $0.anchor = anchor }
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(strings.recorderEditorTextColorLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(Color(white: 0.72))
                HStack(spacing: 6) {
                    ForEach(RecorderTextOverlay.Palette.allCases, id: \.rawValue) { palette in
                        let parts = palette.components
                        Circle()
                            .fill(Color(.sRGB, red: parts.red, green: parts.green,
                                        blue: parts.blue, opacity: 1))
                            .frame(width: 20, height: 20)
                            .overlay {
                                Circle().strokeBorder(
                                    overlay.palette == palette
                                        ? Color.accentColor : Color.white.opacity(0.18),
                                    lineWidth: overlay.palette == palette ? 2.5 : 1)
                            }
                            .onTapGesture {
                                model.updateSelectedText { $0.palette = palette }
                                model.commitZoomEdit()
                            }
                    }
                }
            }

            Button(strings.recorderEditorRemoveText) { model.removeSelectedText() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .frame(maxWidth: .infinity)
        }
    }

    // MARK: - One picture

    /// The picture itself was chosen when the block was made, so what is left
    /// here is how big it is, how solid it is and where it sits.
    private func selectedImageSection(_ overlay: RecorderImageOverlay) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                model.selectLaneItem(.image, id: nil)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10, weight: .semibold))
                    Text(strings.recorderEditorBackToOptions)
                        .font(.system(size: 11, weight: .medium))
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Color.accentColor)
            .keyboardShortcut(.escape, modifiers: [])
            sectionTitle(strings.recorderEditorThisImageLabel)

            Text(URL(fileURLWithPath: overlay.path).lastPathComponent)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            valueSlider(title: strings.recorderEditorImageSizeLabel,
                        value: overlay.size,
                        range: RecorderImageOverlay.sizeRange,
                        format: "%.0f%%",
                        scale: 100,
                        onChange: { value in model.updateSelectedImage { $0.size = value } },
                        onCommit: { model.commitZoomEdit() },
                        onReset: {
                            model.updateSelectedImage { $0.size = RecorderImageOverlay.defaultSize }
                            model.commitZoomEdit()
                        })

            valueSlider(title: strings.recorderEditorImageOpacityLabel,
                        value: overlay.opacity,
                        range: RecorderImageOverlay.opacityRange,
                        format: "%.0f%%",
                        scale: 100,
                        onChange: { value in model.updateSelectedImage { $0.opacity = value } },
                        onCommit: { model.commitZoomEdit() },
                        onReset: {
                            model.updateSelectedImage { $0.opacity = 1 }
                            model.commitZoomEdit()
                        })

            VStack(alignment: .leading, spacing: 5) {
                Text(strings.recorderEditorImagePositionLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(Color(white: 0.72))
                anchorGrid(selected: overlay.anchor) { anchor in
                    model.updateSelectedImage { $0.anchor = anchor }
                }
            }

            Button(strings.recorderEditorRemoveText) { model.removeSelectedImage() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .frame(maxWidth: .infinity)
        }
    }

    // MARK: - One blur

    /// The area is the whole thing, and it is drawn on the picture rather than
    /// typed here: a blur that misses by a few pixels is not a blur.
    private var selectedBlurSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                model.selectLaneItem(.blur, id: nil)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10, weight: .semibold))
                    Text(strings.recorderEditorBackToOptions)
                        .font(.system(size: 11, weight: .medium))
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Color.accentColor)
            .keyboardShortcut(.escape, modifiers: [])
            sectionTitle(strings.recorderEditorThisBlurLabel)

            Button {
                model.beginPickingBlurArea()
            } label: {
                Label(strings.recorderEditorBlurPickArea, systemImage: "aqi.medium")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(model.isPickingBlurArea)
            Text(model.isPickingBlurArea ? strings.recorderEditorBlurPickAreaHint : strings.recorderEditorBlurCaption)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let blur = model.selectedBlur {
                let levels = ScreenshotSupport.BlurStrength.levels
                valueSlider(title: l10n.s.screenshotEditorBlurStrength,
                            value: Double(blur.strength),
                            range: Double(levels.lowerBound)...Double(levels.upperBound),
                            format: "%.0f",
                            step: 1,
                            onChange: { model.setSelectedBlurStrength(Int($0.rounded())) },
                            onCommit: { model.commitZoomEdit() },
                            onReset: {
                                model.setSelectedBlurStrength(ScreenshotSupport.BlurStrength.defaultLevel)
                                model.commitZoomEdit()
                            })
            }

            Button(strings.recorderEditorRemoveZoom) { model.removeSelectedBlur() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .frame(maxWidth: .infinity)
        }
    }

    /// Nine places instead of a drag: it reads at a glance, needs no gesture
    /// on the picture, and covers what people actually do with a caption or a
    /// mark of their own.
    private func anchorGrid(selected: RecorderTextOverlay.Anchor,
                            onSelect: @escaping (RecorderTextOverlay.Anchor) -> Void)
        -> some View {
        let rows: [[RecorderTextOverlay.Anchor]] = [
            [.topLeading, .top, .topTrailing],
            [.leading, .center, .trailing],
            [.bottomLeading, .bottom, .bottomTrailing],
        ]
        return VStack(spacing: 4) {
            ForEach(rows.indices, id: \.self) { row in
                HStack(spacing: 4) {
                    ForEach(rows[row], id: \.rawValue) { anchor in
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(selected == anchor
                                  ? Color.accentColor.opacity(0.85)
                                  : Color.white.opacity(0.08))
                            .frame(height: 20)
                            .onTapGesture {
                                onSelect(anchor)
                                model.commitZoomEdit()
                            }
                    }
                }
            }
        }
    }

    /// A slider that says what it is set to and goes back to its default on a
    /// double click. A bare track with no number is the difference between a
    /// control and a guess.
    private func valueSlider(title: String,
                             value: Double,
                             range: ClosedRange<Double>,
                             format: String,
                             scale: Double = 1,
                             step: Double? = nil,
                             onChange: @escaping (Double) -> Void,
                             onCommit: @escaping () -> Void = {},
                             onReset: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                    .font(.system(size: 11))
                    .foregroundStyle(Color(white: 0.72))
                Spacer()
                Text(String(format: format, value * scale))
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(Color(white: 0.86))
            }
            Group {
                if let step {
                    Slider(value: Binding(get: { value }, set: onChange),
                           in: range,
                           step: step,
                           onEditingChanged: { editing in if !editing { onCommit() } })
                } else {
                    Slider(value: Binding(get: { value }, set: onChange),
                           in: range,
                           onEditingChanged: { editing in if !editing { onCommit() } })
                }
            }
            .controlSize(.small)
            .onTapGesture(count: 2) { onReset() }
        }
    }

    // MARK: - Pointer

    private var pointerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(strings.recorderEditorPointerSectionLabel)
            Toggle(strings.recorderEditorPointerShowToggle, isOn: boolBinding(\.showsPointer))
                .toggleStyle(.switch)
                .controlSize(.mini)
            if model.document.showsPointer {
                Picker(strings.recorderEditorPointerSmoothingLabel, selection: smoothingBinding) {
                    Text(strings.recorderEditorPointerSmoothingOff)
                        .tag(RecorderMotion.Smoothing.off.rawValue)
                    Text(strings.recorderEditorPointerSmoothingLight)
                        .tag(RecorderMotion.Smoothing.light.rawValue)
                    Text(strings.recorderEditorPointerSmoothingSmooth)
                        .tag(RecorderMotion.Smoothing.smooth.rawValue)
                    Text(strings.recorderEditorPointerSmoothingCinematic)
                        .tag(RecorderMotion.Smoothing.cinematic.rawValue)
                }
                .pickerStyle(.menu)
                valueSlider(title: strings.recorderEditorPointerSizeLabel,
                            value: model.document.pointerSize,
                            range: RecorderSupport.pointerSizeRange,
                            format: "%.2f×",
                            onChange: { doubleBinding(\.pointerSize).wrappedValue = $0 },
                            onReset: { doubleBinding(\.pointerSize).wrappedValue = 1 })
                Toggle(strings.recorderEditorClickRingToggle, isOn: boolBinding(\.showsClickRing))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
            }
        }
    }

    // MARK: - Zoom

    private var zoomSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle(strings.recorderEditorZoomSectionLabel)
            if model.hasPointerTrack {
                Toggle(strings.recorderEditorZoomToggle, isOn: Binding(
                    get: { model.document.zoomEnabled },
                    set: model.setAutomaticZoomEnabled))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
            }
            if model.document.zoomEnabled {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(strings.recorderEditorTypingZoomToggle, isOn: Binding(
                        get: { model.document.zoomsOnTyping },
                        set: model.setTypingZoomEnabled))
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                    Text(strings.recorderEditorTypingZoomCaption)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if model.document.zoomSegments.isEmpty {
                    zoomEmptyState
                } else {
                    VStack(alignment: .leading, spacing: 9) {
                        valueSlider(title: strings.recorderEditorZoomAmountLabel,
                                    value: model.document.zoomAmount,
                                    range: RecorderSupport.zoomAmountRange,
                                    format: "%.1f×",
                                    onChange: { doubleBinding(\.zoomAmount).wrappedValue = $0 },
                                    onReset: { doubleBinding(\.zoomAmount).wrappedValue = 1.8 })
                        if model.hasPointerTrack {
                            Button(strings.recorderEditorRegenerateZooms) { model.regenerateZooms() }
                                .buttonStyle(.borderless)
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    .padding(11)
                    .background(Color.white.opacity(0.035),
                                in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                }
            }
        }
    }

    private var zoomEmptyState: some View {
        VStack(spacing: 9) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 38, height: 38)
                Image(systemName: "plus.magnifyingglass")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            VStack(spacing: 3) {
                Text(strings.recorderEditorZoomEmptyTitle)
                    .font(.system(size: 12, weight: .semibold))
                Text(strings.recorderEditorZoomEmptyCaption)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(model.canCreateAutomaticZooms
                   ? strings.recorderEditorCreateAutomaticZooms : strings.recorderEditorAddZoomButton) {
                if model.canCreateAutomaticZooms {
                    model.regenerateZooms()
                } else {
                    model.addZoom(at: model.sourceTime)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
        .background(Color.white.opacity(0.035),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.07), lineWidth: 1)
        }
    }

    // MARK: - Pieces

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color(white: 0.62))
            .textCase(.uppercase)
            .kerning(0.4)
    }

    private func boolBinding(_ path: WritableKeyPath<RecorderEditDocument, Bool>) -> Binding<Bool> {
        Binding(get: { model.document[keyPath: path] },
                set: { newValue in
                    var next = model.document
                    next[keyPath: path] = newValue
                    model.document = next
                })
    }

    private func doubleBinding(
        _ path: WritableKeyPath<RecorderEditDocument, Double>
    ) -> Binding<Double> {
        Binding(get: { model.document[keyPath: path] },
                set: { newValue in
                    var next = model.document
                    next[keyPath: path] = newValue
                    model.document = next
                })
    }

    private var smoothingBinding: Binding<String> {
        Binding(get: { model.document.pointerSmoothing },
                set: { newValue in
                    var next = model.document
                    next.pointerSmoothing = newValue
                    model.document = next
                })
    }

    private var aspectBinding: Binding<String> {
        Binding(get: { model.document.aspect },
                set: { newValue in
                    var next = model.document
                    next.aspect = newValue
                    model.document = next
                })
    }

}
