// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import Foundation

/// The last few hundred health events (secure input on and off, taps that
/// failed or were switched off) in FixDock's own folder, so the feedback
/// report can show what happened before the last restart. The unified log
/// keeps the same lines, but an app cannot read its earlier runs from there.
///
/// Holds only what `KeyTapHealth` writes: never a typed key, never text.
/// The file is FixDock's own; trimming rewrites it whole, owner-only.
final class DiagnosticsJournal {
    static let shared = DiagnosticsJournal()

    static let keepLines = 300
    /// Trimmed back to `keepLines` only past this, so most events cost one
    /// rewrite of a small file rather than a trim each time.
    private static let trimAt = 400

    private let queue = DispatchQueue(label: "FixDock diagnostics journal")
    private var lines: [String]?
    private let fileURL: URL?
    private let stamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    init(fileURL: URL? = PrivateFileStore.containerURL?.appendingPathComponent("diagnostics.log")) {
        self.fileURL = fileURL
    }

    /// Any thread. Writes in the background.
    func record(_ message: String, at date: Date = Date()) {
        queue.async { [self] in
            var current = loadedLines()
            current.append("\(stamp.string(from: date)) \(message)")
            if current.count > Self.trimAt {
                current.removeFirst(current.count - Self.keepLines)
            }
            lines = current
            save(current)
        }
    }

    /// Oldest first, at most `limit`.
    func recent(_ limit: Int = 100) -> [String] {
        queue.sync { Array(loadedLines().suffix(limit)) }
    }

    private func loadedLines() -> [String] {
        if let lines { return lines }
        let read = fileURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            .map { $0.split(separator: "\n").map(String.init) } ?? []
        lines = read
        return read
    }

    private func save(_ current: [String]) {
        guard let fileURL,
              PrivateFileStore.createDirectory(at: fileURL.deletingLastPathComponent())
        else { return }
        PrivateFileStore.write(Data((current.joined(separator: "\n") + "\n").utf8), to: fileURL)
    }
}
