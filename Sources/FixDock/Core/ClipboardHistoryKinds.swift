// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import Foundation

enum ClipboardHistoryKind: String, CaseIterable, Hashable {
    case image, text, link, color, file, email
}

enum ClipboardHistoryFilter: Hashable {
    case all
    case only(ClipboardHistoryKind)

    static let menu: [ClipboardHistoryFilter] = [.all] + ClipboardHistoryKind.allCases.map(Self.only)

    func admits(_ kind: ClipboardHistoryKind) -> Bool {
        switch self {
        case .all: return true
        case .only(let wanted): return wanted == kind
        }
    }
}

enum ClipboardHistoryClassifier {
    static let longTextBytes = 2_048

    static func kind(of content: ClipboardHistoryContent) -> ClipboardHistoryKind {
        switch content {
        case .image: return .image
        case .file: return .file
        case .text(let text): return kind(ofText: text)
        }
    }

    static func kind(ofText text: String) -> ClipboardHistoryKind {
        if text.utf8.count > longTextBytes { return .text }
        if ClipboardHistoryColor.parse(text) != nil { return .color }
        if text.contains(where: \.isWhitespace) || text.isEmpty { return .text }
        if isEmail(text) { return .email }
        if isLink(text) { return .link }
        return .text
    }

    static let linkTopLevelDomains: Set<String> = [
        "com", "net", "org", "edu", "gov", "io", "dev", "app", "co", "ai", "me",
        "kr", "jp", "uk", "de", "fr", "us", "ca", "au", "cn", "info", "xyz",
    ]

    private static func isEmail(_ text: String) -> Bool {
        if text.lowercased().hasPrefix("mailto:") { return text.count > "mailto:".count }
        let parts = text.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty,
              parts[0].unicodeScalars.allSatisfy({ localCharacters.contains($0) }),
              !parts[0].hasPrefix("."), !parts[0].hasSuffix("."), !parts[0].contains("..") else { return false }
        let labels = parts[1].split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy(isDomainLabel),
              let last = labels.last, last.count >= 2, last.allSatisfy(\.isLetter) else { return false }
        return true
    }

    private static func isLink(_ text: String) -> Bool {
        if let range = text.range(of: "://") {
            let scheme = text[..<range.lowerBound]
            guard let first = scheme.unicodeScalars.first, CharacterSet.letters.contains(first),
                  scheme.unicodeScalars.allSatisfy({ schemeCharacters.contains($0) }) else { return false }
            return range.upperBound < text.endIndex
        }
        let host = text.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy(isDomainLabel) else { return false }
        if host.lowercased().hasPrefix("www."), labels.count >= 3 { return true }
        guard host == host.lowercased(), let last = labels.last else { return false }
        return linkTopLevelDomains.contains(String(last))
    }

    private static func isDomainLabel(_ label: Substring) -> Bool {
        !label.isEmpty && !label.hasPrefix("-") && !label.hasSuffix("-")
            && label.unicodeScalars.allSatisfy { domainCharacters.contains($0) }
    }

    private static let asciiAlphanumerics = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
    private static let domainCharacters = asciiAlphanumerics.union(CharacterSet(charactersIn: "-"))
    private static let localCharacters = asciiAlphanumerics.union(CharacterSet(charactersIn: ".!#$%&'*+/=?^_`{|}~-"))
    private static let schemeCharacters = asciiAlphanumerics.union(CharacterSet(charactersIn: "+-."))
}

struct ClipboardHistoryColor: Equatable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    static func parse(_ text: String) -> ClipboardHistoryColor? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { return hex(value.dropFirst()) }
        guard let open = value.firstIndex(of: "("), value.hasSuffix(")") else { return nil }
        let function = value[..<open].lowercased()
        let arguments = value[value.index(after: open)..<value.index(before: value.endIndex)]
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        switch (function, arguments.count) {
        case ("rgb", 3), ("rgba", 4):
            guard let r = channel(arguments[0]), let g = channel(arguments[1]), let b = channel(arguments[2]),
                  let a = arguments.count == 4 ? alpha(arguments[3]) : 1 else { return nil }
            return ClipboardHistoryColor(red: r, green: g, blue: b, alpha: a)
        case ("hsl", 3), ("hsla", 4):
            guard let h = hue(arguments[0]), let s = percent(arguments[1]), let l = percent(arguments[2]),
                  let a = arguments.count == 4 ? alpha(arguments[3]) : 1 else { return nil }
            return fromHSL(hue: h, saturation: s, lightness: l, alpha: a)
        default:
            return nil
        }
    }

    private static func hex(_ digits: Substring) -> ClipboardHistoryColor? {
        guard [3, 4, 6, 8].contains(digits.count), digits.allSatisfy(\.isHexDigit),
              let packed = UInt64(digits, radix: 16) else { return nil }
        let short = digits.count <= 4
        let count = short ? digits.count : digits.count / 2
        let width: UInt64 = short ? 4 : 8
        let maximum = Double((1 << width) - 1)
        var components = (0..<count).map { index -> Double in
            let shift = UInt64(count - 1 - index) * width
            return Double((packed >> shift) & ((1 << width) - 1)) / maximum
        }
        if components.count == 3 { components.append(1) }
        return ClipboardHistoryColor(red: components[0], green: components[1], blue: components[2], alpha: components[3])
    }

    private static func channel(_ text: String) -> Double? {
        if text.hasSuffix("%") { return percent(text) }
        return number(text).map { clamp($0 / 255) }
    }

    private static func alpha(_ text: String) -> Double? {
        if text.hasSuffix("%") { return percent(text) }
        return number(text).map(clamp)
    }

    private static func percent(_ text: String) -> Double? {
        guard text.hasSuffix("%") else { return nil }
        return number(String(text.dropLast())).map { clamp($0 / 100) }
    }

    private static func hue(_ text: String) -> Double? {
        let degrees = text.lowercased().hasSuffix("deg") ? String(text.dropLast(3)) : text
        guard let value = number(degrees) else { return nil }
        let wrapped = value.truncatingRemainder(dividingBy: 360)
        return wrapped < 0 ? wrapped + 360 : wrapped
    }

    private static func number(_ text: String) -> Double? {
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == "." || $0 == "-" || $0 == "+") }),
              let value = Double(text), value.isFinite else { return nil }
        return value
    }

    private static func clamp(_ value: Double) -> Double { min(max(value, 0), 1) }

    private static func fromHSL(hue: Double, saturation: Double, lightness: Double, alpha: Double) -> ClipboardHistoryColor {
        let chroma = (1 - abs(2 * lightness - 1)) * saturation
        let sector = hue / 60
        let second = chroma * (1 - abs(sector.truncatingRemainder(dividingBy: 2) - 1))
        let (r, g, b): (Double, Double, Double)
        switch sector {
        case ..<1: (r, g, b) = (chroma, second, 0)
        case ..<2: (r, g, b) = (second, chroma, 0)
        case ..<3: (r, g, b) = (0, chroma, second)
        case ..<4: (r, g, b) = (0, second, chroma)
        case ..<5: (r, g, b) = (second, 0, chroma)
        default: (r, g, b) = (chroma, 0, second)
        }
        let match = lightness - chroma / 2
        return ClipboardHistoryColor(red: clamp(r + match), green: clamp(g + match), blue: clamp(b + match), alpha: alpha)
    }
}

enum ClipboardHistorySection: CaseIterable, Hashable {
    case pinned, today, yesterday, thisWeek, earlier
}

enum ClipboardHistorySections {
    static func section(for entry: ClipboardHistoryEntry, now: Date, calendar: Calendar) -> ClipboardHistorySection {
        if entry.isPinned { return .pinned }
        if calendar.isDate(entry.copiedAt, inSameDayAs: now) { return .today }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(entry.copiedAt, inSameDayAs: yesterday) { return .yesterday }
        if entry.copiedAt < now, calendar.isDate(entry.copiedAt, equalTo: now, toGranularity: .weekOfYear) {
            return .thisWeek
        }
        return .earlier
    }

    static func grouped(_ entries: [ClipboardHistoryEntry], now: Date,
                        calendar: Calendar) -> [(section: ClipboardHistorySection, entries: [ClipboardHistoryEntry])] {
        var buckets: [ClipboardHistorySection: [ClipboardHistoryEntry]] = [:]
        for entry in entries {
            buckets[section(for: entry, now: now, calendar: calendar), default: []].append(entry)
        }
        return ClipboardHistorySection.allCases.compactMap { section in
            buckets[section].map { (section, $0) }
        }
    }
}
