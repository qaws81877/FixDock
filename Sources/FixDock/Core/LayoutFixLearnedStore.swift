// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import Foundation

/// The words the layout fix was told to leave alone, by undoing a change to
/// them, and the words the person added on the settings page. Only values of
/// this type reach the file, and only `LayoutFixLearnedStore` can make one.
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
    /// In the order they were added.
    private(set) var words: [LayoutFixWord]

    fileprivate init(entries: [Entry] = [], words: [LayoutFixWord] = []) {
        self.entries = entries
        self.words = words
    }

    /// Adds a word the caller checked with `LayoutFixWord.problem`.
    mutating func add(_ word: LayoutFixWord) {
        guard !words.contains(word) else { return }
        words.append(word)
    }

    mutating func remove(_ word: LayoutFixWord) {
        words.removeAll { $0 == word }
    }

    /// A settings import: the backup's words in place of these. Words this
    /// build cannot use, past a list's limit or twice, are left out.
    mutating func replaceWords(with imported: [LayoutFixWord]) {
        var kept: [LayoutFixWord] = []
        for word in imported where LayoutFixWord.problem(adding: word.text, as: word.kind, to: kept, learned: []) == nil {
            kept.append(word)
        }
        words = kept
    }

    func contains(_ key: LearnedKey) -> Bool {
        entries.contains { $0.keys == key.keys && $0.source == key.source }
    }

    /// `times` undos of `key`: added to its entry, or a new entry of that count.
    mutating func countRevert(_ key: LearnedKey, now: Date, times: Int = 1) {
        if let index = entries.firstIndex(where: { $0.keys == key.keys && $0.source == key.source }) {
            entries[index].reverts += times
            entries[index].updatedAt = now
        } else {
            entries.append(Entry(keys: key.keys, source: key.source, reverts: times, updatedAt: now))
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

    /// Drops the entries undone fewer than `threshold` times, which builds
    /// before 1.2.0 wrote from the first undo.
    mutating func forgetBelow(_ threshold: Int) {
        entries.removeAll { $0.reverts < threshold }
    }

    /// The entries undone at least `threshold` times.
    func learned(threshold: Int) -> Set<LearnedKey> {
        Set(entries.filter { $0.reverts >= threshold }.map { LearnedKey(keys: $0.keys, source: $0.source) })
    }
}

/// `LayoutFix.json` in the app's container: words the person typed, so a
/// file with owner-only permissions and not UserDefaults, which travels with
/// settings exports. Only learned words (undone `learnAfter` times) and
/// added words reach it: undos below that are counted in memory and gone at
/// quit (owner, 2026-11-23, so PRIVACY.md holds). A settings export carries the added words only, through
/// `SettingsBackup` (owner, 2026-11-23); the undo counts stay on this Mac.
/// Version 2 added the words: a build that knows only version 1 reads such
/// a file as newer and never writes over it.
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
    private static let formatVersion = 2
    private static let maxEncodedBytes = 1 << 20

    private(set) var state: State
    private let fileURL: URL?
    private let learnAfter: Int
    /// Undos of words not learned yet. Never written.
    private var pendingReverts: [LearnedKey: Int] = [:]

    /// Reads the file and, while `.ready`, drops entries below `learnAfter`
    /// through `mutate`, so a file that is unavailable is never touched.
    init(fileURL: URL?, learnAfter: Int = LayoutFixThresholds().learnAfterReverts) {
        self.fileURL = fileURL
        self.learnAfter = learnAfter
        state = Self.read(fileURL: fileURL)
        mutate { $0.forgetBelow(learnAfter) }
    }

    /// One undo of a fix. A learned word counts on in the file; any other
    /// word is counted here and written once it reaches `learnAfter`.
    func countRevert(_ key: LearnedKey, now: Date) {
        if case .ready(let records) = state, records.contains(key) {
            mutate { $0.countRevert(key, now: now) }
            return
        }
        let count = (pendingReverts[key] ?? 0) + 1
        guard count >= learnAfter else {
            pendingReverts[key] = count
            return
        }
        pendingReverts[key] = nil
        mutate { $0.countRevert(key, now: now, times: count) }
    }

    func forget(_ key: LearnedKey) {
        pendingReverts[key] = nil
        mutate { $0.forget(key) }
    }

    func forgetAll() {
        pendingReverts = [:]
        mutate { $0.forgetAll() }
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
        guard let data = try? JSONEncoder().encode(File(version: Self.formatVersion, entries: records.entries,
                                                        words: records.words)) else { return true }
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
        return .ready(LayoutFixLearnedRecords(entries: file.entries, words: file.words ?? []))
    }

    private struct Header: Decodable { let version: Int }
    private struct File: Codable {
        let version: Int
        let entries: [LayoutFixLearnedRecords.Entry]
        /// Absent in version 1.
        let words: [LayoutFixWord]?
    }
}
