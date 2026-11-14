// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import Foundation

// The pure half of the Korean/English layout fix: the word lists, the word
// being judged, and the rules that decide whether it was typed in the wrong
// layout. The rules are FixDock's own and are numbered as in
// docs/typo-switch.md, section 3 (N: never change, C: change at a word end,
// M: change while typing).

/// First guesses, to be set from the sentence replay and then from use.
struct LayoutFixThresholds: Equatable {
    var minKeys = 2
    /// The same for a word typed in the Latin source, where two keys are a
    /// command or an abbreviation as easily as a Korean word (rm is 그, cp
    /// is 체). Jamo-only chat words (zz for ㅋㅋ) are exempt.
    var minKeysFromLatin = 3
    var shortTokenKeys = 3
    var rareRank = 30_000
    var commonRank = 5_000
    var minKeysWhileTyping = 4
    var whileTypingMaxRank = 20_000
    var learnAfterReverts = 3
    /// Rule C5: with this many whole syllables or more, a Korean reading
    /// counts without being a list word (owner, 2026-11-13). nil: off.
    var wholeSyllables: Int? = 2
    var undoWindowSeconds: TimeInterval = 5
    var handOffTimeout: TimeInterval = 0.5
}

/// One language's words in key-space notation, sorted, so that an exact
/// lookup and a "does any word start with these keys" lookup are both binary
/// searches. In Hangul text "안녀" is no prefix of "안녕"; in key space "dkssu"
/// is a prefix of "dkssud".
struct Lexicon {
    private let words: [[UInt8]]
    /// Line number in the list file, 1 the most frequent.
    private let ranks: [Int32]
    /// How many of `words[..<index]` have a rank within the while-typing limit.
    private let commonBefore: [Int32]

    var count: Int { words.count }

    /// `text` is one word per line, most frequent first. English words are
    /// their own keys. A Korean word is kept only if its keys compose back
    /// into it. nil when nothing is left.
    static func load(_ text: String, as language: TypedSource, whileTypingMaxRank: Int) -> Lexicon? {
        var entries: [(keys: [UInt8], rank: Int32)] = []
        var rank: Int32 = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            rank += 1
            let word = String(line)
            switch language {
            case .latin:
                guard word.utf8.allSatisfy({ (UInt8(ascii: "a")...UInt8(ascii: "z")).contains($0) }) else { continue }
                entries.append((Array(word.utf8), rank))
            case .hangul2:
                guard let keys = HangulTwoSet.keySpace(ofHangul: word),
                      HangulTwoSet.hangul(fromKeySpace: keys) == word else { continue }
                entries.append((Array(keys.utf8), rank))
            }
        }
        guard !entries.isEmpty else { return nil }
        // The same keys twice keep the better rank.
        entries.sort { $0.keys == $1.keys ? $0.rank < $1.rank : $0.keys.lexicographicallyPrecedes($1.keys) }
        var words: [[UInt8]] = []
        var ranks: [Int32] = []
        for entry in entries where words.last != entry.keys {
            words.append(entry.keys)
            ranks.append(entry.rank)
        }
        var commonBefore: [Int32] = [0]
        commonBefore.reserveCapacity(words.count + 1)
        for rank in ranks {
            commonBefore.append(commonBefore[commonBefore.count - 1] + (Int(rank) <= whileTypingMaxRank ? 1 : 0))
        }
        return Lexicon(words: words, ranks: ranks, commonBefore: commonBefore)
    }

    private init(words: [[UInt8]], ranks: [Int32], commonBefore: [Int32]) {
        self.words = words
        self.ranks = ranks
        self.commonBefore = commonBefore
    }

    /// The first index whose word does not satisfy `isBefore`.
    private func partitionPoint(from start: Int = 0, _ isBefore: ([UInt8]) -> Bool) -> Int {
        var low = start
        var high = words.count
        while low < high {
            let middle = (low + high) / 2
            if isBefore(words[middle]) { low = middle + 1 } else { high = middle }
        }
        return low
    }

    /// The words that start with `keys` sit together, right after every word
    /// that sorts before `keys`.
    private func range(startingWith keys: [UInt8]) -> Range<Int> {
        let start = partitionPoint { $0.lexicographicallyPrecedes(keys) }
        let end = partitionPoint(from: start) { $0.starts(with: keys) }
        return start..<end
    }

    func rank(of keys: [UInt8]) -> Int? {
        let index = partitionPoint { $0.lexicographicallyPrecedes(keys) }
        return index < words.count && words[index] == keys ? Int(ranks[index]) : nil
    }

    func hasWord(startingWith keys: [UInt8]) -> Bool {
        !range(startingWith: keys).isEmpty
    }

    /// A word within the while-typing rank limit starts with `keys`.
    func hasCommonWord(startingWith keys: [UInt8]) -> Bool {
        let range = range(startingWith: keys)
        return commonBefore[range.upperBound] > commonBefore[range.lowerBound]
    }
}

/// What a person may have settled by undoing a change: these keys, typed in
/// this source, are left as typed.
struct LearnedKey: Hashable, Codable {
    /// Key-space notation, as typed.
    let keys: String
    let source: TypedSource
}

/// A change that ⌘Z can still take back (5.7). It is made with the claim and
/// becomes live once the change is on screen.
struct LayoutFixUndo: Equatable {
    /// The app in front when the word was changed.
    let app: String?
    /// What the change typed: the other reading, the punctuation behind it
    /// and the Space.
    let shown: String
    /// The word and the punctuation behind it as the field showed them before.
    let original: String
    let delimiter: KeyStroke
    let learned: LearnedKey
    /// When ⌘Z stops taking it back.
    var expires: TimeInterval = 0
}

/// What the layout fix tells its service after a plan, on the main thread.
enum LayoutFixNotice: Equatable {
    /// A change was taken back with ⌘Z.
    case reverted(LearnedKey)
}

/// The word being judged: the chunk without the punctuation around it, which
/// is kept as typed and sent again around a changed word.
struct LayoutToken: Equatable {
    let leading: [TypedKey]
    let keys: [TypedKey]
    let trailing: [TypedKey]

    private static let opening: Set<Character> = ["\"", "'", "(", "[", "{", "<", "“", "‘"]
    private static let closing: Set<Character> = [".", ",", "!", "?", ";", "\"", "'", ")", "]", "}", ">", "”", "’"]

    init(_ chunkKeys: [TypedKey]) {
        func isOne(of set: Set<Character>, _ key: TypedKey) -> Bool {
            key.typed.count == 1 && set.contains(key.typed.first!)
        }
        var start = 0
        var end = chunkKeys.count
        while start < end, isOne(of: Self.opening, chunkKeys[start]) { start += 1 }
        while end > start, isOne(of: Self.closing, chunkKeys[end - 1]) { end -= 1 }
        leading = Array(chunkKeys[..<start])
        keys = Array(chunkKeys[start..<end])
        trailing = Array(chunkKeys[end...])
    }
}

enum KeepReason: Equatable {
    case n1, n2, n3, n4, n5, n6, n7, n8, n9, n10, n11, n12, n13, m1, m2, m3, m5, m6, m7
    /// The usual case: what was typed is a word and the other reading is not.
    case typedIsAWord
}

enum LayoutFixDecision: Equatable {
    case keep(KeepReason)
    /// The word becomes `text`, the same keys read in the other layout.
    case change(to: TypedSource, text: String)
}

/// Rule N11's signal, computed by the reducer on the chunk including the
/// current key: text snippets have this word, or may still take it.
enum EarlierClaim: Equatable { case none, mayStillClaim, claimed }

/// What the rules decide from. Built on the main thread, read on the tap's.
struct LayoutFixRules {
    let latin: Lexicon
    let hangul: Lexicon
    var thresholds = LayoutFixThresholds()
    var learned: Set<LearnedKey> = []

    // MARK: The lists FixDock wrote itself

    /// Jamo-only chat words, which no list of spaced words holds, and a few
    /// everyday one-syllable words the subtitle list happens to lack.
    private static let chatWords: Set<String> = ["ㅋㅋ", "ㅋㅋㅋ", "ㅋㅋㅋㅋ", "ㅎㅎ", "ㅎㅎㅎ", "ㅇㅇ", "ㄴㄴ", "ㄱㄱ", "ㅇㅋ",
                                                 "ㅠㅠ", "ㅜㅜ", "ㄷㄷ", "ㅊㅋ", "ㄱㅅ", "ㅈㅅ", "ㅎㅇ", "ㅂㅂ",
                                                 "뭐", "봐", "줘", "꽤", "쭉", "푹"]
    private static let chatWordRank = 1_000
    /// Particles a known word may carry, since the list holds spaced words.
    private static let particles: [(text: String, keys: [UInt8])] =
        ["은", "는", "이", "가", "을", "를", "에", "의", "도", "로", "와", "과", "만", "에서", "으로", "에게", "한테",
         "까지", "부터", "처럼", "보다", "이나", "나", "랑", "이랑", "요", "이요", "야", "이야"].map {
            ($0, Array((HangulTwoSet.keySpace(ofHangul: $0) ?? "").utf8))
        }
    /// Commands, abbreviations and names a person at a Mac types as they
    /// are, which a list of subtitle words lacks: without them `sudo` would
    /// read as two whole Hangul syllables and be changed.
    private static let technicalWords: Set<String> = [
        "sudo", "grep", "chmod", "chown", "mkdir", "rmdir", "curl", "wget", "ssh", "scp", "rsync", "git", "npm", "npx",
        "pnpm", "yarn", "brew", "pip", "cmd", "ctrl", "cmake", "clang", "swiftc", "xcrun", "zsh", "bash", "vim", "nvim",
        "tmux", "kubectl", "docker", "json", "yaml", "yml", "xml", "html", "css", "svg", "png", "jpg", "jpeg", "gif",
        "pdf", "csv", "tsv", "sql", "src", "tmp", "usr", "env", "dns", "tls", "ssl", "tcp", "udp", "http", "https",
        "url", "uri", "api", "sdk", "cli", "gui", "ide", "cpu", "gpu", "ssd", "hdd", "usb", "hdmi", "wifi", "vpn",
        "ios", "macos", "xcode", "github", "gitlab", "figma", "async", "await", "struct", "enum", "func", "const",
        "printf", "println", "stdin", "stdout", "stderr", "nil", "null", "bool", "int", "str", "len", "args", "argv",
        "kwargs", "regex", "repo", "config", "localhost", "admin", "login", "logout", "signup", "username", "cursor",
        "covid", "cyan", "macbook", "iphone", "ipad", "airpods", "trackpad", "passcode", "spreadsheet", "aftermarket",
        "todo", "fixme", "readme", "changelog", "dockerfile", "makefile", "plist", "dylib", "uuid", "utf", "ascii",
        "ipv", "smtp", "imap", "oauth", "jwt", "cors", "cron", "sqlite", "redis", "nginx", "linux", "ubuntu", "debian",
        "homebrew", "chrome", "safari", "firefox", "kakaotalk", "naver", "google", "youtube", "netflix", "wifi",
    ]
    private static let technicalWordRank = 20_000
    private static let neverInside: Set<Character> = ["@", ":", "/", "\\", "_", "~", "#", "=", "&", "%", ".", "-"]
    /// Capitals after which a late Shift is forgiven: the double consonants.
    private static let doubleConsonantKeys: Set<Character> = ["Q", "W", "E", "R", "T"]

    // MARK: Readings

    /// A token as both layouts read it, or the rule that ends the decision
    /// before any list is asked.
    private struct Readings {
        let typedIn: TypedSource
        /// Lowercase letters: the English list's notation.
        let english: [UInt8]
        /// Key-space notation: the Korean list's.
        let korean: [UInt8]
        /// The English reading as text, capitals as typed.
        let englishText: String
        /// The token exactly as typed, for the learned set.
        let learnedKey: LearnedKey
    }

    private static func isHangulSyllables(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy { (0xAC00...0xD7A3).contains($0.value) }
    }

    /// Rules N12, N2, N3, N4, N5 (after C3) and the shape N8 needs, in that
    /// order. `nil` reason: the token can be looked up.
    private func readings(of token: LayoutToken) -> (readings: Readings?, keep: KeepReason?) {
        let keys = token.keys
        if keys.contains(where: { $0.stroke.option || $0.isRepeat }) { return (nil, .n12) }
        let characters = keys.map { $0.typed.count == 1 ? $0.typed.first : nil }
        if characters.contains(where: { $0?.isNumber ?? false }) { return (nil, .n2) }
        if characters.contains(where: { $0.map(Self.neverInside.contains) ?? false }) { return (nil, .n3) }

        if characters.allSatisfy({ $0.map(HangulTwoSet.isJamo) ?? false }) {
            // Korean source: the event carried jamo. A shifted jamo is its
            // capital key; Shift on any other key is dropped, as the input
            // method drops it, but an English reading keeps it.
            if keys.count >= 2, keys.allSatisfy({ $0.stroke.shift }) { return (nil, .n4) }
            let korean = characters.map { HangulTwoSet.key(typing: $0!)! }
            let english = korean.map { Character($0.lowercased()) }
            let text = zip(english, keys).map { $1.stroke.shift ? $0.uppercased() : String($0) }.joined()
            return (Readings(typedIn: .hangul2, english: Array(String(english).utf8), korean: Array(String(korean).utf8),
                             englishText: text, learnedKey: LearnedKey(keys: String(korean), source: .hangul2)), nil)
        }
        guard characters.allSatisfy({ $0.map { $0.isASCII && $0.isLetter } ?? false }) else {
            // Two sources in one word, or a character no list can hold.
            return (nil, characters.contains(where: { $0.map(HangulTwoSet.isJamo) ?? false }) ? .n1 : .n8)
        }
        let letters = characters.map { $0! }
        if letters.count >= 2, letters.allSatisfy(\.isUppercase) { return (nil, .n4) }
        var korean: [Character] = []
        for (index, letter) in letters.enumerated() {
            if letter.isLowercase || HangulTwoSet.shiftedKeyLetters.contains(letter) {
                korean.append(letter)
            } else if index > 0, Self.doubleConsonantKeys.contains(letters[index - 1]) {
                // C3: Shift released late after a double consonant.
                korean.append(Character(letter.lowercased()))
            } else {
                return (nil, .n5)
            }
        }
        let typed = String(letters)
        return (Readings(typedIn: .latin, english: Array(typed.lowercased().utf8), korean: Array(String(korean).utf8),
                         englishText: typed, learnedKey: LearnedKey(keys: typed, source: .latin)), nil)
    }

    /// The Korean reading's rank and text. Known means a list word, a list
    /// word with one particle, or a chat word; C4 asks for whole syllables
    /// otherwise, so a stray jamo is never known.
    private func hangulReading(_ keys: [UInt8]) -> (rank: Int?, text: String) {
        let text = HangulTwoSet.hangul(fromKeySpace: String(decoding: keys, as: UTF8.self))
        if Self.chatWords.contains(text) { return (Self.chatWordRank, text) }
        guard Self.isHangulSyllables(text) else { return (nil, text) }
        if let rank = hangul.rank(of: keys) { return (rank, text) }
        for particle in Self.particles where keys.count > particle.keys.count && keys.suffix(particle.keys.count).elementsEqual(particle.keys) {
            let stem = Array(keys.dropLast(particle.keys.count))
            if let rank = hangul.rank(of: stem),
               HangulTwoSet.hangul(fromKeySpace: String(decoding: stem, as: UTF8.self)) + particle.text == text {
                return (rank, text)
            }
        }
        return (nil, text)
    }

    // MARK: Decisions

    /// The token exactly as typed, the key the learned set is kept by.
    func learnedKey(of token: LayoutToken) -> LearnedKey? {
        readings(of: token).readings?.learnedKey
    }

    /// Rules N1–N12 and C1–C4, at a whitespace key after `token`.
    func decideAtWordEnd(_ token: LayoutToken, anchored: Bool, earlier: EarlierClaim) -> LayoutFixDecision {
        guard anchored else { return .keep(.n1) }
        let (found, reason) = readings(of: token)
        guard let readings = found else { return .keep(reason ?? .n8) }
        let korean = hangulReading(readings.korean)
        var minKeys = thresholds.minKeys
        if readings.typedIn == .latin, !korean.text.allSatisfy(HangulTwoSet.isJamo) {
            minKeys = max(minKeys, thresholds.minKeysFromLatin)
        }
        if token.keys.count < minKeys { return .keep(.n10) }
        if earlier != .none { return .keep(.n11) }
        if learned.contains(readings.learnedKey) { return .keep(.n9) }

        let english = latin.rank(of: readings.english)
            ?? (Self.technicalWords.contains(String(decoding: readings.english, as: UTF8.self)) ? Self.technicalWordRank : nil)
        // C6: typed in the Korean source, no list word, but nothing except
        // whole syllables. That may be a Korean word the list lacks (애교,
        // whose keys spell dory) or a short English word that happens to
        // compose (the is 솓). Only a common English word wins.
        if readings.typedIn == .hangul2, korean.rank == nil, Self.isHangulSyllables(korean.text) {
            guard let rank = english else { return .keep(.typedIsAWord) }
            return rank < thresholds.commonRank ? .change(to: .latin, text: readings.englishText) : .keep(.n7)
        }
        let typed = readings.typedIn == .latin ? english : korean.rank
        let other = readings.typedIn == .latin ? korean.rank : english
        // C5: typed in the Latin source, not an English word, and the keys
        // compose into nothing but whole syllables. The Korean list holds
        // spaced subtitle words and misses most inflected forms; English
        // letters almost never fall into whole syllables by chance.
        if typed == nil, other == nil, readings.typedIn == .latin, let needed = thresholds.wholeSyllables,
           korean.text.count >= needed, Self.isHangulSyllables(korean.text) {
            return .change(to: .hangul2, text: korean.text)
        }
        guard let otherRank = other else { return .keep(typed == nil ? .n8 : .typedIsAWord) }
        if let typedRank = typed {
            if token.keys.count <= thresholds.shortTokenKeys { return .keep(.n6) }
            // C2: both are words; only a rare one gives way to a common one.
            guard typedRank > thresholds.rareRank, otherRank < thresholds.commonRank else { return .keep(.n7) }
        }
        return readings.typedIn == .latin
            ? .change(to: .hangul2, text: korean.text)
            : .change(to: .latin, text: readings.englishText)
    }

    /// Rules M1–M4 and M7, on a letter key; `token` includes that key. M5
    /// (the hand-off) and M6 (one change per chunk) are the caller's.
    func decideWhileTyping(_ token: LayoutToken, anchored: Bool, earlier: EarlierClaim) -> LayoutFixDecision {
        guard anchored else { return .keep(.n1) }
        let (found, reason) = readings(of: token)
        guard let readings = found else { return .keep(reason ?? .n8) }
        if token.keys.count < thresholds.minKeysWhileTyping { return .keep(.m1) }
        if earlier != .none { return .keep(.n11) }
        let typedKeys = readings.learnedKey.keys
        if learned.contains(where: { $0.source == readings.typedIn && $0.keys.hasPrefix(typedKeys) }) { return .keep(.n9) }
        if token.keys.last?.stroke.shift ?? false { return .keep(.m7) }

        switch readings.typedIn {
        case .latin:
            if latin.hasWord(startingWith: readings.english) { return .keep(.m2) }
            guard hangul.hasCommonWord(startingWith: readings.korean) else { return .keep(.m3) }
            // Everything before the syllable still open has to be whole.
            let text = HangulTwoSet.hangul(fromKeySpace: String(decoding: readings.korean, as: UTF8.self))
            let settled = String(text.dropLast())
            guard settled.isEmpty || Self.isHangulSyllables(settled) else { return .keep(.m3) }
            return .change(to: .hangul2, text: text)
        case .hangul2:
            if hangul.hasWord(startingWith: readings.korean) { return .keep(.m2) }
            guard latin.hasCommonWord(startingWith: readings.english) else { return .keep(.m3) }
            return .change(to: .latin, text: readings.englishText)
        }
    }
}

/// Turns a decision into what the tap's executor does to the screen.
enum LayoutFixPlanner {
    /// A change at a word end, with the finished text injected: the
    /// delimiter was swallowed, so the word and the punctuation behind it
    /// are the last things in the field. They are erased, the other reading
    /// and the same punctuation typed, then the delimiter. Punctuation in
    /// front of the word stays where it is. Then the input source is asked
    /// for the target (D14), where the fast switch can give it.
    static func wordEnd(_ token: LayoutToken, to target: TypedSource, text: String, delimiter: TypedKey) -> ReplacementPlan {
        let erased = token.keys + token.trailing
        let typed = erased.map(\.typed).joined()
        let trailing = token.trailing.map(\.typed).joined()
        let backspaces: PlanStep
        let shown: String
        switch target {
        case .hangul2:
            // Typed in the Latin source: one backspace per key.
            backspaces = .backspaces(erased.count, completionCheck: typed)
            shown = typed
        case .latin:
            // Typed in the Korean source: the field shows composed
            // syllables. The count starts clean, at the whitespace or the
            // punctuation in front of the word.
            backspaces = .backspaces(HangulTwoSet.backspaces(erasing: typed), completionCheck: nil)
            let keySpace = token.keys.compactMap { $0.typed.first.flatMap(HangulTwoSet.key(typing:)) }
            shown = HangulTwoSet.hangul(fromKeySpace: String(keySpace)) + trailing
        }
        return ReplacementPlan(steps: [.expect(shown),
                                       backspaces,
                                       .text(text + trailing),
                                       .key(delimiter.stroke),
                                       .handOff(target)])
    }

    /// ⌘Z after a change: once ⌘ is up, what the change typed is erased and
    /// the word goes back as the field showed it, then the delimiter. The
    /// text is injected, so an open syllable it had comes back closed.
    /// Then the source the word was typed in is asked for again (5.7): the
    /// fast switch finds out then whether the change's hand-off moved it.
    static func undo(_ record: LayoutFixUndo) -> ReplacementPlan {
        ReplacementPlan(steps: [.waitForCommandUp,
                                .expect(record.shown),
                                .backspaces(record.shown.count, completionCheck: nil),
                                .text(record.original),
                                .key(record.delimiter),
                                .handOff(record.learned.source)])
    }
}

/// The layout fix as a tool of the shared typing tap: at a whitespace key it
/// judges the finished word and, for a change, answers with a plan.
struct LayoutFixConsumer {
    struct Config {
        let rules: LayoutFixRules
        /// Bundle identifiers of the apps the person turned the tool off for.
        let ignoredApps: Set<String>
    }

    var config: Config

    /// `chunk` is the finished word. `earlier` is rule N11's signal. A claim
    /// ended by Space comes with the record ⌘Z would take it back by.
    func consider(_ event: TypingEvent, chunk: TypingChunk, earlier: EarlierClaim,
                  frontApp: String?) -> (verdict: Verdict, undo: LayoutFixUndo?) {
        guard case .boundary(let delimiter) = event else { return (.pass, nil) }
        if let frontApp, config.ignoredApps.contains(frontApp) { return (.pass, nil) }
        let token = LayoutToken(chunk.keys)
        guard case .change(let target, let text) = config.rules.decideAtWordEnd(token, anchored: chunk.anchored, earlier: earlier)
        else { return (.pass, nil) }
        let plan = LayoutFixPlanner.wordEnd(token, to: target, text: text, delimiter: delimiter)
        // Only after Space: a Tab may have moved to another field and a
        // Return may have sent a message or run a command, so what is in
        // front of the caret then is not the changed word.
        guard delimiter.typed == " ", let learned = config.rules.learnedKey(of: token) else { return (.claim(plan), nil) }
        let trailing = token.trailing.map(\.typed).joined()
        let original = learned.source == .latin ? learned.keys : HangulTwoSet.hangul(fromKeySpace: learned.keys)
        let undo = LayoutFixUndo(app: frontApp, shown: text + trailing + " ", original: original + trailing,
                                 delimiter: delimiter.stroke, learned: learned)
        return (.claim(plan), undo)
    }
}

/// Why the tool is on and yet does nothing.
enum LayoutFixRest: Equatable {
    case needsAccessibility
    /// Another app that fixes layouts is running; its name as macOS shows it.
    case otherFixer(String)
    case developerBuild
    case unknownLayout
    case listsMissing
    case listsLoading
}

enum LayoutFixMode: Equatable { case off, resting(LayoutFixRest), active }

enum LayoutFixListsState: Equatable { case notLoaded, loading, missing, ready }

struct LayoutFixFacts: Equatable {
    var installed: Bool
    var enabled: Bool
    var accessibility: Bool
    /// Not a developer build, or one started with the claim flag: two
    /// FixDock builds would otherwise fix the same word twice.
    var mayRun: Bool
    var otherFixer: String?
    /// The current input source is QWERTY Latin or Korean 2-Set.
    var layoutKnown: Bool
    var lists: LayoutFixListsState
}

enum LayoutFixPolicy {
    /// The other layout fixer the tool rests for (owner decision D7). It
    /// keeps the input source on ABC and composes Hangul itself, so the
    /// typed source could not be told from the key events while it runs.
    /// The identifier is the one its public Homebrew cask names.
    static let otherFixerBundleID = "com.hebbianai.catchtype"

    /// Input sources whose keys the rules can read.
    static let knownSourceIDs: Set<String> = ["com.apple.keylayout.ABC", "com.apple.keylayout.US",
                                             "com.apple.inputmethod.Korean.2SetKorean"]

    static func mode(_ facts: LayoutFixFacts) -> LayoutFixMode {
        guard facts.installed, facts.enabled else { return .off }
        if !facts.mayRun { return .resting(.developerBuild) }
        if !facts.accessibility { return .resting(.needsAccessibility) }
        if let name = facts.otherFixer { return .resting(.otherFixer(name)) }
        switch facts.lists {
        case .missing: return .resting(.listsMissing)
        case .notLoaded, .loading: return .resting(.listsLoading)
        case .ready: break
        }
        return facts.layoutKnown ? .active : .resting(.unknownLayout)
    }
}
