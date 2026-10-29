// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import Foundation

/// Presets own their pictures independently of the disposable recording.
/// Applying one makes fresh copies in the destination take, including for undo.
struct RecorderPresetImageStore {
    let directory: URL?

    init(directory: URL? = PrivateFileStore.containerURL?
        .appendingPathComponent("RecorderPresetImages", isDirectory: true)) {
        self.directory = directory
    }

    func capture(_ images: [RecorderImageOverlay]) -> [RecorderImageOverlay]? {
        guard !images.isEmpty else { return [] }
        guard let directory, PrivateFileStore.createDirectory(at: directory) else { return nil }
        return copy(images, into: directory)
    }

    func restore(_ images: [RecorderImageOverlay], into take: RecorderTakeStore.Take,
                 duration: Double) -> [RecorderImageOverlay]? {
        guard duration.isFinite, duration > 0,
              images.allSatisfy({ owns(URL(fileURLWithPath: $0.path)) }),
              let restored = copy(images, into: take.folder) else { return nil }
        return restored.map { image in
            var image = image
            image.start = 0
            image.end = duration
            return image
        }
    }

    /// Only retired preset files are passed here. Active edits have their own
    /// copies, so deleting a preset cannot invalidate the document or its undo.
    func remove(_ images: [RecorderImageOverlay]) {
        guard let directory else { return }
        for image in images {
            RecorderImageCopies.remove(URL(fileURLWithPath: image.path), inside: directory)
        }
    }

    private func owns(_ url: URL) -> Bool {
        guard let directory else { return false }
        return RecorderImageCopies.isCopy(url, inside: directory)
    }

    private func copy(_ images: [RecorderImageOverlay], into directory: URL)
        -> [RecorderImageOverlay]? {
        var copied: [RecorderImageOverlay] = []
        for image in images {
            guard let url = RecorderTakeStore.shared.copyImage(
                at: URL(fileURLWithPath: image.path), into: directory) else {
                // Roll back only the fresh copies from this attempt.
                for copy in copied {
                    RecorderImageCopies.remove(URL(fileURLWithPath: copy.path), inside: directory)
                }
                return nil
            }
            var copy = image
            copy.id = UUID()
            copy.path = url.path
            copied.append(copy)
        }
        return copied
    }
}

/// The guard for every picture copy the editor removes. `copyImage` puts each
/// copy in its own `<UUID>` folder directly inside a take or the preset
/// folder; only such a folder is ever removed, compared with `realpath(3)`
/// (`standardizedFileURL` drops a `/private` prefix) and never through a
/// symbolic link.
enum RecorderImageCopies {
    static func isCopy(_ file: URL, inside directory: URL) -> Bool {
        let folder = file.deletingLastPathComponent()
        guard UUID(uuidString: folder.lastPathComponent) != nil,
              let realDirectory = realPath(directory),
              let realParent = realPath(folder.deletingLastPathComponent()),
              realParent == realDirectory
        else { return false }
        var info = stat()
        guard lstat(folder.path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFDIR
    }

    /// Removes the copy's `<UUID>` folder. False when the guard refused or
    /// the removal failed.
    @discardableResult
    static func remove(_ file: URL, inside directory: URL) -> Bool {
        guard isCopy(file, inside: directory) else { return false }
        return (try? FileManager.default.removeItem(at: file.deletingLastPathComponent())) != nil
    }

    private static func realPath(_ url: URL) -> String? {
        guard let resolved = realpath(url.path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
