// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Pure logic for the screenshot editor: window sizing, key rules, the
/// annotation model, selection handles, shape geometry and hit testing, zoom,
/// the undo history, crop geometry, redaction runs and recognized words. No
/// AppKit, so a harness compiles it on its own. Adapted from the upstream
/// editor support, without canvas expansion and pasted images (stage C);
/// the shapes stay upstream's so those slot in.
extension ScreenshotSupport {

    // MARK: - Editor layout

    /// A fresh editor is large enough for its controls and canvas, while
    /// still fitting compact or rotated displays.
    static func editorMinimumContentSize(visibleSize: CGSize) -> CGSize {
        CGSize(width: min(visibleSize.width,
                          min(980, max(760, visibleSize.width * 0.76))),
               height: min(visibleSize.height,
                           min(680, max(560, visibleSize.height * 0.72))))
    }

    /// Initial content size for an editor window. Large captures fit inside
    /// the display and small captures still open on a comfortable canvas.
    static func editorContentSize(imagePointSize: CGSize,
                                  visibleSize: CGSize) -> CGSize {
        let chrome = CGSize(width: 96, height: 140)
        let minimum = editorMinimumContentSize(visibleSize: visibleSize)
        let maximum = CGSize(width: max(minimum.width, visibleSize.width * 0.90),
                             height: max(minimum.height, visibleSize.height * 0.88))
        let fit = min(1,
                      min((maximum.width - chrome.width) / max(imagePointSize.width, 1),
                          (maximum.height - chrome.height) / max(imagePointSize.height, 1)))
        let preferred = CGSize(width: imagePointSize.width * fit + chrome.width,
                               height: imagePointSize.height * fit + chrome.height)
        return CGSize(width: min(maximum.width, max(minimum.width, preferred.width)),
                      height: min(maximum.height, max(minimum.height, preferred.height)))
    }

    /// The footer under the canvas wraps to a second row when a tool's
    /// controls do not fit beside the info and zoom chips, so its height
    /// changes with the tool.
    static let editorWrappedFooterHeight: CGFloat = 76

    /// The height the tool rail plans for: its column, less what a wrapped
    /// footer would take from it, so picking a tool never reflows the rail
    /// under the pointer.
    static func toolRailHeight(column: CGFloat, footer: CGFloat) -> CGFloat {
        min(column, column + footer - editorWrappedFooterHeight)
    }

    /// How the tool rail fits its height. Regular rows when every tool fits,
    /// compact rows when only those fit, and past that the last tools move
    /// behind an overflow button, as toolbar items that do not fit do.
    /// Adapted from upstream unchanged: the extra row it plans is the tool
    /// order and keys button.
    struct ToolRailLayout: Equatable {
        var rowHeight: CGFloat = 29
        var spacing: CGFloat = 2
        /// Tools shown as buttons. The ones after them are in the overflow menu.
        var visibleTools: Int

        /// The rail's padding and the divider above the options button.
        static let chromeHeight: CGFloat = 15

        init(toolCount: Int, height: CGFloat) {
            visibleTools = toolCount
            // Every tool and the options row.
            if Self.chromeHeight + CGFloat(toolCount + 1) * (rowHeight + spacing) <= height { return }
            // Compact rows still hold all of them in the shortest editor.
            rowHeight = 23
            spacing = 1
            let rows = Int(((height - Self.chromeHeight) / (rowHeight + spacing)).rounded(.down))
            if rows >= toolCount + 1 { return }
            // The overflow button and the options row take the last two rows.
            visibleTools = max(0, rows - 2)
        }
    }

    // MARK: - Editor keys

    /// Select-to-copy utilities answer a mouse drag with a posted ⌘C, which in
    /// the editor would copy the capture and close it under a stroke that has
    /// not landed yet. A ⌘C another process posts while the pointer presses or
    /// drags in the editor, or just after, is theirs; a pressed ⌘C always copies.
    static let editorPostedCopyGrace: TimeInterval = 0.6

    static func editorIgnoresPostedCopy(sourceProcessID: Int64,
                                        ownProcessID: Int64,
                                        now: TimeInterval,
                                        lastPointerActivity: TimeInterval) -> Bool {
        sourceProcessID != 0 && sourceProcessID != ownProcessID
            && now - lastPointerActivity < editorPostedCopyGrace
    }

    /// A held Return or ⌘C repeats into what the first press left on screen:
    /// Return that applied a crop, or chose Edit in the preview, would copy
    /// the capture and close the editor a moment later.
    static func editorIgnoresRepeatedOutputKey(keyCode: Int, command: Bool, isRepeat: Bool) -> Bool {
        isRepeat && (keyCode == kVK_Return || keyCode == kVK_ANSI_KeypadEnter
            || (command && keyCode == kVK_ANSI_C))
    }

    /// Local key monitors normally receive the editor's window number, but
    /// AppKit can clear it while resolving a main-menu key equivalent such as
    /// Command-Z. In that case the key window still owns the event. Never use
    /// the fallback for an event that explicitly belongs to another window.
    static func editorOwnsKeyEvent(eventWindowNumber: Int,
                                   editorWindowNumber: Int,
                                   editorIsKey: Bool) -> Bool {
        guard editorWindowNumber != 0 else { return false }
        if eventWindowNumber == editorWindowNumber { return true }
        return eventWindowNumber == 0 && editorIsKey
    }

    // MARK: - Annotation model

    /// Movement in view points, so clicks keep the same tolerance at every
    /// zoom. Only the pen keeps its path when it returns to the start; other
    /// tools still discard a shape whose endpoints form a click.
    struct EditorDrag {
        private var start: CGPoint = .zero
        private var stayedNearStart = true
        private var endsNearStart = true

        mutating func begin(at point: CGPoint) {
            start = point
            stayedNearStart = true
            endsNearStart = true
        }

        mutating func update(to point: CGPoint) {
            endsNearStart = hypot(point.x - start.x, point.y - start.y) < 7
            stayedNearStart = stayedNearStart && endsNearStart
        }

        func isTap(for tool: Tool) -> Bool {
            tool == .freehand ? stayedNearStart : endsNearStart
        }
    }

    enum Tool: String, CaseIterable {
        // Case order is the default rail order and therefore the default
        // mapping for keys 1 through 9: upstream's order. `ordered(from:)`
        // applies the person's own order.
        case select, arrow, pixelate, crop, text, sticker, rect, highlight,
             freehand, line, ellipse, counter, redact, spotlight, expandCanvas, image

        /// Pasted image layers never appear in the rail.
        static var editorTools: [Tool] { allCases.filter { $0 != .image } }

        static let shortcutLimit = 9

        /// Tools that create an annotation by dragging a rectangle.
        var dragsRect: Bool {
            switch self {
            case .rect, .ellipse, .highlight, .pixelate, .redact, .spotlight: return true
            case .select, .arrow, .line, .freehand, .text, .sticker, .counter, .crop, .expandCanvas, .image:
                return false
            }
        }

        /// Existing rectangular marks with visible resize grips.
        var resizesWithHandles: Bool { dragsRect || self == .sticker || self == .image }

        /// The tool a new editor opens with. Select, crop and expand canvas
        /// act on the capture as a whole and an image is never picked by
        /// hand, so each falls back to arrow and the editor opens ready to draw.
        static func startingTool(remembered raw: String?) -> Tool {
            let tool = Tool(rawValue: raw ?? "") ?? .arrow
            return [.select, .crop, .expandCanvas, .image].contains(tool) ? .arrow : tool
        }

        /// The tool in rail slot `number` (1 based), or nil past the rail.
        static func shortcutTool(number: Int) -> Tool? {
            guard (1...shortcutLimit).contains(number) else { return nil }
            let index = number - 1
            return editorTools.indices.contains(index) ? editorTools[index] : nil
        }

        static func shortcutNumber(for tool: Tool) -> Int? {
            guard let index = editorTools.firstIndex(of: tool), index < shortcutLimit else { return nil }
            return index + 1
        }
    }

    enum ColorID: String, CaseIterable {
        case red, orange, yellow, green, blue, purple, black, white

        /// sRGB components, shared by live rendering and export.
        var components: (red: Double, green: Double, blue: Double) {
            switch self {
            case .red: return (0.93, 0.26, 0.21)
            case .orange: return (1.00, 0.58, 0.00)
            case .yellow: return (1.00, 0.80, 0.00)
            case .green: return (0.20, 0.78, 0.35)
            case .blue: return (0.04, 0.52, 1.00)
            case .purple: return (0.69, 0.32, 0.87)
            case .black: return (0.09, 0.09, 0.11)
            case .white: return (1.00, 1.00, 1.00)
            }
        }

        static func sanitized(_ raw: String?) -> ColorID {
            ColorID(rawValue: raw ?? "") ?? .red
        }
    }

    enum StrokeID: String, CaseIterable {
        case small, medium, large

        /// Line width in image points at 1x; export multiplies by the image
        /// scale so marks keep their weight on Retina captures.
        var width: CGFloat {
            switch self {
            case .small: return 2
            case .medium: return 4
            case .large: return 7
            }
        }

        static func sanitized(_ raw: String?) -> StrokeID {
            StrokeID(rawValue: raw ?? "") ?? .medium
        }
    }

    /// Text point sizes at 1x, offered as presets. Text has its own size
    /// instead of borrowing the shape thickness, so a thin arrow can sit
    /// beside a large label.
    static let textSizes: [Int] = [10, 12, 14, 16, 19, 24, 28, 36, 48, 64, 72, 96]
    static let defaultTextSize = 19

    static func sanitizedTextSize(_ size: Int) -> Int {
        guard let first = textSizes.first, let last = textSizes.last else { return defaultTextSize }
        return size == 0 ? defaultTextSize : min(max(size, first), last)
    }

    /// The preset one step away from `size`, or nil at either end.
    static func steppedTextSize(from size: Int, up: Bool) -> Int? {
        up ? textSizes.first(where: { $0 > size }) : textSizes.last(where: { $0 < size })
    }

    /// How dark a spotlight turns everything outside its regions, from 0
    /// (untouched) to 1 (black).
    static let defaultSpotlightDim: CGFloat = 0.5

    /// A stored or passed dim kept within 0...1; an unreadable one falls
    /// back to the default.
    static func sanitizedSpotlightDim(_ strength: CGFloat) -> CGFloat {
        strength.isFinite ? min(max(strength, 0), 1) : defaultSpotlightDim
    }

    /// The dim the editor's control settles on: the nearest 5% step, so a
    /// continuous slider needs no tick marks and the spoken percent stays
    /// whole.
    static func steppedSpotlightDim(_ strength: CGFloat) -> CGFloat {
        (sanitizedSpotlightDim(strength) * 20).rounded() / 20
    }

    /// How hard a blur hides what is under it, from 1 (lightest) to 5
    /// (heaviest). Level 3 is the default strength.
    enum BlurStrength {
        static let levels = 1...5
        static let defaultLevel = 3

        static func sanitized(_ level: Int) -> Int {
            min(max(level, levels.lowerBound), levels.upperBound)
        }

        /// Where a new capture's pixelate tool starts: the remembered level,
        /// but never a light one. Levels 1 and 2 make blocks smaller than a
        /// line of text, which can stay readable, so they are picked area by
        /// area instead of carried into the next redaction.
        static func startingLevel(remembered: Int) -> Int {
            max(sanitized(remembered), defaultLevel)
        }

        /// What the level does to the mosaic block, relative to level 3.
        static func blockFactor(for level: Int) -> CGFloat {
            switch sanitized(level) {
            case 1: return 0.4
            case 2: return 0.65
            case 4: return 1.5
            case 5: return 2.2
            default: return 1
            }
        }
    }

    enum ArrowStyleID: String, CaseIterable {
        case filled, outline, open, doubleEnded, scribbly

        static func sanitized(_ raw: String?) -> ArrowStyleID {
            ArrowStyleID(rawValue: raw ?? "") ?? .filled
        }
    }

    /// What a blur area does to what is under it. Pixelate is the default.
    enum BlurStyleID: String, CaseIterable {
        case pixelate, blur, erase

        static func sanitized(_ raw: String?) -> BlurStyleID {
            BlurStyleID(rawValue: raw ?? "") ?? .pixelate
        }

        /// Erasing paints the surroundings over the area, so it has no strength.
        var usesStrength: Bool {
            self != .erase
        }
    }

    static func randomScribbleSeed() -> UInt64 {
        UInt64.random(in: UInt64.min...UInt64.max)
    }

    enum StickerID: String, CaseIterable {
        case check, cross, star, heart, thumbsUp, thumbsDown,
             smile, laugh, party, fire, warning, eyes

        var glyph: String {
            switch self {
            case .check: return "✅"
            case .cross: return "❌"
            case .star: return "⭐️"
            case .heart: return "❤️"
            case .thumbsUp: return "👍"
            case .thumbsDown: return "👎"
            case .smile: return "😀"
            case .laugh: return "😂"
            case .party: return "🎉"
            case .fire: return "🔥"
            case .warning: return "⚠️"
            case .eyes: return "👀"
            }
        }

        static func sanitized(_ raw: String?) -> StickerID {
            StickerID(rawValue: raw ?? "") ?? .check
        }
    }

    /// A new sticker's side in image pixels: about a sixth of the capture's
    /// short side, within readable limits.
    static func stickerSide(for imageSize: CGSize, scale: CGFloat) -> CGFloat {
        let shortSide = min(imageSize.width, imageSize.height)
        let minimum = min(52 * scale, shortSide * 0.45)
        return max(1, max(minimum, min(shortSide * 0.16, 128 * scale)))
    }

    /// A square sticker centered on the tap, moved back inside the capture
    /// when the tap was near an edge.
    static func stickerRect(centeredAt point: CGPoint,
                            side: CGFloat,
                            within bounds: CGRect) -> CGRect {
        let fittedSide = min(max(1, side), min(bounds.width, bounds.height))
        let rect = CGRect(x: point.x - fittedSide / 2,
                          y: point.y - fittedSide / 2,
                          width: fittedSide,
                          height: fittedSide)
        return movedRect(rect, by: .zero, within: bounds)
    }

    /// One annotation on the canvas. Geometry lives in image-pixel
    /// coordinates (top-left origin), so export is resolution-exact and the
    /// view only scales for display. A sticker keeps its `StickerID` in
    /// `text`.
    struct Annotation: Identifiable, Equatable {
        let id: UUID
        var tool: Tool
        var rect: CGRect
        var points: [CGPoint]
        var text: String
        var color: ColorID
        var stroke: StrokeID
        var textSize: Int
        var blurLevel: Int
        var blurStyle: BlurStyleID
        /// A blur area that covers only the text recognized inside it.
        var blurTextOnly: Bool
        var arrowStyle: ArrowStyleID
        var scribbleSeed: UInt64
        var number: Int
        /// The pixels of a pasted image layer (`tool == .image`).
        var imageAsset: ImageAsset? = nil
        /// The canvas size a counter or blur area keeps its look for after
        /// the canvas grows: its badge and its mosaic blocks stay the size
        /// they were drawn at. Nil follows the current canvas.
        var renderReferenceSize: CGSize? = nil

        init(id: UUID = UUID(),
             tool: Tool,
             rect: CGRect = .zero,
             points: [CGPoint] = [],
             text: String = "",
             color: ColorID = .red,
             stroke: StrokeID = .medium,
             textSize: Int = ScreenshotSupport.defaultTextSize,
             blurLevel: Int = BlurStrength.defaultLevel,
             blurStyle: BlurStyleID = .pixelate,
             blurTextOnly: Bool = false,
             arrowStyle: ArrowStyleID = .filled,
             scribbleSeed: UInt64? = nil,
             number: Int = 0) {
            self.id = id
            self.tool = tool
            self.rect = rect
            self.points = points
            self.text = text
            self.color = color
            self.stroke = stroke
            self.textSize = textSize
            self.blurLevel = blurLevel
            self.blurStyle = blurStyle
            self.blurTextOnly = blurTextOnly
            self.arrowStyle = arrowStyle
            self.scribbleSeed = scribbleSeed
                ?? (arrowStyle == .scribbly ? ScreenshotSupport.randomScribbleSeed() : 0)
            self.number = number
        }
    }

    /// The style values the editor controls should show for a picked mark.
    struct SelectionStyle: Equatable {
        let color: ColorID?
        let stroke: StrokeID?
        let arrowStyle: ArrowStyleID?
        var textSize: Int? = nil
        var blurLevel: Int? = nil
        var blurStyle: BlurStyleID? = nil
        var blurTextOnly: Bool? = nil
    }

    static func selectionStyle(for annotation: Annotation) -> SelectionStyle {
        switch annotation.tool {
        case .arrow:
            return SelectionStyle(color: annotation.color, stroke: annotation.stroke,
                                  arrowStyle: annotation.arrowStyle)
        case .line, .rect, .ellipse, .freehand:
            return SelectionStyle(color: annotation.color, stroke: annotation.stroke, arrowStyle: nil)
        case .text:
            return SelectionStyle(color: annotation.color, stroke: nil, arrowStyle: nil,
                                  textSize: annotation.textSize)
        case .highlight, .counter, .redact:
            return SelectionStyle(color: annotation.color, stroke: nil, arrowStyle: nil)
        case .pixelate:
            return SelectionStyle(color: nil, stroke: nil, arrowStyle: nil,
                                  blurLevel: annotation.blurLevel,
                                  blurStyle: annotation.blurStyle,
                                  blurTextOnly: annotation.blurTextOnly)
        case .sticker, .select, .crop, .spotlight, .expandCanvas, .image:
            return SelectionStyle(color: nil, stroke: nil, arrowStyle: nil)
        }
    }

    /// Which way a selected annotation moves through the drawing order.
    enum LayerMove {
        case forward, backward
    }

    /// Whether the annotation has somewhere to go: false at the end it is
    /// already heading for, and for an id that is not in the array.
    static func canReorder(_ annotations: [Annotation], moving id: UUID, _ move: LayerMove) -> Bool {
        guard let index = annotations.firstIndex(where: { $0.id == id }) else { return false }
        return annotations.indices.contains(move == .forward ? index + 1 : index - 1)
    }

    /// Moves one annotation a single step through the array the renderer draws
    /// in order, so a shape can go behind text that was written first. An
    /// annotation already at the end it is heading for stays put, and an
    /// unknown id leaves the array alone.
    static func reordering(_ annotations: [Annotation], moving id: UUID, _ move: LayerMove) -> [Annotation] {
        guard let index = annotations.firstIndex(where: { $0.id == id }) else { return annotations }
        let target = move == .forward ? index + 1 : index - 1
        guard annotations.indices.contains(target) else { return annotations }
        var reordered = annotations
        reordered.swapAt(index, target)
        return reordered
    }

    /// Counters stay 1…n in drawing order; deleting or moving one renumbers
    /// the rest so a sequence never shows a hole.
    static func renumberingCounters(_ annotations: [Annotation]) -> [Annotation] {
        var next = 1
        return annotations.map { annotation in
            guard annotation.tool == .counter else { return annotation }
            var updated = annotation
            updated.number = next
            next += 1
            return updated
        }
    }

    /// Counter badge diameter for an image, scaling with capture resolution
    /// so badges stay readable without swallowing small screenshots.
    static func counterDiameter(for imageSize: CGSize, scale: CGFloat) -> CGFloat {
        max(22, min(imageSize.width, imageSize.height) / 24) * scale
    }

    // MARK: - Undo history

    /// Snapshots before each edit, at most `limit` of them; a new edit clears
    /// what could be redone. Adapted from the upstream editor model's stacks.
    struct EditorHistory<State> {
        let limit: Int
        private(set) var undoStack: [State] = []
        private(set) var redoStack: [State] = []

        init(limit: Int = 60) {
            self.limit = limit
        }

        var canUndo: Bool { !undoStack.isEmpty }
        var canRedo: Bool { !redoStack.isEmpty }

        /// The state before an edit.
        mutating func record(_ state: State) {
            undoStack.append(state)
            if undoStack.count > limit { undoStack.removeFirst(undoStack.count - limit) }
            redoStack.removeAll()
        }

        /// The state to go back to, with `current` kept for redo.
        mutating func undo(from current: State) -> State? {
            guard let last = undoStack.popLast() else { return nil }
            redoStack.append(current)
            return last
        }

        mutating func redo(from current: State) -> State? {
            guard let next = redoStack.popLast() else { return nil }
            undoStack.append(current)
            return next
        }

        /// Forgets the newest snapshot, for an edit that never landed.
        mutating func dropLast() {
            if !undoStack.isEmpty { undoStack.removeLast() }
        }

        mutating func dropLast(while matches: (State) -> Bool) {
            while let last = undoStack.last, matches(last) { undoStack.removeLast() }
        }
    }

    // MARK: - Zoom

    /// View points per image pixel the editor allows.
    static let editorZoomRange: ClosedRange<CGFloat> = 0.05...3

    /// Margin around the capture inside its scroll region.
    static let editorCanvasMargin: CGFloat = 14

    static func clampedEditorZoom(_ zoom: CGFloat) -> CGFloat {
        min(max(zoom, editorZoomRange.lowerBound), editorZoomRange.upperBound)
    }

    /// The zoom that fits `content` (image pixels) into `available` (view
    /// points) with the margin. Never above 1: a small capture is not blown
    /// up past one view point per pixel.
    static func editorFitZoom(available: CGSize, content: CGSize,
                              margin: CGFloat = editorCanvasMargin) -> CGFloat {
        let width = max(available.width - margin * 2, 80)
        let height = max(available.height - margin * 2, 80)
        let fit = min(width / max(content.width, 1), height / max(content.height, 1))
        return min(fit, 1)
    }

    // MARK: - Selection handles

    enum Handle: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

        func position(in rect: CGRect) -> CGPoint {
            switch self {
            case .topLeft: return CGPoint(x: rect.minX, y: rect.minY)
            case .top: return CGPoint(x: rect.midX, y: rect.minY)
            case .topRight: return CGPoint(x: rect.maxX, y: rect.minY)
            case .right: return CGPoint(x: rect.maxX, y: rect.midY)
            case .bottomRight: return CGPoint(x: rect.maxX, y: rect.maxY)
            case .bottom: return CGPoint(x: rect.midX, y: rect.maxY)
            case .bottomLeft: return CGPoint(x: rect.minX, y: rect.maxY)
            case .left: return CGPoint(x: rect.minX, y: rect.midY)
            }
        }
    }

    static func handle(at point: CGPoint, rect: CGRect, tolerance: CGFloat) -> Handle? {
        Handle.allCases.first { handle in
            let position = handle.position(in: rect)
            return abs(position.x - point.x) <= tolerance && abs(position.y - point.y) <= tolerance
        }
    }

    /// The rectangle after dragging `handle` to `point`. Width and height are
    /// kept non-negative by swapping edges when a drag crosses over.
    static func resizedRect(_ rect: CGRect, dragging handle: Handle, to point: CGPoint) -> CGRect {
        var minX = rect.minX, minY = rect.minY, maxX = rect.maxX, maxY = rect.maxY
        switch handle {
        case .topLeft: minX = point.x; minY = point.y
        case .top: minY = point.y
        case .topRight: maxX = point.x; minY = point.y
        case .right: maxX = point.x
        case .bottomRight: maxX = point.x; maxY = point.y
        case .bottom: maxY = point.y
        case .bottomLeft: minX = point.x; maxY = point.y
        case .left: minX = point.x
        }
        return CGRect(x: min(minX, maxX), y: min(minY, maxY),
                      width: abs(maxX - minX), height: abs(maxY - minY))
    }

    // MARK: - Crop

    /// Moves an existing crop without resizing it, stopping cleanly at the
    /// image edges instead of shrinking the rectangle through intersection.
    static func movedRect(_ rect: CGRect,
                          by delta: CGPoint,
                          within bounds: CGRect) -> CGRect {
        guard rect.width <= bounds.width, rect.height <= bounds.height else {
            return rect.intersection(bounds)
        }
        let x = min(max(rect.minX + delta.x, bounds.minX), bounds.maxX - rect.width)
        let y = min(max(rect.minY + delta.y, bounds.minY), bounds.maxY - rect.height)
        return CGRect(x: x, y: y, width: rect.width, height: rect.height)
    }

    /// The pixel rectangle a crop draft stands for. A crop cuts on pixel
    /// boundaries, so the chrome, the loupe cross and `applyCrop` all read the
    /// draft through here and mark the same edge. Rounding both edges to the
    /// nearest boundary leaves an already snapped rectangle the same size under
    /// a move, because the two edges carry the same fraction.
    static func pixelSnappedCropRect(_ rect: CGRect, within bounds: CGRect) -> CGRect {
        let minX = rect.minX.rounded()
        let minY = rect.minY.rounded()
        let maxX = rect.maxX.rounded()
        let maxY = rect.maxY.rounded()
        return clamp(CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY),
                     to: bounds)
    }

    /// A full-image crop cannot move, so an interior drag must start a new
    /// selection. Dragging outside an existing crop replaces it as well.
    static func startsNewCropSelection(at point: CGPoint,
                                       draft: CGRect,
                                       within bounds: CGRect) -> Bool {
        bounds.contains(point)
            && (draft.standardized == bounds.standardized || !draft.contains(point))
    }

    /// The square of source pixels the crop loupe magnifies. A crop *edge*
    /// runs between pixels, and lands in the middle of the frame only when
    /// the side is even and the coordinate is whole, so the editor passes
    /// `centredOnPixel: false` and reads a draft `pixelSnappedCropRect` has
    /// put on a boundary. Near an image edge the sample slides inward
    /// instead of shrinking. Adapted from upstream unchanged.
    static func cropLoupeSampleRect(around point: CGPoint,
                                    imageSize: CGSize,
                                    sideLength: CGFloat = 13,
                                    centredOnPixel: Bool = true) -> CGRect {
        let imageWidth = max(1, floor(imageSize.width))
        let imageHeight = max(1, floor(imageSize.height))
        var side = max(1, floor(sideLength))
        let isEven = side.truncatingRemainder(dividingBy: 2) == 0
        if centredOnPixel, isEven {
            side = max(1, side - 1)
        } else if !centredOnPixel, !isEven {
            side += 1
        }
        let width = min(side, imageWidth)
        let height = min(side, imageHeight)
        let x = centredOnPixel ? floor(point.x) - floor(width / 2) : floor(point.x - width / 2)
        let y = centredOnPixel ? floor(point.y) - floor(height / 2) : floor(point.y - height / 2)
        return CGRect(x: min(max(x, 0), imageWidth - width),
                      y: min(max(y, 0), imageHeight - height),
                      width: width,
                      height: height)
    }

    /// Annotations moved into a crop's coordinates. Marks past the crop stay
    /// in the list off the canvas, as upstream keeps them. From upstream's
    /// `applyCrop`, pulled out so the harness can check it.
    static func croppedAnnotations(_ annotations: [Annotation], by crop: CGRect) -> [Annotation] {
        annotations.map { annotation in
            var moved = annotation
            moved.rect = annotation.rect.offsetBy(dx: -crop.minX, dy: -crop.minY)
            moved.points = annotation.points.map { CGPoint(x: $0.x - crop.minX, y: $0.y - crop.minY) }
            return moved
        }
    }

    /// Recognized words moved into a crop's coordinates, keeping those still
    /// on it, so text stays selectable until the cropped capture is read.
    static func croppedWords(_ words: [RecognizedWord], by crop: CGRect) -> [RecognizedWord] {
        let bounds = CGRect(origin: .zero, size: crop.size)
        return words.compactMap { word in
            let moved = word.rect.offsetBy(dx: -crop.minX, dy: -crop.minY)
            guard moved.intersects(bounds) else { return nil }
            return RecognizedWord(text: word.text, rect: moved, line: word.line)
        }
    }

    // MARK: - Shape geometry

    /// Arrow head as two wing points for a line ending at `tip`. The head
    /// grows with the stroke so thick arrows stay proportionate.
    static func arrowHead(from tail: CGPoint,
                          to tip: CGPoint,
                          strokeWidth: CGFloat) -> (left: CGPoint, right: CGPoint) {
        let angle = atan2(tip.y - tail.y, tip.x - tail.x)
        let distance = hypot(tip.x - tail.x, tip.y - tail.y)
        let preferred = max(10, strokeWidth * 3.4)
        let proportional = max(distance * 0.72, min(strokeWidth * 1.2, distance))
        let length = min(preferred, proportional)
        let spread: CGFloat = .pi / 7
        let left = CGPoint(x: tip.x - length * cos(angle - spread),
                           y: tip.y - length * sin(angle - spread))
        let right = CGPoint(x: tip.x - length * cos(angle + spread),
                            y: tip.y - length * sin(angle + spread))
        return (left, right)
    }

    /// One continuous outline for the complete arrow. Keeping the shaft,
    /// round tail and head on the same contour avoids winding-rule cutouts
    /// where independently filled shapes would overlap.
    static func arrowSilhouette(from tail: CGPoint,
                                to tip: CGPoint,
                                strokeWidth: CGFloat) -> CGPath {
        let angle = atan2(tip.y - tail.y, tip.x - tail.x)
        let head = arrowHead(from: tail, to: tip, strokeWidth: strokeWidth)
        let baseMid = CGPoint(x: (head.left.x + head.right.x) / 2,
                              y: (head.left.y + head.right.y) / 2)
        let half = strokeWidth / 2
        let perpendicular = CGPoint(x: -sin(angle) * half, y: cos(angle) * half)

        let path = CGMutablePath()
        path.move(to: CGPoint(x: tail.x + perpendicular.x, y: tail.y + perpendicular.y))
        path.addLine(to: CGPoint(x: baseMid.x + perpendicular.x, y: baseMid.y + perpendicular.y))
        path.addLine(to: head.left)
        path.addLine(to: tip)
        path.addLine(to: head.right)
        path.addLine(to: CGPoint(x: baseMid.x - perpendicular.x, y: baseMid.y - perpendicular.y))
        path.addLine(to: CGPoint(x: tail.x - perpendicular.x, y: tail.y - perpendicular.y))
        path.addArc(center: tail, radius: half,
                    startAngle: angle - .pi / 2, endAngle: angle + .pi / 2, clockwise: true)
        path.closeSubpath()
        return path
    }

    /// Shaft and heads of a stroked arrow style as one path, so a single
    /// stroke draws the whole arrow and casts one shadow. The solid style is a
    /// filled silhouette rather than a stroke and answers nil.
    static func arrowStrokePath(from tail: CGPoint,
                                to tip: CGPoint,
                                strokeWidth: CGFloat,
                                style: ArrowStyleID,
                                seed: UInt64) -> CGPath? {
        let head = arrowHead(from: tail, to: tip, strokeWidth: strokeWidth)
        let path = CGMutablePath()
        switch style {
        case .filled:
            return nil
        case .outline:
            path.addLines(between: [tail, CGPoint(x: (head.left.x + head.right.x) / 2,
                                                  y: (head.left.y + head.right.y) / 2)])
            path.addLines(between: [head.left, tip, head.right])
            path.closeSubpath()
        case .open:
            path.addLines(between: [tail, tip])
            path.addLines(between: [head.left, tip, head.right])
        case .doubleEnded:
            let tailHead = arrowHead(from: tip, to: tail, strokeWidth: strokeWidth)
            path.addLines(between: [tail, tip])
            path.addLines(between: [head.left, tip, head.right])
            path.addLines(between: [tailHead.left, tail, tailHead.right])
        case .scribbly:
            let geometry = scribblyArrowGeometry(from: tail, to: tip, strokeWidth: strokeWidth, seed: seed)
            path.addLines(between: geometry.shaft)
            path.addLines(between: geometry.leftWing)
            path.addLines(between: geometry.rightWing)
        }
        return path
    }

    /// A lightly hand-drawn arrow made from stable, seeded wobble. The seed
    /// belongs to the annotation so a redraw or export keeps the same sketch,
    /// while each newly created scribbly arrow gets its own variation.
    struct ScribblyArrowGeometry: Equatable {
        let shaft: [CGPoint]
        let leftWing: [CGPoint]
        let rightWing: [CGPoint]
    }

    static func scribblyArrowGeometry(from tail: CGPoint,
                                      to tip: CGPoint,
                                      strokeWidth: CGFloat,
                                      seed: UInt64) -> ScribblyArrowGeometry {
        let dx = tip.x - tail.x
        let dy = tip.y - tail.y
        let distance = hypot(dx, dy)
        let angle = atan2(dy, dx)
        let direction = CGPoint(x: cos(angle), y: sin(angle))
        let perpendicular = CGPoint(x: -direction.y, y: direction.x)
        let head = arrowHead(from: tail, to: tip, strokeWidth: strokeWidth)
        let base = CGPoint(x: (head.left.x + head.right.x) / 2,
                           y: (head.left.y + head.right.y) / 2)
        var randomizer = ScribbleRandomizer(seed: seed)
        let shaftSegments = max(4, min(24, Int(ceil(distance / max(10, strokeWidth * 3)))))
        let shaftWobble = min(max(1, strokeWidth * 0.35), distance * 0.025)
        let shaft = roughPath(from: tail, to: base, segments: shaftSegments,
                              direction: direction, perpendicular: perpendicular,
                              wobble: shaftWobble, randomizer: &randomizer)
        let wingWobble = min(max(0.8, strokeWidth * 0.22), distance * 0.035)
        let leftWing = roughPath(from: head.left, to: tip, segments: 3,
                                 wobble: wingWobble, randomizer: &randomizer)
        let rightWing = roughPath(from: head.right, to: tip, segments: 3,
                                  wobble: wingWobble, randomizer: &randomizer)
        return ScribblyArrowGeometry(shaft: shaft, leftWing: leftWing, rightWing: rightWing)
    }

    private struct ScribbleRandomizer {
        private var state: UInt64

        init(seed: UInt64) {
            state = seed == 0 ? 0x9E3779B97F4A7C15 : seed
        }

        mutating func signedUnit() -> CGFloat {
            state = state &* 2862933555777941757 &+ 3037000493
            let normalized = Double(state) / Double(UInt64.max)
            return CGFloat(normalized * 2 - 1)
        }
    }

    private static func roughPath(from start: CGPoint,
                                  to end: CGPoint,
                                  segments: Int,
                                  direction: CGPoint? = nil,
                                  perpendicular: CGPoint? = nil,
                                  wobble: CGFloat,
                                  randomizer: inout ScribbleRandomizer) -> [CGPoint] {
        let lineX = end.x - start.x
        let lineY = end.y - start.y
        let length = hypot(lineX, lineY)
        let pathDirection = direction
            ?? CGPoint(x: lineX / max(length, 0.001), y: lineY / max(length, 0.001))
        let pathPerpendicular = perpendicular ?? CGPoint(x: -pathDirection.y, y: pathDirection.x)
        let count = max(1, segments)
        return (0...count).map { index in
            let progress = CGFloat(index) / CGFloat(count)
            guard index != 0, index != count else {
                return CGPoint(x: start.x + lineX * progress, y: start.y + lineY * progress)
            }
            let envelope = CGFloat(sin(Double.pi * Double(progress)))
            let sideOffset = randomizer.signedUnit() * wobble * envelope
            let forwardOffset = randomizer.signedUnit() * wobble * 0.28 * envelope
            return CGPoint(x: start.x + lineX * progress
                                + pathPerpendicular.x * sideOffset + pathDirection.x * forwardOffset,
                           y: start.y + lineY * progress
                                + pathPerpendicular.y * sideOffset + pathDirection.y * forwardOffset)
        }
    }

    /// Distance from a point to a segment, for hit-testing lines and arrows.
    static func distance(from point: CGPoint, toSegment start: CGPoint, _ end: CGPoint) -> CGFloat {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else {
            return hypot(point.x - start.x, point.y - start.y)
        }
        let t = max(0, min(1, ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared))
        let projection = CGPoint(x: start.x + t * dx, y: start.y + t * dy)
        return hypot(point.x - projection.x, point.y - projection.y)
    }

    /// The topmost annotation under `point`, in image pixels. Tolerances are
    /// in points times `scale`; `imageSize` sizes counter badges.
    /// `includeShapeInteriors: false` is the creation-tap variant: area
    /// shapes (boxes, ellipses, highlights, blurs) answer only near their
    /// edge, so a tap inside one still places new text, a sticker or a
    /// counter there. Adapted from the upstream editor model.
    static func hitTest(_ annotations: [Annotation], at point: CGPoint, scale: CGFloat,
                        imageSize: CGSize, includeShapeInteriors: Bool = true) -> UUID? {
        let tolerance = 10 * scale
        for annotation in annotations.reversed() {
            switch annotation.tool {
            case .arrow, .line:
                guard annotation.points.count >= 2 else { continue }
                if distance(from: point, toSegment: annotation.points[0], annotation.points[1])
                    <= tolerance + annotation.stroke.width * scale / 2 {
                    return annotation.id
                }
            case .freehand:
                for pathPoint in annotation.points
                where hypot(point.x - pathPoint.x, point.y - pathPoint.y) <= tolerance {
                    return annotation.id
                }
            case .counter:
                let radius = counterDiameter(for: annotation.renderReferenceSize ?? imageSize, scale: 1) / 2
                if hypot(point.x - annotation.rect.midX, point.y - annotation.rect.midY)
                    <= radius + 4 * scale {
                    return annotation.id
                }
            case .rect, .ellipse, .highlight, .pixelate, .redact, .spotlight:
                let outer = annotation.rect.insetBy(dx: -tolerance / 2, dy: -tolerance / 2)
                guard outer.contains(point) else { continue }
                if includeShapeInteriors { return annotation.id }
                // Edge ring only: a shape too small to have a meaningful
                // interior stays fully tappable.
                let inner = annotation.rect.insetBy(dx: tolerance, dy: tolerance)
                if inner.isEmpty || inner.width <= 0 || inner.height <= 0 || !inner.contains(point) {
                    return annotation.id
                }
            case .text, .sticker:
                if annotation.rect.insetBy(dx: -tolerance / 2, dy: -tolerance / 2).contains(point) {
                    return annotation.id
                }
            case .image:
                // Only a creation tap passes over a layer, to place text on it.
                if includeShapeInteriors,
                   annotation.rect.insetBy(dx: -tolerance / 2, dy: -tolerance / 2).contains(point) {
                    return annotation.id
                }
            case .select, .crop, .expandCanvas:
                continue
            }
        }
        return nil
    }

    // MARK: - Recognized text (selectable on the canvas)

    /// One word of recognized text, in image-pixel coordinates.
    struct RecognizedWord: Equatable {
        let text: String
        let rect: CGRect
        /// Line index, so copied selections keep their line breaks.
        let line: Int
    }

    /// Bands of the capture that text recognition reads one at a time, so a
    /// tall capture never becomes one huge request. Neighboring bands share
    /// some rows, because recognition misses a line cut by a band's edge, and
    /// each band owns the rows up to the middle of what it shares.
    /// `mergedRecognition` uses that seam to keep a word read twice once.
    static func recognitionTiles(width: Int, height: Int) -> [(rect: CGRect, ownedRows: Range<CGFloat>)] {
        let maximumTilePixels = 12_000_000
        let tileHeight = min(height, max(512, min(4096, maximumTilePixels / max(width, 1))))
        // Even, so the owned rows of two bands meet on the same row.
        let overlap = tileHeight < height ? min(256, tileHeight / 4) & ~1 : 0
        var tiles: [(rect: CGRect, ownedRows: Range<CGFloat>)] = []
        var tileY = 0
        while tileY < height {
            let bandHeight = min(tileHeight, height - tileY)
            let isLast = tileY + bandHeight >= height
            tiles.append((CGRect(x: 0, y: tileY, width: width, height: bandHeight),
                          CGFloat(tileY == 0 ? 0 : tileY + overlap / 2)
                            ..< CGFloat(isLast ? height : tileY + bandHeight - overlap / 2)))
            if isLast { break }
            tileY += bandHeight - overlap
        }
        return tiles
    }

    /// A word one recognition band read, in image pixels. `rect` is nil when
    /// recognition gave the word no box of its own; its line's box then
    /// stands in for it wherever text must be covered.
    struct BandWord: Equatable {
        let text: String
        let rect: CGRect?
        let lineBox: CGRect
        let line: Int
    }

    /// Joins what each band read into the capture's words, and the runs a
    /// later text-only redaction covers. `reads` follows `tiles`, and nil
    /// marks a band recognition could not read. A word both bands of a seam
    /// read is kept once, from the band that owns the middle of the two
    /// guesses; a word only one band read is always kept. Runs stay nil
    /// unless every band was read. Adapted from upstream unchanged.
    static func mergedRecognition(_ reads: [[BandWord]?],
                                  tiles: [(rect: CGRect, ownedRows: Range<CGFloat>)])
        -> (words: [RecognizedWord], runs: [CGRect]?) {
        let bands = zip(tiles, reads).map { (tile: $0.0, words: $0.1 ?? []) }
        var dropped = bands.map { [Bool](repeating: false, count: $0.words.count) }
        for upper in bands.indices.dropLast() {
            let lower = upper + 1
            let shared = bands[lower].tile.rect.minY..<bands[upper].tile.rect.maxY
            let seam = bands[upper].tile.ownedRows.upperBound
            func sharedWords(_ band: Int) -> [(index: Int, rect: CGRect)] {
                bands[band].words.indices.compactMap { index -> (index: Int, rect: CGRect)? in
                    guard let rect = bands[band].words[index].rect,
                          rect.maxY > shared.lowerBound, rect.minY < shared.upperBound
                    else { return nil }
                    return (index, rect)
                }
            }
            var unpaired = sharedWords(lower)
            for (index, rect) in sharedWords(upper) {
                let text = bands[upper].words[index].text
                // The other band's read of this word has the same text over
                // at least half its height, or a box covering at least half of
                // the smaller one. The same word on the next line is not it.
                let match = unpaired.indices.compactMap { candidate -> (candidate: Int, score: CGFloat)? in
                    let other = unpaired[candidate].rect
                    let common = rect.intersection(other)
                    guard !common.isNull, common.width > 0, common.height > 0 else { return nil }
                    let share = common.width * common.height
                        / min(rect.width * rect.height, other.width * other.height)
                    let sameText = bands[lower].words[unpaired[candidate].index].text == text
                        && common.height >= min(rect.height, other.height) / 2
                    guard sameText || share >= 0.5 else { return nil }
                    return (candidate, share + (sameText ? 1 : 0))
                }.max { $0.score < $1.score }
                guard let match else { continue }
                let other = unpaired.remove(at: match.candidate)
                if (rect.midY + other.rect.midY) / 2 < seam {
                    dropped[lower][other.index] = true
                } else {
                    dropped[upper][index] = true
                }
            }
        }
        // Kept words follow the band that owns each, so a word kept from
        // the other band of a seam still copies among the lines around it.
        var ownedWords = [[RecognizedWord]](repeating: [], count: bands.count)
        var covered: [RecognizedWord] = []
        for (index, band) in bands.enumerated() {
            // Both guesses of a word near a seam become runs: each band's
            // owned rows reach a quarter of the shared rows past the seam.
            let above = index > 0
                ? (bands[index - 1].tile.rect.maxY - band.tile.rect.minY) / 4 : 0
            let below = index + 1 < bands.count
                ? (band.tile.rect.maxY - bands[index + 1].tile.rect.minY) / 4 : 0
            let nearOwned = (band.tile.ownedRows.lowerBound - above)
                ..< (band.tile.ownedRows.upperBound + below)
            for (position, word) in band.words.enumerated() {
                guard let rect = word.rect else {
                    covered.append(RecognizedWord(text: word.text, rect: word.lineBox, line: word.line))
                    continue
                }
                let kept = !dropped[index][position]
                let recognized = RecognizedWord(text: word.text, rect: rect, line: word.line)
                if kept {
                    let owner = bands.firstIndex { $0.tile.ownedRows.contains(rect.midY) } ?? index
                    ownedWords[owner].append(recognized)
                }
                if kept || nearOwned.contains(rect.midY) { covered.append(recognized) }
            }
        }
        let everyBandRead = reads.count == tiles.count && !reads.contains { $0 == nil }
        return (ownedWords.flatMap { $0 }, everyBandRead ? textRuns(from: covered) : nil)
    }

    /// Recognized words joined into runs: neighbouring words on a line share
    /// one run, words far apart (table columns) stay apart, and each run is
    /// padded past the antialiased edges of its glyphs.
    static func textRuns(from words: [RecognizedWord]) -> [CGRect] {
        var runs: [CGRect] = []
        var current: (rect: CGRect, line: Int)?
        for word in words where word.rect.width > 0 && word.rect.height > 0 {
            if let run = current, run.line == word.line {
                let height = max(run.rect.height, word.rect.height)
                let gap = max(word.rect.minX - run.rect.maxX, run.rect.minX - word.rect.maxX, 0)
                let overlap = min(run.rect.maxY, word.rect.maxY) - max(run.rect.minY, word.rect.minY)
                if gap <= height * 1.5, overlap >= min(run.rect.height, word.rect.height) / 2 {
                    current = (run.rect.union(word.rect), run.line)
                    continue
                }
            }
            if let run = current { runs.append(paddedTextRun(run.rect)) }
            current = (word.rect, word.line)
        }
        if let run = current { runs.append(paddedTextRun(run.rect)) }
        return runs
    }

    private static func paddedTextRun(_ rect: CGRect) -> CGRect {
        rect.insetBy(dx: -max(1, rect.height * 0.6), dy: -max(1, rect.height * 0.3))
    }

    // MARK: - Redaction

    /// Pixelation block size in image pixels, scaled to the capture so small
    /// crops and full screens redact equally well. From the default level up
    /// the mosaic carries no legible detail; levels 1 and 2 are lighter and
    /// can leave large text readable.
    static func pixelBlockSize(for imageSize: CGSize,
                               level: Int = BlurStrength.defaultLevel) -> Int {
        let base = max(10, Int(min(imageSize.width, imageSize.height) / 55))
        return max(2, Int((CGFloat(base) * BlurStrength.blockFactor(for: level)).rounded()))
    }

    /// The blur levels the pixelate marks use. Only their sampled mosaics are
    /// kept; drawing expands each one to the capture size when needed.
    static func mosaicLevels(for annotations: [Annotation]) -> Set<Int> {
        blurLevels(for: annotations, style: .pixelate)
    }

    /// The levels the soft blur marks use, each kept as a small blurred sample
    /// the same way.
    static func softBlurLevels(for annotations: [Annotation]) -> Set<Int> {
        blurLevels(for: annotations, style: .blur)
    }

    private static func blurLevels(for annotations: [Annotation], style: BlurStyleID) -> Set<Int> {
        Set(annotations.filter { $0.tool == .pixelate && $0.blurStyle == style }.map(\.blurLevel))
    }

    /// Runs moved into a crop's coordinates, keeping those still on it, or
    /// nil when there were none to move.
    static func croppedRuns(_ runs: [CGRect]?, by crop: CGRect) -> [CGRect]? {
        let bounds = CGRect(origin: .zero, size: crop.size)
        return runs?.compactMap { run -> CGRect? in
            let moved = run.offsetBy(dx: -crop.minX, dy: -crop.minY)
            return moved.intersects(bounds) ? moved : nil
        }
    }

    /// The runs a text only blur area covers: every run that reaches into it.
    /// Nil runs mean recognition has not read the capture yet, and the whole
    /// area stands in for them, so an early export never leaves text readable.
    static func blurTextRuns(in rect: CGRect, from runs: [CGRect]?) -> [CGRect] {
        guard let runs else { return [rect] }
        return runs.filter { $0.intersects(rect) }
    }

    /// Words a selection drag touches, in reading order. A hairline drag
    /// still selects what it crosses.
    static func wordSelection(anchor: CGPoint, current: CGPoint, boxes: [CGRect]) -> [Int] {
        let selection = rect(from: anchor, to: current).insetBy(dx: -1, dy: -1)
        return boxes.indices.filter { boxes[$0].intersects(selection) }
    }

    /// Joins selected words with spaces inside a line and newlines between
    /// lines, whatever order the indexes arrive in.
    static func joinedWords(_ words: [RecognizedWord], selected: [Int]) -> String {
        let picked = selected.sorted().compactMap { words.indices.contains($0) ? words[$0] : nil }
        guard !picked.isEmpty else { return "" }
        var lines: [String] = []
        var currentLine = picked[0].line
        var currentWords: [String] = []
        for word in picked {
            if word.line != currentLine {
                lines.append(currentWords.joined(separator: " "))
                currentWords = []
                currentLine = word.line
            }
            currentWords.append(word.text)
        }
        lines.append(currentWords.joined(separator: " "))
        return lines.joined(separator: "\n")
    }
}
