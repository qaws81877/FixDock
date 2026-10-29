// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import AppKit
import Combine
import UniformTypeIdentifiers

/// The Media tool's job runner. One job at a time on a serial queue, one file
/// at a time inside it; a new job or `cancel` stops the one before at the
/// next file. Adapted from upstream's MediaService, image half.
final class MediaService: ObservableObject {
    static let shared = MediaService()

    struct ImageResult: Identifiable {
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
        case compression(ImageCompressionError)
        case write
    }

    @Published private(set) var isRunning = false
    @Published private(set) var completed = 0
    @Published private(set) var total = 0
    @Published private(set) var results: [ImageResult] = []
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

    /// Feature binding. Uninstalling stops a job at its next file.
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

    /// Keeps only images; the rest are counted as skipped.
    func compressImages(_ urls: [URL], options: ImageCompressionOptions, output: MediaOutputMode) {
        guard AppFeature.mediaTools.isAvailable else { return }
        token?.cancel()
        let images = urls.filter(Self.isImage)
        let job = CancelToken()
        token = job
        results = []
        zip = nil
        zipFailed = false
        skippedCount = urls.count - images.count
        wasCancelled = false
        completed = 0
        total = images.count
        isRunning = !images.isEmpty
        guard let first = images.first else { return }

        queue.async { [weak self] in
            let zipJob = output == .zip ? ZipJob(nextTo: first) : nil
            for url in images {
                guard !job.isCancelled else { break }
                let result = autoreleasepool { Self.process(url, options: options, zipJob: zipJob) }
                DispatchQueue.main.async {
                    guard let self, self.token === job else { return }
                    self.results.append(result)
                    self.completed += 1
                }
            }
            // A cancelled zip job saves nothing; one with no image saved has nothing to zip.
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

    private static func isImage(_ url: URL) -> Bool {
        guard let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType else { return false }
        return type.conforms(to: .image)
    }

    private static func process(_ url: URL, options: ImageCompressionOptions, zipJob: ZipJob?) -> ImageResult {
        let compressed: ImageCompressionResult
        do {
            compressed = try ImageCompressor.compress(url, options: options)
        } catch let error as ImageCompressionError {
            return failure(url, .compression(error))
        } catch {
            return failure(url, .compression(.unreadable))
        }
        do {
            let output: URL?
            if let zipJob {
                try zipJob.add(compressed, for: url)
                output = nil
            } else {
                output = try ImageOutputWriter.write(compressed.data,
                                                     into: url.deletingLastPathComponent(),
                                                     baseName: ImageCompressionSupport.outputBaseName(for: url),
                                                     fileExtension: compressed.fileExtension)
            }
            return ImageResult(source: url, output: output, originalSize: compressed.originalSize,
                               outputSize: Int64(compressed.data.count),
                               keptOriginal: compressed.keptOriginal, failure: nil)
        } catch {
            return failure(url, .write)
        }
    }

    private static func failure(_ url: URL, _ failure: Failure) -> ImageResult {
        ImageResult(source: url, output: nil, originalSize: 0, outputSize: 0, keptOriginal: false, failure: failure)
    }
}

/// Collects a job's images in a staging folder on the destination's volume,
/// then zips and moves the archive in without replacing anything. The
/// staging folder is removed whatever happens. Used on the media queue only.
private final class ZipJob {
    private let destination: URL
    private let staging: URL?
    private let contents: URL?
    private var names: [String] = []

    init(nextTo first: URL) {
        destination = first.deletingLastPathComponent()
        staging = try? FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                               appropriateFor: destination, create: true)
        contents = staging?.appendingPathComponent("images", isDirectory: true)
        if let contents { try? FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true) }
    }

    deinit {
        if let staging { try? FileManager.default.removeItem(at: staging) }
    }

    /// Inside the zip each image keeps its original name, numbered on a clash.
    func add(_ result: ImageCompressionResult, for source: URL) throws {
        guard let contents else { throw CocoaError(.fileWriteUnknown) }
        let base = source.deletingPathExtension().lastPathComponent
        let name = ImageCompressionSupport.uniqueName(base: base.isEmpty ? "image" : base,
                                                      extension: result.fileExtension) { names.contains($0) }
        try result.data.write(to: contents.appendingPathComponent(name))
        names.append(name)
    }

    func finish() -> Result<MediaService.ZipResult, Error>? {
        guard !names.isEmpty else { return nil }
        guard let staging, let contents else { return .failure(ZipArchive.Failure.archiveFailed) }
        do {
            let archive = staging.appendingPathComponent("archive.zip")
            try ZipArchive.archive(contentsOf: contents, to: archive, expectedNames: names)
            let data = try Data(contentsOf: archive)
            let url = try ImageOutputWriter.write(data, into: destination,
                                                  baseName: ImageCompressionSupport.zipBaseName(),
                                                  fileExtension: "zip")
            return .success(MediaService.ZipResult(url: url, count: names.count, size: Int64(data.count)))
        } catch {
            return .failure(error)
        }
    }
}

/// Image settings as saved on the Media page.
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
}

/// Checked by the queue between files, set from the main thread.
private final class CancelToken {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }

    func cancel() { lock.withLock { cancelled = true } }
}
