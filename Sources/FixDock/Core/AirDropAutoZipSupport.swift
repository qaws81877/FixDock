// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import Foundation
import UniformTypeIdentifiers

/// The pure rules of AirDrop auto-zip, new in FixDock. Which files are
/// candidates, how a batch is ordered and named, and when a batch closes.
enum AirDropAutoZipSupport {
    /// A batch closes this long after its last candidate arrived.
    static let quietPeriod: TimeInterval = 5

    /// The quarantine agent macOS records for a file received by AirDrop.
    static let airDropAgent = "sharingd"

    /// `flags;timestamp;agent;uuid`. The agent is the third field.
    static func quarantineAgent(_ value: String?) -> String? {
        guard let value else { return nil }
        let fields = value.split(separator: ";", omittingEmptySubsequences: false)
        guard fields.count >= 3 else { return nil }
        let agent = fields[2].trimmingCharacters(in: .whitespaces)
        return agent.isEmpty ? nil : agent
    }

    /// When the file was received: the second field, hex Unix seconds.
    static func quarantineDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let fields = value.split(separator: ";", omittingEmptySubsequences: false)
        guard fields.count >= 2, let seconds = UInt64(fields[1], radix: 16) else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    /// Clock slack between the quarantine stamp and the watch's start.
    static let receivedSlack: TimeInterval = 60

    /// Only an image received by AirDrop after `receivedAfter` is ever a
    /// candidate. An older AirDrop photo renamed in, or moved into, the
    /// folder is not: its stamp predates the watch. Everything else in the
    /// folder, including the zips this feature writes, is left alone.
    static func isCandidate(name: String, contentType: UTType?, quarantine: String?,
                            receivedAfter: Date) -> Bool {
        guard !name.hasPrefix("."), !isOwnZip(name),
              let contentType, contentType.conforms(to: .image),
              quarantineAgent(quarantine) == airDropAgent,
              let received = quarantineDate(quarantine)
        else { return false }
        return received >= receivedAfter.addingTimeInterval(-receivedSlack)
    }

    static func isOwnZip(_ name: String) -> Bool {
        name.hasPrefix("compressed_images_") && name.lowercased().hasSuffix(".zip")
    }

    /// Capture time first, then the time the file was made, then its name,
    /// so `1` is the first photo taken.
    struct Member: Equatable {
        let name: String
        let captured: Date?
        let created: Date?
    }

    static func ordered(_ members: [Member]) -> [Member] {
        members.sorted { lhs, rhs in
            let left = lhs.captured ?? lhs.created ?? .distantFuture
            let right = rhs.captured ?? rhs.created ?? .distantFuture
            if left != right { return left < right }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    /// `1.heic`, `2.jpg`, … keeping each file's own extension.
    static func sequentialName(index: Int, fileExtension: String) -> String {
        fileExtension.isEmpty ? "\(index)" : "\(index).\(fileExtension.lowercased())"
    }

    /// EXIF `DateTimeOriginal`, `yyyy:MM:dd HH:mm:ss` in the camera's local time.
    static func exifDate(_ value: String?, timeZone: TimeZone = .current) -> Date? {
        guard let value else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: value)
    }

    /// A file is ready once its size has held still across two looks.
    static func isSettled(previous: Int64?, current: Int64) -> Bool {
        guard let previous else { return false }
        return previous == current && current > 0
    }
}
