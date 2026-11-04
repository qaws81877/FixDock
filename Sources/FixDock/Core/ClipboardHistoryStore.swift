// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import Foundation

/// One saved copy. Text only, restored from upstream's entry without its
/// image, file and source-app fields: nothing about where a copy came from
/// is written to disk.
///
/// Decoding is strict (id, text and copiedAt are required). FixDock is the
/// only writer of the file, so a missing field means a damaged file, and a
/// damaged file must read as unreadable, never as a partial history.
struct ClipboardHistoryEntry: Codable, Equatable, Identifiable {
    let id: UUID
    let text: String
    var copiedAt: Date
    var pinnedAt: Date?

    var isPinned: Bool { pinnedAt != nil }

    /// Rows only need enough text to fill their visible lines, so a very
    /// large saved document is never copied again just to draw its row.
    static let previewCharacters = 2_000

    var preview: String {
        let prefix = text.prefix(Self.previewCharacters)
        let collapsed = prefix
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let visible = collapsed.isEmpty ? String(prefix) : collapsed
        return prefix.endIndex == text.endIndex ? visible : visible + "…"
    }
}

/// The owner's periods, stored as days. 0 is "forever"; an unknown stored
/// value reads as the default.
enum ClipboardHistoryRetention: Int, CaseIterable, Identifiable {
    case oneDay = 1
    case week = 7
    case month = 30
    case quarter = 90
    case forever = 0

    static let `default`: ClipboardHistoryRetention = .month
    /// Unpinned entries kept at most, oldest dropped first. Not a setting.
    static let recentCap = 1_000

    var id: Int { rawValue }

    init(storedDays: Int?) {
        self = storedDays.flatMap(Self.init(rawValue:)) ?? .default
    }
}

/// Why the history file is not in use. While any of these holds nothing is
/// recorded, saved or dropped, and the file is never moved, rewritten or
/// deleted.
enum ClipboardHistoryStoreProblem: Equatable {
    /// No Application Support location (no bundle id).
    case noContainer
    /// Something exists at the path but could not be examined or read.
    case unreadable(String)
    /// A symlink, folder or other item that is not a plain file.
    case notARegularFile
    case tooLarge(bytes: Int)
    /// Written by a newer FixDock.
    case newerFormat(version: Int)
    /// Not the envelope, or any single entry fails to decode.
    case undecodable
}

/// The history as it is on disk, or a new empty one when there is no file
/// yet. The initializer is fileprivate: only `ClipboardHistoryStore.read`
/// makes one, from an absent file or a whole, valid decode. Every operation
/// that drops entries is a method here and the encoder takes only this
/// type, so neither a drop nor a save can be aimed at a file that did not
/// read.
///
/// Order: pinned first, newest pin first; then the rest, newest copy first.
struct ClipboardHistoryRecords: Equatable {
    fileprivate(set) var entries: [ClipboardHistoryEntry]

    fileprivate init(entries: [ClipboardHistoryEntry]) {
        self.entries = entries
    }

    /// A copy of text already saved refreshes that entry, keeping its id and
    /// its pin, instead of adding a second one.
    mutating func record(_ text: String, now: Date) {
        guard let text = ClipboardHistoryStore.storableText(text) else { return }
        if let index = entries.firstIndex(where: { $0.text == text }) {
            if entries[index].isPinned {
                entries[index].copiedAt = now
                return
            }
            let existing = entries.remove(at: index)
            entries.insert(ClipboardHistoryEntry(id: existing.id, text: text, copiedAt: now, pinnedAt: nil),
                           at: firstRecentIndex)
            return
        }
        entries.insert(ClipboardHistoryEntry(id: UUID(), text: text, copiedAt: now, pinnedAt: nil),
                       at: firstRecentIndex)
    }

    /// A chosen entry counts as just copied. Pinned entries keep their place.
    mutating func touch(_ id: UUID, now: Date) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        if entries[index].isPinned {
            entries[index].copiedAt = now
            return
        }
        var entry = entries.remove(at: index)
        entry.copiedAt = now
        entries.insert(entry, at: firstRecentIndex)
    }

    /// Unpinning puts the entry at the top of the rest with `copiedAt = now`,
    /// so retention cannot drop it on the spot and silently undo the unpin.
    /// A pin the file could no longer hold is refused (false), because the
    /// encoder would otherwise drop a pinned entry to fit.
    @discardableResult
    mutating func setPinned(_ pinned: Bool, id: UUID, now: Date) -> Bool {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return false }
        guard entries[index].isPinned != pinned else { return true }
        var next = entries
        var entry = next.remove(at: index)
        if pinned {
            entry.pinnedAt = now
            next.insert(entry, at: 0)
            guard ClipboardHistoryStore.pinnedEntriesFit(next) else { return false }
        } else {
            entry.pinnedAt = nil
            entry.copiedAt = now
            next.insert(entry, at: next.firstIndex { !$0.isPinned } ?? next.endIndex)
        }
        entries = next
        return true
    }

    mutating func remove(_ id: UUID) {
        entries.removeAll { $0.id == id }
    }

    /// Only the unpinned entries a confirmation counted, as they were then
    /// (`id -> copiedAt`): a copy that lands while it is open survives, even
    /// a new copy of a counted text.
    mutating func clearUnpinned(confirmed: [UUID: Date]) {
        entries.removeAll { !$0.isPinned && confirmed[$0.id] == $0.copiedAt }
    }

    /// Pinned entries are exempt from the period and the cap. Unpinned ones
    /// older than the period go, then all but the newest `recentCap`, then
    /// whatever no longer fits the text budget (pins counted first).
    mutating func applyRetention(_ retention: ClipboardHistoryRetention, now: Date) {
        var remainingBytes = ClipboardHistoryStore.maxTextBytes
        func retained(_ candidates: [ClipboardHistoryEntry], limit: Int?) -> [ClipboardHistoryEntry] {
            var result: [ClipboardHistoryEntry] = []
            for entry in candidates {
                if let limit, result.count >= limit { break }
                let byteCount = entry.text.utf8.count
                guard byteCount <= remainingBytes else { continue }
                remainingBytes -= byteCount
                result.append(entry)
            }
            return result
        }
        let cutoff = retention == .forever
            ? nil
            : now.addingTimeInterval(-Double(retention.rawValue) * 86_400)
        let pinned = retained(entries.filter(\.isPinned), limit: nil)
        let recent = retained(entries.filter { entry in
            guard !entry.isPinned else { return false }
            guard let cutoff else { return true }
            return entry.copiedAt >= cutoff
        }, limit: ClipboardHistoryRetention.recentCap)
        let kept = pinned + recent
        if kept != entries { entries = kept }
    }

    private var firstRecentIndex: Int { entries.firstIndex { !$0.isPinned } ?? entries.endIndex }
}

/// Owns `ClipboardHistory.json` in FixDock's private container: its only
/// reader and writer, and the only place entries are dropped. Main thread
/// only. The file is read once, in `init`; saves coalesce to one per
/// main-loop turn and are encoded and written on a private serial queue.
///
/// The deletion guard is `State`. `mutate` runs a change only in `.ready`;
/// `.unavailable` holds no records to hand out, so capture, retention,
/// remove, clear and save all have nothing to act on.
final class ClipboardHistoryStore {
    enum State: Equatable {
        case ready(ClipboardHistoryRecords)
        case unavailable(ClipboardHistoryStoreProblem)
    }

    static let fileName = "ClipboardHistory.json"
    static let formatVersion = 1
    /// Upstream's bounds: a copied document stays available while a
    /// pathological payload still has a firm bound in memory and on disk.
    static let maxCharacters = 1_000_000
    static let maxTextBytes = 64 * 1_024 * 1_024
    static let maxEncodedBytes = 96 * 1_024 * 1_024

    let fileURL: URL?
    private(set) var state: State
    /// Bumped on every change to the entries, saves that trimmed them
    /// included, so caches keyed on it cannot outlive what they describe.
    private(set) var revision = 0
    private let persistQueue: DispatchQueue
    private var saveScheduled = false

    var entries: [ClipboardHistoryEntry] {
        if case .ready(let records) = state { return records.entries }
        return []
    }

    var problem: ClipboardHistoryStoreProblem? {
        if case .unavailable(let problem) = state { return problem }
        return nil
    }

    /// Reads the file. Never writes and never creates the folder.
    init(fileURL: URL?,
         persistQueue: DispatchQueue = DispatchQueue(label: "io.github.qaws81877.fixdock.clipboard-history",
                                                     qos: .utility)) {
        self.fileURL = fileURL
        self.persistQueue = persistQueue
        state = Self.read(fileURL: fileURL)
    }

    /// The guard. Runs `change` and schedules a save only while `.ready`;
    /// returns false and changes nothing otherwise. Callers do not check
    /// first: this is the check.
    @discardableResult
    func mutate(_ change: (inout ClipboardHistoryRecords) -> Void) -> Bool {
        precondition(Thread.isMainThread)
        guard case .ready(var records) = state else { return false }
        let before = records
        change(&records)
        guard records != before else { return true }
        state = .ready(records)
        revision &+= 1
        scheduleSave()
        return true
    }

    /// Runs a pending save now and waits for it to land, so the last change
    /// of a session (often a Clear) is on disk before the process ends.
    func flush() {
        if saveScheduled {
            saveScheduled = false
            persist()
        }
        persistQueue.sync {}
    }

    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self, self.saveScheduled else { return }
            self.saveScheduled = false
            self.persist()
        }
    }

    private func persist() {
        guard case .ready(let records) = state, let url = fileURL else { return }
        let revision = revision
        persistQueue.async { [weak self] in
            guard let encoded = Self.encode(records) else { return }
            PrivateFileStore.createDirectory(at: url.deletingLastPathComponent())
            guard PrivateFileStore.write(encoded.data, to: url) else { return }
            guard encoded.kept != records.entries else { return }
            // What the file could not hold is gone from it, so it goes from
            // memory too, unless a newer change will be saved anyway.
            DispatchQueue.main.async {
                guard let self, self.revision == revision else { return }
                self.state = .ready(ClipboardHistoryRecords(entries: encoded.kept))
                self.revision &+= 1
            }
        }
    }

    // MARK: Pure parts

    /// `.ready` only for an absent file or a whole, valid envelope of this
    /// version or older. Retention is not applied here, so a read alone can
    /// never drop anything.
    static func read(fileURL: URL?) -> State {
        guard let fileURL else { return .unavailable(.noContainer) }
        var info = stat()
        guard lstat(fileURL.path, &info) == 0 else {
            let code = errno
            if code == ENOENT { return .ready(ClipboardHistoryRecords(entries: [])) }
            return .unavailable(.unreadable(String(cString: strerror(code))))
        }
        guard info.st_mode & S_IFMT == S_IFREG else { return .unavailable(.notARegularFile) }
        guard info.st_size <= Int64(maxEncodedBytes) else { return .unavailable(.tooLarge(bytes: Int(info.st_size))) }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            return .unavailable(.unreadable(error.localizedDescription))
        }
        guard data.count <= maxEncodedBytes else { return .unavailable(.tooLarge(bytes: data.count)) }
        let decoder = JSONDecoder()
        // The version first, so a newer file is reported as newer even when
        // its entries would not decode here.
        guard let header = try? decoder.decode(ClipboardHistoryFileVersion.self, from: data),
              header.version >= 1 else { return .unavailable(.undecodable) }
        guard header.version <= formatVersion else { return .unavailable(.newerFormat(version: header.version)) }
        guard let file = try? decoder.decode(ClipboardHistoryFile.self, from: data),
              // Two entries with one id would make a removal take both.
              Set(file.entries.map(\.id)).count == file.entries.count
        else { return .unavailable(.undecodable) }
        let entries = file.entries.filter(\.isPinned) + file.entries.filter { !$0.isPinned }
        return .ready(ClipboardHistoryRecords(entries: entries))
    }

    private static let envelopePrefix = Data(#"{"version":1,"entries":["#.utf8)
    private static let envelopeSuffix = Data("]}".utf8)

    /// Upstream's encoder inside the envelope: entries encoded one by one,
    /// pins first, and any entry that would push the file past
    /// `maxEncodedBytes` left out. JSON escaping can make the file much
    /// larger than the text budget, so the bound is checked on the bytes.
    static func encode(_ records: ClipboardHistoryRecords) -> (data: Data, kept: [ClipboardHistoryEntry])? {
        let encoder = JSONEncoder()
        let ordered = records.entries.filter(\.isPinned) + records.entries.filter { !$0.isPinned }
        var kept: [ClipboardHistoryEntry] = []
        var encodedEntries: [Data] = []
        var size = envelopePrefix.count + envelopeSuffix.count
        for entry in ordered {
            guard let encoded = try? encoder.encode(entry) else { return nil }
            let added = encoded.count + (encodedEntries.isEmpty ? 0 : 1)
            guard size + added <= maxEncodedBytes else { continue }
            kept.append(entry)
            encodedEntries.append(encoded)
            size += added
        }
        var data = Data(capacity: size)
        data.append(envelopePrefix)
        for (index, encoded) in encodedEntries.enumerated() {
            if index > 0 { data.append(0x2C) }
            data.append(encoded)
        }
        data.append(envelopeSuffix)
        return (data, kept)
    }

    /// Without the surrounding space, non-empty, and within `maxCharacters`.
    static func storableText(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxCharacters else { return nil }
        return trimmed
    }

    /// Whether the pinned entries alone still fit the file.
    static func pinnedEntriesFit(_ entries: [ClipboardHistoryEntry]) -> Bool {
        let pinned = entries.filter(\.isPinned)
        let limit = maxEncodedBytes - envelopePrefix.count - envelopeSuffix.count
        // JSON escaping turns one UTF-8 byte into at most six and an entry's
        // other fields stay under 512 bytes, so a small pinned set is never
        // encoded on the main thread just to be measured.
        let rawBound = pinned.reduce(0) { $0 + 512 + $1.text.utf8.count }
        guard rawBound > limit / 6 else { return true }
        let encoder = JSONEncoder()
        var size = 0
        for (offset, entry) in pinned.enumerated() {
            guard let encoded = try? encoder.encode(entry) else { return false }
            size += encoded.count + (offset == 0 ? 0 : 1)
            if size > limit { return false }
        }
        return true
    }
}

private struct ClipboardHistoryFileVersion: Decodable { let version: Int }
private struct ClipboardHistoryFile: Decodable {
    let version: Int
    let entries: [ClipboardHistoryEntry]
}
