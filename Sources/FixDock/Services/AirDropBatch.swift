// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import Foundation
import ImageIO

/// One AirDrop auto-zip batch: compress, zip, verify, then trash. Free of app
/// state so a developer run can point it at a temporary folder. Blocking.
///
/// Deletion guard: an original is moved to the Trash only after the zip that
/// holds its compressed copy has been written, listed back and moved into
/// place, and only if the original is still the file that was compressed
/// (same size and modification date). Any earlier failure returns before the
/// trash step is reached, so every original stays. Nothing is ever removed
/// with `rm`; the Trash keeps them recoverable.
enum AirDropBatch {
    struct Outcome {
        let zip: URL?
        let count: Int
        let zipSize: Int64
        let originalBytes: Int64
        /// Originals moved to the Trash.
        let trashed: [URL]
        /// Zipped, but left in place: changed since, or the Trash refused.
        let kept: [URL]
        let failure: Failure?
    }

    enum Failure: Error, Equatable {
        case compression(String)
        case zip
        case write
    }

    private struct Snapshot: Equatable {
        let size: Int64
        let modified: Date?
    }

    static func run(_ files: [URL], in folder: URL, options: ImageCompressionOptions,
                    trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) })
        -> Outcome {
        let fileManager = FileManager.default
        let snapshots = Dictionary(uniqueKeysWithValues: files.map { ($0, snapshot($0)) })
        let originalBytes = snapshots.values.compactMap { $0?.size }.reduce(0, +)

        guard let staging = try? fileManager.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                 appropriateFor: folder, create: true)
        else { return failed(.write, originalBytes) }
        defer { try? fileManager.removeItem(at: staging) }
        let contents = staging.appendingPathComponent("photos", isDirectory: true)
        guard (try? fileManager.createDirectory(at: contents, withIntermediateDirectories: true)) != nil
        else { return failed(.write, originalBytes) }

        // Compress every member first. One failure keeps the whole batch.
        var names: [String] = []
        for (index, url) in ordered(files).enumerated() {
            let result: ImageCompressionResult
            do {
                result = try ImageCompressor.compress(url, options: options)
            } catch {
                return failed(.compression(url.lastPathComponent), originalBytes)
            }
            let name = AirDropAutoZipSupport.sequentialName(index: index + 1, fileExtension: result.fileExtension)
            // Written from the encoded bytes only: no extended attributes, so
            // the Photos location copy (com.apple.assetsd.customLocation)
            // never comes along.
            guard (try? result.data.write(to: contents.appendingPathComponent(name))) != nil else {
                return failed(.write, originalBytes)
            }
            names.append(name)
        }

        let archive = staging.appendingPathComponent("archive.zip")
        let zip: URL
        do {
            try ZipArchive.archive(contentsOf: contents, to: archive, expectedNames: names)
        } catch {
            return failed(.zip, originalBytes)
        }
        let zipSize = Int64((try? archive.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        do {
            zip = try ImageOutputWriter.move(archive, into: folder,
                                             baseName: ImageCompressionSupport.zipBaseName(),
                                             fileExtension: "zip")
        } catch {
            return failed(.write, originalBytes)
        }

        // The zip is in place and verified. Only now may originals go.
        var trashed: [URL] = []
        var kept: [URL] = []
        for url in files {
            guard let before = snapshots[url] ?? nil, snapshot(url) == before else {
                kept.append(url)
                continue
            }
            do {
                try trash(url)
                trashed.append(url)
            } catch {
                kept.append(url)
            }
        }
        return Outcome(zip: zip, count: names.count, zipSize: zipSize, originalBytes: originalBytes,
                       trashed: trashed, kept: kept, failure: nil)
    }

    private static func failed(_ failure: Failure, _ originalBytes: Int64) -> Outcome {
        Outcome(zip: nil, count: 0, zipSize: 0, originalBytes: originalBytes, trashed: [], kept: [],
                failure: failure)
    }

    private static func snapshot(_ url: URL) -> Snapshot? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize
        else { return nil }
        return Snapshot(size: Int64(size), modified: values.contentModificationDate)
    }

    private static func ordered(_ files: [URL]) -> [URL] {
        let members = files.map { url -> (AirDropAutoZipSupport.Member, URL) in
            (AirDropAutoZipSupport.Member(name: url.lastPathComponent,
                                          captured: captureDate(url),
                                          created: try? url.resourceValues(forKeys: [.creationDateKey]).creationDate),
             url)
        }
        let byName = Dictionary(members.map { ($0.0.name, $0.1) }, uniquingKeysWith: { first, _ in first })
        return AirDropAutoZipSupport.ordered(members.map(\.0)).compactMap { byName[$0.name] }
    }

    private static func captureDate(_ url: URL) -> Date? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        else { return nil }
        return AirDropAutoZipSupport.exifDate(exif[kCGImagePropertyExifDateTimeOriginal] as? String)
    }
}
