// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import AppKit
import SwiftUI

/// The annotation editor: tool rail on the left, actions top right, style
/// controls and zoom along the bottom, and the canvas drawn by the shared
/// renderer so the screen matches the export. Adapted from the upstream
/// editor view, without its brand mark, the cuts in
/// `docs/screenshot-editor.md` and the later-stage controls.
struct ScreenshotEditorView: View {
    @ObservedObject var model: ScreenshotEditorModel
    let controller: ScreenshotEditorController
    @ObservedObject private var l10n = L10n.shared

    @State private var editingText = ""
    @FocusState private var textFieldFocused: Bool
    @State private var dragInFlight = false
    @State private var drag = ScreenshotSupport.EditorDrag()
    @State private var dragCanvasArea: CGSize?
    @State private var appeared = false
    @State private var hoveredTool: ScreenshotSupport.Tool?
    @State private var magnifyBase: CGFloat?
    // Stage C: rail order and keys, the tool order popover, and the zoom an
    // Expand canvas drag holds so the canvas does not refit under it.
    @AppStorage(DefaultsKey.screenshotToolOrder) private var toolOrderRaw =
        ScreenshotSupport.Tool.defaultOrderStorage
    @AppStorage(DefaultsKey.screenshotToolShortcutsEnabled) private var toolShortcutsEnabled = true
    @State private var toolOrderShown = false
    @State private var expansionDragZoom: CGFloat?

    private var s: Strings { l10n.s }

    var body: some View {
        // Real rows and columns, not overlays: the canvas scrolls in its own
        // region, so zoomed content never slides under the controls.
        ZStack {
            artboard
            VStack(spacing: 0) {
                topBand
                    .padding(.top, 10)
                    .padding(.horizontal, 12)
                HStack(spacing: 0) {
                    toolRail
                        .padding(.leading, 10)
                    canvasArea
                }
                .padding(.top, 6)
                bottomRow
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
                    .padding(.bottom, 10)
            }
        }
        .ignoresSafeArea()
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: model.tool)
    }

    /// The traffic lights sit on the left of this strip; the actions on the
    /// right.
    private var topBand: some View {
        HStack {
            Spacer()
            actionCluster
        }
        .frame(height: 38)
    }

    // MARK: - Artboard

    private var artboard: some View {
        Rectangle()
            .fill(Color(white: 0.115))
            .overlay {
                LinearGradient(colors: [Color.white.opacity(0.035), .clear], startPoint: .top, endPoint: .bottom)
            }
            .allowsHitTesting(false)
            .ignoresSafeArea()
    }

    // MARK: - Canvas

    private var canvasArea: some View {
        GeometryReader { proxy in
            // Until a drag ends the canvas keeps the region it started in, so
            // a footer that changes with the selection never moves the canvas
            // under a still cursor and turns a click into a drag.
            let available = dragCanvasArea ?? proxy.size
            let zoom = zoomFactor(available: available)
            let canvasSize = CGSize(width: contentPixelSize.width * zoom, height: contentPixelSize.height * zoom)
            ScrollView([.horizontal, .vertical]) {
                canvas(zoom: zoom, available: available)
                    .frame(width: canvasSize.width, height: canvasSize.height)
                    .padding(canvasInsets(available: available, canvas: canvasSize))
            }
            .scrollIndicators(.never)
            .frame(width: available.width, height: available.height, alignment: .topLeading)
            // Trackpad pinch, anchored at the zoom the gesture started from.
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { value in
                        let base = magnifyBase ?? (model.zoomOverride ?? model.currentDisplayZoom)
                        magnifyBase = base
                        model.setZoom(base * value.magnification)
                    }
                    .onEnded { _ in magnifyBase = nil }
            )
        }
        .clipped()
        .overlay(alignment: .bottom) {
            if let notice = model.notice {
                Text(notice)
                    .font(.callout)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
                    .padding(10)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.18), value: model.notice)
    }

    private func zoomFactor(available: CGSize) -> CGFloat {
        if let expansionDragZoom { return expansionDragZoom }
        // Expand canvas leaves room around the capture to drag into.
        let zoom = model.zoomOverride
            ?? ScreenshotSupport.editorFitZoom(available: available, content: contentPixelSize,
                                               margin: model.tool == .expandCanvas
                                                   ? 64 : ScreenshotSupport.editorCanvasMargin)
        // Pinch and scroll zoom start from what is actually on screen.
        model.currentDisplayZoom = zoom
        return zoom
    }

    private func canvasInsets(available: CGSize, canvas: CGSize) -> EdgeInsets {
        let margin = ScreenshotSupport.editorCanvasMargin
        let vertical = max((available.height - canvas.height) / 2, margin)
        let horizontal = max((available.width - canvas.width) / 2, margin)
        return EdgeInsets(top: vertical, leading: horizontal, bottom: vertical, trailing: horizontal)
    }

    private func canvas(zoom: CGFloat, available: CGSize) -> some View {
        let outerRadius = canvasCornerRadius(zoom: zoom)
        return ZStack {
            backdropLayer(zoom: zoom)
            Canvas { context, size in
                context.withCGContext { cg in
                    drawContent(cg, size: size, zoom: zoom)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: outerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: outerRadius, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.14), lineWidth: 1))
        .shadow(color: .black.opacity(0.30), radius: 24, y: 10)
        .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
        .scaleEffect(appeared ? 1 : 0.965)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { appeared = true }
        }
        .overlay(alignment: .topLeading) {
            expansionOverlay(zoom: zoom, cornerRadius: outerRadius)
        }
        .gesture(canvasGesture(zoom: zoom, available: available))
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                updateHoverCursor(at: imagePoint(from: location, zoom: zoom))
            case .ended:
                NSCursor.arrow.set()
            }
        }
        .overlay(alignment: .topLeading) {
            textEditorOverlay(zoom: zoom)
        }
    }

    private func drawContent(_ cg: CGContext, size: CGSize, zoom: CGFloat) {
        let pad = model.backdropPaddingPixels * zoom
        let imageRect = CGRect(x: pad, y: pad, width: model.imageSize.width * zoom,
                               height: model.imageSize.height * zoom)
        let cardPath = drawCardBase(cg, imageRect: imageRect, size: size, zoom: zoom)
        cg.saveGState()
        if let cardPath {
            cg.addPath(cardPath)
            cg.clip()
        }
        drawImageUpright(cg, in: imageRect, canvasHeight: size.height)
        cg.restoreGState()
        cg.saveGState()
        enterImageSpace(cg, zoom: zoom)
        ScreenshotRenderer.drawAnnotations(model.annotations, in: cg, scale: model.scale,
                                           skippingText: model.editingTextID)
        ScreenshotRenderer.drawWatermark(model.decor.watermarkStyle, image: model.decor.watermarkImage,
                                         in: cg, imageSize: model.imageSize,
                                         cornerRadius: model.cardCornerPixels)
        drawTextSelection(cg)
        drawSelectionChrome(cg)
        cg.restoreGState()
    }

    /// Highlight for recognized words selected on the canvas.
    private func drawTextSelection(_ cg: CGContext) {
        guard !model.selectedWordIndexes.isEmpty else { return }
        cg.setFillColor(CGColor(srgbRed: 0.04, green: 0.52, blue: 1, alpha: 0.32))
        for index in model.selectedWordIndexes where model.textWords.indices.contains(index) {
            let rect = model.textWords[index].rect.insetBy(dx: -1.5 * model.scale, dy: -1.5 * model.scale)
            cg.addPath(CGPath(roundedRect: rect, cornerWidth: 2 * model.scale, cornerHeight: 2 * model.scale,
                              transform: nil))
            cg.fillPath()
        }
    }

    private func drawImageUpright(_ cg: CGContext, in rect: CGRect, canvasHeight: CGFloat) {
        cg.saveGState()
        cg.translateBy(x: 0, y: canvasHeight)
        cg.scaleBy(x: 1, y: -1)
        cg.interpolationQuality = .high
        cg.draw(model.baseImage, in: CGRect(x: rect.minX, y: canvasHeight - rect.maxY,
                                            width: rect.width, height: rect.height))
        cg.restoreGState()
    }

    private func drawSelectionChrome(_ cg: CGContext) {
        guard let selectedID = model.selectedID,
              let selected = model.annotations.first(where: { $0.id == selectedID })
        else { return }
        let scale = model.scale
        cg.setStrokeColor(CGColor(srgbRed: 0.04, green: 0.52, blue: 1, alpha: 0.9))
        cg.setLineWidth(1.5 * scale)
        cg.setLineDash(phase: 0, lengths: [4 * scale, 3 * scale])
        if selected.points.count >= 2, selected.tool != .freehand {
            // Lines and arrows: a grip at each end.
            cg.setLineDash(phase: 0, lengths: [])
            for point in selected.points.prefix(2) {
                cg.setFillColor(CGColor(gray: 1, alpha: 1))
                let handle = CGRect(x: point.x - 4 * scale, y: point.y - 4 * scale, width: 8 * scale, height: 8 * scale)
                cg.fillEllipse(in: handle)
                cg.strokeEllipse(in: handle)
            }
            return
        }
        let box = selected.tool == .freehand ? freehandBounds(selected) : selected.rect
        cg.stroke(box.insetBy(dx: -3 * scale, dy: -3 * scale))
        cg.setLineDash(phase: 0, lengths: [])
        if selected.tool.resizesWithHandles {
            for handle in ScreenshotSupport.Handle.allCases {
                let position = handle.position(in: selected.rect)
                let dot = CGRect(x: position.x - 3.5 * scale, y: position.y - 3.5 * scale,
                                 width: 7 * scale, height: 7 * scale)
                cg.setFillColor(CGColor(gray: 1, alpha: 1))
                cg.fillEllipse(in: dot)
                cg.strokeEllipse(in: dot)
            }
        }
    }

    /// A pen stroke has no rect of its own; its points' bounds, padded by
    /// half its width, frame it.
    private func freehandBounds(_ annotation: ScreenshotSupport.Annotation) -> CGRect {
        guard let first = annotation.points.first else { return .zero }
        var box = CGRect(origin: first, size: .zero)
        for point in annotation.points { box = box.union(CGRect(origin: point, size: .zero)) }
        let half = annotation.stroke.width * model.scale / 2
        return box.insetBy(dx: -half, dy: -half)
    }

    // MARK: - Gestures

    private func canvasGesture(zoom: CGFloat, available: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let point = imagePoint(from: value.location, zoom: zoom)
                if !dragInFlight {
                    if model.tool == .expandCanvas { expansionDragZoom = zoom }
                    dragInFlight = true
                    drag.begin(at: value.startLocation)
                    dragCanvasArea = available
                    commitEditingTextIfNeeded()
                    model.beginDrag(at: imagePoint(from: value.startLocation, zoom: zoom))
                    if value.location != value.startLocation { model.continueDrag(to: point) }
                } else {
                    model.continueDrag(to: point)
                }
                drag.update(to: value.location)
            }
            .onEnded { value in
                defer { expansionDragZoom = nil }
                dragInFlight = false
                dragCanvasArea = nil
                let point = imagePoint(from: value.location, zoom: zoom)
                drag.update(to: value.location)
                if model.tool == .expandCanvas { model.continueDrag(to: point) }
                let isTap = drag.isTap(for: model.tool)
                // A text tap outside the capture places nothing.
                if isTap, model.tool == .text, !CGRect(origin: .zero, size: model.imageSize).contains(point) {
                    return
                }
                model.endDrag(at: point, isTap: isTap)
                if model.editingTextID != nil {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { textFieldFocused = true }
                }
            }
    }

    private func imagePoint(from viewPoint: CGPoint, zoom: CGFloat) -> CGPoint {
        let pad = model.backdropPaddingPixels
        return CGPoint(x: viewPoint.x / zoom - pad, y: viewPoint.y / zoom - pad)
    }

    private func updateHoverCursor(at point: CGPoint) {
        if model.tool == .expandCanvas {
            (expansionGrip(at: point) != nil ? NSCursor.crosshair : NSCursor.arrow).set()
        } else if model.tool != .select, model.selectedAnnotationOwns(point) {
            NSCursor.openHand.set()
        } else if model.tool != .select {
            NSCursor.crosshair.set()
        } else if model.wordIndex(at: point) != nil {
            // Recognized text under the cursor reads as text.
            NSCursor.iBeam.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    // MARK: - Inline text editing

    @ViewBuilder
    private func textEditorOverlay(zoom: CGFloat) -> some View {
        if let editingID = model.editingTextID,
           let annotation = model.annotations.first(where: { $0.id == editingID }) {
            let fontSize = max(11, ScreenshotRenderer.fontSize(for: annotation.textSize, scale: model.scale) * zoom)
            TextField(s.screenshotEditorTextPlaceholder, text: $editingText)
                .textFieldStyle(.plain)
                .font(.system(size: fontSize, weight: .semibold))
                .foregroundStyle(Color(nsColor: ScreenshotRenderer.nsColor(annotation.color)))
                .focused($textFieldFocused)
                .frame(minWidth: 130)
                .fixedSize()
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 1))
                .offset(x: (annotation.rect.minX + model.backdropPaddingPixels) * zoom - 6,
                        y: (annotation.rect.minY + model.backdropPaddingPixels) * zoom - 3)
                // A fresh field per text, so switching texts reloads its words.
                .id(editingID)
                .onAppear {
                    editingText = annotation.text
                    DispatchQueue.main.async { textFieldFocused = true }
                }
                .onSubmit { model.commitText(editingID, text: editingText) }
                .onExitCommand { model.commitText(editingID, text: editingText) }
        }
    }

    private func commitEditingTextIfNeeded() {
        if let editingID = model.editingTextID {
            model.commitText(editingID, text: editingText)
        }
    }

    // MARK: - Tool rail

    private var toolRail: some View {
        VStack(spacing: 2) {
            ForEach(ScreenshotSupport.Tool.ordered(from: toolOrderRaw), id: \.self) { tool in
                railButton(tool)
            }
            toolOrderButton
        }
        .padding(5)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 16, y: 5)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func selectTool(_ tool: ScreenshotSupport.Tool) {
        commitEditingTextIfNeeded()
        model.tool = tool
    }

    private func railButton(_ tool: ScreenshotSupport.Tool) -> some View {
        let isActive = model.tool == tool
        let isHovered = hoveredTool == tool
        let number = ScreenshotSupport.Tool.shortcutNumber(for: tool, orderRaw: toolOrderRaw,
                                                           enabled: toolShortcutsEnabled)
        let title = toolTitle(tool) + (number.map { "  (\($0))" } ?? "")
        return Button {
            selectTool(tool)
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: toolSymbol(tool))
                    .font(.system(size: 13.5, weight: .medium))
                    .frame(width: 33, height: 29)
                if let number {
                    Text("\(number)")
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .fixedSize()
                        .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                        .padding(2)
                        .opacity(isHovered || isActive ? 0.9 : 0.55)
                }
            }
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isActive ? Color.accentColor.opacity(0.22)
                      : isHovered ? Color.primary.opacity(0.08) : .clear))
            .foregroundStyle(isActive ? Color.accentColor : Color.primary.opacity(0.85))
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.borderless)
        .onHover { inside in
            hoveredTool = inside ? tool : (hoveredTool == tool ? nil : hoveredTool)
        }
        .help(title)
        .accessibilityLabel(title)
    }

    private func toolSymbol(_ tool: ScreenshotSupport.Tool) -> String {
        tool.railSymbol
    }

    private func toolTitle(_ tool: ScreenshotSupport.Tool) -> String {
        tool.railTitle(s)
    }

    // MARK: - Action cluster (top right)

    private var actionCluster: some View {
        HStack(spacing: 4) {
            iconButton("arrow.uturn.backward", s.menuUndo + "  (⌘Z)", enabled: model.canUndo) {
                commitEditingTextIfNeeded()
                model.undo()
            }
            iconButton("arrow.uturn.forward", s.menuRedo + "  (⇧⌘Z)", enabled: model.canRedo) {
                commitEditingTextIfNeeded()
                model.redo()
            }
            if model.qrReading != nil {
                Divider().frame(height: 16).padding(.horizontal, 3)
                iconButton("qrcode", s.screenshotPreviewQR, enabled: true) { controller.showQRResult() }
                    .transition(.scale.combined(with: .opacity))
            }
            Divider().frame(height: 16).padding(.horizontal, 3)
            iconButton("pin", s.screenshotPreviewPin + "  (⌘P)", enabled: true) {
                commitEditingTextIfNeeded()
                controller.pin()
            }
            Divider().frame(height: 16).padding(.horizontal, 3)
            Menu {
                Button(s.screenshotPreviewSave + "  (⌘S)") {
                    commitEditingTextIfNeeded()
                    controller.save()
                }
                Button(s.screenshotPinSaveAs + "  (⇧⌘S)") {
                    commitEditingTextIfNeeded()
                    controller.saveAs()
                }
            } label: {
                Text(s.screenshotPreviewSave)
            } primaryAction: {
                commitEditingTextIfNeeded()
                controller.save()
            }
            .fixedSize()
            .help(s.screenshotPreviewSave + "  (⌘S)")
            .accessibilityHint(s.screenshotEditorSaveMenu)
            Button(s.screenshotPreviewCopy) {
                commitEditingTextIfNeeded()
                controller.copyToClipboard()
            }
            .buttonStyle(.borderedProminent)
            .help(s.screenshotPreviewCopy + "  (⌘C, ⏎)")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.16), radius: 14, y: 4)
    }

    private func iconButton(_ symbol: String, _ title: String, enabled: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 24, height: 24)
        }
        .buttonStyle(.borderless)
        .disabled(!enabled)
        .help(title)
        .accessibilityLabel(title)
    }

    // MARK: - Bottom row

    private var selectedAnnotation: ScreenshotSupport.Annotation? {
        guard let selectedID = model.selectedID else { return nil }
        return model.annotations.first { $0.id == selectedID }
    }

    private var showsColorControls: Bool {
        if model.tool == .expandCanvas { return false }
        if let selectedAnnotation { return selectedAnnotation.tool != .image }
        return model.tool != .select
    }

    /// Text takes a point size where shapes take a thickness.
    private var showsTextSizeControls: Bool {
        model.tool == .text || (model.tool == .select && selectedAnnotation?.tool == .text)
    }

    /// Depth only means something when there is another shape to pass. The
    /// buttons stay while there is, dimmed until a shape is picked, so picking
    /// or dropping a shape never adds or removes them. A shape still being
    /// drawn counts once it lands.
    private var showsLayerControls: Bool {
        model.annotations.lazy.filter { $0.id != model.draftID }.count > 1
    }

    private var bottomRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 10) {
                infoChip
                Spacer(minLength: 6)
                styleBar
                decorBar
                Spacer(minLength: 6)
                zoomChip
            }
            // Small captures open at the minimum window width. Keep the
            // controls inside it rather than letting this row widen the root.
            VStack(spacing: 6) {
                styleBar
                HStack {
                    infoChip
                    Spacer()
                    decorBar
                    Spacer()
                    zoomChip
                }
            }
        }
    }

    @ViewBuilder
    private var styleBar: some View {
        if showsColorControls || showsLayerControls {
            HStack(spacing: 10) {
                if showsColorControls {
                    HStack(spacing: 4) {
                        ForEach(ScreenshotSupport.ColorID.allCases, id: \.self) { colorDot($0) }
                    }
                    Divider().frame(height: 16)
                    if showsTextSizeControls {
                        textSizeControl
                    } else {
                        HStack(spacing: 3) {
                            ForEach(ScreenshotSupport.StrokeID.allCases, id: \.self) { strokeGlyph($0) }
                        }
                    }
                }
                if showsColorControls, showsLayerControls {
                    Divider().frame(height: 16)
                }
                if showsLayerControls {
                    layerButton(.backward, symbol: "square.2.layers.3d.bottom.filled",
                                label: s.screenshotEditorSendBackward)
                    layerButton(.forward, symbol: "square.2.layers.3d.top.filled",
                                label: s.screenshotEditorBringForward)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule(style: .continuous))
            .overlay(Capsule(style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
            .shadow(color: .black.opacity(0.16), radius: 12, y: 3)
        }
    }

    private func layerButton(_ move: ScreenshotSupport.LayerMove, symbol: String, label: String) -> some View {
        let enabled = model.selectedID.map { ScreenshotSupport.canReorder(model.annotations, moving: $0, move) }
            ?? false
        return iconButton(symbol, label, enabled: enabled) {
            commitEditingTextIfNeeded()
            model.moveSelected(move)
        }
    }

    private func colorDot(_ colorID: ScreenshotSupport.ColorID) -> some View {
        let selected = model.color == colorID
        return Button {
            withAnimation(.spring(response: 0.22, dampingFraction: 0.7)) { model.color = colorID }
        } label: {
            ZStack {
                Circle()
                    .fill(Color(nsColor: ScreenshotRenderer.nsColor(colorID)))
                    .frame(width: 17, height: 17)
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.22), lineWidth: 0.5))
                if selected {
                    Circle()
                        .strokeBorder(Color.primary.opacity(0.9), lineWidth: 1.5)
                        .frame(width: 23, height: 23)
                }
            }
            .frame(width: 24, height: 24)
        }
        .buttonStyle(.borderless)
        .help(s.screenshotEditorColor)
        .accessibilityLabel(s.screenshotEditorColor)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// Line-weight glyphs with three increasing stroke widths.
    private func strokeGlyph(_ stroke: ScreenshotSupport.StrokeID) -> some View {
        let selected = model.stroke == stroke
        let height: CGFloat
        switch stroke {
        case .small: height = 1.8
        case .medium: height = 3.4
        case .large: height = 5.4
        }
        return Button {
            model.stroke = stroke
        } label: {
            Capsule()
                .fill(selected ? Color.accentColor : Color.primary.opacity(0.6))
                .frame(width: 15, height: height)
                .frame(width: 25, height: 24)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.18) : .clear))
        }
        .buttonStyle(.borderless)
        .help(s.screenshotEditorStroke)
        .accessibilityLabel(s.screenshotEditorStroke)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// Smaller and larger buttons step through the presets; the menu jumps
    /// straight to any of them.
    private var textSizeControl: some View {
        HStack(spacing: 1) {
            textSizeStepButton(up: false)
            Menu {
                Picker(s.screenshotEditorTextSize, selection: $model.textSize) {
                    ForEach(ScreenshotSupport.textSizes, id: \.self) { size in
                        Text("\(size) pt").tag(size)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Text("\(model.textSize) pt")
                    .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .frame(height: 24)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            textSizeStepButton(up: true)
        }
        .help(s.screenshotEditorTextSize)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(s.screenshotEditorTextSize)
    }

    private func textSizeStepButton(up: Bool) -> some View {
        let next = ScreenshotSupport.steppedTextSize(from: model.textSize, up: up)
        return Button {
            if let next { model.textSize = next }
        } label: {
            Image(systemName: up ? "textformat.size.larger" : "textformat.size.smaller")
                .font(.system(size: 12, weight: .medium))
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.borderless)
        .disabled(next == nil)
        .accessibilityLabel(s.screenshotEditorTextSize + (up ? " +" : " −"))
    }

    // MARK: - Corner chips

    private var infoChip: some View {
        Text(dimensionsLabel)
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule(style: .continuous))
            .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
    }

    private var zoomChip: some View {
        HStack(spacing: 3) {
            zoomButton(active: model.zoomOverride == nil, help: s.screenshotEditorZoomFit + "  (⌘0)") {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .font(.system(size: 11, weight: .medium))
            } action: {
                model.zoomOverride = nil
            }
            Text(zoomPercentLabel)
                .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 38)
                .lineLimit(1)
                .fixedSize()
                .help(s.screenshotEditorZoomHint + "  (⌘+ ⌘−)")
            zoomButton(active: isActualZoom, help: s.screenshotEditorZoomActual + "  (⌘1)") {
                Text("1:1").font(.system(size: 11, weight: .medium))
            } action: {
                model.zoomToActualSize()
            }
        }
        .padding(4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
    }

    private func zoomButton<Label: View>(active: Bool, help: String,
                                         @ViewBuilder label: () -> Label,
                                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            label()
                .frame(width: 30, height: 20)
                .background(active ? Color.accentColor : .clear,
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .foregroundStyle(active ? Color.white : Color.primary.opacity(0.85))
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(help)
    }

    private var isActualZoom: Bool {
        guard let override = model.zoomOverride else { return false }
        return abs(override - 1 / model.scale) < 0.001
    }

    private var zoomPercentLabel: String {
        let zoom = model.zoomOverride ?? model.currentDisplayZoom
        return "\(Int((zoom * model.scale * 100).rounded()))%"
    }

    private var dimensionsLabel: String {
        let width = Int(model.imageSize.width)
        let height = Int(model.imageSize.height)
        let retina = model.scale > 1 ? "  @\(Int(model.scale.rounded()))x" : ""
        return "\(width) × \(height) px\(retina)"
    }
}

// MARK: - Stage C: backdrop, watermark, canvas expansion, tool order

/// Same file as the view, so these reach its private state. Adapted from
/// the upstream editor view.
extension ScreenshotEditorView {
    /// The capture plus the backdrop margin around it, in image pixels.
    private var contentPixelSize: CGSize {
        let pad = model.backdropPaddingPixels
        return CGSize(width: model.imageSize.width + pad * 2, height: model.imageSize.height + pad * 2)
    }

    /// With a backdrop the margin is square at the canvas edge; without one
    /// the canvas is the card and shows its rounding.
    private func canvasCornerRadius(zoom: CGFloat) -> CGFloat {
        model.decor.showsBackdrop ? 6 : max(4, model.cardCornerPixels * zoom)
    }

    /// The live backdrop under the canvas, painted the way the exporter
    /// paints it; blurred a little past its edge so the blur never shows a
    /// seam.
    @ViewBuilder
    private func backdropLayer(zoom: CGFloat) -> some View {
        let blur = CGFloat(model.decor.backdropStyle.sanitized().blur)
        switch model.decor.backdropFill {
        case .none:
            EmptyView()
        case .colors(let components):
            Group {
                if components.count == 1, let single = components.first {
                    Color(.sRGB, red: single.red, green: single.green, blue: single.blue, opacity: 1)
                } else {
                    LinearGradient(colors: components.map {
                        Color(.sRGB, red: $0.red, green: $0.green, blue: $0.blue, opacity: 1)
                    }, startPoint: .topLeading, endPoint: .bottomTrailing)
                }
            }
            .scaleEffect(1 + blur * 0.08)
            .blur(radius: ScreenshotSupport.backdropBlurRadius(for: contentPixelSize, factor: blur) * zoom)
        case .image(let image):
            // The overlay clips aspect-fill overflow to the backdrop bounds.
            Rectangle()
                .fill(.clear)
                .overlay {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFill()
                }
                .clipped()
                .scaleEffect(1 + blur * 0.08)
                .blur(radius: ScreenshotSupport.backdropBlurRadius(for: contentPixelSize, factor: blur) * zoom)
        }
    }

    /// Under the capture: the card's shadow and rounding on a backdrop, or
    /// the checkerboard where a picture without one is transparent, as the
    /// export keeps it. Returns the card's clip path when there is a card.
    private func drawCardBase(_ cg: CGContext, imageRect: CGRect, size: CGSize, zoom: CGFloat) -> CGPath? {
        guard model.decor.showsBackdrop else {
            cg.setFillColor(ScreenshotCanvasExpansionPreview.checker)
            cg.fill(imageRect)
            return nil
        }
        let corner = model.cardCornerPixels * zoom
        let outlineCorner = model.cardOutlineCornerPixels * zoom
        let outline = CGPath(roundedRect: imageRect, cornerWidth: outlineCorner, cornerHeight: outlineCorner,
                             transform: nil)
        cg.saveGState()
        cg.setShadow(offset: CGSize(width: 0, height: -5), blur: 18, color: CGColor(gray: 0, alpha: 0.38))
        cg.addRect(CGRect(origin: .zero, size: size))
        cg.addPath(outline)
        cg.clip(using: .evenOdd)
        cg.addPath(outline)
        cg.setFillColor(CGColor(gray: 1, alpha: 1))
        cg.fillPath()
        cg.restoreGState()
        return CGPath(roundedRect: imageRect, cornerWidth: corner, cornerHeight: corner, transform: nil)
    }

    /// Image pixels from here on. On a backdrop the exporter composes the
    /// marks before the margin exists, so they never spill onto it here.
    private func enterImageSpace(_ cg: CGContext, zoom: CGFloat) {
        cg.scaleBy(x: zoom, y: zoom)
        cg.translateBy(x: model.backdropPaddingPixels, y: model.backdropPaddingPixels)
        if model.decor.showsBackdrop {
            cg.clip(to: CGRect(origin: .zero, size: model.imageSize))
        }
    }

    /// The grown canvas while Expand canvas is the tool. The grips straddle
    /// the capture's edge, so a clear frame takes presses a little past it
    /// for the canvas gesture.
    @ViewBuilder
    private func expansionOverlay(zoom: CGFloat, cornerRadius: CGFloat) -> some View {
        if model.tool == .expandCanvas {
            let reach = ScreenshotCanvasSupport.expansionGripReach
            let draft = model.expansionDraft ?? CGRect(origin: .zero, size: model.imageSize)
            ZStack(alignment: .topLeading) {
                Color.clear
                    .frame(width: contentPixelSize.width * zoom + reach * 2,
                           height: contentPixelSize.height * zoom + reach * 2)
                    .contentShape(Rectangle())
                    .offset(x: -reach, y: -reach)
                ScreenshotCanvasExpansionPreview(originalSize: model.imageSize, draft: draft,
                                                 fill: model.expansionFill, zoom: zoom, scale: model.scale,
                                                 cardCornerRadius: model.decor.showsBackdrop
                                                     ? model.cardCornerPixels * zoom : cornerRadius)
                    .offset(x: (draft.minX + model.backdropPaddingPixels) * zoom,
                            y: (draft.minY + model.backdropPaddingPixels) * zoom)
            }
        }
    }

    private func expansionGrip(at point: CGPoint) -> ScreenshotSupport.Handle? {
        ScreenshotCanvasSupport.expansionHandle(
            at: point, rect: CGRect(origin: .zero, size: model.imageSize),
            tolerance: ScreenshotCanvasSupport.expansionGripReach / max(model.currentDisplayZoom, 0.001))
    }

    /// The footer's backdrop and watermark buttons, or the fill and size
    /// while the canvas is being expanded.
    @ViewBuilder
    private var decorBar: some View {
        if model.tool == .expandCanvas {
            ScreenshotCanvasExpansionControls(model: model)
        } else {
            ScreenshotEditorDecorButtons(decor: model.decor)
        }
    }

    /// The rail's last button: the order of the tools and their keys.
    private var toolOrderButton: some View {
        Button {
            toolOrderShown.toggle()
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 33, height: 22)
                .foregroundStyle(Color.secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(s.screenshotEditorToolOrder)
        .accessibilityLabel(s.screenshotEditorToolOrder)
        .popover(isPresented: $toolOrderShown, arrowEdge: .trailing) {
            ScrollView {
                ScreenshotToolOrderControls()
                    .padding(14)
            }
            .frame(width: 320, height: 420)
        }
    }
}
