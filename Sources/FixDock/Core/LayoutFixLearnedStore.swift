// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import Foundation

/// The words the layout fix was told to leave alone, by undoing a change to
/// them. Only values of this type reach the file, and only
/// `LayoutFixLearnedStore` can make one.
struct LayoutFixLearnedRecords: Equatable {
    struct Entry: Codable, Equatable {
        var keys: String
        var source: TypedSource
        var reverts: Int
        var updatedAt: Date
    }

    /// Past this many, the entry undone least, and longest ago, goes first.
    static let limit = 500

    private(set) var entries: [Entry]

    fileprivate init(entries: [Entry] = []) {
        self.entries = entries
    }

    mutating func countRevert(_ key: LearnedKey, now: Date) {
        if let index = entries.firstIndex(where: { $0.keys == key.keys && $0.source == key.source }) {
            entries[index].reverts += 1
            entries[index].updatedAt = now
        } else {
            entries.append(Entry(keys: key.keys, source: key.source, reverts: 1, updatedAt: now))
        }
        while entries.count > Self.limit,
              let least = entries.indices.min(by: { (entries[$0].reverts, entries[$0].updatedAt) < (entries[$1].reverts, entries[$1].updatedAt) }) {
            entries.remove(at: least)
        }
    }

    mutating func forget(_ key: LearnedKey) {
        entries.removeAll { $0.keys == key.keys && $0.source == key.source }
    }

    mutating func forgetAll() {
        entries = []
    }

    /// The entries undone at least `threshold` times.
    func learned(threshold: Int) -> Set<LearnedKey> {
        Set(entries.filter { $0.reverts >= threshold }.map { LearnedKey(keys: $0.keys, source: $0.source) })
    }
}

/// `LayoutFix.json` in the app's container: words the person typed, so a
/// file with owner-only permissions and not UserDefaults, which travels with
/// settings exports.
///
/// The guard is `State`. `.ready` exists only after the file was absent or
/// decoded whole as a version this build knows. A file that is unreadable,
/// damaged or from a newer build makes the store `.unavailable`, which holds
/// no records, so nothing can be written over it: every change goes through
/// `mutate`, and `mutate` does nothing unless `.ready`. The file is only
/// ever replaced whole by a write; this type has no way to take it away.
final class LayoutFixLearnedStore {
    enum State: Equatable {
        case ready(LayoutFixLearnedRecords)
        case unavailable(String)
    }

    static let fileName = "LayoutFix.json"
    private static let formatVersion = 1
    private static let maxEncodedBytes = 1 << 20

    private(set) var state: State
    private let fileURL: URL?

    init(fileURL: URL?) {
        self.fileURL = fileURL
        state = Self.read(fileURL: fileURL)
    }

    /// The guard. Runs `change` and writes only while `.ready`; returns
    /// false and changes nothing otherwise. Callers do not check first.
    @discardableResult
    func mutate(_ change: (inout LayoutFixLearnedRecords) -> Void) -> Bool {
        guard case .ready(var records) = state, let fileURL else { return false }
        let before = records
        change(&records)
        guard records != before else { return true }
        state = .ready(records)
        guard let data = try? JSONEncoder().encode(File(version: Self.formatVersion, entries: records.entries)) else { return true }
        PrivateFileStore.createDirectory(at: fileURL.deletingLastPathComponent())
        PrivateFileStore.write(data, to: fileURL)
        return true
    }

    /// `.ready` only for no file at all, or one regular file that decodes
    /// whole as a known version.
    static func read(fileURL: URL?) -> State {
        guard let fileURL else { return .unavailable("no container") }
        var info = stat()
        guard lstat(fileURL.path, &info) == 0 else {
            return errno == ENOENT ? .ready(LayoutFixLearnedRecords()) : .unavailable(String(cString: strerror(errno)))
        }
        guard info.st_mode & S_IFMT == S_IFREG else { return .unavailable("not a regular file") }
        guard info.st_size <= Int64(maxEncodedBytes) else { return .unavailable("too large") }
        guard let data = try? Data(contentsOf: fileURL) else { return .unavailable("unreadable") }
        // The version first, so a newer file is reported as newer even when
        // its entries have a shape this build cannot read.
        guard let header = try? JSONDecoder().decode(Header.self, from: data), header.version >= 1 else {
            return .unavailable("undecodable")
        }
        guard header.version <= formatVersion else { return .unavailable("written by a newer FixDock") }
        guard let file = try? JSONDecoder().decode(File.self, from: data) else { return .unavailable("undecodable") }
        return .ready(LayoutFixLearnedRecords(entries: file.entries))
    }

    private struct Header: Decodable { let version: Int }
    private struct File: Codable {
        let version: Int
        let entries: [LayoutFixLearnedRecords.Entry]
    }
}
