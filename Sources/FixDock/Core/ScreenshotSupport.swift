// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import CoreGraphics
import Foundation

/// The modes the capture overlay offers. The digit is the key that picks it.
/// Recording has a slot now and a service in a later step.
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

    static func fileName(prefix: String, date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "\(prefix) \(formatter.string(from: date)).png"
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
        let values: [UInt8]

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
    }

    enum ScrollStep: Equatable {
        /// Nothing moved.
        case unchanged
        /// The content between the fixed bands moved up by `rows`. `footer`
        /// rows at the bottom stayed put (a fixed toolbar or footer), so the
        /// new rows sit just above them.
        case advanced(rows: Int, footer: Int)
        /// Something changed but no shift explains it (scrolled back, an
        /// animation, a new page). The frame is skipped.
        case unmatched
    }

    /// Most a row may differ, in grey levels, and still count as the same.
    static let scrollMatchTolerance = 6
    /// Least overlap between two frames, as a share of the frame height.
    static let scrollMinimumOverlap = 0.2
    /// Limits for one scrolling capture.
    static let scrollMaximumHeight = 30_000
    static let scrollMaximumFrames = 600
    static let scrollMaximumDuration: TimeInterval = 180

    /// Largest share of the frame a fixed header or footer may take.
    static let scrollMaximumFixedBand = 0.4

    /// How far the content moved between two frames of the same region.
    /// Rows that stayed put at the top (a sticky header) and bottom (a
    /// footer) are left out of the match; `knownFooter` keeps the footer
    /// found on the first move so every strip is cut the same way.
    static func scrollStep(previous: RowSignature, current: RowSignature,
                           knownFooter: Int? = nil) -> ScrollStep {
        let height = min(previous.rows, current.rows)
        guard height >= 8, previous.columns == current.columns else { return .unmatched }
        if error(previous, current, shift: 0, height: height, stride: 1) <= scrollMatchTolerance / 2 {
            return .unchanged
        }
        let cap = Int(Double(height) * scrollMaximumFixedBand)
        var header = 0
        while header < cap, previous.difference(row: header, current, row: header) <= scrollMatchTolerance {
            header += 1
        }
        var footer = 0
        while footer < cap,
              previous.difference(row: height - 1 - footer, current, row: height - 1 - footer)
                <= scrollMatchTolerance {
            footer += 1
        }
        footer = min(knownFooter ?? footer, height - header - 8)
        guard footer >= 0, height - header - footer >= 8,
              let shift = contentShift(previous.slice(header..<(height - footer)),
                                       current.slice(header..<(height - footer)))
        else { return .unmatched }
        return .advanced(rows: shift, footer: footer)
    }

    /// The shift of one band. Every shift is tried on a sample of rows,
    /// since text is too fine for a coarse grid of shifts; the few best are
    /// then checked on every row.
    private static func contentShift(_ previous: RowSignature, _ current: RowSignature) -> Int? {
        let height = min(previous.rows, current.rows)
        let minimumOverlap = max(4, Int(Double(height) * scrollMinimumOverlap))
        let maximumShift = height - minimumOverlap
        guard maximumShift >= 1 else { return nil }
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
        guard let best, best.error <= scrollMatchTolerance,
              mismatchedRows(previous, current, shift: best.shift, height: height)
                <= (height - best.shift) / 50
        else { return nil }
        // The match must be the only one: a flat page or repeating rows fit
        // several shifts, and guessing would duplicate or drop content.
        if let rival = candidates.first(where: { abs($0.shift - best.shift) > 2 }) {
            let rivalError = error(previous, current, shift: rival.shift, height: height, stride: 1)
            guard rivalError >= best.error + scrollMatchTolerance else { return nil }
        }
        return best.shift
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
