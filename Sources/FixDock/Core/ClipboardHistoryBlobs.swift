// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import CryptoKit
import Foundation
import ImageIO

enum ClipboardImageFormat: String, CaseIterable {
    case png
    case gif

    var fileExtension: String { rawValue }

    var typeIdentifier: String {
        switch self {
        case .png: return "public.png"
        case .gif: return "com.compuserve.gif"
        }
    }

    private static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    static func sniff(_ data: Data) -> ClipboardImageFormat? {
        if data.starts(with: pngSignature) { return .png }
        if data.starts(with: Array("GIF87a".utf8)) || data.starts(with: Array("GIF89a".utf8)) { return .gif }
        return nil
    }
}

struct ClipboardBlobName: Hashable {
    let digest: String
    let format: ClipboardImageFormat

    fileprivate init?(digest: String, format: ClipboardImageFormat) {
        guard Self.isDigest(digest) else { return nil }
        self.digest = digest
        self.format = format
    }

    fileprivate init(hashing bytes: Data, format: ClipboardImageFormat) {
        digest = Self.hex(of: bytes)
        self.format = format
    }

    var fileName: String { "\(digest).\(format.fileExtension)" }

    fileprivate static func hex(of bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private static func isDigest(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        return bytes.count == 64 && bytes.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }

    fileprivate enum Listing: Equatable {
        case blob(ClipboardBlobName)
        /// `.<64 hex>.<png|gif>.<digits>.tmp`, the sibling `writeDurably` writes
        /// first. Puts and sweeps share one serial queue, so one present at sweep
        /// time belongs to a write that did not finish.
        case leftoverTemporary
        case foreign
    }

    fileprivate static func classify(fileName: String) -> Listing {
        if let name = parse(fileName) { return .blob(name) }
        guard fileName.hasPrefix("."), fileName.hasSuffix(".tmp") else { return .foreign }
        let middle = fileName.dropFirst().dropLast(".tmp".count)
        guard let dot = middle.lastIndex(of: ".") else { return .foreign }
        let pid = middle[middle.index(after: dot)...]
        guard !pid.isEmpty, pid.utf8.allSatisfy({ (0x30...0x39).contains($0) }),
              parse(String(middle[..<dot])) != nil else { return .foreign }
        return .leftoverTemporary
    }

    private static func parse(_ fileName: String) -> ClipboardBlobName? {
        let parts = fileName.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, let format = ClipboardImageFormat(rawValue: String(parts[1])) else { return nil }
        return ClipboardBlobName(digest: String(parts[0]), format: format)
    }
}

struct ClipboardImageRef: Hashable, Codable {
    let name: ClipboardBlobName
    let pixelWidth: Int
    let pixelHeight: Int
    let byteCount: Int

    fileprivate init(name: ClipboardBlobName, pixelWidth: Int, pixelHeight: Int, byteCount: Int) {
        self.name = name
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.byteCount = byteCount
    }

    private enum CodingKeys: String, CodingKey {
        case sha256, format, width, height, bytes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let digest = try container.decode(String.self, forKey: .sha256)
        let formatName = try container.decode(String.self, forKey: .format)
        guard let format = ClipboardImageFormat(rawValue: formatName),
              let name = ClipboardBlobName(digest: digest, format: format) else {
            throw DecodingError.dataCorruptedError(forKey: .sha256, in: container, debugDescription: "not an own blob name")
        }
        let width = try container.decode(Int.self, forKey: .width)
        let height = try container.decode(Int.self, forKey: .height)
        let bytes = try container.decode(Int.self, forKey: .bytes)
        guard width > 0, height > 0, bytes > 0, bytes <= ClipboardImagePayload.maxBytes else {
            throw DecodingError.dataCorruptedError(forKey: .bytes, in: container, debugDescription: "bad size")
        }
        self.init(name: name, pixelWidth: width, pixelHeight: height, byteCount: bytes)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name.digest, forKey: .sha256)
        try container.encode(name.format.rawValue, forKey: .format)
        try container.encode(pixelWidth, forKey: .width)
        try container.encode(pixelHeight, forKey: .height)
        try container.encode(byteCount, forKey: .bytes)
    }
}

struct ClipboardImagePayload {
    let ref: ClipboardImageRef
    fileprivate let bytes: Data

    static let maxBytes = 50 * 1_024 * 1_024
    /// Decoding costs about four bytes a pixel whatever the file size, so a
    /// small, highly compressed image is refused by its declared size before
    /// anything decodes it (64 MP, about 256 MB).
    static let maxPixels = 64_000_000

    static func withinPixelBudget(width: Int, height: Int) -> Bool {
        let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
        return width > 0 && height > 0 && !overflow && pixels <= maxPixels
    }

    private static let reencodedTypes: Set<String> = ["public.tiff", "public.jpeg", "public.heic"]

    fileprivate init(ref: ClipboardImageRef, bytes: Data) {
        self.ref = ref
        self.bytes = bytes
    }

    static func prepare(bytes data: Data) -> ClipboardImagePayload? {
        guard !data.isEmpty, data.count <= maxBytes else { return nil }
        let stored: Data
        let format: ClipboardImageFormat
        if let sniffed = ClipboardImageFormat.sniff(data) {
            stored = data
            format = sniffed
        } else {
            guard let reencoded = autoreleasepool(invoking: { pngReencoding(data) }),
                  reencoded.count <= maxBytes else { return nil }
            stored = reencoded
            format = .png
        }
        guard let size = pixelSize(of: stored), withinPixelBudget(width: size.width, height: size.height)
        else { return nil }
        let name = ClipboardBlobName(hashing: stored, format: format)
        return ClipboardImagePayload(ref: ClipboardImageRef(name: name, pixelWidth: size.width,
                                                            pixelHeight: size.height, byteCount: stored.count),
                                     bytes: stored)
    }

    private static func pngReencoding(_ data: Data) -> Data? {
        let noCache = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, noCache),
              let type = CGImageSourceGetType(source) as String?, reencodedTypes.contains(type),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, noCache) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              withinPixelBudget(width: width, height: height) else { return nil }
        // A thumbnail at full size is the one ImageIO call that applies the
        // EXIF orientation, so the stored PNG is upright and carries none.
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height),
            kCGImageSourceShouldCache: false,
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, "public.png" as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    private static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
        let noCache = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, noCache),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, noCache) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { return nil }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        return (5...8).contains(orientation) ? (height, width) : (width, height)
    }
}

struct ClipboardImageLocator {
    fileprivate let folder: URL

    func url(for name: ClipboardBlobName) -> URL {
        folder.appendingPathComponent(name.fileName, isDirectory: false)
    }

    func isPresent(_ name: ClipboardBlobName) -> Bool {
        var info = stat()
        return lstat(url(for: name).path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG
    }

    func verifiedBytes(_ name: ClipboardBlobName) -> Data? {
        let fd = open(url(for: name).path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size <= Int64(ClipboardImagePayload.maxBytes),
              let data = try? handle.readToEnd(),
              ClipboardBlobName.hex(of: data) == name.digest else { return nil }
        return data
    }
}

/// The only code that creates or deletes anything in the image folder. It
/// never learns the history file's name, and check-shell allows exactly one
/// deletion here, inside `sweep(after:)`.
final class ClipboardHistoryBlobs {
    private static let folderName = "ClipboardHistoryImages"

    let locator: ClipboardImageLocator
    private let folder: URL
    private let container: URL
    private let queue: DispatchQueue

    init(container: URL, queue: DispatchQueue) {
        self.container = container
        folder = Self.folderURL(in: container)
        locator = ClipboardImageLocator(folder: folder)
        self.queue = queue
    }

    static func folderURL(in container: URL) -> URL {
        container.appendingPathComponent(folderName, isDirectory: true)
    }

    enum FolderState: Equatable {
        case absent
        case folder
        case notAFolder
        case unreadable(String)
    }

    static func folderState(in container: URL) -> FolderState {
        var info = stat()
        guard lstat(folderURL(in: container).path, &info) == 0 else {
            let code = errno
            return code == ENOENT ? .absent : .unreadable(String(cString: strerror(code)))
        }
        return info.st_mode & S_IFMT == S_IFDIR ? .folder : .notAFolder
    }

    static func folderHoldsOwnNames(in container: URL) -> Bool? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folderURL(in: container).path)
        else { return nil }
        return names.contains { ClipboardBlobName.classify(fileName: $0) != .foreign }
    }

    @discardableResult
    /// Idempotent by name: a regular file of the right size is kept, anything
    /// else at the name makes the put fail and the entry keeps its placeholder.
    func put(_ payload: ClipboardImagePayload) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        guard PrivateFileStore.createDirectory(at: folder, container: container) else { return false }
        var info = stat()
        guard lstat(folder.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return false }
        let target = locator.url(for: payload.ref.name)
        if lstat(target.path, &info) == 0 {
            return info.st_mode & S_IFMT == S_IFREG && info.st_size == Int64(payload.bytes.count)
        }
        guard errno == ENOENT else { return false }
        return PrivateFileStore.writeDurably(payload.bytes, to: target)
    }

    enum SweepOutcome: Equatable {
        case swept(deleted: Int, kept: Int)
        case noFolder
    }

    @discardableResult
    /// The one deletion in clipboard history. Persist queue, in the same job as
    /// the write the token proves. An item goes only when all hold:
    /// 1. The history file write landed (`landed` exists only after
    ///    `writeDurably` returned true, from a ready store).
    /// 2. It is directly inside the folder, opened O_DIRECTORY | O_NOFOLLOW;
    ///    every check and the deletion are relative to that descriptor.
    /// 3. Its name is FixDock's own, or the leftover temporary of one.
    /// 4. It is a regular file (fstatat, AT_SYMLINK_NOFOLLOW).
    /// 5. The saved snapshot does not reference it.
    func sweep(after landed: ClipboardHistoryLandedWrite) -> SweepOutcome {
        dispatchPrecondition(condition: .onQueue(queue))
        let dir = open(folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard dir >= 0 else { return .noFolder }
        defer { close(dir) }
        var deleted = 0
        var kept = 0
        for name in Self.names(in: dir) {
            switch ClipboardBlobName.classify(fileName: name) {
            case .foreign:
                continue
            case .blob(let blob) where landed.referenced.contains(blob):
                kept += 1
                continue
            case .blob, .leftoverTemporary:
                break
            }
            var info = stat()
            guard fstatat(dir, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                  info.st_mode & S_IFMT == S_IFREG else { continue }
            if unlinkat(dir, name, 0) == 0 { deleted += 1 }
        }
        return .swept(deleted: deleted, kept: kept)
    }

    private static func names(in dir: Int32) -> [String] {
        let listing = dup(dir)
        guard listing >= 0 else { return [] }
        guard let stream = fdopendir(listing) else {
            close(listing)
            return []
        }
        defer { closedir(stream) }
        var names: [String] = []
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name != ".", name != ".." { names.append(name) }
        }
        return names
    }
}
