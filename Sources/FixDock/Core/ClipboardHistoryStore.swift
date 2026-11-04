// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import Foundation

enum ClipboardHistoryContent: Equatable {
    case text(String)
    case image(ClipboardImageRef)
    case file(ClipboardFileRef)

    var blobName: ClipboardBlobName? {
        if case .image(let ref) = self { return ref.name }
        return nil
    }

    fileprivate func isSameCopy(as other: ClipboardHistoryContent) -> Bool {
        switch (self, other) {
        case (.text(let a), .text(let b)): return a == b
        case (.image(let a), .image(let b)): return a.name == b.name
        case (.file(let a), .file(let b)): return a.path == b.path
        default: return false
        }
    }
}

struct ClipboardFileRef: Hashable, Codable {
    let path: String
    let isDirectory: Bool

    static let maxPathBytes = 1_024

    init?(path: String, isDirectory: Bool) {
        guard Self.isStandardAbsolute(path) else { return nil }
        self.path = path
        self.isDirectory = isDirectory
    }

    var name: String { (path as NSString).lastPathComponent }

    private enum CodingKeys: String, CodingKey { case path, isDirectory }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let path = try container.decode(String.self, forKey: .path)
        let isDirectory = try container.decode(Bool.self, forKey: .isDirectory)
        guard Self.isStandardAbsolute(path) else {
            throw DecodingError.dataCorruptedError(forKey: .path, in: container, debugDescription: "not a standard path")
        }
        self.path = path
        self.isDirectory = isDirectory
    }

    private static func isStandardAbsolute(_ path: String) -> Bool {
        guard path.hasPrefix("/"), path.utf8.count <= maxPathBytes, !path.utf8.contains(0) else { return false }
        if path == "/" { return true }
        return path.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}

///
struct ClipboardHistoryEntry: Codable, Equatable, Identifiable {
    let id: UUID
    let content: ClipboardHistoryContent
    var copiedAt: Date
    var pinnedAt: Date?
    var source: String?

    var isPinned: Bool { pinnedAt != nil }

    var text: String? {
        if case .text(let text) = content { return text }
        return nil
    }

    static let previewCharacters = 2_000
    static let maxSourceBytes = 255

    var preview: String {
        switch content {
        case .text(let text):
            let prefix = text.prefix(Self.previewCharacters)
            let collapsed = prefix
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\t", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let visible = collapsed.isEmpty ? String(prefix) : collapsed
            return prefix.endIndex == text.endIndex ? visible : visible + "…"
        case .file(let file):
            return file.name
        case .image:
            return ""
        }
    }

    fileprivate init(id: UUID, content: ClipboardHistoryContent, copiedAt: Date, pinnedAt: Date?, source: String?) {
        self.id = id
        self.content = content
        self.copiedAt = copiedAt
        self.pinnedAt = pinnedAt
        self.source = source
    }

    private enum Kind: String, Codable { case text, image, file }

    private enum CodingKeys: String, CodingKey {
        case id, kind, text, image, file, copiedAt, pinnedAt, source
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        copiedAt = try container.decode(Date.self, forKey: .copiedAt)
        pinnedAt = try container.decodeIfPresent(Date.self, forKey: .pinnedAt)
        source = try container.decodeIfPresent(String.self, forKey: .source)
        if let source, source.isEmpty || source.utf8.count > Self.maxSourceBytes {
            throw DecodingError.dataCorruptedError(forKey: .source, in: container, debugDescription: "bad source")
        }
        let kind = try container.decode(Kind.self, forKey: .kind)
        let payloadKeys: [Kind: CodingKeys] = [.text: .text, .image: .image, .file: .file]
        for (other, key) in payloadKeys where other != kind && container.contains(key) {
            throw DecodingError.dataCorruptedError(forKey: key, in: container, debugDescription: "extra payload")
        }
        switch kind {
        case .text: content = .text(try container.decode(String.self, forKey: .text))
        case .image: content = .image(try container.decode(ClipboardImageRef.self, forKey: .image))
        case .file: content = .file(try container.decode(ClipboardFileRef.self, forKey: .file))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        switch content {
        case .text(let text):
            try container.encode(Kind.text, forKey: .kind)
            try container.encode(text, forKey: .text)
        case .image(let ref):
            try container.encode(Kind.image, forKey: .kind)
            try container.encode(ref, forKey: .image)
        case .file(let file):
            try container.encode(Kind.file, forKey: .kind)
            try container.encode(file, forKey: .file)
        }
        try container.encode(copiedAt, forKey: .copiedAt)
        try container.encodeIfPresent(pinnedAt, forKey: .pinnedAt)
        try container.encodeIfPresent(source, forKey: .source)
    }
}

enum ClipboardHistoryCapture {
    case text(String)
    case image(ClipboardImagePayload)
    case files([ClipboardFileRef])
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

enum ClipboardHistoryImageBudget: Int, CaseIterable, Identifiable {
    case mb250 = 250
    case gb1 = 1_024
    case gb5 = 5_120
    case unlimited = 0

    static let `default`: ClipboardHistoryImageBudget = .gb1

    var id: Int { rawValue }
    var bytes: Int? { self == .unlimited ? nil : rawValue * 1_024 * 1_024 }

    init(storedMegabytes: Int?) {
        self = storedMegabytes.flatMap(Self.init(rawValue:)) ?? .default
    }
}

struct ClipboardHistoryRetentionPolicy: Equatable {
    var period: ClipboardHistoryRetention
    var imageBudget: ClipboardHistoryImageBudget
}

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
    /// The history file is absent but own-named images sit beside it (the file
    /// was deleted by hand, or a path changed). An empty history must never be
    /// swept against a real image folder, so this reads as unavailable.
    case imagesWithoutHistory
    case imageFolderNotAFolder

    var concernsImageFolder: Bool { self == .imagesWithoutHistory || self == .imageFolderNotAFolder }
}

///
/// Order: pinned first, newest pin first; then the rest, newest copy first.
struct ClipboardHistoryRecords: Equatable {
    fileprivate(set) var entries: [ClipboardHistoryEntry]

    fileprivate init(entries: [ClipboardHistoryEntry]) {
        self.entries = entries
    }

    var referencedBlobNames: Set<ClipboardBlobName> {
        Set(entries.compactMap(\.content.blobName))
    }

    fileprivate mutating func insert(_ content: ClipboardHistoryContent, source: String?, now: Date) {
        var id = UUID()
        var keptSource = source
        if let index = entries.firstIndex(where: { $0.content.isSameCopy(as: content) }) {
            if entries[index].isPinned {
                entries[index].copiedAt = now
                if let source { entries[index].source = source }
                return
            }
            let existing = entries.remove(at: index)
            id = existing.id
            keptSource = source ?? existing.source
            entries.insert(ClipboardHistoryEntry(id: id, content: existing.content, copiedAt: now,
                                                 pinnedAt: nil, source: keptSource),
                           at: unpinnedIndex(for: now))
            return
        }
        entries.insert(ClipboardHistoryEntry(id: id, content: content, copiedAt: now, pinnedAt: nil, source: keptSource),
                       at: unpinnedIndex(for: now))
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
        entries.insert(entry, at: unpinnedIndex(for: now))
    }

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
            entries = next
        } else {
            entry.pinnedAt = nil
            entry.copiedAt = now
            entries = next
            entries.insert(entry, at: unpinnedIndex(for: now))
        }
        return true
    }

    mutating func remove(_ id: UUID) {
        entries.removeAll { $0.id == id }
    }

    /// Only the unpinned entries a confirmation counted, as they were then
    mutating func clearUnpinned(confirmed: [UUID: Date]) {
        entries.removeAll { !$0.isPinned && confirmed[$0.id] == $0.copiedAt }
    }

    mutating func applyRetention(_ policy: ClipboardHistoryRetentionPolicy, now: Date) {
        var remainingText = ClipboardHistoryStore.maxTextBytes
        var keep = Set<UUID>()
        for entry in entries where entry.isPinned {
            let cost = Self.textCost(entry.content)
            guard cost <= remainingText else { continue }
            remainingText -= cost
            keep.insert(entry.id)
        }
        let cutoff = policy.period == .forever
            ? nil
            : now.addingTimeInterval(-Double(policy.period.rawValue) * 86_400)
        let recent = entries.enumerated()
            .filter { candidate in
                guard !candidate.element.isPinned else { return false }
                guard let cutoff else { return true }
                return candidate.element.copiedAt >= cutoff
            }
            .sorted { $0.element.copiedAt != $1.element.copiedAt
                ? $0.element.copiedAt > $1.element.copiedAt : $0.offset < $1.offset }
            .map(\.element)
        var remainingImages = policy.imageBudget.bytes
        var imagesFull = false
        var kept = 0
        for entry in recent {
            if kept >= ClipboardHistoryRetention.recentCap { break }
            if case .image(let ref) = entry.content {
                if let left = remainingImages {
                    guard !imagesFull, ref.byteCount <= left else {
                        imagesFull = true
                        continue
                    }
                    remainingImages = left - ref.byteCount
                }
            } else {
                let cost = Self.textCost(entry.content)
                guard cost <= remainingText else { continue }
                remainingText -= cost
            }
            keep.insert(entry.id)
            kept += 1
        }
        let next = entries.filter { keep.contains($0.id) }
        if next != entries { entries = next }
    }

    private static func textCost(_ content: ClipboardHistoryContent) -> Int {
        switch content {
        case .text(let text): return text.utf8.count
        case .file(let file): return file.path.utf8.count
        case .image: return 0
        }
    }

    private func unpinnedIndex(for copiedAt: Date) -> Int {
        entries.firstIndex { !$0.isPinned && $0.copiedAt <= copiedAt } ?? entries.endIndex
    }
}

/// Proof that a history file write landed durably, carrying the image names
/// of the snapshot that was saved. The only way to ask
/// `ClipboardHistoryBlobs` to delete anything; made once, in `persist()`.
struct ClipboardHistoryLandedWrite {
    let referenced: Set<ClipboardBlobName>

    fileprivate init(referenced: Set<ClipboardBlobName>) {
        self.referenced = referenced
    }
}

/// Owns `ClipboardHistory.json` in FixDock's private container: its only
///
/// Owns `ClipboardHistory.json`: its only reader and writer, the only place
/// entries are dropped, and the only holder of the image blobs. Main thread
/// only. Saves coalesce to one per main-loop turn and run on a private serial
/// queue, the same queue that writes images.
///
/// The deletion guard is `State`: `.unavailable` holds no records and no
/// blob instance, so capture, retention, remove, clear, save and the image
/// sweep all have nothing to act on.
final class ClipboardHistoryStore {
    enum State: Equatable {
        case ready(ClipboardHistoryRecords)
        case unavailable(ClipboardHistoryStoreProblem)
    }

    static let fileName = "ClipboardHistory.json"
    static let formatVersion = 2
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
    private let blobs: ClipboardHistoryBlobs?

    var entries: [ClipboardHistoryEntry] {
        if case .ready(let records) = state { return records.entries }
        return []
    }

    var problem: ClipboardHistoryStoreProblem? {
        if case .unavailable(let problem) = state { return problem }
        return nil
    }

    var problemItemURL: URL? {
        guard let problem, problem.concernsImageFolder, let container = fileURL?.deletingLastPathComponent()
        else { return fileURL }
        return ClipboardHistoryBlobs.folderURL(in: container)
    }

    var imageLocator: ClipboardImageLocator? { blobs?.locator }

    init(fileURL: URL?,
         persistQueue: DispatchQueue = DispatchQueue(label: "io.github.qaws81877.fixdock.clipboard-history",
                                                     qos: .utility)) {
        self.fileURL = fileURL
        self.persistQueue = persistQueue
        let state = Self.read(fileURL: fileURL)
        self.state = state
        if case .ready = state, let container = fileURL?.deletingLastPathComponent() {
            blobs = ClipboardHistoryBlobs(container: container, queue: persistQueue)
        } else {
            blobs = nil
        }
    }

    @discardableResult
    /// The one way to add content; nothing happens while unavailable. An
    /// image's bytes are queued in this same main turn, behind every save
    /// already queued and ahead of every save that will name it.
    ///
    /// Why a sweep never takes a blob an entry needs: a save snapshots the
    /// records on main and runs on the persist queue, as does this put. A save
    /// taken before this call does not name the image and its sweep ran before
    /// this put wrote it; any save taken after names it and runs after the put.
    /// Remove then re-copy works the same way: the older sweep takes the file,
    /// this put writes it again, the newer save keeps it.
    func record(_ capture: ClipboardHistoryCapture, source: String?, now: Date) -> Bool {
        precondition(Thread.isMainThread)
        var staged: ClipboardImagePayload?
        let ran = mutate { records in
            switch capture {
            case .text(let raw):
                guard let text = Self.storableText(raw) else { return }
                records.insert(.text(text), source: source, now: now)
            case .image(let payload):
                records.insert(.image(payload.ref), source: source, now: now)
                staged = payload
            case .files(let refs):
                for ref in refs.reversed() { records.insert(.file(ref), source: source, now: now) }
            }
        }
        if ran, let staged, let blobs, let fileURL {
            persistQueue.async {
                guard Self.ensureHistoryFile(at: fileURL) else { return }
                blobs.put(staged)
            }
        }
        return ran
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

    /// Durable, because a sweep follows: a power loss must not bring back an
    /// older file that names a swept image. The sweep keeps the names of the
    /// snapshot that was saved, not of what the encoder kept, so a trimmed
    /// entry still in memory keeps its image until memory drops it too.
    private func persist() {
        guard case .ready(let records) = state, let url = fileURL else { return }
        let revision = revision
        let blobs = blobs
        persistQueue.async { [weak self] in
            guard let encoded = Self.encode(records) else { return }
            PrivateFileStore.createDirectory(at: url.deletingLastPathComponent())
            guard PrivateFileStore.writeDurably(encoded.data, to: url) else { return }
            blobs?.sweep(after: ClipboardHistoryLandedWrite(referenced: records.referencedBlobNames))
            guard encoded.kept != records.entries else { return }
            DispatchQueue.main.async {
                guard let self, self.revision == revision else { return }
                self.state = .ready(ClipboardHistoryRecords(entries: encoded.kept))
                self.revision &+= 1
            }
        }
    }

    /// An image is written only beside a history file, so a crash after the put
    /// leaves an orphan of a readable history (swept by the next landed write),
    /// never `.imagesWithoutHistory`. The empty envelope proves nothing about
    /// images, so no sweep follows it.
    private static func ensureHistoryFile(at url: URL) -> Bool {
        var info = stat()
        if lstat(url.path, &info) == 0 { return info.st_mode & S_IFMT == S_IFREG }
        guard errno == ENOENT else { return false }
        PrivateFileStore.createDirectory(at: url.deletingLastPathComponent())
        return PrivateFileStore.writeDurably(envelopePrefix + envelopeSuffix, to: url)
    }

    // MARK: Pure parts

    /// `.ready` only for an absent file with no own-named images beside it, or a
    /// whole, valid envelope of version 1 or 2. Version 1 entries read as text
    /// and are written as version 2 on the next change, never by the read.
    /// Retention is not applied here, so a read alone can never drop anything.
    static func read(fileURL: URL?) -> State {
        guard let fileURL else { return .unavailable(.noContainer) }
        let container = fileURL.deletingLastPathComponent()
        let folder = ClipboardHistoryBlobs.folderState(in: container)
        switch folder {
        case .absent, .folder: break
        case .notAFolder: return .unavailable(.imageFolderNotAFolder)
        case .unreadable(let reason): return .unavailable(.unreadable(reason))
        }
        var info = stat()
        guard lstat(fileURL.path, &info) == 0 else {
            let code = errno
            guard code == ENOENT else { return .unavailable(.unreadable(String(cString: strerror(code)))) }
            guard folder == .folder else { return .ready(ClipboardHistoryRecords(entries: [])) }
            switch ClipboardHistoryBlobs.folderHoldsOwnNames(in: container) {
            case false?: return .ready(ClipboardHistoryRecords(entries: []))
            case true?: return .unavailable(.imagesWithoutHistory)
            case nil: return .unavailable(.unreadable(String(cString: strerror(EACCES))))
            }
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
        let decoded: [ClipboardHistoryEntry]?
        if header.version == 1 {
            decoded = (try? decoder.decode(ClipboardHistoryFileV1.self, from: data))?.entries.map {
                ClipboardHistoryEntry(id: $0.id, content: .text($0.text), copiedAt: $0.copiedAt,
                                      pinnedAt: $0.pinnedAt, source: nil)
            }
        } else {
            decoded = (try? decoder.decode(ClipboardHistoryFileV2.self, from: data))?.entries
        }
        guard let entries = decoded, Set(entries.map(\.id)).count == entries.count
        else { return .unavailable(.undecodable) }
        return .ready(ClipboardHistoryRecords(entries: entries.filter(\.isPinned) + entries.filter { !$0.isPinned }))
    }

    private static let envelopePrefix = Data(#"{"version":2,"entries":["#.utf8)
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
        let rawBound = pinned.reduce(0) { total, entry in
            switch entry.content {
            case .text(let text): return total + 512 + text.utf8.count
            case .file(let file): return total + 512 + file.path.utf8.count
            case .image: return total + 512
            }
        }
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

private struct ClipboardHistoryFileV1: Decodable {
    struct Entry: Decodable {
        let id: UUID
        let text: String
        let copiedAt: Date
        let pinnedAt: Date?
    }

    let version: Int
    let entries: [Entry]
}

private struct ClipboardHistoryFileV2: Decodable {
    let version: Int
    let entries: [ClipboardHistoryEntry]
}
