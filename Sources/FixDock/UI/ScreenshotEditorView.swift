// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import AppKit
import SwiftUI

/// The annotation editor: tool rail on the left, actions top right, style
/// controls and zoom along the bottom, and the canvas drawn by the shared
/// renderer so the screen matches the export. Adapted from the upstream
/// editor view, without its brand mark and the cuts in
/// `docs/screenshot-editor.md`.
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
    @State private var hoveredRailItem: RailItem?
    @State private var tooltipRailItem: RailItem?
    @State private var magnifyBase: CGFloat?
    // Rail order and keys, the tool order popover, and the zoom an
    // Expand canvas drag holds so the canvas does not refit under it.
    @AppStorage(DefaultsKey.screenshotToolOrder) private var toolOrderRaw =
        ScreenshotSupport.Tool.defaultOrderStorage
    @AppStorage(DefaultsKey.screenshotToolShortcutsEnabled) private var toolShortcutsEnabled = true
    @AppStorage(DefaultsKey.screenshotToolShortcuts) private var toolBindingsRaw = ""
    @State private var toolOrderShown = false
    @State private var expansionDragZoom: CGFloat?
    @State private var railColumnHeight = CGFloat.infinity
    @State private var footerHeight = ScreenshotSupport.editorWrappedFooterHeight

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
                    // The rail scrolls only if even its overflow layout
                    // cannot fit, which a minimum-size window never needs.
                    ScrollView(.vertical) {
                        toolRail
                    }
                    .scrollIndicators(.never)
                    .fixedSize(horizontal: true, vertical: false)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { railColumnHeight = $0 }
                    .padding(.leading, 10)
                    canvasArea
                }
                .padding(.top, 6)
                bottomRow
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { footerHeight = $0 }
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
                    .padding(.bottom, 10)
            }
        }
        .ignoresSafeArea()
        .overlayPreferenceValue(RailTooltipKey.self) { anchors in
            railTooltip(anchors)
        }
        .task(id: hoveredRailItem) {
            tooltipRailItem = nil
            guard hoveredRailItem != nil else { return }
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            tooltipRailItem = hoveredRailItem
        }
        .animation(.easeOut(duration: 0.12), value: tooltipRailItem)
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: model.tool)
        .animation(.easeOut(duration: 0.16), value: model.annotationShadowsEnabled)
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
                canvas(zoom: zoom, canvasSize: canvasSize, available: available)
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

    private func canvas(zoom: CGFloat, canvasSize: CGSize, available: CGSize) -> some View {
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
        .overlay(alignment: .topLeading) {
            cropLoupeOverlay(zoom: zoom, canvasSize: canvasSize)
        }
    }

    private func drawContent(_ cg: CGContext, size: CGSize, zoom: CGFloat) {
        let pad = model.backdropPaddingPixels * zoom
        let imageRect = CGRect(x: pad, y: pad, width: model.imageSize.width * zoom,
                               height: model.imageSize.height * zoom)
        let cardPath = drawCardBase(cg, imageRect: imageRect, size: size, zoom: zoom)
        // Blur areas replace the pixels under them. With any on the canvas,
        // the capture and its annotations draw in a layer of their own, as
        // the exporter flattens them, so that never reaches the card's
        // shadow, the backdrop or the checkerboard. A spotlight dims only
        // what is painted below it, so over the checkerboard it needs the
        // layer too. Without either the layer is skipped, since it costs a
        // canvas-sized buffer on every redraw.
        let showsChecker = !model.decor.showsBackdrop
        let isolatesContent = model.annotations.contains {
            $0.tool == .pixelate || (showsChecker && $0.tool == .spotlight)
        }
        if isolatesContent { cg.beginTransparencyLayer(auxiliaryInfo: nil) }
        cg.saveGState()
        if let cardPath {
            cg.addPath(cardPath)
            cg.clip()
        }
        drawImageUpright(cg, in: imageRect, canvasHeight: size.height)
        cg.restoreGState()
        cg.saveGState()
        enterImageSpace(cg, zoom: zoom)
        ScreenshotRenderer.drawAnnotations(model.annotations, in: cg, blurSources: model.blurSources,
                                           imageSize: model.imageSize, scale: model.scale,
                                           annotationShadowsEnabled: model.annotationShadowsEnabled,
                                           skippingText: model.editingTextID,
                                           spotlightDimStrength: model.spotlightDimStrength)
        cg.restoreGState()
        if isolatesContent { cg.endTransparencyLayer() }

        cg.saveGState()
        enterImageSpace(cg, zoom: zoom)
        ScreenshotRenderer.drawWatermark(model.decor.watermarkStyle, image: model.decor.watermarkImage,
                                         in: cg, imageSize: model.imageSize,
                                         cornerRadius: model.cardCornerPixels)
        drawTextSelection(cg)
        drawSelectionChrome(cg)
        drawCropChrome(cg, canvasSize: size, zoom: zoom)
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
        let box: CGRect
        switch selected.tool {
        case .freehand: box = freehandBounds(selected).insetBy(dx: -3 * scale, dy: -3 * scale)
        case .counter: box = counterBox(selected)
        default: box = selected.rect.insetBy(dx: -3 * scale, dy: -3 * scale)
        }
        cg.stroke(box)
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

    /// A counter's rect is its tap point; the badge around it is framed.
    private func counterBox(_ annotation: ScreenshotSupport.Annotation) -> CGRect {
        let diameter = ScreenshotSupport.counterDiameter(for: annotation.renderReferenceSize ?? model.imageSize,
                                                         scale: 1)
        return CGRect(x: annotation.rect.midX - diameter / 2, y: annotation.rect.midY - diameter / 2,
                      width: diameter, height: diameter).insetBy(dx: -3, dy: -3)
    }

    /// Dims what the crop cuts away and marks the draft with its grips.
    private func drawCropChrome(_ cg: CGContext, canvasSize: CGSize, zoom: CGFloat) {
        guard model.tool == .crop, let draft = model.cropDraft else { return }
        let scale = model.scale
        // Image space starts inside the backdrop margin; the dim covers the
        // whole canvas, and on a backdrop the image clip keeps it on the card.
        let pad = model.backdropPaddingPixels
        cg.setFillColor(CGColor(gray: 0, alpha: 0.45))
        cg.beginPath()
        cg.addRect(CGRect(x: -pad, y: -pad, width: canvasSize.width / zoom, height: canvasSize.height / zoom))
        cg.addRect(draft)
        cg.fillPath(using: .evenOdd)
        cg.setStrokeColor(CGColor(gray: 1, alpha: 0.95))
        cg.setLineWidth(1.5 * scale)
        cg.stroke(draft)
        for handle in ScreenshotSupport.Handle.allCases {
            let position = handle.position(in: draft)
            // A crop grip belongs to the edge itself. Full-image grips are not
            // pushed inward just to keep the entire circle visible.
            let dot = CGRect(x: position.x - 4 * scale, y: position.y - 4 * scale,
                             width: 8 * scale, height: 8 * scale)
            cg.setFillColor(CGColor(gray: 1, alpha: 1))
            cg.fillEllipse(in: dot)
        }
    }

    // MARK: - Crop loupe

    private static let cropLoupeSize: CGFloat = 72

    /// The pixels around the crop grip being dragged, magnified with a cross
    /// on the exact edge, so a crop can land on a chosen pixel.
    @ViewBuilder
    private func cropLoupeOverlay(zoom: CGFloat, canvasSize: CGSize) -> some View {
        if let point = model.cropLoupePoint {
            // A crop edge sits between pixels, so the sample side is even and
            // the edge lands in the middle of the frame.
            let sourceRect = ScreenshotSupport.cropLoupeSampleRect(
                around: point, imageSize: model.imageSize, sideLength: 14, centredOnPixel: false)
            if let sample = model.baseImage.cropping(to: sourceRect) {
                let size = Self.cropLoupeSize
                let crossX = min(max((point.x - sourceRect.minX) / sourceRect.width * size, 0.5), size - 0.5)
                let crossY = min(max((point.y - sourceRect.minY) / sourceRect.height * size, 0.5), size - 0.5)
                ZStack(alignment: .topLeading) {
                    Image(decorative: sample, scale: 1)
                        .resizable()
                        .interpolation(.none)
                        .frame(width: size, height: size)
                    Rectangle()
                        .fill(Color.black.opacity(0.72))
                        .frame(width: 1, height: size)
                        .offset(x: crossX - 0.5)
                    Rectangle()
                        .fill(Color.black.opacity(0.72))
                        .frame(width: size, height: 1)
                        .offset(y: crossY - 0.5)
                    Circle()
                        .strokeBorder(Color.white, lineWidth: 1)
                        .background(Circle().fill(Color.black.opacity(0.3)))
                        .frame(width: 7, height: 7)
                        .offset(x: crossX - 3.5, y: crossY - 3.5)
                }
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.9), lineWidth: 1.5))
                .shadow(color: .black.opacity(0.45), radius: 8, y: 3)
                .position(cropLoupePosition(for: point, zoom: zoom, canvasSize: canvasSize))
                .allowsHitTesting(false)
                .transition(.opacity.combined(with: .scale(scale: 0.92)))
            }
        }
    }

    /// Up and to the right of the grip, flipped to the other side near an
    /// edge, and kept inside the canvas.
    private func cropLoupePosition(for point: CGPoint, zoom: CGFloat, canvasSize: CGSize) -> CGPoint {
        let size = Self.cropLoupeSize
        let half = size / 2
        let gap: CGFloat = 14
        let pad = model.backdropPaddingPixels
        let anchor = CGPoint(x: (point.x + pad) * zoom, y: (point.y + pad) * zoom)
        var x = anchor.x + half + gap
        var y = anchor.y - half - gap
        if x + half > canvasSize.width { x = anchor.x - half - gap }
        if y - half < 0 { y = anchor.y + half + gap }
        x = canvasSize.width >= size ? min(max(x, half), canvasSize.width - half) : canvasSize.width / 2
        y = canvasSize.height >= size ? min(max(y, half), canvasSize.height - half) : canvasSize.height / 2
        return CGPoint(x: x, y: y)
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
                // A text, sticker or counter tap outside the capture places nothing.
                if isTap, [ScreenshotSupport.Tool.text, .sticker, .counter].contains(model.tool),
                   !CGRect(origin: .zero, size: model.imageSize).contains(point) {
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
        // The same rule a press follows: a spotlight region offers only its
        // handles and edge while its tool is active, and expanding the canvas
        // answers only at its grips.
        if model.tool == .expandCanvas {
            (expansionGrip(at: point) != nil ? NSCursor.crosshair : NSCursor.arrow).set()
        } else if model.tool != .select,
                  model.selectedAnnotationOwns(point, includingInterior: model.tool != .spotlight) {
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
        let tools = ScreenshotSupport.Tool.ordered(from: toolOrderRaw)
        let layout = ScreenshotSupport.ToolRailLayout(
            toolCount: tools.count,
            height: ScreenshotSupport.toolRailHeight(column: railColumnHeight, footer: footerHeight))
        return VStack(spacing: layout.spacing) {
            ForEach(tools.prefix(layout.visibleTools), id: \.self) { tool in
                railButton(tool, height: layout.rowHeight)
            }
            if layout.visibleTools < tools.count {
                railOverflowMenu(Array(tools.dropFirst(layout.visibleTools)), height: layout.rowHeight)
            }
            // The row ToolRailLayout plans for: tool order and keys.
            Divider()
                .frame(width: 22)
                .padding(.vertical, 2)
            toolOrderButton(height: layout.rowHeight)
        }
        .padding(5)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 16, y: 5)
    }

    private func selectTool(_ tool: ScreenshotSupport.Tool) {
        tooltipRailItem = nil
        commitEditingTextIfNeeded()
        model.tool = tool
    }

    /// AppKit tooltips do not show here, so the rail draws its own: beside
    /// the hovered row, above the canvas, after the pointer rests.
    @ViewBuilder
    private func railTooltip(_ anchors: [RailItem: RailTooltipAnchor]) -> some View {
        if let item = tooltipRailItem, let anchor = anchors[item] {
            GeometryReader { proxy in
                let row = proxy[anchor.bounds]
                Text(anchor.title)
                    .font(.system(size: 11.5, weight: .medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
                    .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
                    .fixedSize()
                    .frame(height: row.height, alignment: .leading)
                    .offset(x: row.maxX + 10, y: row.minY)
            }
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }

    private func railButton(_ tool: ScreenshotSupport.Tool, height: CGFloat) -> some View {
        let isActive = model.tool == tool
        let isHovered = hoveredRailItem == .tool(tool)
        let keyLabel = ScreenshotSupport.Tool.shortcutLabel(for: tool, orderRaw: toolOrderRaw,
                                                          bindingsRaw: toolBindingsRaw,
                                                          enabled: toolShortcutsEnabled)
        let title = toolTitle(tool) + (keyLabel.map { "  (\($0))" } ?? "")
        return Button {
            selectTool(tool)
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: toolSymbol(tool))
                    .font(.system(size: 13.5, weight: .medium))
                    .frame(width: 33, height: height)
                if let keyLabel {
                    Text(keyLabel)
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
        .railTooltip(.tool(tool), title: title, hovered: $hoveredRailItem)
        .accessibilityLabel(title)
    }

    /// The tools past the rail's last row, behind the chevron a toolbar shows
    /// for items that do not fit. It stays lit while one of them is active.
    private func railOverflowMenu(_ tools: [ScreenshotSupport.Tool], height: CGFloat) -> some View {
        let holdsActive = tools.contains(model.tool)
        return Menu {
            ForEach(tools, id: \.self) { tool in
                Toggle(isOn: Binding(get: { model.tool == tool }, set: { _ in selectTool(tool) })) {
                    Label(toolTitle(tool), systemImage: toolSymbol(tool))
                }
            }
        } label: {
            Image(systemName: "chevron.forward.2")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 33, height: height)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(holdsActive ? Color.accentColor.opacity(0.22) : .clear))
                .foregroundStyle(holdsActive ? Color.accentColor : Color.secondary)
                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        // A borderless menu draws its label as a small pop-up button; a
        // plain one keeps the whole row as the target, like the other tools.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .railTooltip(.moreTools, title: s.screenshotEditorMoreTools, hovered: $hoveredRailItem)
        .accessibilityLabel(s.screenshotEditorMoreTools)
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

    /// The tool in effect for the style controls: the active tool, or the
    /// picked mark's while the select tool is on.
    private func controlsApply(to tool: ScreenshotSupport.Tool) -> Bool {
        model.tool == tool || (model.tool == .select && selectedAnnotation?.tool == tool)
    }

    private var showsColorControls: Bool {
        switch model.tool {
        case .arrow, .line, .rect, .ellipse, .freehand, .highlight, .text, .counter, .redact:
            return true
        case .select:
            guard let selected = selectedAnnotation else { return false }
            return ![.sticker, .pixelate, .spotlight, .image].contains(selected.tool)
        case .sticker, .pixelate, .crop, .spotlight, .expandCanvas, .image:
            return false
        }
    }

    /// Text takes a point size where shapes take a thickness.
    private var showsTextSizeControls: Bool { controlsApply(to: .text) }

    /// A picked region keeps the dim control, so its strength changes
    /// without going back to the tool.
    private var showsSpotlightControls: Bool { controlsApply(to: .spotlight) }
    private var showsBlurControls: Bool { controlsApply(to: .pixelate) }
    private var showsArrowStyleControls: Bool { controlsApply(to: .arrow) }
    private var showsStickerControls: Bool { controlsApply(to: .sticker) }

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
                contextualBar
                decorBar
                Spacer(minLength: 6)
                zoomChip
            }
            // Small captures open at the minimum window width. Keep the
            // controls inside it rather than letting this row widen the root.
            VStack(spacing: 6) {
                contextualBar
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

    /// Cancel and Crop while a crop is being drawn, the style controls
    /// otherwise.
    @ViewBuilder
    private var contextualBar: some View {
        if model.tool == .crop, model.cropDraft != nil {
            cropBar
        } else {
            styleBar
        }
    }

    private var styleBar: some View {
        HStack(spacing: 10) {
            if showsArrowStyleControls {
                arrowStyleMenu
                Divider().frame(height: 16)
            }
            if showsStickerControls {
                stickerMenu
                Divider().frame(height: 16)
            }
            if showsBlurControls {
                blurStyleMenu
                blurTextOnlyButton
                if model.blurStyle.usesStrength {
                    blurLevelControl
                }
                Divider().frame(height: 16)
            }
            if showsSpotlightControls {
                spotlightDimControl
                Divider().frame(height: 16)
            }
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
                Divider().frame(height: 16)
            }
            if showsLayerControls {
                layerButton(.backward, symbol: "square.2.layers.3d.bottom.filled",
                            label: s.screenshotEditorSendBackward)
                layerButton(.forward, symbol: "square.2.layers.3d.top.filled",
                            label: s.screenshotEditorBringForward)
                Divider().frame(height: 16)
            }
            annotationShadowButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule(style: .continuous))
        .overlay(Capsule(style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.16), radius: 12, y: 3)
    }

    private var cropBar: some View {
        HStack(spacing: 8) {
            Button(s.screenshotEditorCancel) {
                model.tool = .select
            }
            .help(s.screenshotEditorCancel + "  (esc)")
            Button(s.screenshotEditorCropApply) {
                model.applyCrop()
            }
            .buttonStyle(.borderedProminent)
            .help(s.screenshotEditorCropApply + "  (⏎)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule(style: .continuous))
        .shadow(color: .black.opacity(0.16), radius: 12, y: 3)
    }

    private func layerButton(_ move: ScreenshotSupport.LayerMove, symbol: String, label: String) -> some View {
        let enabled = model.selectedID.map { ScreenshotSupport.canReorder(model.annotations, moving: $0, move) }
            ?? false
        return iconButton(symbol, label, enabled: enabled) {
            commitEditingTextIfNeeded()
            model.moveSelected(move)
        }
    }

    /// An inline picker gives each style a native row with a checkmark, and
    /// the sample images come from the editor's own renderer, so the menu
    /// shows exactly what draws.
    private var arrowStyleMenu: some View {
        Menu {
            Picker(s.screenshotEditorArrowStyle, selection: $model.arrowStyle) {
                ForEach(ScreenshotSupport.ArrowStyleID.allCases, id: \.self) { style in
                    Label {
                        Text(arrowStyleTitle(style))
                    } icon: {
                        Image(nsImage: ScreenshotArrowStyleSamples.image(for: style))
                    }
                    .tag(style)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 5) {
                Image(nsImage: ScreenshotArrowStyleSamples.image(for: model.arrowStyle))
                    .renderingMode(.template)
                Text(arrowStyleTitle(model.arrowStyle))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 7)
            .frame(height: 24)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(s.screenshotEditorArrowStyle)
        .accessibilityLabel(s.screenshotEditorArrowStyle)
    }

    private func arrowStyleTitle(_ style: ScreenshotSupport.ArrowStyleID) -> String {
        switch style {
        case .filled: return s.screenshotEditorArrowFilled
        case .outline: return s.screenshotEditorArrowOutline
        case .open: return s.screenshotEditorArrowOpen
        case .doubleEnded: return s.screenshotEditorArrowDoubleEnded
        case .scribbly: return s.screenshotEditorArrowScribbly
        }
    }

    private var stickerMenu: some View {
        Menu {
            ForEach(ScreenshotSupport.StickerID.allCases, id: \.self) { sticker in
                Button {
                    model.sticker = sticker
                } label: {
                    HStack {
                        Text(sticker.glyph)
                        if model.sticker == sticker {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(model.sticker.glyph)
                    .font(.system(size: 16))
                Text(s.screenshotEditorToolSticker)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 7)
            .frame(height: 24)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(s.screenshotEditorToolSticker)
        .accessibilityLabel(s.screenshotEditorToolSticker)
    }

    /// Pixelate, blur or erase, picked the way an arrow style is.
    private var blurStyleMenu: some View {
        Menu {
            Picker(s.screenshotEditorBlurStyle, selection: $model.blurStyle) {
                ForEach(ScreenshotSupport.BlurStyleID.allCases, id: \.self) { style in
                    Label(blurStyleTitle(style), systemImage: blurStyleSymbol(style))
                        .tag(style)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: blurStyleSymbol(model.blurStyle))
                    .font(.system(size: 12, weight: .medium))
                Text(blurStyleTitle(model.blurStyle))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 7)
            .frame(height: 24)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(s.screenshotEditorBlurStyle)
        .accessibilityLabel(s.screenshotEditorBlurStyle)
    }

    private func blurStyleTitle(_ style: ScreenshotSupport.BlurStyleID) -> String {
        switch style {
        case .pixelate: return s.screenshotEditorBlurPixelate
        case .blur: return s.screenshotEditorToolBlur
        case .erase: return s.screenshotEditorBlurErase
        }
    }

    private func blurStyleSymbol(_ style: ScreenshotSupport.BlurStyleID) -> String {
        switch style {
        case .pixelate: return "aqi.medium"
        case .blur: return "drop.halffull"
        case .erase: return "eraser"
        }
    }

    /// Covers only the text recognized inside the area and leaves the rest of
    /// the picture as it was. The name shows beside the icon because tooltips
    /// may not show.
    private var blurTextOnlyButton: some View {
        Button {
            model.blurTextOnly.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "character.textbox")
                    .font(.system(size: 12, weight: .medium))
                Text(s.screenshotEditorBlurTextOnly)
                    .font(.system(size: 11.5, weight: .medium))
            }
            .padding(.horizontal, 7)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(model.blurTextOnly ? Color.accentColor.opacity(0.20) : .clear))
            .foregroundStyle(model.blurTextOnly ? Color.accentColor : Color.primary.opacity(0.65))
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.borderless)
        .fixedSize()
        .help(s.screenshotEditorBlurTextOnly)
        .accessibilityLabel(s.screenshotEditorBlurTextOnly)
        .accessibilityAddTraits(model.blurTextOnly ? .isSelected : [])
    }

    /// Five steps from a light blur to a heavy one; the middle is the
    /// default strength.
    private var blurLevelControl: some View {
        let levels = ScreenshotSupport.BlurStrength.levels
        return HStack(spacing: 5) {
            Image(systemName: "aqi.low")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Slider(value: Binding(get: { Double(model.blurLevel) },
                                  set: { model.blurLevel = Int($0.rounded()) }),
                   in: Double(levels.lowerBound)...Double(levels.upperBound),
                   step: 1)
                .controlSize(.mini)
                .frame(width: 84)
            Image(systemName: "aqi.high")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(height: 24)
        .help(s.screenshotEditorBlurStrength)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(s.screenshotEditorBlurStrength)
        .accessibilityValue("\(model.blurLevel)")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: model.blurLevel = min(levels.upperBound, model.blurLevel + 1)
            case .decrement: model.blurLevel = max(levels.lowerBound, model.blurLevel - 1)
            @unknown default: break
            }
        }
    }

    /// From leaving the outside untouched to turning it black, shaped like
    /// the blur strength control. A stepped slider would draw 21 tick marks,
    /// so it stays continuous and its value settles on 5% steps.
    private var spotlightDimControl: some View {
        let step: CGFloat = 0.05
        return HStack(spacing: 5) {
            Image(systemName: "sun.max.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Slider(value: spotlightDimValue, in: 0...1)
                .controlSize(.mini)
                .frame(width: 84)
            Image(systemName: "moon.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(height: 24)
        .help(s.screenshotEditorSpotlightDim)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(s.screenshotEditorSpotlightDim)
        .accessibilityValue(Double(model.spotlightDimStrength).formatted(.percent.precision(.fractionLength(0))))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: spotlightDimValue.wrappedValue = model.spotlightDimStrength + step
            case .decrement: spotlightDimValue.wrappedValue = model.spotlightDimStrength - step
            @unknown default: break
            }
        }
    }

    private var spotlightDimValue: Binding<CGFloat> {
        Binding(get: { model.spotlightDimStrength },
                set: { model.spotlightDimStrength = ScreenshotSupport.steppedSpotlightDim($0) })
    }

    private var annotationShadowButton: some View {
        Button {
            model.annotationShadowsEnabled.toggle()
        } label: {
            Image(systemName: "circle.lefthalf.filled")
                .font(.system(size: 12.5, weight: .medium))
                .frame(width: 25, height: 24)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(model.annotationShadowsEnabled ? Color.accentColor.opacity(0.20) : .clear))
                .foregroundStyle(model.annotationShadowsEnabled ? Color.accentColor : Color.primary.opacity(0.65))
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.borderless)
        .help(s.screenshotEditorShadows)
        .accessibilityLabel(s.screenshotEditorShadows)
        .accessibilityAddTraits(model.annotationShadowsEnabled ? .isSelected : [])
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

// MARK: - Backdrop, watermark, canvas expansion, tool order

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
    private func toolOrderButton(height: CGFloat) -> some View {
        Button {
            tooltipRailItem = nil
            toolOrderShown.toggle()
        } label: {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 13, weight: .medium))
                .frame(width: 33, height: height)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(toolOrderShown ? Color.accentColor.opacity(0.22) : .clear))
                .foregroundStyle(toolOrderShown ? Color.accentColor : Color.secondary)
                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.borderless)
        .railTooltip(.toolOrder, title: s.screenshotEditorToolOrder, hovered: $hoveredRailItem)
        .accessibilityLabel(s.screenshotEditorToolOrder)
        .popover(isPresented: $toolOrderShown, arrowEdge: .trailing) {
            ScrollView {
                ScreenshotToolOrderControls()
                    .padding(14)
            }
            .frame(width: 340, height: 480)
        }
    }
}

/// Small samples of each arrow style, drawn by the editor's own renderer so
/// the menu and the bottom row show exactly what a stroke will look like.
/// They are templates, so menus tint them like their text. Adapted from
/// upstream.
private enum ScreenshotArrowStyleSamples {
    private static let images: [ScreenshotSupport.ArrowStyleID: NSImage] = Dictionary(
        uniqueKeysWithValues: ScreenshotSupport.ArrowStyleID.allCases.map { ($0, render($0)) })

    static func image(for style: ScreenshotSupport.ArrowStyleID) -> NSImage {
        images[style] ?? render(style)
    }

    private static func render(_ style: ScreenshotSupport.ArrowStyleID) -> NSImage {
        let size = NSSize(width: 36, height: 16)
        let image = NSImage(size: size)
        image.isTemplate = true
        // Rasterized at 2x so the sample stays crisp on Retina displays.
        let scale: CGFloat = 2
        let pixels = CGSize(width: size.width * scale, height: size.height * scale)
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                                            pixelsWide: Int(pixels.width),
                                            pixelsHigh: Int(pixels.height),
                                            bitsPerSample: 8,
                                            samplesPerPixel: 4,
                                            hasAlpha: true,
                                            isPlanar: false,
                                            colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0,
                                            bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap)?.cgContext
        else { return image }
        bitmap.size = size
        // The renderer works in top-down image pixels.
        context.translateBy(x: 0, y: pixels.height)
        context.scaleBy(x: 1, y: -1)
        // A thin sample; the fixed seed keeps the scribbly one stable.
        let sample = ScreenshotSupport.Annotation(
            tool: .arrow,
            points: [CGPoint(x: 3 * scale, y: pixels.height / 2),
                     CGPoint(x: pixels.width - 3 * scale, y: pixels.height / 2)],
            color: .black,
            stroke: .small,
            arrowStyle: style,
            scribbleSeed: 0x5343524942424C59)
        ScreenshotRenderer.drawAnnotations([sample], in: context, blurSources: .none,
                                           imageSize: pixels, scale: scale,
                                           annotationShadowsEnabled: false)
        image.addRepresentation(bitmap)
        return image
    }
}

/// A row of the editor's tool rail that can show a tooltip.
private enum RailItem: Hashable {
    case tool(ScreenshotSupport.Tool)
    case moreTools
    case toolOrder
}

private struct RailTooltipAnchor {
    let title: String
    let bounds: Anchor<CGRect>
}

private struct RailTooltipKey: PreferenceKey {
    static let defaultValue: [RailItem: RailTooltipAnchor] = [:]

    static func reduce(value: inout [RailItem: RailTooltipAnchor], nextValue: () -> [RailItem: RailTooltipAnchor]) {
        value.merge(nextValue()) { $1 }
    }
}

private extension View {
    /// Tracks the pointer over a rail row and publishes where the row is, so
    /// the editor can draw its tooltip outside the rail's scroll view.
    func railTooltip(_ item: RailItem, title: String, hovered: Binding<RailItem?>) -> some View {
        onHover { inside in
            if inside {
                hovered.wrappedValue = item
            } else if hovered.wrappedValue == item {
                hovered.wrappedValue = nil
            }
        }
        .anchorPreference(key: RailTooltipKey.self, value: .bounds) {
            [item: RailTooltipAnchor(title: title, bounds: $0)]
        }
    }
}
