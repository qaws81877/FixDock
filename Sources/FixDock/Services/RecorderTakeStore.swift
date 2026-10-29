// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import Foundation
import ImageIO

/// Where recordings live before they become a file the person keeps.
///
/// A recording is a small folder holding the untouched master, so the editor
/// can always start over from the original pixels instead of from an already
/// rendered result. The person never sees the folder: they see a recording,
/// and then a video file wherever they chose to save it. The folder lives
/// exactly as long as the editor that owns it, so there is never a pile of
/// intermediates nobody asked for.
final class RecorderTakeStore: @unchecked Sendable {
    static let shared = RecorderTakeStore()

    struct Take: Equatable, Sendable {
        let id: UUID
        let folder: URL

        var videoURL: URL { folder.appendingPathComponent(RecorderSupport.takeVideoName) }
        var pointerURL: URL { folder.appendingPathComponent(RecorderSupport.takePointerName) }
        var typingURL: URL { folder.appendingPathComponent(RecorderSupport.takeTypingName) }
        var editURL: URL { folder.appendingPathComponent(RecorderSupport.takeEditName) }
    }

    private let manager = FileManager.default

    /// Set only by a harness naming its own scratch root; the app always
    /// uses the private container.
    private let rootOverride: URL?

    private init() { rootOverride = nil }

    init(root: URL) { rootOverride = root }

    // MARK: - Location

    /// Nil outside a real bundle, and then nothing is ever deleted.
    private var root: URL? {
        rootOverride ?? PrivateFileStore.containerURL?
            .appendingPathComponent("Recordings", isDirectory: true)
    }

    /// Space left where recordings are written, the way the system reports it
    /// for something the person actually wants to keep.
    func freeBytes() -> Int64 {
        guard let root else { return 0 }
        let probe = manager.fileExists(atPath: root.path)
            ? root
            : manager.homeDirectoryForCurrentUser
        let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    // MARK: - Lifecycle

    func makeTake() -> Take? {
        guard let root else { return nil }
        let id = UUID()
        let folder = root.appendingPathComponent(RecorderSupport.takeFolderName(id: id),
                                                 isDirectory: true)
        guard PrivateFileStore.createDirectory(at: folder) else { return nil }
        return Take(id: id, folder: folder)
    }

    /// Gives an ordinary movie the same private, disposable master a screen
    /// recording gets. The copy is intentionally independent: edits or
    /// external changes to either file can never affect the other one.
    func importVideo(at sourceURL: URL) -> Take? {
        guard let take = makeTake() else { return nil }
        guard importVideo(at: sourceURL, into: take) else {
            delete(take)
            return nil
        }
        return take
    }

    /// The file operation is separate from choosing the private folder so the
    /// transactional contract can be exercised without touching app storage.
    func importVideo(at sourceURL: URL, into take: Take) -> Bool {
        guard let values = try? sourceURL.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              let fileSize = values.fileSize,
              fileSize > 0,
              Self.canImport(fileSize: Int64(fileSize), availableBytes: freeBytes(at: take.folder))
        else { return false }

        // A failed copy leaves at most a partial master inside the take; the
        // caller deletes the whole take.
        return (try? manager.copyItem(at: sourceURL, to: take.videoURL)) != nil
    }

    static func canImport(fileSize: Int64, availableBytes: Int64) -> Bool {
        guard fileSize > 0, availableBytes >= fileSize else { return false }
        return availableBytes - fileSize >= RecorderSupport.minimumFreeBytesToContinue
    }

    /// Keep one independent file for both preview and export. Its folder lives
    /// until the take closes, including while undo can still restore the image.
    func importImage(at sourceURL: URL, into take: Take) -> URL? {
        copyImage(at: sourceURL, into: take.folder)
    }

    /// The same private image copy is used by recordings and saved presets.
    /// The destination must already exist, so a closed recording stays closed.
    func copyImage(at sourceURL: URL, into directory: URL) -> URL? {
        guard let values = try? sourceURL.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let fileSize = values.fileSize,
              Self.canImport(fileSize: Int64(fileSize), availableBytes: freeBytes(at: directory))
        else { return nil }

        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let destination = folder.appendingPathComponent(sourceURL.lastPathComponent)
        do {
            // Never recreate a take that closed while this import was queued.
            try manager.createDirectory(at: folder, withIntermediateDirectories: false,
                                        attributes: [.posixPermissions: 0o700])
            try manager.copyItem(at: sourceURL, to: destination)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            guard Self.isReadableImage(destination) else {
                try? manager.removeItem(at: folder)
                return nil
            }
            return destination
        } catch {
            try? manager.removeItem(at: folder)
            return nil
        }
    }

    private static func isReadableImage(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 1,
        ] as CFDictionary) != nil
    }

    private func freeBytes(at url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    /// Sharing never accepts a raw caller-supplied URL. The staged master must
    /// still be the regular file inside the exact private recording folder
    /// this store assigned to its id, with no symbolic-link escape.
    func owns(_ take: Take) -> Bool {
        guard let root else { return false }
        let expected = root.appendingPathComponent(RecorderSupport.takeFolderName(id: take.id),
                                                    isDirectory: true)
        guard take.folder.standardizedFileURL == expected.standardizedFileURL,
              let folderValues = try? take.folder.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              folderValues.isDirectory == true,
              folderValues.isSymbolicLink != true,
              let videoValues = try? take.videoURL.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              videoValues.isRegularFile == true,
              videoValues.isSymbolicLink != true,
              (videoValues.fileSize ?? 0) > 0
        else { return false }
        return true
    }

    /// The only way a take leaves the disk. Refuses anything that is not a
    /// real `Take-<UUID>` folder directly inside the private root, so a
    /// missing container, a symbolic link or a stray path deletes nothing.
    @discardableResult
    func delete(_ take: Take) -> Bool {
        guard let root, Self.isTakeFolder(take.folder, id: take.id, root: root) else { return false }
        return (try? manager.removeItem(at: take.folder)) != nil
    }

    /// The guard behind `delete`, separate so a harness can name its own root.
    /// Paths are compared with `realpath(3)`: `standardizedFileURL` drops a
    /// `/private` prefix and would let two spellings disagree.
    static func isTakeFolder(_ folder: URL, id: UUID, root: URL) -> Bool {
        guard folder.lastPathComponent == RecorderSupport.takeFolderName(id: id),
              let realRoot = realPath(root),
              let realParent = realPath(folder.deletingLastPathComponent()),
              realParent == realRoot
        else { return false }
        var info = stat()
        guard lstat(folder.path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFDIR
    }

    private static func realPath(_ url: URL) -> String? {
        guard let resolved = realpath(url.path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Copies the finished master to the file the person keeps. Never
    /// deletes: the take stays for the preview and the editor, and the
    /// destination is a new unique name the caller picked.
    func saveCopy(_ take: Take, to destination: URL) throws {
        try manager.copyItem(at: take.videoURL, to: destination)
    }

    func takes() -> [Take] {
        guard let root,
              let names = try? manager.contentsOfDirectory(atPath: root.path)
        else { return [] }
        return names.compactMap { name in
            guard let id = RecorderSupport.takeID(fromFolderName: name) else { return nil }
            return Take(id: id, folder: root.appendingPathComponent(name, isDirectory: true))
        }
    }

    /// When a take stopped being written, read from the master itself so no
    /// extra bookkeeping file has to stay in sync with reality.
    func finishedAt(_ take: Take) -> Date? {
        let values = try? take.videoURL.resourceValues(forKeys: [.contentModificationDateKey])
        return values?.contentModificationDate
    }

    // MARK: - Sweep

    /// Removes folders no editor owns any more: what a crash or a quit left
    /// behind. The recordings that still have an editor on screen are named by
    /// the caller and left alone whatever their age, so an editor left open
    /// overnight never has its master taken out from under it.
    func sweep(keeping owned: Set<UUID> = [], now: Date = Date()) {
        let all = takes().filter { !owned.contains($0.id) }
        guard !all.isEmpty else { return }
        var byID: [UUID: Take] = [:]
        let described: [(id: UUID, finishedAt: Date?, createdAt: Date?)] = all.map { take in
            byID[take.id] = take
            let created = try? take.folder.resourceValues(forKeys: [.creationDateKey]).creationDate
            return (id: take.id, finishedAt: finishedAt(take), createdAt: created)
        }
        for id in RecorderSupport.orphanTakeIDs(described, now: now) {
            if let take = byID[id] { delete(take) }
        }
    }
}
