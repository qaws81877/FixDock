// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import CoreGraphics
import Foundation

/// Snapping a selection corner to nearby horizontal and vertical lines of the
/// frozen display image (window borders, separators, table rules). Pure: the
/// overlay builds a grid once per display and asks for each pointer position.
/// New in FixDock.
enum ScreenshotLineSnap {
    /// How far, in points, a corner may jump to reach a line.
    static let searchRadius = 6
    /// Rows (or columns) on each side of the pointer that are looked at along
    /// a candidate line.
    static let span = 24
    /// A line must keep its step for this many points in a row inside the
    /// span, so body-text stems and noise do not snap but a window corner
    /// up to `searchRadius` away (its line runs only to one side of the
    /// pointer) still does. Stems of large bold headings can pass.
    static let minimumRun = 18
    /// Smallest luma difference across the line, out of 255. A one-pixel
    /// separator (10% black on white, or 10% white on dark grey) averaged
    /// into a point cell on a 2x display still clears it.
    static let minimumStep = 10

    /// 8-bit luma at one cell per point, top row first like the overlay view.
    struct LumaGrid {
        let width: Int
        let height: Int
        let bytes: [UInt8]

        /// `image` drawn at `width` × `height` cells, averaged down from its
        /// pixels; nil for an empty size or a failed context.
        init?(image: CGImage, width: Int, height: Int) {
            guard width > 1, height > 1 else { return nil }
            var bytes = [UInt8](repeating: 0, count: width * height)
            let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                              bitsPerComponent: 8, bytesPerRow: width,
                                              space: CGColorSpaceCreateDeviceGray(),
                                              bitmapInfo: CGImageAlphaInfo.none.rawValue)
                else { return false }
                // Not `.none`: a one-pixel hairline on a 2x display must
                // survive the halving as a step, not be skipped.
                context.interpolationQuality = .medium
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            guard drawn else { return nil }
            self.init(width: width, height: height, bytes: bytes)
        }

        init(width: Int, height: Int, bytes: [UInt8]) {
            precondition(bytes.count == width * height)
            self.width = width
            self.height = height
            self.bytes = bytes
        }

        func luma(_ x: Int, _ y: Int) -> Int {
            Int(bytes[y * width + x])
        }
    }

    /// The nearest line on each axis, as a boundary between two cells: `x` is
    /// a vertical line between columns `x - 1` and `x`, `y` a horizontal line
    /// between rows `y - 1` and `y`. Grid cells are view points, so a
    /// boundary is a point coordinate as is. Nil on an axis with no line
    /// within `searchRadius`.
    struct Snap: Equatable {
        var x: Int?
        var y: Int?
    }

    static func snap(_ point: CGPoint, in grid: LumaGrid) -> Snap {
        let column = Int(point.x.rounded(.down))
        let row = Int(point.y.rounded(.down))
        let x = nearestLine(near: point.x, along: row, boundaryLimit: grid.width, alongLimit: grid.height) {
            grid.luma($0, $1) - grid.luma($0 - 1, $1)
        }
        let y = nearestLine(near: point.y, along: column, boundaryLimit: grid.height, alongLimit: grid.width) {
            grid.luma($1, $0) - grid.luma($1, $0 - 1)
        }
        return Snap(x: x, y: y)
    }

    /// `step(boundary, along)` is the luma change across `boundary` at
    /// position `along` on the line. Ties go to the longer line.
    private static func nearestLine(near position: CGFloat, along center: Int,
                                    boundaryLimit: Int, alongLimit: Int,
                                    step: (Int, Int) -> Int) -> Int? {
        let nearest = Int(position.rounded())
        let first = max(1, nearest - searchRadius)
        let last = min(boundaryLimit - 1, nearest + searchRadius)
        let alongFirst = max(0, center - span)
        let alongLast = min(alongLimit - 1, center + span)
        guard first <= last, alongFirst <= alongLast else { return nil }
        var best: (boundary: Int, distance: CGFloat, run: Int)?
        for boundary in first...last {
            let distance = abs(CGFloat(boundary) - position)
            guard distance <= CGFloat(searchRadius) else { continue }
            let run = longestRun(alongFirst...alongLast) { step(boundary, $0) }
            guard run >= minimumRun else { continue }
            if let current = best,
               current.distance < distance || (current.distance == distance && current.run >= run) {
                continue
            }
            best = (boundary, distance, run)
        }
        return best?.boundary
    }

    /// The longest stretch where the step clears `minimumStep` with one sign.
    private static func longestRun(_ range: ClosedRange<Int>, step: (Int) -> Int) -> Int {
        var longest = 0
        var run = 0
        var sign = 0
        for position in range {
            let value = step(position)
            let valueSign = abs(value) >= minimumStep ? (value > 0 ? 1 : -1) : 0
            if valueSign == 0 {
                run = 0
            } else if valueSign == sign {
                run += 1
            } else {
                run = 1
            }
            sign = valueSign
            longest = max(longest, run)
        }
        return longest
    }
}
