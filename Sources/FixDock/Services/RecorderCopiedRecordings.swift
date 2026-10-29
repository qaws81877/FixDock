// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import Foundation

/// Where the editor's Copy writes the file it puts on the clipboard: the
/// app's own cache folder, `~/Library/Caches/<bundle id>/Copied Recordings`.
/// Split out of upstream's `RecorderEditorController.copyDestination` so the
/// sweep has one guarded place.
enum RecorderCopiedRecordings {
    static let maxAge: TimeInterval = 24 * 3600

    /// Nil outside a real bundle, and then nothing is written or swept.
    static func folder() -> URL? {
        guard let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first,
              let bundleID = Bundle.main.bundleIdentifier
        else { return nil }
        return base.appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("Copied Recordings", isDirectory: true)
    }

    static func prepare(_ folder: URL) -> Bool {
        (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                  attributes: [.posixPermissions: 0o700])) != nil
    }

    /// Removes copies older than `maxAge`. Only plain files directly in the
    /// folder: a symbolic link or a folder someone put there is left alone.
    static func sweep(_ folder: URL, now: Date = Date()) {
        let manager = FileManager.default
        guard let files = try? manager.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return }
        let cutoff = now.addingTimeInterval(-maxAge)
        for file in files {
            var info = stat()
            guard lstat(file.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
                  let modified = try? file.resourceValues(
                    forKeys: [.contentModificationDateKey]).contentModificationDate,
                  modified < cutoff
            else { continue }
            try? manager.removeItem(at: file)
        }
    }
}
