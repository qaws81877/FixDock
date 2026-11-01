// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import Foundation

/// The app's Application Support container and the only way its contents are
/// created.
///
/// Everything kept there is the user's own material: clipboard history, shelf
/// files, recordings and the deletion tokens for temporary share links. A plain
/// `createDirectory` and `Data.write` take whatever the process umask gives,
/// typically 0755 and 0644, which leaves that material readable by every other
/// account on the Mac. Directories are created owner-only, files are written
/// owner-only, and both are set again on every write, so a container an earlier
/// version left readable heals itself.
enum PrivateFileStore {
    private static let directoryPermissions = 0o700
    private static let filePermissions = 0o600

    /// `~/Library/Application Support/<bundle id>`, nil outside a real bundle.
    /// Building the URL touches no disk; `createDirectory(at:)` does that.
    static var containerURL: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first,
              let bundleID = Bundle.main.bundleIdentifier
        else { return nil }
        return base.appendingPathComponent(bundleID, isDirectory: true)
    }

    /// Creates `url` and its parents owner-only. `container` bounds how far up
    /// the tightening walks and exists so tests can name their own root.
    @discardableResult
    static func createDirectory(at url: URL, container: URL? = containerURL) -> Bool {
        let manager = FileManager.default
        guard (try? manager.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: directoryPermissions])) != nil
        else { return false }
        for directory in directoriesToTighten(from: url, container: container) {
            try? manager.setAttributes([.posixPermissions: directoryPermissions],
                                       ofItemAtPath: directory.path)
        }
        return true
    }

    /// Atomic, owner-only write. `.atomic` swaps in a freshly created file, so
    /// the mode belongs after every write rather than once at creation.
    @discardableResult
    static func write(_ data: Data, to url: URL) -> Bool {
        guard (try? data.write(to: url, options: .atomic)) != nil else { return false }
        try? FileManager.default.setAttributes([.posixPermissions: filePermissions],
                                               ofItemAtPath: url.path)
        return true
    }

    /// Owner-only write that is on disk before it returns: a temporary
    /// sibling, `F_FULLFSYNC`, rename, then the directory synced. Used where
    /// the file is an undo record that must land before the change it guards.
    @discardableResult
    static func writeDurably(_ data: Data, to url: URL) -> Bool {
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(getpid()).tmp")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_TRUNC, mode_t(filePermissions))
        guard fd >= 0 else { return false }
        let written = data.withUnsafeBytes { buffer -> Bool in
            var offset = 0
            while offset < buffer.count {
                let n = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
        let synced = written && fcntl(fd, F_FULLFSYNC) == 0
        close(fd)
        guard synced, rename(temporary.path, url.path) == 0 else {
            unlink(temporary.path)
            return false
        }
        let directory = open(url.deletingLastPathComponent().path, O_RDONLY)
        if directory >= 0 {
            _ = fsync(directory)
            close(directory)
        }
        return true
    }

    /// `url` plus every directory between it and `container`, the container
    /// included. `createDirectory` leaves directories that already exist with
    /// the mode they were created with, so a container from a version that made
    /// it world readable is only fixed by setting the whole chain. Nothing above
    /// the container is ever touched: that part belongs to macOS, not to us.
    static func directoriesToTighten(from url: URL, container: URL?) -> [URL] {
        var chain = [url.standardizedFileURL]
        guard let containerPath = container?.standardizedFileURL.path else { return chain }
        var current = chain[0]
        while current.path != containerPath, current.path.hasPrefix(containerPath + "/") {
            let parent = current.deletingLastPathComponent()
            guard parent.path != current.path else { break }
            chain.append(parent)
            current = parent
        }
        return chain
    }
}
