// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import AppKit
import Combine
import UniformTypeIdentifiers

/// The Media tool's job runner. One job at a time on a serial queue, one file
/// at a time inside it; a new job or `cancel` stops the one before. Adapted
/// from upstream's MediaService, image and video compression.
final class MediaService: ObservableObject {
    static let shared = MediaService()

    struct ItemResult: Identifiable {
        let id = UUID()
        let source: URL
        /// The saved file in files mode; nil in zip mode and on failure.
        let output: URL?
        let originalSize: Int64
        let outputSize: Int64
        let keptOriginal: Bool
        let failure: Failure?
    }

    struct ZipResult {
        let url: URL
        let count: Int
        let size: Int64
    }

    enum Failure: Equatable {
        case image(ImageCompressionError)
        case video(VideoCompressionError)
        case write
    }

    @Published private(set) var isRunning = false
    @Published private(set) var completed = 0
    @Published private(set) var total = 0
    /// The current file, 0…1. Images jump; videos move with the encode.
    @Published private(set) var fileProgress = 0.0
    @Published private(set) var results: [ItemResult] = []
    @Published private(set) var zip: ZipResult?
    @Published private(set) var zipFailed = false
    @Published private(set) var skippedCount = 0
    @Published private(set) var wasCancelled = false

    private let queue = DispatchQueue(label: "io.github.qaws81877.fixdock.media", qos: .userInitiated)
    private var token: CancelToken?

    /// Where the results can be on screen.
    enum Screen { case settings, panel }
    private var visibleScreens: Set<Screen> = []
    /// Left while a job ran: clear when it ends, unless a screen came back.
    private var clearWhenDone = false

    private init() {}

    /// Feature binding. Uninstalling stops a job at once.
    func syncWithPreferences() {
        if !AppFeature.mediaTools.isAvailable { cancel() }
    }

    func cancel() {
        token?.cancel()
    }

    /// The history belongs to the screen it is shown on: moving to another
    /// Settings page or closing the panel clears it, unless the other screen
    /// is still showing it. A running job keeps its results until it ends.
    /// The panel reports through the popover delegate, because a closed
    /// popover keeps its views and SwiftUI never calls their onDisappear.
    func setVisible(_ visible: Bool, on screen: Screen) {
        if visible {
            visibleScreens.insert(screen)
            clearWhenDone = false
            return
        }
        visibleScreens.remove(screen)
        guard visibleScreens.isEmpty else { return }
        if isRunning {
            clearWhenDone = true
        } else {
            clearResults()
        }
    }

    func clearResults() {
        guard !isRunning else { return }
        results = []
        zip = nil
        zipFailed = false
        skippedCount = 0
        wasCancelled = false
    }

    func compressImages(_ urls: [URL], options: ImageCompressionOptions, output: MediaOutputMode) {
        run(urls, kind: .image, output: output) { url, zipJob, _, _ in
            Self.processImage(url, options: options, zipJob: zipJob)
        }
    }

    func compressVideos(_ urls: [URL], sizing: VideoSizing, output: MediaOutputMode) {
        run(urls, kind: .movie, output: output) { url, zipJob, job, progress in
            Self.processVideo(url, sizing: sizing, zipJob: zipJob, job: job, progress: progress)
        }
    }

    /// Keeps only files of `kind`; the rest are counted as skipped.
    private func run(_ urls: [URL], kind: UTType, output: MediaOutputMode,
                     process: @escaping (URL, ZipJob?, CancelToken, @escaping (Double) -> Void) -> ItemResult) {
        guard AppFeature.mediaTools.isAvailable else { return }
        token?.cancel()
        let items = urls.filter { Self.conforms($0, to: kind) }
        let job = CancelToken()
        token = job
        results = []
        zip = nil
        zipFailed = false
        skippedCount = urls.count - items.count
        wasCancelled = false
        completed = 0
        fileProgress = 0
        total = items.count
        isRunning = !items.isEmpty
        guard let first = items.first else { return }

        queue.async { [weak self] in
            let zipJob = output == .zip ? ZipJob(nextTo: first) : nil
            for url in items {
                guard !job.isCancelled else { break }
                let reporter = ProgressThrottle { value in
                    DispatchQueue.main.async {
                        guard let self, self.token === job else { return }
                        self.fileProgress = value
                    }
                }
                let result = autoreleasepool { process(url, zipJob, job, reporter.report) }
                DispatchQueue.main.async {
                    guard let self, self.token === job else { return }
                    // A file cut short by cancel is not a result.
                    if result.failure != .video(.cancelled) { self.results.append(result) }
                    self.completed += 1
                    self.fileProgress = 0
                }
            }
            // A cancelled zip job saves nothing; one with nothing saved has nothing to zip.
            let finished: Result<ZipResult, Error>? = job.isCancelled ? nil : zipJob?.finish()
            DispatchQueue.main.async {
                guard let self, self.token === job else { return }
                switch finished {
                case .success(let result): self.zip = result
                case .failure: self.zipFailed = true
                case nil: break
                }
                self.wasCancelled = job.isCancelled
                self.isRunning = false
                self.token = nil
                if self.clearWhenDone {
                    self.clearWhenDone = false
                    self.clearResults()
                }
            }
        }
    }

    private static func conforms(_ url: URL, to kind: UTType) -> Bool {
        guard let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType else { return false }
        return type.conforms(to: kind)
    }

    private static func size(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    private static func processImage(_ url: URL, options: ImageCompressionOptions, zipJob: ZipJob?) -> ItemResult {
        let compressed: ImageCompressionResult
        do {
            compressed = try ImageCompressor.compress(url, options: options)
        } catch let error as ImageCompressionError {
            return failure(url, .image(error))
        } catch {
            return failure(url, .image(.unreadable))
        }
        do {
            let output: URL?
            if let zipJob {
                try zipJob.add(compressed.data, for: url, fileExtension: compressed.fileExtension)
                output = nil
            } else {
                output = try ImageOutputWriter.write(compressed.data,
                                                     into: url.deletingLastPathComponent(),
                                                     baseName: ImageCompressionSupport.outputBaseName(for: url),
                                                     fileExtension: compressed.fileExtension)
            }
            return ItemResult(source: url, output: output, originalSize: compressed.originalSize,
                              outputSize: Int64(compressed.data.count),
                              keptOriginal: compressed.keptOriginal, failure: nil)
        } catch {
            return failure(url, .write)
        }
    }

    /// Encodes into a staging file on the destination's volume, then moves
    /// it into place (files) or into the zip folder. A failed or cancelled
    /// encode leaves nothing behind.
    private static func processVideo(_ url: URL, sizing: VideoSizing, zipJob: ZipJob?,
                                     job: CancelToken, progress: @escaping (Double) -> Void) -> ItemResult {
        let fileManager = FileManager.default
        let directory = url.deletingLastPathComponent()
        guard let staging = try? fileManager.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                 appropriateFor: zipJob?.directory ?? directory, create: true)
        else { return failure(url, .write) }
        defer { try? fileManager.removeItem(at: staging) }
        let staged = staging.appendingPathComponent("output.mp4")
        do {
            try VideoCompressor.compress(url, sizing: sizing, to: staged,
                                         isCancelled: { job.isCancelled }, progress: progress)
        } catch let error as VideoCompressionError {
            return failure(url, .video(error))
        } catch {
            return failure(url, .video(.failed))
        }
        let outputSize = size(staged)
        do {
            let output: URL?
            if let zipJob {
                try zipJob.add(fileAt: staged, for: url, fileExtension: "mp4")
                output = nil
            } else {
                output = try ImageOutputWriter.move(staged, into: directory,
                                                    baseName: ImageCompressionSupport.outputBaseName(for: url),
                                                    fileExtension: "mp4")
            }
            return ItemResult(source: url, output: output, originalSize: size(url), outputSize: outputSize,
                              keptOriginal: false, failure: nil)
        } catch {
            return failure(url, .write)
        }
    }

    private static func failure(_ url: URL, _ failure: Failure) -> ItemResult {
        ItemResult(source: url, output: nil, originalSize: 0, outputSize: 0, keptOriginal: false, failure: failure)
    }
}

/// Collects a job's files in a staging folder on the destination's volume,
/// then zips and moves the archive in without replacing anything. The
/// staging folder is removed whatever happens. Used on the media queue only.
private final class ZipJob {
    let directory: URL
    private let staging: URL?
    private let contents: URL?
    private var names: [String] = []

    init(nextTo first: URL) {
        directory = first.deletingLastPathComponent()
        staging = try? FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                               appropriateFor: directory, create: true)
        contents = staging?.appendingPathComponent("files", isDirectory: true)
        if let contents { try? FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true) }
    }

    deinit {
        if let staging { try? FileManager.default.removeItem(at: staging) }
    }

    func add(_ data: Data, for source: URL, fileExtension: String) throws {
        let target = try nextURL(for: source, fileExtension: fileExtension)
        try data.write(to: target)
        names.append(target.lastPathComponent)
    }

    func add(fileAt file: URL, for source: URL, fileExtension: String) throws {
        let target = try nextURL(for: source, fileExtension: fileExtension)
        try FileManager.default.moveItem(at: file, to: target)
        names.append(target.lastPathComponent)
    }

    /// Inside the zip each file keeps its original name, numbered on a clash.
    private func nextURL(for source: URL, fileExtension: String) throws -> URL {
        guard let contents else { throw CocoaError(.fileWriteUnknown) }
        let base = source.deletingPathExtension().lastPathComponent
        let name = ImageCompressionSupport.uniqueName(base: base.isEmpty ? "file" : base,
                                                      extension: fileExtension) { names.contains($0) }
        return contents.appendingPathComponent(name)
    }

    func finish() -> Result<MediaService.ZipResult, Error>? {
        guard !names.isEmpty else { return nil }
        guard let staging, let contents else { return .failure(ZipArchive.Failure.archiveFailed) }
        do {
            let archive = staging.appendingPathComponent("archive.zip")
            try ZipArchive.archive(contentsOf: contents, to: archive, expectedNames: names)
            let size = Int64((try? archive.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            let url = try ImageOutputWriter.move(archive, into: directory,
                                                 baseName: ImageCompressionSupport.zipBaseName(),
                                                 fileExtension: "zip")
            return .success(MediaService.ZipResult(url: url, count: names.count, size: size))
        } catch {
            return .failure(error)
        }
    }
}

/// Settings as saved on the Media page.
enum MediaImageSettings {
    static var options: ImageCompressionOptions {
        let defaults = UserDefaults.standard
        return ImageCompressionOptions(
            quality: CompressionPreset.from(defaults.string(forKey: DefaultsKey.mediaImagePreset)).percent,
            format: ImageOutputFormat.from(defaults.string(forKey: DefaultsKey.mediaImageFormat)),
            maxDimension: ImageCompressionOptions.sanitizedMaxDimension(
                defaults.integer(forKey: DefaultsKey.mediaImageMaxDimension)),
            metadata: ImageMetadataPolicy.from(defaults.string(forKey: DefaultsKey.mediaImageMetadata)))
    }

    static var output: MediaOutputMode {
        MediaOutputMode.from(UserDefaults.standard.string(forKey: DefaultsKey.mediaOutputMode))
    }

    static var videoSizing: VideoSizing {
        let defaults = UserDefaults.standard
        switch VideoSizingMode.from(defaults.string(forKey: DefaultsKey.mediaVideoSizing)) {
        case .resolution:
            return .resolution(CompressionPreset.from(defaults.string(forKey: DefaultsKey.mediaVideoPreset)))
        case .fileSize:
            let megabytes = defaults.object(forKey: DefaultsKey.mediaVideoTargetMegabytes) as? Int
                ?? VideoCompressionSupport.defaultTargetMegabytes
            return .fileSize(bytes: VideoCompressionSupport.targetBytes(megabytes: megabytes))
        }
    }
}

/// Checked by the queue and the encoders, set from the main thread.
final class CancelToken {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }

    func cancel() { lock.withLock { cancelled = true } }
}

/// The encoder reports every frame; the screen needs a hundredth at most.
private final class ProgressThrottle {
    private let send: (Double) -> Void
    private var lastPercent = -1

    init(_ send: @escaping (Double) -> Void) { self.send = send }

    func report(_ value: Double) {
        let percent = Int(value * 100)
        guard percent != lastPercent else { return }
        lastPercent = percent
        send(value)
    }
}
