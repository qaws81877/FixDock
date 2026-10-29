// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Everything the annotation editor can do to one capture: the mutable
/// document (image, annotations, undo history) and the gestures that change
/// it. The SwiftUI editor view observes this model; geometry is in image
/// pixels. Adapted from the upstream editor model, without canvas
/// expansion, pasted images, backdrop and watermark (stage C).
final class ScreenshotEditorModel: ObservableObject {
    /// One undo step. The image is part of it so a crop can be undone.
    struct State {
        let image: CGImage
        let annotations: [ScreenshotSupport.Annotation]
    }

    @Published private(set) var baseImage: CGImage
    @Published var annotations: [ScreenshotSupport.Annotation] = []
    /// How dark a spotlight turns everything outside its regions,
    /// remembered between captures like the blur strength.
    @Published var spotlightDimStrength: CGFloat {
        didSet {
            UserDefaults.standard.set(Double(spotlightDimStrength),
                                      forKey: DefaultsKey.screenshotEditorSpotlightDim)
            refreshDirtyState()
        }
    }
    @Published var selectedID: UUID?
    @Published var editingTextID: UUID?
    @Published var tool: ScreenshotSupport.Tool {
        didSet {
            UserDefaults.standard.set(tool.rawValue, forKey: DefaultsKey.screenshotEditorTool)
            if oldValue == .expandCanvas, tool != .expandCanvas { cancelCanvasExpansion() }
            if tool != .select { clearTextSelection() }
            if tool != oldValue, tool != .select {
                selectedID = nil
                editingTextID = nil
            }
            if tool == .crop, oldValue != .crop {
                selectedID = nil
                cropDraft = CGRect(origin: .zero, size: imageSize)
            } else if oldValue == .crop {
                cropDraft = nil
                cropLoupePoint = nil
            }
        }
    }
    /// Words recognized in the capture and selectable with the select tool.
    @Published private(set) var textWords: [ScreenshotSupport.RecognizedWord] = []
    /// The recognized words joined into the runs text only blur areas cover,
    /// or nil until recognition has read all of the current capture.
    @Published private(set) var textRuns: [CGRect]?
    /// Runs a crop carried over to the capture it made. Recognition misses a
    /// line the crop cut through, so the cropped capture's runs keep these
    /// once it is read, and after an undo or redo back to it.
    private var carriedRuns: [ObjectIdentifier: [CGRect]] = [:]
    @Published private(set) var selectedWordIndexes: [Int] = []
    private var textSelectionAnchor: CGPoint?
    /// A code found in the capture, offered through the QR button.
    @Published private(set) var qrReading: ScreenshotRecognition.CodeReading?
    @Published var color: ScreenshotSupport.ColorID {
        didSet {
            UserDefaults.standard.set(color.rawValue, forKey: DefaultsKey.screenshotEditorColor)
            applyStyleToSelection()
        }
    }
    @Published var stroke: ScreenshotSupport.StrokeID {
        didSet {
            UserDefaults.standard.set(stroke.rawValue, forKey: DefaultsKey.screenshotEditorStroke)
            applyStyleToSelection()
        }
    }
    @Published var textSize: Int {
        didSet {
            UserDefaults.standard.set(textSize, forKey: DefaultsKey.screenshotEditorTextSize)
            applyStyleToSelection()
        }
    }
    @Published var blurLevel: Int {
        didSet {
            UserDefaults.standard.set(blurLevel, forKey: DefaultsKey.screenshotEditorBlurLevel)
            applyBlurToSelection()
        }
    }
    @Published var blurStyle: ScreenshotSupport.BlurStyleID {
        didSet {
            UserDefaults.standard.set(blurStyle.rawValue, forKey: DefaultsKey.screenshotEditorBlurStyle)
            applyBlurToSelection()
        }
    }
    @Published var blurTextOnly: Bool {
        didSet {
            UserDefaults.standard.set(blurTextOnly, forKey: DefaultsKey.screenshotEditorBlurTextOnly)
            applyBlurToSelection()
        }
    }
    @Published var arrowStyle: ScreenshotSupport.ArrowStyleID {
        didSet {
            UserDefaults.standard.set(arrowStyle.rawValue, forKey: DefaultsKey.screenshotEditorArrowStyle)
            applyStyleToSelection()
        }
    }
    @Published var sticker: ScreenshotSupport.StickerID {
        didSet {
            UserDefaults.standard.set(sticker.rawValue, forKey: DefaultsKey.screenshotEditorSticker)
            applyStickerToSelection()
        }
    }
    @Published var annotationShadowsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(annotationShadowsEnabled,
                                      forKey: DefaultsKey.screenshotEditorAnnotationShadows)
            refreshDirtyState()
        }
    }
    /// The crop rectangle while the crop tool is active, in image pixels.
    @Published var cropDraft: CGRect?
    /// Exact image pixel under a crop resize grip. Nil while moving the
    /// whole crop so the loupe appears only when it adds precision.
    @Published private(set) var cropLoupePoint: CGPoint?
    /// Continuous zoom (view points per image pixel); nil fits the window.
    @Published var zoomOverride: CGFloat?
    /// What the view actually laid out last, so pinch and scroll zoom start
    /// from the visible scale even in fit mode. Plain var on purpose: the
    /// view writes it during layout.
    var currentDisplayZoom: CGFloat = 0.5
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    /// True while there is work that never left the editor: closing then asks.
    @Published private(set) var isDirty = false
    /// A short line over the canvas (text copied, save failed).
    @Published var notice: String?

    // MARK: Backdrop, watermark and canvas expansion state (stage C)

    /// Backdrop and watermark, remembered between captures.
    let decor = ScreenshotEditorDecor()
    /// What Expand canvas fills new space with, and the drag in progress:
    /// the grown canvas in the current canvas's pixels, or a drag rejected
    /// for growing past the size limit.
    @Published var expansionFill = ScreenshotCanvasSupport.Fill.white
    @Published private(set) var expansionDraft: CGRect?
    @Published private(set) var expansionRejected = false
    private var expansionHandle: ScreenshotSupport.Handle?
    private var expansionStartPoint: CGPoint?

    let scale: CGFloat
    /// Sampled mosaics of the base image, one per blur level in use.
    private(set) var pixelated: [Int: CGImage] = [:]
    /// Small soft blurs of the base image, one per blur level in use.
    private(set) var softBlurred: [Int: CGImage] = [:]
    private let eraseCache = ScreenshotRenderer.EraseCache()

    /// What blur areas paint from, shared by the canvas and the exporter.
    var blurSources: ScreenshotRenderer.BlurSources {
        ScreenshotRenderer.BlurSources(mosaics: pixelated, softBlurs: softBlurred, image: baseImage,
                                       eraseCache: eraseCache, textRuns: textRuns)
    }

    private var history = ScreenshotSupport.EditorHistory<State>(limit: 60)
    private var cleanImage: CGImage?
    private var cleanAnnotations: [ScreenshotSupport.Annotation] = []
    private var cleanAnnotationShadowsEnabled = false
    private var cleanSpotlightDimStrength = ScreenshotSupport.defaultSpotlightDim

    // Gesture state, in image pixels.
    private var dragStart: CGPoint = .zero
    /// The shape a drag is drawing, until it lands.
    @Published private(set) var draftID: UUID?
    private var moveOrigin: CGRect = .zero
    private var movePoints: [CGPoint] = []
    private var activeHandle: ScreenshotSupport.Handle?
    private var cropResizeOrigin: CGRect?
    private var cropMoveOrigin: CGRect?
    private var cropSelectionOrigin: CGRect?
    private var dragRegistered = false
    private var editingSelectedAnnotation = false
    private var newTextID: UUID?
    /// System uptime of the last press, drag or release in the editor window.
    private(set) var lastPointerActivityUptime: TimeInterval = -.infinity

    func notePointerActivity() {
        lastPointerActivityUptime = ProcessInfo.processInfo.systemUptime
    }

    var imageSize: CGSize {
        CGSize(width: baseImage.width, height: baseImage.height)
    }

    /// Natural on-screen size in points (pixels over capture scale).
    var pointSize: CGSize {
        CGSize(width: CGFloat(baseImage.width) / scale, height: CGFloat(baseImage.height) / scale)
    }

    init(image: CGImage, scale: CGFloat) {
        baseImage = image
        self.scale = scale
        let defaults = UserDefaults.standard
        tool = ScreenshotSupport.Tool.startingTool(
            remembered: defaults.string(forKey: DefaultsKey.screenshotEditorTool))
        color = ScreenshotSupport.ColorID.sanitized(defaults.string(forKey: DefaultsKey.screenshotEditorColor))
        stroke = ScreenshotSupport.StrokeID.sanitized(defaults.string(forKey: DefaultsKey.screenshotEditorStroke))
        textSize = ScreenshotSupport.sanitizedTextSize(defaults.integer(forKey: DefaultsKey.screenshotEditorTextSize))
        blurLevel = ScreenshotSupport.BlurStrength.startingLevel(
            remembered: defaults.integer(forKey: DefaultsKey.screenshotEditorBlurLevel))
        blurStyle = ScreenshotSupport.BlurStyleID.sanitized(
            defaults.string(forKey: DefaultsKey.screenshotEditorBlurStyle))
        blurTextOnly = defaults.bool(forKey: DefaultsKey.screenshotEditorBlurTextOnly)
        spotlightDimStrength = ScreenshotSupport.sanitizedSpotlightDim(
            CGFloat(defaults.double(forKey: DefaultsKey.screenshotEditorSpotlightDim)))
        arrowStyle = ScreenshotSupport.ArrowStyleID.sanitized(
            defaults.string(forKey: DefaultsKey.screenshotEditorArrowStyle))
        sticker = ScreenshotSupport.StickerID.sanitized(defaults.string(forKey: DefaultsKey.screenshotEditorSticker))
        annotationShadowsEnabled = defaults.bool(forKey: DefaultsKey.screenshotEditorAnnotationShadows)
        recordCleanState()
        forwardDecorChanges()
    }

    // MARK: - Selectable text on the canvas

    var selectedText: String {
        ScreenshotSupport.joinedWords(textWords, selected: selectedWordIndexes)
    }

    func clearTextSelection() {
        textSelectionAnchor = nil
        if !selectedWordIndexes.isEmpty { selectedWordIndexes = [] }
    }

    func wordIndex(at point: CGPoint) -> Int? {
        textWords.firstIndex { $0.rect.insetBy(dx: -2 * scale, dy: -2 * scale).contains(point) }
    }

    /// Word-level recognition of the base capture, off the main thread; the
    /// boxes land in image pixels with their line index, and the runs that
    /// text only blur areas cover come with them.
    func recognizeText() {
        let image = baseImage
        let languages = ScreenshotRecognition.preferredLanguages(for: L10n.shared.language)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let read = ScreenshotRecognition.readWords(image, languages: languages)
            DispatchQueue.main.async {
                guard let self, image === self.baseImage else { return }
                self.textWords = read.words
                self.textRuns = read.runs.map { $0 + (self.carriedRuns[ObjectIdentifier(image)] ?? []) }
            }
        }
    }

    /// Scans the capture for a code off the main thread; the result drives
    /// the QR button. Re-run whenever the base image changes (crop, undo) so
    /// a cropped out code stops being offered.
    func recognizeQRCodes() {
        let image = baseImage
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let reading = ScreenshotRecognition.readCodes(image)
            DispatchQueue.main.async {
                guard let self, image === self.baseImage else { return }
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { self.qrReading = reading }
            }
        }
    }

    // MARK: - Zoom

    /// Multiplies the current zoom (pinch, ⌃ scroll, ⌘ plus and minus).
    func adjustZoom(by factor: CGFloat) {
        zoomOverride = ScreenshotSupport.clampedEditorZoom((zoomOverride ?? currentDisplayZoom) * factor)
    }

    /// Absolute zoom for pinch gestures anchored at the gesture's start.
    func setZoom(_ zoom: CGFloat) {
        zoomOverride = ScreenshotSupport.clampedEditorZoom(zoom)
    }

    /// One view point per capture point, the size it had on screen.
    func zoomToActualSize() {
        zoomOverride = ScreenshotSupport.clampedEditorZoom(1 / scale)
    }

    // MARK: - Undo

    private func registerUndo() {
        history.record(State(image: baseImage, annotations: annotations))
        refreshUndoFlags()
        isDirty = true
    }

    func undo() {
        guard let last = history.undo(from: State(image: baseImage, annotations: annotations)) else { return }
        restore(last)
    }

    func redo() {
        guard let next = history.redo(from: State(image: baseImage, annotations: annotations)) else { return }
        restore(next)
    }

    /// Keeps carried runs only for captures the editor can still show.
    private func pruneCarriedRuns() {
        let live = Set([ObjectIdentifier(baseImage)]
            + (history.undoStack + history.redoStack).map { ObjectIdentifier($0.image) })
        carriedRuns = carriedRuns.filter { live.contains($0.key) }
    }

    private func restore(_ state: State) {
        cancelCanvasExpansion()
        if state.image !== baseImage {
            baseImage = state.image
            pixelated = [:]
            softBlurred = [:]
            // The runs belong to the other image. Text only areas cover all
            // of themselves until this one is read.
            textRuns = nil
            textWords = []
            clearTextSelection()
            recognizeText()
            recognizeQRCodes()
        }
        annotations = state.annotations
        ensureBlurSamplesForAnnotations()
        selectedID = nil
        editingTextID = nil
        newTextID = nil
        cropDraft = nil
        refreshUndoFlags()
        refreshDirtyState()
    }

    private func refreshUndoFlags() {
        canUndo = history.canUndo
        canRedo = history.canRedo
    }

    /// The edits left the editor (saved, copied or pinned), so closing no
    /// longer asks.
    func markExported() {
        recordCleanState()
    }

    private func recordCleanState() {
        cleanImage = baseImage
        cleanAnnotations = annotations
        cleanAnnotationShadowsEnabled = annotationShadowsEnabled
        cleanSpotlightDimStrength = spotlightDimStrength
        decor.markClean()
        isDirty = false
    }

    private func refreshDirtyState() {
        guard let cleanImage else { return }
        isDirty = baseImage !== cleanImage
            || annotations != cleanAnnotations
            || annotationShadowsEnabled != cleanAnnotationShadowsEnabled
            // Without a region the dim changes nothing in the output.
            || (spotlightDimStrength != cleanSpotlightDimStrength
                && annotations.contains { $0.tool == .spotlight })
            || decor.differsFromClean
    }

    // MARK: - Selection styling

    /// Applies colour, thickness, text size or arrow style changes to the
    /// selected mark.
    private func applyStyleToSelection() {
        guard let selectedID,
              let index = annotations.firstIndex(where: { $0.id == selectedID }),
              annotations[index].tool != .image
        else { return }
        let arrowStyleChanged = annotations[index].tool == .arrow && annotations[index].arrowStyle != arrowStyle
        let textSizeChanged = annotations[index].tool == .text && annotations[index].textSize != textSize
        // Marks without a thickness control keep theirs, so picking one never
        // records an edit nobody made.
        let usesStroke = ScreenshotSupport.selectionStyle(for: annotations[index]).stroke != nil
        let strokeChanged = usesStroke && annotations[index].stroke != stroke
        guard annotations[index].color != color || strokeChanged || arrowStyleChanged || textSizeChanged
        else { return }
        registerUndo()
        annotations[index].color = color
        if usesStroke { annotations[index].stroke = stroke }
        if annotations[index].tool == .arrow {
            if arrowStyleChanged, arrowStyle == .scribbly {
                annotations[index].scribbleSeed = ScreenshotSupport.randomScribbleSeed()
            }
            annotations[index].arrowStyle = arrowStyle
        }
        if annotations[index].tool == .text {
            annotations[index].textSize = textSize
            annotations[index].rect = ScreenshotRenderer.textBounds(
                annotations[index].text, at: annotations[index].rect.origin,
                textSize: textSize, scale: scale)
        }
    }

    private func applyBlurToSelection() {
        guard let selectedID,
              let index = annotations.firstIndex(where: { $0.id == selectedID }),
              annotations[index].tool == .pixelate
        else { return }
        let mark = annotations[index]
        guard mark.blurLevel != blurLevel || mark.blurStyle != blurStyle || mark.blurTextOnly != blurTextOnly
        else { return }
        // The sample must exist before the mark points at it, or the redraw
        // would show the area uncovered. Without one the area keeps its look.
        guard ensureBlurSample(blurStyle, level: blurLevel) else {
            self.selectedID = nil
            syncControls(to: mark)
            self.selectedID = selectedID
            return
        }
        registerUndo()
        annotations[index].blurLevel = blurLevel
        annotations[index].blurStyle = blurStyle
        annotations[index].blurTextOnly = blurTextOnly
        ensureBlurSamplesForAnnotations()
    }

    private func applyStickerToSelection() {
        guard let selectedID,
              let index = annotations.firstIndex(where: { $0.id == selectedID }),
              annotations[index].tool == .sticker,
              annotations[index].text != sticker.rawValue
        else { return }
        registerUndo()
        annotations[index].text = sticker.rawValue
    }

    /// Copies only the controls that have meaning for the picked annotation.
    /// Unused values remain available as defaults for the next new mark.
    private func syncControls(to annotation: ScreenshotSupport.Annotation) {
        let style = ScreenshotSupport.selectionStyle(for: annotation)
        if let color = style.color { self.color = color }
        if let stroke = style.stroke { self.stroke = stroke }
        if let textSize = style.textSize { self.textSize = textSize }
        if let blurLevel = style.blurLevel { self.blurLevel = blurLevel }
        if let blurStyle = style.blurStyle { self.blurStyle = blurStyle }
        if let blurTextOnly = style.blurTextOnly { self.blurTextOnly = blurTextOnly }
        if let arrowStyle = style.arrowStyle { self.arrowStyle = arrowStyle }
        if annotation.tool == .sticker {
            sticker = ScreenshotSupport.StickerID.sanitized(annotation.text)
        }
    }

    // MARK: - Gestures (image-pixel coordinates)

    func beginDrag(at point: CGPoint) {
        dragStart = point
        dragRegistered = false
        editingSelectedAnnotation = false
        // The mark just drawn stays directly editable with its creating tool.
        // A spotlight region claims only its handles and edge, so a drag
        // inside the one just drawn lights another region.
        if tool != .select, tool != .crop, tool != .expandCanvas,
           selectedAnnotationOwns(point, includingInterior: tool != .spotlight) {
            editingSelectedAnnotation = true
            beginSelectDrag(at: point)
            return
        }
        if tool != .select, tool != .crop, tool != .expandCanvas { selectedID = nil }
        switch tool {
        case .select:
            beginSelectDrag(at: point)
        case .crop:
            let bounds = CGRect(origin: .zero, size: imageSize)
            if let draft = cropDraft,
               let handle = ScreenshotSupport.handle(at: point, rect: draft, tolerance: 14 * scale) {
                activeHandle = handle
                cropResizeOrigin = draft
                cropLoupePoint = handle.position(in: draft)
            } else if let draft = cropDraft,
                      ScreenshotSupport.startsNewCropSelection(at: point, draft: draft, within: bounds) {
                cropSelectionOrigin = draft
            } else if let draft = cropDraft, draft.contains(point) {
                cropMoveOrigin = draft
            }
        case .arrow, .line:
            registerUndo()
            dragRegistered = true
            let annotation = ScreenshotSupport.Annotation(
                tool: tool, points: [point, point], color: color, stroke: stroke, arrowStyle: arrowStyle)
            annotations.append(annotation)
            draftID = annotation.id
        case .freehand:
            registerUndo()
            dragRegistered = true
            let annotation = ScreenshotSupport.Annotation(tool: tool, points: [point], color: color, stroke: stroke)
            annotations.append(annotation)
            draftID = annotation.id
        case .rect, .ellipse, .highlight, .pixelate, .redact, .spotlight:
            if tool == .pixelate { ensureBlurSample(blurStyle, level: blurLevel) }
            registerUndo()
            dragRegistered = true
            let annotation = ScreenshotSupport.Annotation(
                tool: tool, rect: CGRect(origin: point, size: .zero), color: color, stroke: stroke,
                blurLevel: blurLevel, blurStyle: blurStyle, blurTextOnly: blurTextOnly)
            annotations.append(annotation)
            draftID = annotation.id
        case .expandCanvas:
            beginCanvasExpansion(at: point)
        case .text, .sticker, .counter, .image:
            break
        }
    }

    private func beginSelectDrag(at point: CGPoint) {
        if let selectedID, let selected = annotations.first(where: { $0.id == selectedID }) {
            let tolerance = 12 * scale
            if let handle = grip(of: selected, at: point, tolerance: tolerance) {
                activeHandle = handle
                moveOrigin = selected.rect
                return
            }
            if selected.points.count >= 2, selected.tool != .freehand {
                if hypot(point.x - selected.points[0].x, point.y - selected.points[0].y) < tolerance {
                    activeHandle = .topLeft
                    movePoints = selected.points
                    return
                }
                if hypot(point.x - selected.points[1].x, point.y - selected.points[1].y) < tolerance {
                    activeHandle = .bottomRight
                    movePoints = selected.points
                    return
                }
            }
        }
        let hitID = hitTest(point)
        self.selectedID = nil
        if let hitID, let hit = annotations.first(where: { $0.id == hitID }) {
            syncControls(to: hit)
            self.selectedID = hitID
            moveOrigin = hit.rect
            movePoints = hit.points
            clearTextSelection()
        } else if let word = wordIndex(at: point) {
            // A drag over recognized text selects intersecting words.
            textSelectionAnchor = point
            selectedWordIndexes = [word]
        } else {
            clearTextSelection()
        }
    }

    func continueDrag(to point: CGPoint) {
        if editingSelectedAnnotation {
            continueSelectDrag(to: point)
            return
        }
        switch tool {
        case .select:
            continueSelectDrag(to: point)
        case .crop:
            let bounds = CGRect(origin: .zero, size: imageSize)
            if let handle = activeHandle, let origin = cropResizeOrigin {
                let rect = ScreenshotSupport.resizedRect(origin, dragging: handle, to: point)
                let snapped = ScreenshotSupport.pixelSnappedCropRect(rect, within: bounds)
                cropDraft = snapped
                cropLoupePoint = handle.position(in: snapped)
            } else if cropSelectionOrigin != nil {
                cropDraft = ScreenshotSupport.pixelSnappedCropRect(
                    ScreenshotSupport.rect(from: dragStart, to: point), within: bounds)
            } else if let origin = cropMoveOrigin {
                let delta = CGPoint(x: point.x - dragStart.x, y: point.y - dragStart.y)
                cropDraft = ScreenshotSupport.pixelSnappedCropRect(
                    ScreenshotSupport.movedRect(origin, by: delta, within: bounds), within: bounds)
            }
        case .arrow, .line:
            updateDraft { $0.points = [dragStart, point] }
        case .freehand:
            updateDraft { $0.points.append(point) }
        case .rect, .ellipse, .highlight, .pixelate, .redact, .spotlight:
            updateDraft { $0.rect = ScreenshotSupport.rect(from: dragStart, to: point) }
        case .expandCanvas:
            continueCanvasExpansion(to: point)
        case .text, .sticker, .counter, .image:
            break
        }
    }

    private func continueSelectDrag(to point: CGPoint) {
        if let anchor = textSelectionAnchor {
            selectedWordIndexes = ScreenshotSupport.wordSelection(
                anchor: anchor, current: point, boxes: textWords.map(\.rect))
            return
        }
        guard let selectedID,
              let index = annotations.firstIndex(where: { $0.id == selectedID })
        else { return }
        if !dragRegistered {
            registerUndo()
            dragRegistered = true
        }
        if let handle = activeHandle {
            if annotations[index].points.count >= 2, annotations[index].tool != .freehand {
                var points = movePoints
                if handle == .topLeft { points[0] = point } else { points[1] = point }
                annotations[index].points = points
            } else if annotations[index].tool == .image {
                annotations[index].rect = ScreenshotCanvasSupport.resizedImageRect(moveOrigin, handle: handle,
                                                                                   point: point)
            } else {
                annotations[index].rect = ScreenshotSupport.resizedRect(moveOrigin, dragging: handle, to: point)
            }
            return
        }
        let delta = CGPoint(x: point.x - dragStart.x, y: point.y - dragStart.y)
        if annotations[index].tool == .image {
            annotations[index].rect = ScreenshotCanvasSupport.movedImageRect(moveOrigin, by: delta)
        } else if annotations[index].points.isEmpty {
            annotations[index].rect = moveOrigin.offsetBy(dx: delta.x, dy: delta.y)
        } else {
            annotations[index].points = movePoints.map { CGPoint(x: $0.x + delta.x, y: $0.y + delta.y) }
        }
    }

    /// `isTap` is decided by the view in screen points, so a click stays a
    /// click at any zoom level.
    func endDrag(at point: CGPoint, isTap: Bool) {
        defer {
            draftID = nil
            activeHandle = nil
            cropResizeOrigin = nil
            cropMoveOrigin = nil
            cropSelectionOrigin = nil
            cropLoupePoint = nil
            dragRegistered = false
            editingSelectedAnnotation = false
        }
        if editingSelectedAnnotation {
            finishSelectDrag(at: point, isTap: isTap)
            return
        }
        switch tool {
        case .text:
            guard isTap else { return }
            if selectExistingAnnotation(at: point) { return }
            registerUndo()
            var annotation = ScreenshotSupport.Annotation(tool: .text, color: color, stroke: stroke,
                                                          textSize: textSize)
            annotation.rect = ScreenshotRenderer.textBounds("", at: point, textSize: textSize, scale: scale)
            annotations.append(annotation)
            newTextID = annotation.id
            selectedID = annotation.id
            editingTextID = annotation.id
        case .sticker:
            guard isTap else { return }
            if selectExistingAnnotation(at: point) { return }
            registerUndo()
            let bounds = CGRect(origin: .zero, size: imageSize)
            let side = ScreenshotSupport.stickerSide(for: imageSize, scale: scale)
            let annotation = ScreenshotSupport.Annotation(
                tool: .sticker,
                rect: ScreenshotSupport.stickerRect(centeredAt: point, side: side, within: bounds),
                text: sticker.rawValue, color: color, stroke: stroke)
            annotations.append(annotation)
            selectedID = annotation.id
        case .counter:
            guard isTap else { return }
            if selectExistingAnnotation(at: point) { return }
            registerUndo()
            let annotation = ScreenshotSupport.Annotation(
                tool: .counter, rect: CGRect(x: point.x, y: point.y, width: 0, height: 0),
                color: color, stroke: stroke, number: 1)
            annotations.append(annotation)
            annotations = ScreenshotSupport.renumberingCounters(annotations)
            selectedID = annotation.id
        case .arrow, .line, .rect, .ellipse, .highlight, .pixelate, .redact, .spotlight, .freehand:
            if isTap {
                // A tap never leaves a degenerate shape behind; treat it as
                // picking whatever is under the cursor instead.
                annotations.removeAll { $0.id == draftID }
                history.dropLast()
                refreshUndoFlags()
                refreshDirtyState()
                selectExistingAnnotation(at: point)
            } else if let draftID {
                selectedID = draftID
            }
        case .expandCanvas:
            finishCanvasExpansion()
        case .image:
            break
        case .select:
            finishSelectDrag(at: point, isTap: isTap)
        case .crop:
            // A click outside the crop keeps the crop it would have replaced.
            if isTap, let origin = cropSelectionOrigin {
                cropDraft = origin
            }
        }
    }

    /// The visible selection remains directly editable after creation. A new
    /// tool or a gesture outside it ends that priority and creates normally.
    /// Without the interior, an area mark answers only at its handles and edge.
    func selectedAnnotationOwns(_ point: CGPoint, includingInterior: Bool = true) -> Bool {
        guard let selectedID, let selected = annotations.first(where: { $0.id == selectedID })
        else { return false }
        let tolerance = 12 * scale
        if grip(of: selected, at: point, tolerance: tolerance) != nil {
            return true
        }
        if selected.tool != .freehand,
           selected.points.prefix(2).contains(where: { hypot(point.x - $0.x, point.y - $0.y) < tolerance }) {
            return true
        }
        return hitTest(point, includeShapeInteriors: includingInterior) == selectedID
    }

    private func finishSelectDrag(at point: CGPoint, isTap: Bool) {
        textSelectionAnchor = nil
        guard isTap, !dragRegistered else { return }
        let hitID = hitTest(point)
        self.selectedID = nil
        if let hitID, let hit = annotations.first(where: { $0.id == hitID }) {
            syncControls(to: hit)
            self.selectedID = hitID
            editingTextID = hit.tool == .text ? hitID : nil
            clearTextSelection()
        } else if let word = wordIndex(at: point) {
            selectedWordIndexes = [word]
        } else {
            clearTextSelection()
        }
    }

    /// A click on an existing mark always means "edit this", even while a
    /// creation tool is active. Real drags still create with the active tool.
    /// Sticker selection updates the sticker picker without changing the
    /// mark; text enters its inline editor immediately.
    @discardableResult
    private func selectExistingAnnotation(at point: CGPoint) -> Bool {
        guard let hitID = hitTest(point, includeShapeInteriors: false),
              let hit = annotations.first(where: { $0.id == hitID })
        else {
            selectedID = nil
            return false
        }
        self.selectedID = nil
        syncControls(to: hit)
        selectedID = hitID
        editingTextID = hit.tool == .text ? hitID : nil
        clearTextSelection()
        tool = .select
        return true
    }

    private func updateDraft(_ mutate: (inout ScreenshotSupport.Annotation) -> Void) {
        guard let draftID, let index = annotations.firstIndex(where: { $0.id == draftID }) else { return }
        mutate(&annotations[index])
    }

    func hitTest(_ point: CGPoint, includeShapeInteriors: Bool = true) -> UUID? {
        ScreenshotSupport.hitTest(annotations, at: point, scale: scale, imageSize: imageSize,
                                  includeShapeInteriors: includeShapeInteriors)
    }

    // MARK: - Edits

    func deleteSelected() {
        guard let selectedID, annotations.contains(where: { $0.id == selectedID }) else { return }
        registerUndo()
        annotations.removeAll { $0.id == selectedID }
        annotations = ScreenshotSupport.renumberingCounters(annotations)
        self.selectedID = nil
        editingTextID = nil
        if newTextID == selectedID { newTextID = nil }
    }

    /// Moves the selected annotation one step through the drawing order, so a
    /// box drawn last can sit behind text written first. Counters are numbered
    /// by their place in the array, so moving one past another renumbers both,
    /// the same way deleting one does.
    func moveSelected(_ move: ScreenshotSupport.LayerMove) {
        guard let selectedID else { return }
        let reordered = ScreenshotSupport.reordering(annotations, moving: selectedID, move)
        guard reordered.map(\.id) != annotations.map(\.id) else { return }
        registerUndo()
        annotations = ScreenshotSupport.renumberingCounters(reordered)
    }

    /// Ends inline editing. A new text left empty disappears with the undo
    /// steps it made, as if it was never placed.
    func commitText(_ id: UUID, text: String) {
        guard let index = annotations.firstIndex(where: { $0.id == id }) else { return }
        editingTextID = nil
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let isNew = newTextID == id
        if isNew, trimmed.isEmpty {
            annotations.remove(at: index)
            if selectedID == id { selectedID = nil }
            history.dropLast(while: { $0.annotations.contains(where: { $0.id == id }) })
            history.dropLast()
            newTextID = nil
            refreshUndoFlags()
            refreshDirtyState()
            return
        }
        guard annotations[index].text != trimmed else {
            newTextID = nil
            return
        }
        if !isNew { registerUndo() }
        guard !trimmed.isEmpty else {
            annotations.remove(at: index)
            if selectedID == id { selectedID = nil }
            return
        }
        annotations[index].text = trimmed
        annotations[index].rect = ScreenshotRenderer.textBounds(
            trimmed, at: annotations[index].rect.origin,
            textSize: annotations[index].textSize, scale: scale)
        newTextID = nil
    }

    /// Cuts the capture to the crop draft, one undo step. Annotations, the
    /// recognized words and the text runs move into the crop's coordinates;
    /// the cropped capture is read again afterwards.
    func applyCrop() {
        guard let draft = cropDraft else {
            tool = .select
            return
        }
        let cropRect = ScreenshotSupport.pixelSnappedCropRect(draft, within: CGRect(origin: .zero, size: imageSize))
        guard cropRect.width >= 8, cropRect.height >= 8,
              let cropped = baseImage.cropping(to: cropRect)
        else {
            tool = .select
            return
        }
        registerUndo()
        let previousImage = baseImage
        baseImage = cropped
        pixelated = [:]
        softBlurred = [:]
        clearTextSelection()
        textWords = ScreenshotSupport.croppedWords(textWords, by: cropRect)
        // Moved runs still cover the cropped capture's text, including what
        // the words alone miss, and stay once it is read again. If the old
        // one was never read, text only areas keep waiting for recognition.
        let previousCarried = carriedRuns[ObjectIdentifier(previousImage)]
        textRuns = ScreenshotSupport.croppedRuns(textRuns, by: cropRect)
        if let carried = textRuns ?? ScreenshotSupport.croppedRuns(previousCarried, by: cropRect),
           !carried.isEmpty {
            carriedRuns[ObjectIdentifier(cropped)] = carried
        }
        pruneCarriedRuns()
        annotations = ScreenshotSupport.croppedAnnotations(annotations, by: cropRect)
        ensureBlurSamplesForAnnotations()
        cropDraft = nil
        selectedID = nil
        tool = .select
        recognizeText()
        recognizeQRCodes()
    }

    // MARK: - Output

    /// The capture as it leaves the editor, at full resolution: annotations,
    /// then the watermark, the corners and, unless it is for a pin, the
    /// backdrop.
    func exportImage(withBackdrop: Bool = true) -> ScreenshotRenderer.Export? {
        ensureBlurSamplesForAnnotations()
        guard let flattened = ScreenshotRenderer.renderExport(baseImage: baseImage, annotations: annotations,
                                                              blurSources: blurSources, scale: scale,
                                                              annotationShadowsEnabled: annotationShadowsEnabled,
                                                              spotlightDimStrength: spotlightDimStrength)
        else { return nil }
        return decor.finished(flattened, base: baseImage, withBackdrop: withBackdrop)
    }

    /// Makes the sample a blur area of this style and level paints from, and
    /// says whether it is there. Erasing reads the capture and needs none.
    @discardableResult
    private func ensureBlurSample(_ style: ScreenshotSupport.BlurStyleID, level: Int) -> Bool {
        switch style {
        case .pixelate:
            if pixelated[level] == nil {
                pixelated[level] = ScreenshotRenderer.pixelatedImage(from: baseImage, level: level)
            }
            return pixelated[level] != nil
        case .blur:
            if softBlurred[level] == nil {
                softBlurred[level] = ScreenshotRenderer.softBlurredImage(from: baseImage, level: level)
            }
            return softBlurred[level] != nil
        case .erase:
            return true
        }
    }

    /// Keeps a sample for each style and level in use and drops the rest.
    private func ensureBlurSamplesForAnnotations() {
        let mosaicLevels = ScreenshotSupport.mosaicLevels(for: annotations)
        let softBlurLevels = ScreenshotSupport.softBlurLevels(for: annotations)
        pixelated = pixelated.filter { mosaicLevels.contains($0.key) }
        softBlurred = softBlurred.filter { softBlurLevels.contains($0.key) }
        for level in mosaicLevels { ensureBlurSample(.pixelate, level: level) }
        for level in softBlurLevels { ensureBlurSample(.blur, level: level) }
    }
}

// MARK: - Stage C: backdrop, canvas expansion, pasted images

/// Same file as the model, so these reach its undo history and base image.
/// Adapted from the upstream editor model.
extension ScreenshotEditorModel {
    /// The canvas, the popovers and the dirty state follow the decor.
    private func forwardDecorChanges() {
        decor.forwardChanges(to: self)
        decor.changed = { [weak self] in self?.refreshDirtyState() }
    }

    /// Backdrop margin in image pixels; zero while the backdrop is off.
    var backdropPaddingPixels: CGFloat { decor.paddingPixels(for: imageSize) }

    /// Corner rounding of the capture card in image pixels.
    var cardCornerPixels: CGFloat { decor.cardCornerPixels(for: imageSize) }

    /// The outline the card's shadow follows, as the exporter draws it.
    var cardOutlineCornerPixels: CGFloat { decor.cardOutlineCornerPixels(for: baseImage) }

    /// The resize grip of a selected mark under `point`: an image layer's
    /// keeps its proportions from the corners and never overlaps on a small
    /// layer.
    private func grip(of selected: ScreenshotSupport.Annotation, at point: CGPoint,
                      tolerance: CGFloat) -> ScreenshotSupport.Handle? {
        guard selected.tool.resizesWithHandles else { return nil }
        return selected.tool == .image
            ? ScreenshotCanvasSupport.imageHandle(at: point, rect: selected.rect, tolerance: tolerance)
            : ScreenshotSupport.handle(at: point, rect: selected.rect, tolerance: tolerance)
    }

    // MARK: Pasted images

    /// Adds `image` as a movable, resizable layer centred on the canvas and
    /// selects it. False for a picture past the size limit.
    func pasteImage(_ image: CGImage) -> Bool {
        guard ScreenshotCanvasSupport.validSize(CGSize(width: image.width, height: image.height))
        else { return false }
        var annotation = ScreenshotSupport.Annotation(
            tool: .image, rect: ScreenshotCanvasSupport.fittedImageRect(image, canvas: imageSize))
        annotation.imageAsset = ScreenshotSupport.ImageAsset(image: image)
        registerUndo()
        clearTextSelection()
        // Before the selection: changing the tool clears it.
        tool = .select
        annotations.append(annotation)
        selectedID = annotation.id
        return true
    }

    // MARK: Canvas expansion

    private func beginCanvasExpansion(at point: CGPoint) {
        let bounds = CGRect(origin: .zero, size: imageSize)
        expansionRejected = false
        expansionDraft = bounds
        expansionHandle = ScreenshotCanvasSupport.expansionHandle(
            at: point, rect: bounds,
            tolerance: ScreenshotCanvasSupport.expansionGripReach / max(currentDisplayZoom, 0.001))
        expansionStartPoint = expansionHandle == nil ? nil : point
    }

    private func continueCanvasExpansion(to point: CGPoint) {
        guard let handle = expansionHandle, let start = expansionStartPoint else { return }
        let anchor = handle.position(in: CGRect(origin: .zero, size: imageSize))
        let target = CGPoint(x: anchor.x + point.x - start.x, y: anchor.y + point.y - start.y)
        expansionDraft = ScreenshotCanvasSupport.expandedRect(size: imageSize, handle: handle, point: target)
        expansionRejected = expansionDraft == nil
    }

    private func finishCanvasExpansion() {
        if expansionRejected {
            NSSound.beep()
        } else if let draft = expansionDraft, draft.size != imageSize {
            if !commitCanvasExpansion(to: draft) { NSSound.beep() }
        }
        cancelCanvasExpansion()
    }

    /// Grows the canvas to `rect` (in the current canvas's pixels) as one
    /// undo step; every mark keeps its place on the capture.
    func commitCanvasExpansion(to rect: CGRect) -> Bool {
        guard rect != CGRect(origin: .zero, size: imageSize),
              let expanded = ScreenshotCanvasSupport.expandedImage(baseImage, to: rect, fill: expansionFill)
        else { return false }
        registerUndo()
        annotations = ScreenshotCanvasSupport.shifted(annotations, into: rect)
        baseImage = expanded
        textWords = []
        clearTextSelection()
        selectedID = nil
        editingTextID = nil
        recognizeText()
        recognizeQRCodes()
        return true
    }

    func cancelCanvasExpansion() {
        expansionDraft = nil
        expansionHandle = nil
        expansionStartPoint = nil
        expansionRejected = false
    }

    /// Escape backs out one step: a drag in progress first, then the tool,
    /// so the editor only closes once there is nothing left to leave.
    func leaveCanvasExpansion() {
        if expansionDraft != nil || expansionRejected {
            cancelCanvasExpansion()
        } else {
            tool = .select
        }
    }
}

// MARK: - Window controller

/// Hosts one editor window per capture and owns everything with a side
/// effect: clipboard, files, pins, recognition and the close confirmation.
/// Nothing is written unless Save or Save As is used. Adapted from the
/// upstream editor controller, without the parts `docs/screenshot-editor.md`
/// cuts (no network, no file-copy clipboard mode, no temporary files).
final class ScreenshotEditorController: NSObject, NSWindowDelegate {
    let model: ScreenshotEditorModel
    private var window: NSWindow?
    private var keyMonitor: Any?
    private var scrollMonitor: Any?
    private var pointerMonitor: Any?
    private var noticeWork: DispatchWorkItem?

    init(image: CGImage, scale: CGFloat) {
        model = ScreenshotEditorModel(image: image, scale: scale)
        super.init()
    }

    func show() {
        let pointer = NSEvent.mouseLocation
        let screen = (NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main)?
            .visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let minimumSize = ScreenshotSupport.editorMinimumContentSize(visibleSize: screen.size)
        // The hosting view rewrites the window's size limits on its first
        // layout pass, so the minimum is declared on the hosted view and the
        // hosting controller maintains contentMinSize from it.
        let content = ScreenshotEditorView(model: model, controller: self)
            .frame(minWidth: minimumSize.width, minHeight: minimumSize.height)
        let host = NSHostingController(rootView: content)
        host.sizingOptions = [.minSize]
        let window = NSWindow(contentViewController: host)
        // One continuous surface: the canvas fills the window and the
        // controls float over it.
        window.title = L10n.shared.s.screenshotEditorTitle
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // Dark, so canvas contrast and popovers stay consistent.
        window.appearance = NSAppearance(named: .darkAqua)
        // Content drags edit annotations. Only the title strip moves the window.
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        let contentSize = ScreenshotSupport.editorContentSize(imagePointSize: model.pointSize,
                                                              visibleSize: screen.size)
        window.setContentSize(contentSize)
        window.setFrameOrigin(CGPoint(x: screen.midX - window.frame.width / 2,
                                      y: screen.midY - window.frame.height / 2))
        self.window = window
        installMonitors()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        // Let the window appear before starting competing Vision work.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window?.isVisible == true else { return }
            self.model.recognizeText()
            self.model.recognizeQRCodes()
        }
    }

    /// Closes without the unsaved-edit question, for an uninstall.
    func closeWithoutAsking() {
        window?.close()
    }

    // MARK: Keyboard

    /// Installed per window, removed in `windowWillClose`.
    private func installMonitors() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = self.window,
                  ScreenshotSupport.editorOwnsKeyEvent(eventWindowNumber: event.windowNumber,
                                                       editorWindowNumber: window.windowNumber,
                                                       editorIsKey: window.isKeyWindow)
            else { return event }
            // While a text field edits, every key belongs to it.
            if window.firstResponder is NSText || self.model.editingTextID != nil { return event }
            return self.handleKey(event) ? nil : event
        }
        // A stroke can draw a select-to-copy utility's posted ⌘C; see
        // `ScreenshotSupport.editorIgnoresPostedCopy`.
        pointerMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            if let self, let window = self.window, event.windowNumber == window.windowNumber {
                self.model.notePointerActivity()
            }
            return event
        }
        // Control-scroll zooms the canvas.
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, let window = self.window,
                  ScreenshotSupport.editorOwnsKeyEvent(eventWindowNumber: event.windowNumber,
                                                       editorWindowNumber: window.windowNumber,
                                                       editorIsKey: window.isKeyWindow),
                  event.modifierFlags.contains(.control)
            else { return event }
            let delta = event.scrollingDeltaY
            guard delta != 0 else { return nil }
            self.model.adjustZoom(by: 1 + max(-24, min(24, delta)) * 0.014)
            return nil
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = Int(event.keyCode)
        if ScreenshotSupport.editorIgnoresRepeatedOutputKey(
            keyCode: key, command: flags.contains(.command), isRepeat: event.isARepeat) {
            return true
        }
        // The typed digit picks the rail slot, whatever the keyboard layout.
        if flags.isDisjoint(with: [.command, .control, .option]),
           let number = event.characters.flatMap({ Int($0) }),
           let tool = ScreenshotSupport.Tool.shortcutTool(
            number: number,
            orderRaw: UserDefaults.standard.string(forKey: DefaultsKey.screenshotToolOrder),
            enabled: UserDefaults.standard.bool(forKey: DefaultsKey.screenshotToolShortcutsEnabled)) {
            model.tool = tool
            return true
        }

        if flags.contains(.command) {
            switch key {
            case kVK_ANSI_C:
                if !model.selectedWordIndexes.isEmpty {
                    copySelectedText()
                } else if !ScreenshotSupport.editorIgnoresPostedCopy(
                    sourceProcessID: event.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID) ?? 0,
                    ownProcessID: Int64(getpid()),
                    now: ProcessInfo.processInfo.systemUptime,
                    lastPointerActivity: model.lastPointerActivityUptime) {
                    copyToClipboard()
                }
                return true
            case kVK_ANSI_V: pasteImageFromClipboard(); return true
            case kVK_ANSI_S:
                if flags.contains(.shift) { saveAs() } else { save() }
                return true
            case kVK_ANSI_Z:
                if flags.contains(.shift) { model.redo() } else { model.undo() }
                return true
            case kVK_ANSI_P: pin(); return true
            case kVK_ANSI_W: window?.performClose(nil); return true
            case kVK_ANSI_0: model.zoomOverride = nil; return true
            case kVK_ANSI_1: model.zoomToActualSize(); return true
            case kVK_ANSI_Equal, kVK_ANSI_KeypadPlus: model.adjustZoom(by: 1.25); return true
            case kVK_ANSI_Minus, kVK_ANSI_KeypadMinus: model.adjustZoom(by: 0.8); return true
            default: return false
            }
        }
        guard flags.isDisjoint(with: [.command, .control, .option]) else { return false }

        switch key {
        case kVK_Delete, kVK_ForwardDelete:
            model.deleteSelected()
            return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            // Applies a crop in progress; otherwise the same as ⌘C: selected
            // text as text, otherwise the capture.
            if model.tool == .crop, model.cropDraft != nil {
                model.applyCrop()
            } else if model.selectedWordIndexes.isEmpty {
                copyToClipboard()
            } else {
                copySelectedText()
            }
            return true
        case kVK_Escape:
            // Steps out one level at a time, and closes only at the last.
            if model.tool == .expandCanvas {
                model.leaveCanvasExpansion()
            } else if model.tool == .crop, model.cropDraft != nil {
                model.tool = .select
            } else if !model.selectedWordIndexes.isEmpty {
                model.clearTextSelection()
            } else if model.selectedID != nil {
                model.selectedID = nil
            } else {
                window?.performClose(nil)
            }
            return true
        default:
            return false
        }
    }

    // MARK: Export actions

    /// The capture leaves as image data only and the editor closes, as
    /// upstream: the window's job is done.
    func copyToClipboard() {
        guard let export = model.exportImage() else {
            NSSound.beep()
            return
        }
        // copyEdited beeps itself when the image cannot be encoded.
        guard ScreenshotService.shared.copyEdited(export.image) else { return }
        model.markExported()
        window?.close()
    }

    /// A new file in the chosen folder, never replacing one. On failure the
    /// editor stays open so nothing is lost.
    func save() {
        guard let export = model.exportImage(),
              let data = ScreenshotRenderer.pngData(from: export.image, scale: export.scale)
        else {
            NSSound.beep()
            return
        }
        guard ScreenshotService.shared.saveEdited(data) else {
            showNotice(L10n.shared.s.screenshotFolderUnavailable)
            return
        }
        model.markExported()
        window?.close()
    }

    /// The system save panel asks before replacing a file, so the write may
    /// overwrite only what the person confirmed there.
    func saveAs() {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.directoryURL = ScreenshotService.saveFolder
        panel.nameFieldStringValue = ScreenshotSupport.fileName(prefix: L10n.shared.s.screenshotFilePrefix,
                                                                date: Date())
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            guard let export = self.model.exportImage(),
                  let data = ScreenshotRenderer.pngData(from: export.image, scale: export.scale)
            else {
                NSSound.beep()
                return
            }
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                NSSound.beep()
                return
            }
            ScreenshotSupport.markAsScreenCapture(url)
            ScreenshotService.shared.editorSaved(url)
            self.model.markExported()
            self.window?.close()
        }
    }

    /// Pinning snapshots the current export, without the backdrop as
    /// upstream, and leaves the editor open.
    func pin() {
        guard let export = model.exportImage(withBackdrop: false) else { return }
        ScreenshotPinController.shared.pin(image: export.image, scale: export.scale)
        model.markExported()
    }

    /// Copies the words selected on the canvas as plain text.
    func copySelectedText() {
        let text = model.selectedText
        guard !text.isEmpty else { return }
        ScreenshotService.copyText(text)
        showNotice(L10n.shared.s.screenshotPreviewTextCopied)
    }

    /// The code's content in the shared result panel; the editor stays open.
    func showQRResult() {
        guard let reading = model.qrReading else { return }
        ScreenshotQRResultController.shared.show(reading)
    }

    private func showNotice(_ text: String) {
        model.notice = text
        noticeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.model.notice = nil }
        noticeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }

    // MARK: NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard model.isDirty else { return true }
        let s = L10n.shared.s
        let alert = NSAlert()
        alert.messageText = s.screenshotEditorDiscardTitle
        alert.informativeText = s.screenshotEditorDiscardMessage
        alert.addButton(withTitle: s.screenshotEditorDiscard)
        alert.addButton(withTitle: s.screenshotEditorCancel)
        alert.alertStyle = .warning
        return alert.runModal() == .alertFirstButtonReturn
    }

    func windowWillClose(_ notification: Notification) {
        for monitor in [keyMonitor, scrollMonitor, pointerMonitor].compactMap({ $0 }) {
            NSEvent.removeMonitor(monitor)
        }
        keyMonitor = nil
        scrollMonitor = nil
        pointerMonitor = nil
        noticeWork?.cancel()
        window?.delegate = nil
        window = nil
        ScreenshotService.shared.editorDidClose(self)
    }
}

// MARK: - Stage C: pasting an image

extension ScreenshotEditorController {
    /// Reads the clipboard image on the shared pasteboard lane, since a read
    /// can wait on data another app only promised. The picture stays in
    /// memory as a layer; nothing is written. The paste lands only while
    /// this editor is still open.
    func pasteImageFromClipboard() {
        GeneralPasteboardAccess.shared.async({
            autoreleasepool { Self.clipboardImage() }
        }, then: { [weak self] image in
            guard let self, self.window != nil else { return }
            guard let image, self.model.pasteImage(image) else {
                NSSound.beep()
                return
            }
        })
    }

    /// Image data at its own pixel size first; anything else AppKit can
    /// read as a picture (a copied image file, for one) after that.
    private static func clipboardImage() -> CGImage? {
        let pasteboard = NSPasteboard.general
        if let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff),
           let source = CGImageSourceCreateWithData(data as CFData, nil),
           let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            return image
        }
        return NSImage(pasteboard: pasteboard)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}
