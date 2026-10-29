// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Pure logic for the screenshot editor: window sizing, key rules, the
/// annotation model, selection handles, shape geometry and hit testing, zoom,
/// the undo history and recognized words. No AppKit, so a harness compiles it
/// on its own. Adapted from the upstream editor support, trimmed to the
/// stage A tools; the shapes stay upstream's so later tools slot in.
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
    /// Return that chose Edit in the preview would copy the capture and close
    /// the editor a moment later.
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
        // Case order is the rail order and therefore the mapping for keys 1
        // through 9: upstream's default order, filtered to these tools.
        case select, arrow, text, rect, freehand, line, ellipse

        static var editorTools: [Tool] { allCases }

        static let shortcutLimit = 9

        /// Tools that create an annotation by dragging a rectangle.
        var dragsRect: Bool {
            switch self {
            case .rect, .ellipse: return true
            case .select, .arrow, .text, .freehand, .line: return false
            }
        }

        /// Existing rectangular marks with visible resize grips.
        var resizesWithHandles: Bool { dragsRect }

        /// The tool a new editor opens with. Select acts on what is already
        /// there, so it falls back to arrow and the editor opens ready to draw.
        static func startingTool(remembered raw: String?) -> Tool {
            let tool = Tool(rawValue: raw ?? "") ?? .arrow
            return tool == .select ? .arrow : tool
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

    /// Only the filled arrow so far; the other upstream styles come later.
    enum ArrowStyleID: String, CaseIterable {
        case filled

        static func sanitized(_ raw: String?) -> ArrowStyleID {
            ArrowStyleID(rawValue: raw ?? "") ?? .filled
        }
    }

    /// One annotation on the canvas. Geometry lives in image-pixel
    /// coordinates (top-left origin), so export is resolution-exact and the
    /// view only scales for display.
    struct Annotation: Identifiable, Equatable {
        let id: UUID
        var tool: Tool
        var rect: CGRect
        var points: [CGPoint]
        var text: String
        var color: ColorID
        var stroke: StrokeID
        var textSize: Int
        var arrowStyle: ArrowStyleID

        init(id: UUID = UUID(),
             tool: Tool,
             rect: CGRect = .zero,
             points: [CGPoint] = [],
             text: String = "",
             color: ColorID = .red,
             stroke: StrokeID = .medium,
             textSize: Int = ScreenshotSupport.defaultTextSize,
             arrowStyle: ArrowStyleID = .filled) {
            self.id = id
            self.tool = tool
            self.rect = rect
            self.points = points
            self.text = text
            self.color = color
            self.stroke = stroke
            self.textSize = textSize
            self.arrowStyle = arrowStyle
        }
    }

    /// The style values the editor controls should show for a picked mark.
    struct SelectionStyle: Equatable {
        let color: ColorID?
        let stroke: StrokeID?
        let arrowStyle: ArrowStyleID?
        var textSize: Int? = nil
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
        case .select:
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
    /// in points times `scale`. `includeShapeInteriors: false` is the
    /// creation-tap variant: boxes and ellipses answer only near their edge,
    /// so a tap inside one still places new text there. Adapted from the
    /// upstream editor model.
    static func hitTest(_ annotations: [Annotation], at point: CGPoint, scale: CGFloat,
                        includeShapeInteriors: Bool = true) -> UUID? {
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
            case .rect, .ellipse:
                let outer = annotation.rect.insetBy(dx: -tolerance / 2, dy: -tolerance / 2)
                guard outer.contains(point) else { continue }
                if includeShapeInteriors { return annotation.id }
                // Edge ring only: a shape too small to have a meaningful
                // interior stays fully tappable.
                let inner = annotation.rect.insetBy(dx: tolerance, dy: tolerance)
                if inner.isEmpty || inner.width <= 0 || inner.height <= 0 || !inner.contains(point) {
                    return annotation.id
                }
            case .text:
                if annotation.rect.insetBy(dx: -tolerance / 2, dy: -tolerance / 2).contains(point) {
                    return annotation.id
                }
            case .select:
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
