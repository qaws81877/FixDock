// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import AppKit
import ImageIO
import QuickLookThumbnailing
import UniformTypeIdentifiers

final class ClipboardHistoryMedia {
    enum Size {
        case row, preview

        var pixels: Int {
            switch self {
            case .row: return 128
            case .preview: return 1_200
            }
        }
    }

    private let locator: () -> ClipboardImageLocator?
    private let rows = ClipboardHistoryMedia.cache(megabytes: 24)
    private let previews = ClipboardHistoryMedia.cache(megabytes: 16)
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "io.github.qaws81877.fixdock.clipboard-history.pictures"
        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .userInitiated
        return queue
    }()

    init(locator: @escaping () -> ClipboardImageLocator?) {
        self.locator = locator
    }

    private static func cache(megabytes: Int) -> NSCache<NSString, CGImage> {
        let cache = NSCache<NSString, CGImage>()
        cache.totalCostLimit = megabytes * 1_024 * 1_024
        return cache
    }

    private static func key(_ content: ClipboardHistoryContent, _ size: Size) -> NSString? {
        switch content {
        case .text: return nil
        case .image(let ref): return "image:\(ref.name.fileName):\(size.pixels)" as NSString
        case .file(let file): return "file:\(file.path):\(size.pixels)" as NSString
        }
    }

    private func cache(for size: Size) -> NSCache<NSString, CGImage> {
        size == .row ? rows : previews
    }

    func cached(_ content: ClipboardHistoryContent, _ size: Size) -> CGImage? {
        Self.key(content, size).flatMap { cache(for: size).object(forKey: $0) }
    }

    func picture(_ content: ClipboardHistoryContent, _ size: Size) async -> CGImage? {
        guard let key = Self.key(content, size) else { return nil }
        let cache = cache(for: size)
        if let image = cache.object(forKey: key) { return image }
        let locator = locator()
        let image: CGImage? = await run {
            switch content {
            case .text:
                return nil
            case .image(let ref):
                guard let locator, locator.isPresent(ref.name) else { return nil }
                return Self.downsample(locator.url(for: ref.name), maxPixel: size.pixels)
            case .file(let file):
                return Self.quickLook(file, maxPixel: size.pixels)
            }
        }
        if let image { cache.setObject(image, forKey: key, cost: image.bytesPerRow * image.height) }
        return image
    }

    func facts(_ file: ClipboardFileRef) async -> ClipboardHistoryFileFacts? {
        await run { ClipboardHistoryFileFacts(file) }
    }

    func dropPreviews() {
        previews.removeAllObjects()
    }

    private func run<T>(_ work: @escaping () -> T?) async -> T? {
        let request = Request()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.addOperation {
                    continuation.resume(returning: request.isCancelled ? nil : work())
                }
            }
        } onCancel: {
            request.cancel()
        }
    }

    private final class Request: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        var isCancelled: Bool { lock.withLock { cancelled } }
        func cancel() { lock.withLock { cancelled = true } }
    }

    private static func downsample(_ url: URL, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL,
                                                      [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
    }

    private static func quickLook(_ file: ClipboardFileRef, maxPixel: Int) -> CGImage? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let request = QLThumbnailGenerator.Request(
            fileAt: URL(fileURLWithPath: file.path, isDirectory: file.isDirectory),
            size: CGSize(width: maxPixel, height: maxPixel), scale: 1, representationTypes: .all)
        let answer = Answer()
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
            answer.image = representation?.cgImage
            answer.done.signal()
        }
        guard answer.done.wait(timeout: .now() + 5) == .success else {
            QLThumbnailGenerator.shared.cancel(request)
            return nil
        }
        return answer.image
    }

    private final class Answer: @unchecked Sendable {
        let done = DispatchSemaphore(value: 0)
        var image: CGImage?
    }

    static func placeholderIcon(for file: ClipboardFileRef) -> NSImage {
        let type = file.isDirectory ? UTType.folder
            : UTType(filenameExtension: (file.name as NSString).pathExtension) ?? .data
        return NSWorkspace.shared.icon(for: type)
    }
}

struct ClipboardHistoryFileFacts: Equatable {
    var exists: Bool
    var kind: String?
    var byteCount: Int?

    init(_ file: ClipboardFileRef) {
        let url = URL(fileURLWithPath: file.path, isDirectory: file.isDirectory)
        let values = try? url.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey, .isRegularFileKey])
        exists = values != nil && FileManager.default.fileExists(atPath: file.path)
        let type = values?.contentType ?? (file.isDirectory ? .folder
            : UTType(filenameExtension: (file.name as NSString).pathExtension))
        kind = type?.localizedDescription
        byteCount = values?.isRegularFile == true ? values?.fileSize : nil
    }
}

enum ClipboardHistorySourceApp {
    private static var known: [String: (name: String, icon: NSImage)] = [:]

    static func info(for bundleID: String) -> (name: String, icon: NSImage) {
        if let info = known[bundleID] { return info }
        let info: (name: String, icon: NSImage)
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let name = FileManager.default.displayName(atPath: url.path)
            info = (name.hasSuffix(".app") ? String(name.dropLast(4)) : name, NSWorkspace.shared.icon(forFile: url.path))
        } else {
            info = (bundleID, NSWorkspace.shared.icon(for: .application))
        }
        known[bundleID] = info
        return info
    }
}
