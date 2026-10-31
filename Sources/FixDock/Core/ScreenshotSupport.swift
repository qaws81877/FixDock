// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import CoreGraphics
import Foundation

/// The modes the capture overlay offers. The digit is the key that picks it.
/// Recording returns a region for `ScreenRecorderService` instead of an image.
enum ScreenCaptureTool: String, CaseIterable, Identifiable {
    case screenshot
    case recording

    var id: String { rawValue }

    var shortcutKey: String {
        switch self {
        case .screenshot: return "1"
        case .recording: return "2"
        }
    }

    var feature: AppFeature {
        switch self {
        case .screenshot: return .screenshot
        case .recording: return .screenRecorder
        }
    }

    var symbolName: String { feature.symbolName }

    /// Shown in the bar: the recorder only once it is installed.
    static func shown(isAvailable: (AppFeature) -> Bool = { $0.isAvailable }) -> [ScreenCaptureTool] {
        allCases.filter { isAvailable($0.feature) }
    }

    /// Whether this build can run the mode, not only show it.
    var isImplemented: Bool { feature.hasService }

    static func matchingShortcut(_ characters: String?) -> ScreenCaptureTool? {
        guard let characters else { return nil }
        return allCases.first { $0.shortcutKey == characters }
    }
}

/// Pure logic for the screenshot tool: file naming, geometry between Cocoa
/// screen points, window-server points and image pixels, window hit-testing,
/// remembered regions, colour text and scroll stitching. No AppKit, so a
/// harness compiles it on its own. Naming and geometry adapted from upstream.
enum ScreenshotSupport {

    // MARK: - Files

    /// `Prefix yyyy-MM-dd at HH.mm.ss.ext`, PNG unless the recorder asks
    /// for its movie extension.
    static func fileName(prefix: String, date: Date, fileExtension: String = "png") -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "\(prefix) \(formatter.string(from: date)).\(fileExtension)"
    }

    /// `name`, or `name (2)`, `name (3)`… when it is taken. `nil` when every
    /// candidate is taken, so the caller refuses instead of overwriting.
    static func uniqueFileName(_ name: String, exists: (String) -> Bool) -> String? {
        guard exists(name) else { return name }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        for index in 2...999 {
            let candidate = ext.isEmpty ? "\(base) (\(index))" : "\(base) (\(index)).\(ext)"
            if !exists(candidate) { return candidate }
        }
        return nil
    }

    /// Marks a saved capture the way macOS marks its own screenshots. Best
    /// effort. Adapted from upstream.
    static func markAsScreenCapture(_ url: URL) {
        guard let data = try? PropertyListSerialization.data(fromPropertyList: true,
                                                             format: .binary,
                                                             options: 0) else { return }
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return }
            _ = data.withUnsafeBytes {
                setxattr(path, "com.apple.metadata:kMDItemIsScreenCapture",
                         $0.baseAddress, data.count, 0, XATTR_NOFOLLOW)
            }
        }
    }

    // MARK: - Geometry

    /// Cocoa screen coordinates have their origin at the bottom left of the
    /// main display; the window server's at its top left. The flip is its
    /// own inverse.
    static func flipped(_ rect: CGRect, mainScreenHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: mainScreenHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// A rect in a display's local points (top-left origin) as pixels of an
    /// image of that display, snapped outward to whole pixels and kept
    /// inside the image.
    static func pixelRect(_ localPoints: CGRect, scale: CGFloat, imageSize: CGSize) -> CGRect {
        let scaled = CGRect(x: localPoints.minX * scale, y: localPoints.minY * scale,
                            width: localPoints.width * scale, height: localPoints.height * scale)
        return clamp(scaled.integral, to: CGRect(origin: .zero, size: imageSize))
    }

    static func clamp(_ rect: CGRect, to bounds: CGRect) -> CGRect {
        let clipped = rect.standardized.intersection(bounds)
        return clipped.isNull ? .zero : clipped
    }

    /// A drag from `start` to `end` as a rect, at least zero sized.
    static func rect(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
               width: abs(end.x - start.x), height: abs(end.y - start.y))
    }

    /// A drag shorter than this, in points, is a click.
    static let clickTolerance: CGFloat = 4

    static func isClick(from start: CGPoint, to end: CGPoint) -> Bool {
        abs(end.x - start.x) < clickTolerance && abs(end.y - start.y) < clickTolerance
    }

    // MARK: - Windows

    /// An on-screen window that a click can pick. `frame` is in window-server
    /// points (top-left origin of the main display).
    struct PickableWindow: Equatable {
        let id: CGWindowID
        let ownerPID: pid_t
        let frame: CGRect
    }

    /// Smallest window, in points per side, that can be picked.
    static let minimumPickableSide: CGFloat = 40

    /// Ordinary windows from a window-server list, front to back, leaving
    /// out FixDock's own, invisible and tiny ones.
    static func pickableWindows(in info: [[String: Any]], ownPID: pid_t) -> [PickableWindow] {
        info.compactMap { entry in
            guard let layer = entry[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = entry[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                  let id = (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let bounds = entry[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary)
            else { return nil }
            if let alpha = entry[kCGWindowAlpha as String] as? Double, alpha <= 0.01 { return nil }
            guard frame.width >= minimumPickableSide, frame.height >= minimumPickableSide
            else { return nil }
            return PickableWindow(id: id, ownerPID: pid, frame: frame)
        }
    }

    /// The front-most window containing `point` (window-server points).
    static func window(at point: CGPoint, in frontToBack: [PickableWindow]) -> PickableWindow? {
        frontToBack.first { $0.frame.contains(point) }
    }

    // MARK: - Remembered regions

    static func encodeRegion(_ rect: CGRect) -> String {
        [rect.minX, rect.minY, rect.width, rect.height]
            .map { String(format: "%.1f", Double($0)) }
            .joined(separator: ",")
    }

    static func decodeRegion(_ text: String) -> CGRect? {
        let parts = text.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 4, parts[2] >= 1, parts[3] >= 1 else { return nil }
        return CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
    }

    // MARK: - Colour

    static func hexColor(red: UInt8, green: UInt8, blue: UInt8) -> String {
        String(format: "#%02X%02X%02X", red, green, blue)
    }

    // MARK: - Preview

    /// Where the preview sits. `automatic` is beside the captured area.
    enum PreviewPosition: String, CaseIterable, Identifiable {
        case automatic
        case bottomRight
        case bottomLeft
        case topRight
        case topLeft

        var id: String { rawValue }
    }

    /// Seconds before an untouched preview closes; 0 keeps it open.
    static let previewCloseChoices = [0, 5, 10, 30]

    /// The preview's frame in Cocoa screen points. A corner sits inside the
    /// visible frame; automatic sits beside the captured area, else beside
    /// the pointer. Adapted from upstream.
    static func previewFrame(size: CGSize, anchor: CGRect?, pointer: CGPoint,
                             visibleFrame: CGRect, position: PreviewPosition) -> CGRect {
        let inset: CGFloat = 16
        let usable = visibleFrame.insetBy(dx: inset, dy: inset)
        let right = max(usable.minX, usable.maxX - size.width)
        let top = max(usable.minY, usable.maxY - size.height)
        switch position {
        case .bottomRight: return CGRect(origin: CGPoint(x: right, y: usable.minY), size: size)
        case .bottomLeft: return CGRect(origin: CGPoint(x: usable.minX, y: usable.minY), size: size)
        case .topRight: return CGRect(origin: CGPoint(x: right, y: top), size: size)
        case .topLeft: return CGRect(origin: CGPoint(x: usable.minX, y: top), size: size)
        case .automatic:
            break
        }
        let area = anchor ?? CGRect(origin: pointer, size: .zero)
        let gap: CGFloat = 14
        var x = area.maxX + gap
        if x + size.width > usable.maxX { x = area.minX - size.width - gap }
        if x < usable.minX || x + size.width > usable.maxX { x = pointer.x + gap }
        var y = area.midY - size.height / 2
        if y < usable.minY || y + size.height > usable.maxY {
            let below = area.minY - size.height - gap
            let above = area.maxY + gap
            if below >= usable.minY {
                y = below
            } else if above + size.height <= usable.maxY {
                y = above
            } else {
                y = pointer.y - size.height / 2
            }
        }
        x = min(max(x, usable.minX), right)
        y = min(max(y, usable.minY), top)
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    // MARK: - Recognized text and codes

    /// One recognized line or code with its normalized position (bottom-left
    /// origin, as Vision reports it).
    struct RecognizedItem {
        let text: String
        let x: Double
        let y: Double
    }

    /// Lines in reading order: top to bottom, left to right within a visual
    /// row. Empty lines are dropped. Adapted from upstream.
    static func joinedReadingOrder(_ items: [RecognizedItem]) -> String {
        items
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted {
                // Vision's y grows upward; rows are bucketed so small
                // baseline wobbles do not shuffle words of one line.
                let rowA = (1 - $0.y) * 50
                let rowB = (1 - $1.y) * 50
                if abs(rowA - rowB) >= 0.5 { return rowA < rowB }
                return $0.x < $1.x
            }
            .map(\.text)
            .joined(separator: "\n")
    }

    /// A scanned payload as a web link for the Open button: http and https
    /// only, so a code can never launch another URL scheme. Adapted from
    /// upstream.
    static func openableURL(from payload: String) -> URL? {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: { $0.isWhitespace }),
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty
        else { return nil }
        return url
    }

    // MARK: - Scrolling capture

    /// One frame reduced to a grey value per sampled column for every pixel
    /// row, top to bottom. Comparing these finds how far the content moved.
    struct RowSignature {
        let columns: Int
        /// `rows * columns` grey values, row after row.
        private(set) var values: [UInt8]

        var rows: Int { columns > 0 ? values.count / columns : 0 }

        /// Mean absolute difference between row `a` here and row `b` of `other`.
        func difference(row a: Int, _ other: RowSignature, row b: Int) -> Int {
            var total = 0
            let lhs = a * columns
            let rhs = b * other.columns
            for column in 0..<columns {
                total += abs(Int(values[lhs + column]) - Int(other.values[rhs + column]))
            }
            return total / max(1, columns)
        }

        /// The rows `range` as a signature of their own.
        func slice(_ range: Range<Int>) -> RowSignature {
            RowSignature(columns: columns, values: Array(values[(range.lowerBound * columns)..<(range.upperBound * columns)]))
        }

        /// Rows `range` of `other` added at the bottom.
        mutating func append(rows range: Range<Int>, of other: RowSignature) {
            values += other.values[(range.lowerBound * other.columns)..<(range.upperBound * other.columns)]
        }

        mutating func removeLast(rows count: Int) {
            values.removeLast(min(values.count, max(0, count) * columns))
        }

        /// Only the sampled columns `range` of every row.
        func keeping(columns range: Range<Int>) -> RowSignature {
            guard range != 0..<columns else { return self }
            var kept: [UInt8] = []
            kept.reserveCapacity(rows * range.count)
            for row in 0..<rows {
                kept += values[(row * columns + range.lowerBound)..<(row * columns + range.upperBound)]
            }
            return RowSignature(columns: range.count, values: kept)
        }
    }

    /// Sampled columns at the left and right edge that stayed put while the
    /// content scrolled: a sidebar or a fixed panel. They are left out of the
    /// match, and below the first frame the output shows them blank, since
    /// stitching them would repeat the sidebar down the image.
    struct FixedSides: Equatable {
        var left: Int
        var right: Int

        static let none = FixedSides(left: 0, right: 0)

        /// The columns between the sides, out of `columns`.
        func content(of columns: Int) -> Range<Int> { left..<max(left, columns - right) }

        /// The sides in image pixels. Only whole sampled columns count, so a
        /// column the sidebar shares with content is never blanked.
        func pixels(columns: Int, width: Int) -> (left: Int, right: Int) {
            guard columns > 0 else { return (0, 0) }
            return (left * width / columns, right * width / columns)
        }

        /// Sides fixed in both this step and `other`.
        func common(with other: FixedSides) -> FixedSides {
            FixedSides(left: min(left, other.left), right: min(right, other.right))
        }
    }

    enum ScrollStep: Equatable {
        /// Nothing moved.
        case unchanged
        /// The content between the fixed bands moved up by `rows`. `footer`
        /// rows at the bottom stayed put (a fixed toolbar or footer), so the
        /// new rows sit just above them.
        case advanced(rows: Int, footer: Int, sides: FixedSides)
        /// Something changed but no shift explains it (scrolled back, an
        /// animation, a new page). The frame is skipped.
        case unmatched(ScrollSkip)
    }

    /// Why a frame was skipped, for the scrolling-capture log.
    enum ScrollSkip: String, CaseIterable, Error {
        /// The frames differ in size, or too few rows are left to compare.
        case tooSmall
        /// No shift fits: the content moved further than the overlap
        /// allows, moved up, or changed.
        case noShift
        /// The best shift fits on average but too many rows differ clearly.
        case scattered
        /// Another shift fits almost as well (a flat or repeating page).
        case ambiguous
    }

    /// Most a row may differ, in grey levels, and still count as the same.
    static let scrollMatchTolerance = 6
    /// Least overlap between two frames, as a share of the frame height.
    static let scrollMinimumOverlap = 0.2
    /// Limits for one scrolling capture.
    static let scrollMaximumHeight = 30_000
    static let scrollMaximumDuration: TimeInterval = 180

    /// Largest share of the frame a fixed header or footer may take, and of
    /// the width a fixed side may take.
    static let scrollMaximumFixedBand = 0.4
    /// Columns that must stay in the match after the fixed sides are cut.
    static let scrollMinimumContentColumns = 16

    /// The fixed sides between two frames: edge columns where nearly every
    /// row is the same in both.
    static func fixedSides(previous: RowSignature, current: RowSignature, height: Int) -> FixedSides {
        let columns = previous.columns
        guard columns == current.columns, height > 0 else { return .none }
        let allowedChanges = height / 50
        func isFixed(_ column: Int) -> Bool {
            var changes = 0
            for row in 0..<height {
                let a = Int(previous.values[row * columns + column])
                let b = Int(current.values[row * columns + column])
                if abs(a - b) > scrollMatchTolerance * 3 {
                    changes += 1
                    if changes > allowedChanges { return false }
                }
            }
            return true
        }
        let cap = Int(Double(columns) * scrollMaximumFixedBand)
        var left = 0
        while left < cap, isFixed(left) { left += 1 }
        var right = 0
        while right < cap, isFixed(columns - 1 - right) { right += 1 }
        guard columns - left - right >= scrollMinimumContentColumns else { return .none }
        return FixedSides(left: left, right: right)
    }

    /// How far the content moved between two frames of the same region.
    /// Rows that stayed put at the top (a sticky header) and bottom (a
    /// footer) are left out of the match; `knownFooter` keeps the footer
    /// found on the first move so every strip is cut the same way.
    static func scrollStep(previous: RowSignature, current: RowSignature,
                           knownFooter: Int? = nil) -> ScrollStep {
        let height = min(previous.rows, current.rows)
        guard height >= 8, previous.columns == current.columns else { return .unmatched(.tooSmall) }
        if error(previous, current, shift: 0, height: height, stride: 1) <= scrollMatchTolerance / 2 {
            return .unchanged
        }
        let sides = fixedSides(previous: previous, current: current, height: height)
        let before = previous.keeping(columns: sides.content(of: previous.columns))
        let after = current.keeping(columns: sides.content(of: current.columns))
        let cap = Int(Double(height) * scrollMaximumFixedBand)
        var header = 0
        while header < cap, before.difference(row: header, after, row: header) <= scrollMatchTolerance {
            header += 1
        }
        var footer = 0
        while footer < cap,
              before.difference(row: height - 1 - footer, after, row: height - 1 - footer)
                <= scrollMatchTolerance {
            footer += 1
        }
        footer = min(knownFooter ?? footer, height - header - 8)
        guard footer >= 0, height - header - footer >= 8 else { return .unmatched(.tooSmall) }
        switch contentShift(before.slice(header..<(height - footer)),
                            after.slice(header..<(height - footer))) {
        case .success(let shift): return .advanced(rows: shift, footer: footer, sides: sides)
        case .failure(let skip): return .unmatched(skip)
        }
    }

    /// Whether an unmatched frame shows only content already in the stitched
    /// image (`stitched`, every row added so far): the person scrolled back
    /// up, however far, or something animated in place. Matching then stays
    /// anchored to the last stitched frame, so scrolling down again adds
    /// nothing twice. Any other unmatched frame (a jump too far down) becomes
    /// the new anchor, leaving a gap. Rows that stayed put against `anchor`
    /// at the top, and the known footer, are left out of the search.
    static func isAlreadyStitched(current fullCurrent: RowSignature, anchor fullAnchor: RowSignature,
                                  stitched fullStitched: RowSignature, knownFooter: Int?,
                                  sides: FixedSides = .none) -> Bool {
        guard fullCurrent.columns == fullAnchor.columns, fullCurrent.columns == fullStitched.columns
        else { return false }
        let kept = sides.content(of: fullCurrent.columns)
        let current = fullCurrent.keeping(columns: kept)
        let anchor = fullAnchor.keeping(columns: kept)
        let stitched = fullStitched.keeping(columns: kept)
        let height = min(current.rows, anchor.rows)
        guard height >= 8 else { return false }
        let cap = Int(Double(height) * scrollMaximumFixedBand)
        var header = 0
        while header < cap, anchor.difference(row: header, current, row: header) <= scrollMatchTolerance {
            header += 1
        }
        let footer = min(max(0, knownFooter ?? 0), cap)
        let band = header..<(height - footer)
        guard band.count >= 8, stitched.rows >= band.count else { return false }
        let rowStride = max(1, band.count / 160)
        let sampled = (band.count + rowStride - 1) / rowStride
        let allowedSampled = sampled / 50
        let allowed = band.count / 50
        // Most offsets fail within a few rows, so every offset is cheap to try.
        offsets: for offset in 0...(stitched.rows - band.count) {
            var misses = 0
            for row in Swift.stride(from: band.lowerBound, to: band.upperBound, by: rowStride)
            where current.difference(row: row, stitched, row: offset + row - header) > scrollMatchTolerance * 3 {
                misses += 1
                if misses > allowedSampled { continue offsets }
            }
            var total = 0
            misses = 0
            for row in band {
                let value = current.difference(row: row, stitched, row: offset + row - header)
                total += value
                if value > scrollMatchTolerance * 3 {
                    misses += 1
                    if misses > allowed { continue offsets }
                }
            }
            if total / band.count <= scrollMatchTolerance { return true }
        }
        return false
    }

    /// The shift of one band. Every shift is tried on a sample of rows,
    /// since text is too fine for a coarse grid of shifts; the few best are
    /// then checked on every row.
    private static func contentShift(_ previous: RowSignature,
                                     _ current: RowSignature) -> Result<Int, ScrollSkip> {
        let height = min(previous.rows, current.rows)
        let minimumOverlap = max(4, Int(Double(height) * scrollMinimumOverlap))
        let maximumShift = height - minimumOverlap
        guard maximumShift >= 1 else { return .failure(.tooSmall) }
        let rowStride = max(1, height / 160)
        var candidates: [(shift: Int, error: Int)] = []
        for shift in 1...maximumShift {
            let value = error(previous, current, shift: shift, height: height, stride: rowStride)
            candidates.append((shift, value))
        }
        candidates.sort { $0.error != $1.error ? $0.error < $1.error : $0.shift < $1.shift }
        var best: (shift: Int, error: Int)?
        for candidate in candidates.prefix(4) {
            let value = error(previous, current, shift: candidate.shift, height: height, stride: 1)
            if best == nil || value < best!.error { best = (candidate.shift, value) }
        }
        guard let best, best.error <= scrollMatchTolerance else { return .failure(.noShift) }
        guard mismatchedRows(previous, current, shift: best.shift, height: height)
                <= (height - best.shift) / 50
        else { return .failure(.scattered) }
        // The match must be the only one: a flat page or repeating rows fit
        // several shifts, and guessing would duplicate or drop content.
        if let rival = candidates.first(where: { abs($0.shift - best.shift) > 2 }) {
            let rivalError = error(previous, current, shift: rival.shift, height: height, stride: 1)
            guard rivalError >= best.error + scrollMatchTolerance else { return .failure(.ambiguous) }
        }
        return .success(best.shift)
    }

    /// Rows of the overlap that differ clearly, at `shift`.
    private static func mismatchedRows(_ previous: RowSignature, _ current: RowSignature,
                                       shift: Int, height: Int) -> Int {
        var count = 0
        for row in 0..<(height - shift)
        where previous.difference(row: row + shift, current, row: row) > scrollMatchTolerance * 3 {
            count += 1
        }
        return count
    }

    /// Mean row difference when `current` is `previous` moved up by `shift`.
    private static func error(_ previous: RowSignature, _ current: RowSignature,
                              shift: Int, height: Int, stride step: Int) -> Int {
        let overlap = height - shift
        var total = 0
        var count = 0
        for row in Swift.stride(from: 0, to: overlap, by: step) {
            total += previous.difference(row: row + shift, current, row: row)
            count += 1
        }
        return count > 0 ? total / count : Int.max
    }
}

// MARK: - Loupe

extension ScreenshotSupport {
    /// Z steps forward through the cases, Shift-Z backward. Each step carries
    /// its own numbers, so the overlay never branches on size itself.
    enum LoupeMode: String, CaseIterable {
        case off
        case regular
        case large

        var next: LoupeMode {
            switch self {
            case .off: return .regular
            case .regular: return .large
            case .large: return .off
            }
        }

        var previous: LoupeMode {
            switch self {
            case .off: return .large
            case .regular: return .off
            case .large: return .regular
            }
        }

        var isOn: Bool { self != .off }

        /// Device pixels on each side of the centre pixel.
        var radius: Int {
            switch self {
            case .off: return 0
            case .regular: return 7
            case .large: return 10
            }
        }

        /// Points per device pixel, so the loupe looks the same at any scale.
        var cell: CGFloat {
            switch self {
            case .off: return 0
            case .regular: return 9
            case .large: return 12
            }
        }

        /// Regular cells are too small for lines between them.
        var showsGrid: Bool { self == .large }

        var side: CGFloat { CGFloat(radius * 2 + 1) * cell }
    }

    struct PixelColor: Equatable {
        let red, green, blue: UInt8
    }

    /// How the loupe label shows a colour and C copies it.
    enum ColorFormat: String, CaseIterable, Identifiable {
        case hex
        case hexPlain
        case rgb
        case hsl

        static let `default` = ColorFormat.hex

        var id: String { rawValue }

        static func stored(_ raw: String?) -> ColorFormat {
            raw.flatMap(ColorFormat.init(rawValue:)) ?? .default
        }

        func text(_ color: PixelColor) -> String {
            switch self {
            case .hex:
                return ScreenshotSupport.hexColor(red: color.red, green: color.green, blue: color.blue)
            case .hexPlain:
                return String(ScreenshotSupport.hexColor(red: color.red, green: color.green, blue: color.blue)
                    .dropFirst())
            case .rgb:
                return "rgb(\(color.red), \(color.green), \(color.blue))"
            case .hsl:
                let parts = ScreenshotSupport.hsl(color)
                return "hsl(\(parts.hue), \(parts.saturation)%, \(parts.lightness)%)"
            }
        }
    }

    /// Whole degrees and percents, each rounded on its own; a grey has hue 0
    /// and saturation 0, and a hue that rounds to 360 is 0.
    static func hsl(_ color: PixelColor) -> (hue: Int, saturation: Int, lightness: Int) {
        let r = Double(color.red) / 255
        let g = Double(color.green) / 255
        let b = Double(color.blue) / 255
        let high = max(r, g, b)
        let low = min(r, g, b)
        let delta = high - low
        let lightness = (high + low) / 2
        let lightnessPercent = Int((lightness * 100).rounded())
        guard delta > 0 else { return (0, 0, lightnessPercent) }
        let saturation = delta / (1 - abs(2 * lightness - 1))
        var hue: Double
        if high == r {
            hue = (g - b) / delta
        } else if high == g {
            hue = (b - r) / delta + 2
        } else {
            hue = (r - g) / delta + 4
        }
        hue *= 60
        if hue < 0 { hue += 360 }
        return (Int(hue.rounded()) % 360, Int((saturation * 100).rounded()), lightnessPercent)
    }

    /// The overlay's stand-in for the cursor: one device pixel wide lines,
    /// edge to edge, through the device pixel under the pointer (flipped view).
    static func crosshairLines(pointer: CGPoint, pixelScale: CGFloat,
                               bounds: CGRect) -> (vertical: CGRect, horizontal: CGRect) {
        let thickness = 1 / pixelScale
        let x = (pointer.x * pixelScale).rounded(.down) / pixelScale
        let y = (pointer.y * pixelScale).rounded(.down) / pixelScale
        return (CGRect(x: x, y: bounds.minY, width: thickness, height: bounds.height),
                CGRect(x: bounds.minX, y: y, width: bounds.width, height: thickness))
    }

    /// Gap plus box height of the label under the loupe.
    static let loupeLabelHeight: CGFloat = 22

    /// Where the loupe square goes for a pointer in the overlay view (flipped,
    /// y down): 24 pt right and below, on the other side near the right or
    /// bottom edge, then kept inside `bounds` with room for the label below.
    /// Drawing and any partial redraw use this one rect.
    static func loupeFrame(pointer: CGPoint, side: CGFloat, labelHeight: CGFloat,
                           bounds: CGRect) -> CGRect {
        let gap: CGFloat = 24
        var x = pointer.x + gap
        if x + side > bounds.maxX { x = pointer.x - gap - side }
        var y = pointer.y + gap
        if y + side + labelHeight > bounds.maxY { y = pointer.y - gap - side - labelHeight }
        x = max(bounds.minX, min(x, bounds.maxX - side))
        y = max(bounds.minY, min(y, bounds.maxY - side - labelHeight))
        return CGRect(x: x, y: y, width: side, height: side)
    }

    /// The label box under `loupe`: as wide as the loupe or the text plus its
    /// padding, whichever is wider, shifted left to stay inside `bounds`.
    static func loupeLabelFrame(loupe: CGRect, textWidth: CGFloat, bounds: CGRect) -> CGRect {
        let gap: CGFloat = 4
        let width = max(loupe.width, (textWidth + 12).rounded(.up))
        let x = max(bounds.minX, min(loupe.minX, bounds.maxX - width))
        return CGRect(x: x, y: loupe.maxY + gap, width: width, height: loupeLabelHeight - gap)
    }
}
