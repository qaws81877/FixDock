// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import Foundation

/// One text snippet: typing the trigger inserts the replacement. Stored as
/// JSON in defaults; ids and raw values are persisted, so keep them stable.
/// `folder` and `showsInLibrary` belong to upstream's snippet library, which
/// FixDock does not have yet; they are kept so stored snippets round-trip.
struct TextSnippet: Codable, Identifiable, Equatable {
    /// When the replacement fires relative to the trigger.
    enum Expansion: String, Codable, CaseIterable {
        /// The moment the last trigger character is typed.
        case immediate
        /// Only when space, Tab or Return follows the trigger (the delimiter
        /// itself is kept, typed after the replacement).
        case afterDelimiter
    }

    var id = UUID()
    var name = ""
    var trigger = ""
    var replacement = ""
    var expansion = Expansion.afterDelimiter
    var enabled = true
    var ignoresCase = false
    /// Plain folder name for the library; empty means no folder. Folders are
    /// derived from the snippets themselves, so there is no folder entity to
    /// migrate or orphan.
    var folder = ""
    var showsInLibrary = true

    enum CodingKeys: String, CodingKey {
        case id, name, trigger, replacement, expansion, enabled, ignoresCase, folder, showsInLibrary
    }
}

extension TextSnippet {
    /// Snippets stored before an option existed have no key for it; each one
    /// falls back to the behavior of its day (exact matching, no folder,
    /// visible in the library).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        trigger = try container.decode(String.self, forKey: .trigger)
        replacement = try container.decode(String.self, forKey: .replacement)
        expansion = try container.decode(Expansion.self, forKey: .expansion)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        ignoresCase = try container.decodeIfPresent(Bool.self, forKey: .ignoresCase) ?? false
        folder = try container.decodeIfPresent(String.self, forKey: .folder) ?? ""
        showsInLibrary = try container.decodeIfPresent(Bool.self, forKey: .showsInLibrary) ?? true
    }
}

/// The pure half of the snippets engine: buffer bookkeeping, trigger
/// matching and variable expansion, all deterministic and injectable so the
/// harness can pin the behavior down.
enum TextSnippetSupport {
    /// Keystrokes the buffer remembers; longer triggers cannot match.
    static let bufferLimit = 64
    static let maxTriggerLength = 40

    /// Characters that fire an afterDelimiter snippet.
    static let delimiters: Set<Character> = [" ", "\t", "\r", "\n"]

    /// Triggers cannot contain whitespace (the buffer resets on it) and stay
    /// within a sane length.
    static func sanitizedTrigger(_ raw: String) -> String {
        String(raw.filter { !$0.isWhitespace }.prefix(maxTriggerLength))
    }

    /// The typing buffer after one insertion. Anything beyond the limit
    /// slides off the front; the buffer only ever needs to hold the longest
    /// possible trigger.
    static func bufferAppending(_ buffer: String, typed: String) -> String {
        let next = buffer + typed
        return String(next.suffix(bufferLimit))
    }

    /// The snippet whose trigger the buffer just completed for the given
    /// expansion mode. The longest trigger wins, so ";email2" beats ";email"
    /// the way the user expects.
    static func match(buffer: String,
                      expansion: TextSnippet.Expansion,
                      snippets: [TextSnippet]) -> TextSnippet? {
        var best: TextSnippet?
        for snippet in snippets where snippet.enabled
            && snippet.expansion == expansion
            && !snippet.trigger.isEmpty
            && completes(buffer, trigger: snippet.trigger, ignoresCase: snippet.ignoresCase) {
            if let current = best, current.trigger.count >= snippet.trigger.count { continue }
            best = snippet
        }
        return best
    }

    /// Whether the buffer just finished typing the trigger. The insensitive
    /// path compares exactly `trigger.count` characters, so the deletes the
    /// expansion posts always erase precisely what the user typed.
    static func completes(_ buffer: String, trigger: String, ignoresCase: Bool) -> Bool {
        guard ignoresCase else { return buffer.hasSuffix(trigger) }
        guard buffer.count >= trigger.count else { return false }
        return String(buffer.suffix(trigger.count))
            .compare(trigger, options: .caseInsensitive) == .orderedSame
    }

    /// The part of `trigger` the expansion's backspaces clear, as it was
    /// typed: the end of `buffer` that completed it, less `swallowed`, the key
    /// that completed an immediate trigger and never reached the field. The
    /// stored trigger can differ in case, or in Unicode normalization when it
    /// was pasted in, and so in UTF-16 length.
    static func typedTrigger(_ trigger: String, buffer: String, swallowed: String = "") -> String {
        String(buffer.suffix(trigger.count).dropLast(swallowed.count))
    }

    /// The snippet `buffer` just completed, with the backspaces that clear
    /// its trigger and the text they clear, both decided by `swallowed` in
    /// one place: the key that completed an immediate trigger, or "" after a
    /// delimiter, which never enters the buffer.
    static func expansionMatch(buffer: String,
                               expansion: TextSnippet.Expansion,
                               snippets: [TextSnippet],
                               swallowed: String)
        -> (snippet: TextSnippet, deleteCount: Int, typedTrigger: String)? {
        guard let snippet = match(buffer: buffer, expansion: expansion, snippets: snippets) else { return nil }
        return (snippet,
                max(0, snippet.trigger.count - swallowed.count),
                typedTrigger(snippet.trigger, buffer: buffer, swallowed: swallowed))
    }

    /// Replaces the dynamic variables. Unknown {{tags}} pass through
    /// untouched, so a typo stays visible instead of vanishing silently.
    /// The one variable whose value comes from somewhere that can hang: the
    /// general pasteboard may hold content an app renders only on demand, and
    /// an app that stops answering never answers. Both expansion paths ask
    /// this first, so a replacement without the variable pays nothing.
    static func needsClipboard(_ replacement: String) -> Bool {
        replacement.contains("{{clipboard}}")
    }

    static func requiresPaste(_ text: String) -> Bool {
        text.contains(where: \.isNewline)
    }

    static func pastePayload(text: String, trailingText: String) -> String {
        text + trailingText.replacingOccurrences(of: "\r", with: "\n")
    }

    /// The backspaces that clear the `deleteCount` characters of a trigger,
    /// `typed`, from the focused text. A field that completes as you type
    /// shows the rest selected after the caret: a browser's address bar turns
    /// "gitgra" into "gitgra[ph]". The first backspace then removes only that
    /// selection, so it takes one more, or the trigger keeps its first
    /// character (issue #1377). Only a selection that starts after the
    /// trigger and runs to the end of the text counts, measured in the UTF-16
    /// units Accessibility counts in. A selection elsewhere is not where the
    /// backspaces land: a terminal can keep one in its scrollback while you
    /// type at the prompt.
    ///
    /// Such a selection is then checked against `textBefore`, the field's
    /// text in the range right before it, which has to be the typed trigger:
    /// keys can go to a launcher's panel that never activates its app, while
    /// the field asked belongs to the app behind it. Compared without case,
    /// since a field can capitalize what was typed. A field that does not say,
    /// or does not answer in time, keeps the plain count: the extra backspace
    /// would otherwise go out unchecked exactly when an app is slow. Without
    /// `typed` there is nothing to check, so no selection counts.
    static func triggerDeleteCount(_ deleteCount: Int,
                                   typed: String,
                                   focusedSelection: (range: NSRange, textLength: Int)?,
                                   textBefore: (NSRange) -> String?) -> Int {
        guard deleteCount > 0, !typed.isEmpty, let focusedSelection else { return deleteCount }
        let range = focusedSelection.range
        let typedLength = typed.utf16.count
        guard range.length > 0,
              range.location >= typedLength,
              NSMaxRange(range) == focusedSelection.textLength
        else { return deleteCount }
        guard let before = textBefore(NSRange(location: range.location - typedLength, length: typedLength))
        else { return deleteCount }
        return before.compare(typed, options: .caseInsensitive) == .orderedSame ? deleteCount + 1 : deleteCount
    }

    static func expand(_ replacement: String,
                       date: Date,
                       clipboard: String?,
                       locale: Locale = .current) -> String {
        guard replacement.contains("{{") else { return replacement }
        let dateFormatter = DateFormatter()
        dateFormatter.locale = locale
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .none
        let timeFormatter = DateFormatter()
        timeFormatter.locale = locale
        timeFormatter.dateStyle = .none
        timeFormatter.timeStyle = .short
        let dateText = dateFormatter.string(from: date)
        let timeText = timeFormatter.string(from: date)
        let expanded = replacement
            .replacingOccurrences(of: "{{date}}", with: dateText)
            .replacingOccurrences(of: "{{time}}", with: timeText)
            .replacingOccurrences(of: "{{datetime}}", with: "\(dateText) \(timeText)")
        // The clipboard goes in last so pasted text is never re-expanded.
        return expandingFormattedDates(expanded, date: date, locale: locale)
            .replacingOccurrences(of: "{{clipboard}}", with: clipboard ?? "")
    }

    /// The date variables also take an explicit pattern after a colon, in the
    /// system's own date-format language: {{date:yyyy-MM-dd}}, and the same
    /// for time and datetime so every spelling works. The pattern keeps the
    /// user's locale, so month and weekday names come out in their language.
    /// A variant with an explicit IANA identifier after the kind,
    /// {{date-tz(America/New_York):yyyy-MM-dd}}, overrides the device's
    /// current time zone for that one token.
    private static let formattedDateKinds = ["date", "time", "datetime"]

    /// Configures a DateFormatter's pattern and timezone override. Called by
    /// both expandingFormattedDates and configuredFormatter to ensure a single
    /// place decides how these two properties map from pattern and identifier.
    private static func configure(_ formatter: DateFormatter,
                                  pattern: String,
                                  timeZoneIdentifier: String?) {
        formatter.dateFormat = pattern
        formatter.timeZone = timeZoneIdentifier.flatMap { TimeZone(identifier: $0) }
    }

    /// A fresh formatter for one-off use (a preview), as opposed to
    /// expandingFormattedDates's single instance reused across a whole
    /// replacement string's tokens.
    private static func configuredFormatter(pattern: String,
                                            timeZoneIdentifier: String?,
                                            locale: Locale) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        configure(formatter, pattern: pattern, timeZoneIdentifier: timeZoneIdentifier)
        return formatter
    }

    private static func expandingFormattedDates(_ text: String,
                                                date: Date,
                                                locale: Locale) -> String {
        guard formattedDateKinds.contains(where: { text.contains("{{\($0)") }) else { return text }
        let formatter = DateFormatter()
        formatter.locale = locale
        var result = ""
        var rest = Substring(text)
        while let start = rest.range(of: "{{") {
            result += rest[..<start.lowerBound]
            let tail = rest[start.lowerBound...]
            guard let close = tail.range(of: "}}"),
                  let match = formattedPattern(in: tail[..<close.lowerBound]) else {
                result += "{{"
                rest = rest[start.upperBound...]
                continue
            }
            configure(formatter, pattern: match.pattern, timeZoneIdentifier: match.timeZoneIdentifier)
            result += formatter.string(from: date)
            rest = rest[close.upperBound...]
        }
        return result + rest
    }

    /// The kind, pattern and optional time zone inside one "{{name:pattern"
    /// or "{{name-tz(identifier):pattern" chunk, nil when the tag is not a
    /// date variable, malformed, or the pattern is empty (all stay visible,
    /// like any unknown tag).
    private static func formattedPattern(in tag: Substring) -> (kind: String, pattern: String, timeZoneIdentifier: String?)? {
        for kind in formattedDateKinds {
            let tzPrefix = "{{\(kind)-tz("
            if tag.hasPrefix(tzPrefix) {
                let afterPrefix = tag.dropFirst(tzPrefix.count)
                guard let closeParen = afterPrefix.firstIndex(of: ")") else { return nil }
                let identifier = String(afterPrefix[..<closeParen])
                let afterIdentifier = afterPrefix[afterPrefix.index(after: closeParen)...]
                guard afterIdentifier.hasPrefix(":") else { return nil }
                let pattern = String(afterIdentifier.dropFirst())
                // An identifier this Mac cannot resolve leaves the tag
                // literal rather than quietly formatting in the device's
                // own zone: a plausible-looking wrong time is worse than a
                // tag the user can see is wrong, and the captions now
                // invite typing these by hand.
                guard !pattern.isEmpty, TimeZone(identifier: identifier) != nil else { return nil }
                return (kind, pattern, identifier)
            }
            let plainPrefix = "{{\(kind):"
            if tag.hasPrefix(plainPrefix) {
                let pattern = String(tag.dropFirst(plainPrefix.count))
                return pattern.isEmpty ? nil : (kind, pattern, nil)
            }
        }
        return nil
    }

    /// Snippets in the order lists show them: alphabetical by the title rows
    /// display, the trigger standing in for an unnamed snippet, with the stored
    /// order breaking ties. Storage keeps creation order.
    static func sortedForDisplay(_ snippets: [TextSnippet]) -> [TextSnippet] {
        snippets.enumerated().sorted { lhs, rhs in
            let left = lhs.element.name.isEmpty ? lhs.element.trigger : lhs.element.name
            let right = rhs.element.name.isEmpty ? rhs.element.trigger : rhs.element.name
            switch left.localizedStandardCompare(right) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: return lhs.offset < rhs.offset
            }
        }.map(\.element)
    }

    // MARK: - Persistence

    static func decode(_ data: Data?) -> [TextSnippet] {
        decodeStored(data) ?? []
    }

    /// Nil when snippets are stored but cannot be read, such as a format
    /// from a newer build. Settings then refuses to write, because saving
    /// over that data would delete every snippet in it. No data at all is
    /// an empty library, not an unreadable one.
    static func decodeStored(_ data: Data?) -> [TextSnippet]? {
        guard let data else { return [] }
        return try? JSONDecoder().decode([TextSnippet].self, from: data)
    }

    static func encode(_ snippets: [TextSnippet]) -> Data? {
        try? JSONEncoder().encode(snippets)
    }
}
