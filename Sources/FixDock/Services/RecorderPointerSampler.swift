// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import AppKit
import QuartzCore

/// Records where the pointer went while a recording runs.
///
/// A fixed-cadence sampler on its own thread rather than an event tap, for
/// three reasons: it needs no permission at all, it costs about a hundred
/// nanoseconds per sample, and a filter that runs offline wants its input on
/// an even grid anyway. The presses come from a mouse-only global monitor,
/// which is exact and, unlike key events, ungated.
///
/// Nothing here exists between recordings: the thread, the monitor and the
/// buffer are all created in `start()` and gone after `stop()`.
///
/// Ported from upstream. FixDock does not use upstream's private window
/// server cursor reads (`RecorderCursorCatalog`): pointer shapes come from
/// `RecorderCursorShapes` (public `NSCursor`), the system pointer scale is
/// taken as 1, and the pointer counts as visible in every sample.
final class RecorderPointerSampler {

    private let region: RecorderSupport.Region
    private let displayBounds: CGRect
    private let pauseClock: RecorderPauseClock

    private var thread: Thread?
    private var clickMonitor: Any?
    private let lock = NSLock()
    private var samples: [RecorderMotion.Sample] = []
    /// The pointer shape in effect for each sample, kept alongside rather than
    /// inside it: the identity only becomes an index once the recording is
    /// over and every shape that appeared is known.
    private var identities: [UInt64] = []
    private var clicks: [RecorderMotion.Click] = []
    private let cursors = RecorderCursorShapes()
    private var running = false
    private var generation = 0
    private let displayScale: Double

    /// 125 Hz: comfortably above any mouse report rate we care about, and
    /// still around fourteen microseconds of work per second of recording.
    private static let sampleRate: Double = 125

    init(region: RecorderSupport.Region, pauseClock: RecorderPauseClock) {
        self.region = region
        self.pauseClock = pauseClock
        displayBounds = CGDisplayBounds(region.displayID)
        displayScale = region.scale > 0 ? region.scale : 2
    }

    // MARK: - Lifecycle

    /// Main thread: the click monitor and the shape reader belong there.
    func start() {
        guard thread == nil else { return }
        let generation = lock.withLock { () -> Int in
            self.generation += 1
            running = true
            samples.removeAll(keepingCapacity: true)
            samples.reserveCapacity(Int(Self.sampleRate) * 60)
            identities.removeAll(keepingCapacity: true)
            identities.reserveCapacity(Int(Self.sampleRate) * 60)
            clicks.removeAll(keepingCapacity: true)
            return self.generation
        }

        cursors.start()

        // Mouse-only monitors need no Accessibility grant, and a press is
        // never coalesced the way a move is, so these timestamps are exact.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp]
        ) { [weak self] event in
            self?.record(event, generation: generation)
        }

        let thread = Thread { [weak self] in
            self?.loop(generation: generation)
        }
        thread.qualityOfService = .userInteractive
        thread.name = "io.github.qaws81877.fixdock.recorder.pointer"
        self.thread = thread
        thread.start()
    }

    /// Stops sampling and hands over what was collected. Main thread.
    func stop() -> RecorderPointerTrack {
        thread = nil
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
            self.clickMonitor = nil
        }
        cursors.stop()
        return lock.withLock {
            running = false
            let track = Self.pack(samples: samples,
                                  identities: identities,
                                  clicks: clicks,
                                  shapes: cursors.collected(),
                                  displayScale: displayScale)
            samples.removeAll()
            identities.removeAll()
            clicks.removeAll()
            return track
        }
    }

    // MARK: - Sampling

    private func loop(generation: Int) {
        let interval = 1.0 / Self.sampleRate
        while lock.withLock({ running && self.generation == generation }) {
            let now = CACurrentMediaTime()
            if let time = pauseClock.eventTime(now),
               let point = normalizedPointerLocation() {
                let identity = cursors.currentIdentity
                lock.withLock {
                    guard running, self.generation == generation else { return }
                    samples.append(RecorderMotion.Sample(time: time, point: point))
                    identities.append(identity)
                }
            }
            let elapsed = CACurrentMediaTime() - now
            if elapsed < interval {
                Thread.sleep(forTimeInterval: interval - elapsed)
            }
        }
    }

    /// The pointer inside the recorded area, 0...1 with a top-left origin.
    /// `CGEvent(source: nil)?.location` is already in the window server's
    /// top-left global space, which is the same space the recorded rectangle
    /// is expressed in, so there is no flipping to get wrong.
    private func normalizedPointerLocation() -> CGPoint? {
        guard let location = CGEvent(source: nil)?.location,
              location.x.isFinite, location.y.isFinite
        else { return nil }
        let scale = region.scale > 0 ? region.scale : 1
        let originX = displayBounds.origin.x + region.pixelRect.origin.x / scale
        let originY = displayBounds.origin.y + region.pixelRect.origin.y / scale
        let width = region.pixelRect.width / scale
        let height = region.pixelRect.height / scale
        guard width > 0, height > 0 else { return nil }
        return CGPoint(x: (location.x - originX) / width,
                       y: (location.y - originY) / height)
    }

    private func record(_ event: NSEvent, generation: Int) {
        lock.withLock {
            guard running, self.generation == generation else { return }
            guard let time = pauseClock.eventTime(CACurrentMediaTime())
            else { return }
            let isDown = event.type == .leftMouseDown || event.type == .rightMouseDown
            clicks.append(RecorderMotion.Click(time: time, isDown: isDown))
        }
    }

    // MARK: - Packing

    /// Turns the collected shapes into the track's table and remaps each
    /// sample's shape identity onto its index there. Index zero is the first
    /// shape the recording showed, so a sample whose shape was never read
    /// falls back to something sensible. Upstream's `packing`, without the
    /// private catalog.
    static func pack(samples: [RecorderMotion.Sample],
                     identities: [UInt64],
                     clicks: [RecorderMotion.Click],
                     shapes: [(id: UInt64, shape: RecorderCursorShapes.Shape)],
                     displayScale: Double) -> RecorderPointerTrack {
        var indexByIdentity: [UInt64: Int] = [:]
        var packed: [RecorderPointerTrack.CursorShape] = []
        for entry in shapes {
            guard let png = RecorderPointerTrack.pngData(entry.shape.image) else { continue }
            indexByIdentity[entry.id] = packed.count
            packed.append(RecorderPointerTrack.CursorShape(png: png,
                                                           hotSpot: entry.shape.hotSpot,
                                                           pointSize: entry.shape.size))
        }
        let remapped = samples.enumerated().map { offset, sample -> RecorderMotion.Sample in
            var copy = sample
            let identity = identities.indices.contains(offset) ? identities[offset] : 0
            copy.shapeIndex = indexByIdentity[identity] ?? 0
            return copy
        }
        return RecorderPointerTrack(samples: remapped,
                                    clicks: clicks,
                                    shapes: packed,
                                    systemScale: 1,
                                    displayScale: displayScale)
    }
}

/// The pointer images a recording showed, read from `NSCursor.currentSystem`
/// a few times a second on the main thread. A shape is keyed by its size and
/// hot spot, which tells the arrow, I-beam, hand and resize pointers apart
/// without hashing pixels. When the system gives no pointer back, nothing is
/// collected and the editor draws its own arrow.
final class RecorderCursorShapes {
    struct Shape {
        let image: CGImage
        /// Size in screen points.
        let size: CGSize
        /// Where inside it the pointer points, from the top-left, in points.
        let hotSpot: CGPoint
    }

    private let lock = NSLock()
    private var shapes: [UInt64: Shape] = [:]
    private var order: [UInt64] = []
    private var identity: UInt64 = 0
    private var timer: Timer?

    private static let interval: TimeInterval = 0.1

    var currentIdentity: UInt64 { lock.withLock { identity } }

    /// Main thread.
    func start() {
        guard timer == nil else { return }
        read()
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            self?.read()
        }
        timer.tolerance = 0.02
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Main thread.
    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func collected() -> [(id: UInt64, shape: Shape)] {
        lock.withLock {
            order.compactMap { key in shapes[key].map { (id: key, shape: $0) } }
        }
    }

    private func read() {
        guard let cursor = NSCursor.currentSystem else { return }
        let size = cursor.image.size
        let hotSpot = cursor.hotSpot
        guard size.width >= 1, size.height >= 1 else { return }
        let key = Self.key(size: size, hotSpot: hotSpot)
        let known = lock.withLock { shapes[key] != nil }
        if !known, let image = Self.bestImage(of: cursor.image) {
            lock.withLock {
                if shapes[key] == nil {
                    shapes[key] = Shape(image: image, size: size,
                                        hotSpot: CGPoint(x: min(hotSpot.x, size.width),
                                                         y: min(hotSpot.y, size.height)))
                    order.append(key)
                }
            }
        }
        lock.withLock { if shapes[key] != nil { identity = key } }
    }

    /// The sharpest bitmap the cursor carries, so a zoomed pointer stays crisp.
    private static func bestImage(of image: NSImage) -> CGImage? {
        let reps = image.representations.compactMap { $0 as? NSBitmapImageRep }
        if let best = reps.max(by: { $0.pixelsWide < $1.pixelsWide }), let cgImage = best.cgImage {
            return cgImage
        }
        var rect = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    private static func key(size: CGSize, hotSpot: CGPoint) -> UInt64 {
        var value: UInt64 = 0xcbf2_9ce4_8422_2325
        for component in [size.width, size.height, hotSpot.x, hotSpot.y] {
            withUnsafeBytes(of: Float(component).bitPattern) { bytes in
                for byte in bytes {
                    value ^= UInt64(byte)
                    value = value &* 0x0000_0100_0000_01B3
                }
            }
        }
        return value == 0 ? 1 : value
    }
}
