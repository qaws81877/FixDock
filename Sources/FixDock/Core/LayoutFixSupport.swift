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
    /// Rule M8 (7.13): a word this many keys long, shorter than
    /// `minKeysWhileTyping`, is judged too, under a stricter rule: M8 in the
    /// Latin source, M8b and M8c in the Korean source. nil: off.
    var shortKeysWhileTyping: Int? = 3
    /// M8: the one syllable is a Korean list word this common.
    var shortWhileTypingKoreanRank = 5_000
    /// Rule M8c (third key, owner 2026-11-23): at `shortKeysWhileTyping`
    /// keys in the Korean source, an English word this common starts with
    /// the keys. nil: off.
    var shortWhileTypingEnglishRank: Int? = 1_000
    var learnAfterReverts = 3
    /// Rule C5: with this many whole syllables or more, a Korean reading
    /// counts without being a list word (owner, 2026-11-13). nil: off.
    var wholeSyllables: Int? = 2
    /// Rule C7 (owner, 2026-11-15): typed in the Korean source with a jamo
    /// left over and no list word either way, the keys must score this much
    /// higher as English than as Korean typing. nil: off.
    var keyScoreMargin: Double? = 2.47
    var undoWindowSeconds: TimeInterval = 5
    var handOffTimeout: TimeInterval = 0.5
}

/// Letter trigrams of one list's words in key space, lowercased: how much a
/// key sequence looks like that language typed on its own layout (rule C7).
struct KeyTrigram {
    /// a to z, then the word's start and its end.
    private static let symbols = 28
    private var trigrams = [Int32](repeating: 0, count: symbols * symbols * symbols)
    private var contexts = [Int32](repeating: 0, count: symbols * symbols)
    private var used = 0

    init(_ words: [[UInt8]]) {
        var seen = [Bool](repeating: false, count: Self.symbols)
        for word in words {
            let sequence = Self.sequence(word)
            for symbol in sequence { seen[symbol] = true }
            for index in 2..<sequence.count {
                let context = sequence[index - 2] * Self.symbols + sequence[index - 1]
                contexts[context] += 1
                trigrams[context * Self.symbols + sequence[index]] += 1
            }
        }
        used = seen.filter { $0 }.count
    }

    /// Keys are letters only: the lists' words and a reading's key space.
    private static func sequence(_ keys: [UInt8]) -> [Int] {
        [26, 26] + keys.map { Int(($0 | 0x20) - UInt8(ascii: "a")) } + [27]
    }

    /// Mean log probability per key, with add-0.1 smoothing.
    func score(_ keys: [UInt8]) -> Double {
        let sequence = Self.sequence(keys)
        var total = 0.0
        for index in 2..<sequence.count {
            let context = sequence[index - 2] * Self.symbols + sequence[index - 1]
            total += log((Double(trigrams[context * Self.symbols + sequence[index]]) + 0.1)
                         / (Double(contexts[context]) + 0.1 * Double(used)))
        }
        return total / Double(sequence.count - 2)
    }
}

/// One language's words in key-space notation, sorted, so that an exact
/// lookup and a "does any word start with these keys" lookup are both binary
/// searches. In Hangul text "안녀" is no prefix of "안녕"; in key space "dkssu"
/// is a prefix of "dkssud".
struct Lexicon {
    private let words: [[UInt8]]
    /// Line number in the list file, 1 the most frequent.
    private let ranks: [Int32]
    /// How many of `words[..<index]` count while typing: a list line within
    /// the while-typing rank limit, or a Korean added word.
    private let commonBefore: [Int32]
    let keyModel: KeyTrigram

    var count: Int { words.count }

    /// `text` is one word per line, most frequent first. English words are
    /// their own keys. A Korean word is kept only if its keys compose back
    /// into it. nil when nothing is left.
    static func load(_ text: String, as language: TypedSource, whileTypingMaxRank: Int) -> Lexicon? {
        var entries: [(keys: [UInt8], rank: Int32, whileTyping: Bool)] = []
        var rank: Int32 = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            rank += 1
            let word = String(line)
            switch language {
            case .latin:
                guard word.utf8.allSatisfy({ (UInt8(ascii: "a")...UInt8(ascii: "z")).contains($0) }) else { continue }
                entries.append((Array(word.utf8), rank, Int(rank) <= whileTypingMaxRank))
            case .hangul2:
                guard let keys = HangulTwoSet.keySpace(ofHangul: word),
                      HangulTwoSet.hangul(fromKeySpace: keys) == word else { continue }
                entries.append((Array(keys.utf8), rank, Int(rank) <= whileTypingMaxRank))
            }
        }
        if language == .latin {
            // At the word end only: a name's start would read Korean typed
            // right on 2-Set as English mid-word (밈처럼 opens like alacritty).
            for word in LayoutFixRules.addedEnglishWords.flatMap(\.words) {
                entries.append((Array(word.utf8), Int32(LayoutFixRules.addedEnglishWordRank), false))
            }
        }
        if language == .hangul2 {
            for word in LayoutFixRules.addedWords.flatMap(\.words) {
                guard let keys = HangulTwoSet.keySpace(ofHangul: word),
                      HangulTwoSet.hangul(fromKeySpace: keys) == word else { continue }
                entries.append((Array(keys.utf8), Int32(LayoutFixRules.addedWordRank), true))
            }
        }
        guard !entries.isEmpty else { return nil }
        // The same keys twice keep the better rank, and count while typing
        // if either does.
        entries.sort { $0.keys == $1.keys ? $0.rank < $1.rank : $0.keys.lexicographicallyPrecedes($1.keys) }
        var words: [[UInt8]] = []
        var ranks: [Int32] = []
        var whileTyping: [Bool] = []
        for entry in entries {
            if words.last == entry.keys {
                whileTyping[whileTyping.count - 1] = whileTyping[whileTyping.count - 1] || entry.whileTyping
                continue
            }
            words.append(entry.keys)
            ranks.append(entry.rank)
            whileTyping.append(entry.whileTyping)
        }
        var commonBefore: [Int32] = [0]
        commonBefore.reserveCapacity(words.count + 1)
        for counts in whileTyping {
            commonBefore.append(commonBefore[commonBefore.count - 1] + (counts ? 1 : 0))
        }
        return Lexicon(words: words, ranks: ranks, commonBefore: commonBefore, keyModel: KeyTrigram(words))
    }

    private init(words: [[UInt8]], ranks: [Int32], commonBefore: [Int32], keyModel: KeyTrigram) {
        self.words = words
        self.ranks = ranks
        self.commonBefore = commonBefore
        self.keyModel = keyModel
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

    /// The best rank of the words that start with `keys`.
    func bestRank(startingWith keys: [UInt8]) -> Int? {
        ranks[range(startingWith: keys)].min().map(Int.init)
    }

    /// How many words end with `keys` (`atEnd`) or hold them anywhere. A scan:
    /// rules C8 and M9 ask only once everything else agreed.
    func count(holding keys: [UInt8], atEnd: Bool) -> Int {
        words.reduce(0) { total, word in
            let holds = atEnd ? word.count > keys.count && word.suffix(keys.count).elementsEqual(keys)
                : word.count > keys.count && word.indices.dropLast(keys.count - 1)
                    .contains { word[$0..<$0 + keys.count].elementsEqual(keys) }
            return total + (holds ? 1 : 0)
        }
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
    var shown: String
    /// The word and the punctuation behind it as the field showed them before.
    var original: String
    /// nil while a word changed as it was typed is still being typed.
    var delimiter: KeyStroke?
    var learned: LearnedKey
    /// When ⌘Z stops taking it back.
    var expires: TimeInterval = 0
    /// A change made while the word was typed (3.4): its keys so far.
    var word: MidWordRecord?

    /// The person typed on in the changed word: ⌘Z takes that back too.
    mutating func extend(with key: TypedKey, until expires: TimeInterval) {
        guard var word else { return }
        word.keys.append(key.reading(in: word.typedIn))
        self.word = word
        shown = word.shown
        original = LayoutFixPlanner.render(word.keys, in: word.typedIn)
        learned = LayoutFixPlanner.learnedKey(word.keys, typedIn: word.typedIn)
        self.expires = expires
    }

    /// The changed word ended with this Space.
    mutating func seal(by delimiter: KeyStroke, until expires: TimeInterval) {
        self.delimiter = delimiter
        shown += " "
        self.expires = expires
    }
}

/// A word changed while it was typed, as ⌘Z needs it.
struct MidWordRecord: Equatable {
    /// Punctuation in front of the word, which the change left where it was.
    let leading: [TypedKey]
    /// Every key of the word so far, read in the source it was typed in.
    var keys: [TypedKey]
    let typedIn: TypedSource
    /// Where the change sent it.
    let target: TypedSource
    /// Rule M9: the keys before this many, an English stem, were left as
    /// typed; only the tail behind them went to the target.
    var lead = 0

    /// What the field shows of the word.
    var shown: String {
        LayoutFixPlanner.render(Array(keys[..<lead]), in: typedIn) + LayoutFixPlanner.render(Array(keys[lead...]), in: target)
    }
}

/// A mid-word plan in flight: the word's keys and where the plan sends
/// them. The reducer takes it up when the plan ends.
struct MidWordClaim: Equatable {
    let leading: [TypedKey]
    /// Read in the source they were typed in.
    let keys: [TypedKey]
    let typedIn: TypedSource
    let target: TypedSource
    /// The source the tap has read them in so far.
    let before: TypedSource
    /// An undo: the word the learned count hears of once it is back.
    let reverts: LearnedKey?
    /// Rule M9: the first this many keys stayed as they were read.
    var lead = 0

    /// The keys as the field shows them with `source` live behind the lead.
    func keys(readIn source: TypedSource) -> [TypedKey] {
        keys.enumerated().map { $0.offset < lead ? $0.element : $0.element.reading(in: source) }
    }
}

extension TypedKey {
    /// The key in key-space notation (3.1); nil for a key that types no
    /// letter. A Latin capital counts as Shift, as `readings` counts it.
    var keySpaceLetter: Character? {
        guard typed.count == 1, let character = typed.first else { return nil }
        if let key = HangulTwoSet.key(typing: character) { return key }
        guard character.isASCII, character.isLetter else { return nil }
        return character.isUppercase && HangulTwoSet.shiftedKeyLetters.contains(character)
            ? character : Character(character.lowercased())
    }

    /// The same key as `source` types it: a letter key's letter or jamo,
    /// Shift kept as the input method keeps it. Anything else as it is.
    func reading(in source: TypedSource) -> TypedKey {
        guard let key = keySpaceLetter else { return self }
        let isJamo = HangulTwoSet.isJamo(typed.first!)
        switch source {
        case .latin:
            guard isJamo else { return self }
            return TypedKey(stroke: stroke, isRepeat: isRepeat, typed: stroke.shift ? key.uppercased() : key.lowercased())
        case .hangul2:
            guard !isJamo else { return self }
            return TypedKey(stroke: stroke, isRepeat: isRepeat, typed: HangulTwoSet.hangul(fromKeySpace: String(key)))
        }
    }
}

extension RawKey {
    /// The same key as `source` types it (`TypedKey.reading`).
    func reading(in source: TypedSource) -> RawKey {
        let key = TypedKey(stroke: stroke, isRepeat: isRepeat, typed: characters).reading(in: source)
        return RawKey(kind: kind, origin: origin, stroke: stroke, isRepeat: isRepeat, characters: key.typed)
    }
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
    case n1, n2, n3, n4, n5, n6, n7, n8, n9, n10, n11, n12, n13, m1, m2, m3, m5, m6, m7, m8
    /// The usual case: what was typed is a word and the other reading is not.
    case typedIsAWord
}

/// Why a finished word was left as typed, for the debug log. Never the word.
enum LayoutFixSkip: Equatable {
    case ignoredApp
    case rule(KeepReason)
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
                                                 "ㅠㅠ", "ㅜㅜ", "ㄷㄷ", "ㅊㅋ", "ㄱㅅ", "ㅈㅅ", "ㅎㅇ", "ㅂㅂ", "ㅇㄷ",
                                                 "뭐", "봐", "줘", "꽤", "쭉", "푹"]
    private static let chatWordRank = 1_000
    /// Korean words the subtitle list lacks, chosen by FixDock (owner,
    /// 2026-11-15, 7.14), each group with why it is here. The Korean list
    /// loads them at `addedWordRank`, so every rule takes them as list words.
    static let addedWords: [(why: String, words: [String])] = [
        ("food and fruit, named in everyday chat",
         ["귤", "한라봉", "떡볶이", "김밥", "짜장면", "짬뽕", "족발", "보쌈", "순대", "어묵", "깍두기", "고추장",
          "참기름", "녹차", "빙수", "호떡", "붕어빵", "참외", "키위", "대추", "고구마", "오이", "배추", "상추",
          "깻잎", "시금치", "팥", "잼", "찌개", "미역", "멸치", "고등어", "삼겹살", "불고기", "냉면", "비빔밥",
          "김치찌개", "된장찌개", "떡국", "컵라면", "야식", "밀크티", "아메리카노"]),
        ("things at home and on a desk",
         ["프라이팬", "국자", "젓가락", "텀블러", "목도리", "물티슈", "선풍기", "충전기", "이어폰", "태블릿", "볼펜",
          "지우개", "공책"]),
        ("words of a repair counter",
         ["액정", "침수", "견적", "보증", "메인보드", "단자", "출고", "무상", "유상", "초기화", "애플케어", "맥북",
          "아이폰", "에어팟", "워치", "트랙패드", "힌지", "기판", "발열", "부팅", "재부팅", "먹통", "수리비", "반납"]),
        ("short loanwords", ["앱", "깃", "팁", "줌", "캡처", "카톡", "블투", "탭", "봇", "밈", "짤", "줌인"]),
        ("interjections", ["헐", "헉", "엥", "흠", "짱", "꿀잼", "노잼", "넵", "냠냠", "히히"]),
    ]
    static let addedWordRank = 2_000
    /// English names the lists lack or rank low, chosen by FixDock (owner,
    /// 2026-11-16, 7.16): what a developer at a Mac types by name, each group
    /// with why it is here. The English list loads them at
    /// `addedEnglishWordRank`. Left out: a name whose 2-Set reading is
    /// consonants alone (zed is ㅋㄷㅇ) or one syllable, or a Korean word.
    static let addedEnglishWords: [(why: String, words: [String])] = [
        ("AI models, their makers and AI coding tools",
         ["anthropic", "claude", "opus", "sonnet", "haiku", "fable", "openai", "chatgpt", "gemini", "deepmind",
          "deepseek", "mistral", "qwen", "kimi", "moonshot", "grok", "xai", "llama", "ollama", "perplexity",
          "copilot", "codex", "cohere", "groq", "cerebras", "huggingface", "midjourney", "anythingllm",
          "openrouter", "minimax", "cursor", "windsurf", "cline", "aider", "devin", "kiro", "antigravity",
          "coderabbit", "superwhisper", "macwhisper", "lmstudio", "langchain", "llamaindex", "pytorch",
          "tensorflow", "jupyter", "jupyterlab", "pydantic", "numpy", "pandas", "herdr", "omo", "opencode"]),
        ("command-line tools a developer types by name",
         ["awscli", "ffmpeg", "cmake", "coreutils", "pyenv", "pipx", "openssl", "ripgrep", "helm", "protobuf",
          "graphviz", "pandoc", "swiftlint", "swiftformat", "swiftgen", "redis", "mkcert", "cocoapods", "openjdk",
          "cloudflared", "llvm", "lazygit", "lazydocker", "maven", "xcodegen", "starship", "nmap", "htop", "btop",
          "ansible", "qemu", "watchman", "rclone", "fastfetch", "colima", "podman", "gradle", "flyctl", "atuin",
          "shellcheck", "zoxide", "postgresql", "postgres", "kustomize", "hugo", "powershell", "chezmoi",
          "tailscale", "fastlane", "direnv", "argocd", "trivy", "exiftool", "gitleaks", "ruff", "terragrunt",
          "terraform", "opentofu", "nginx", "caddy", "rustup", "buildx", "rbenv", "sops", "yazi", "scrcpy",
          "pipenv", "virtualenv", "semgrep", "httpie", "mongosh", "ocrmypdf", "duckdb", "trufflehog", "bazelisk",
          "minikube", "kubernetes", "jsonnet", "cosign", "tflint", "kubectx", "nushell", "syncthing", "wireshark",
          "yamllint", "doctl", "ugrep", "sccache", "lefthook", "helmfile", "pgvector", "pulumi", "mariadb",
          "certbot", "skopeo", "wrangler", "typst", "ncdu", "emacs", "ghidra", "tealdeer", "grpcurl", "ngrok",
          "gcloud", "mycli", "conda", "miniconda", "anaconda", "pytest", "vitest", "eslint", "prettier", "biome",
          "mise", "deno", "vite", "nodejs", "zellij", "neovim", "tmux", "esbuild", "webpack", "rollup", "babel",
          "playwright", "puppeteer", "cypress", "storybook"]),
        ("editors, terminals and Mac apps",
         ["ghostty", "iterm", "wezterm", "alacritty", "warp", "vscode", "vscodium", "sublime", "intellij",
          "pycharm", "datagrip", "webstorm", "raycast", "alfred", "obsidian", "notion", "figma", "postman",
          "insomnia", "orbstack", "maccy", "hammerspoon", "karabiner", "aerospace", "spotify", "slack", "discord",
          "telegram", "whatsapp", "zoom", "dropbox", "onedrive", "chromium", "librewolf", "vivaldi", "tableplus",
          "dbeaver", "sourcetree", "tabby", "termius", "typora", "zotero", "anki", "inkscape", "blender", "gimp",
          "krita", "handbrake", "audacity", "iina", "virtualbox", "vagrant", "cyberduck", "cleanshot", "shottr",
          "bartender", "espanso", "jira", "confluence", "trello", "asana"]),
        ("languages, frameworks and hosted services",
         ["typescript", "javascript", "python", "golang", "kotlin", "swiftui", "appkit", "nextjs", "svelte",
          "sveltekit", "nuxt", "astro", "remix", "angular", "django", "flask", "fastapi", "rails", "laravel",
          "redux", "tailwind", "tailwindcss", "prisma", "drizzle", "supabase", "firebase", "vercel", "netlify",
          "cloudflare", "railway", "heroku", "mongodb", "mysql", "elixir", "haskell", "scala", "clojure", "flutter",
          "lua", "perl", "php", "strapi", "streamlit", "traefik", "treesitter", "kafka", "rabbitmq",
          "elasticsearch", "grafana", "prometheus", "datadog", "sentry", "stripe", "twilio", "openapi", "graphql",
          "grpc"]),
    ]
    static let addedEnglishWordRank = 3_000
    /// Particles a known word may carry, since the list holds spaced words.
    private static let particles: [(text: String, keys: [UInt8])] =
        ["은", "는", "이", "가", "을", "를", "에", "의", "도", "로", "와", "과", "만", "에서", "으로", "에게", "한테",
         "까지", "부터", "처럼", "보다", "이나", "나", "랑", "이랑", "요", "이요", "야", "이야"].map {
            ($0, Array((HangulTwoSet.keySpace(ofHangul: $0) ?? "").utf8))
        }
    /// Rules C8 and M9 (2026-11-20): what a Korean sentence glues to an
    /// English word (staging에, deploy할게요, PR을): particles, copulas, the
    /// endings of 하다 and 되다, and a few nouns. Closed on purpose: a tail
    /// outside it leaves the word as typed.
    static let tails: [String] = [
        "은", "는", "이", "가", "을", "를", "에", "의", "도", "로", "와", "과", "만", "에서", "으로", "에게", "한테", "께",
        "까지", "부터", "처럼", "보다", "마다", "밖에", "만큼", "이나", "나", "랑", "이랑", "들", "들이", "들을",
        "들은", "들도", "에는", "에서는", "에도", "에서도", "으로는", "로는", "으로도", "로도",
        "이다", "이야", "야", "이에요", "예요", "입니다", "이고", "이라", "이라서", "인데", "인지", "이면", "임", "이죠",
        "죠", "이지", "이네요", "인가요", "이요", "요",
        "하다", "한다", "해", "해요", "했어", "했어요", "했다", "했음", "했습니다", "합니다", "함", "할", "할게",
        "할게요", "할까", "할까요", "하자", "해줘", "해줘요", "해주세요", "해봐", "해봐요", "해볼게요", "해야", "해야지",
        "해도", "해서", "하고", "하면", "하는", "하는데", "했는데", "했고", "한", "하기", "하려고", "하려면", "할래",
        "할래요", "하세요", "하시면", "하지", "하고요", "했죠", "했나요", "했네요", "합시다", "하겠습니다",
        "돼", "돼요", "됐어", "됐어요", "됐다", "됐습니다", "됩니다", "됨", "되는", "된", "될", "되면", "되고",
        "되나요", "됐나요",
        "중", "중이에요", "중입니다", "완료",
    ]
    private static let tailSet = Set(tails)
    /// C8: how many English words a two-key tail may end before a short
    /// lowercase stem with it is left alone (rk of 가 ends work and dark).
    /// M9: how many the tail typed so far may sit in (dl of 이 sits in deadly).
    private static let tailEndings = 3
    private static let tailInside = 10
    /// Rule C8a: 가 나 요 야 in key space, the short tails a Korean sentence
    /// glues to an English word (push가) that those two counts refuse.
    private static let sentenceTails: Set<String> = ["rk", "sk", "dy", "di"]
    /// M9 takes three of them at a key; 야 waits for the word's end, since
    /// English words go on after its keys (-ding, -dic, -dis). On a word M
    /// already changed, which its end does not judge again (M6), 야 too.
    private static let sentenceTailsAtAKey: Set<String> = ["rk", "sk", "dy"]
    /// The tails in key space, for M9's "a tail starts here".
    private static let tailKeys: [String] = tails.compactMap { HangulTwoSet.keySpace(ofHangul: $0) }
    /// Commands, abbreviations and names a person at a Mac types as they
    /// are, which a list of subtitle words lacks: without them `sudo` would
    /// read as two whole Hangul syllables and be changed.
    private static let technicalWords: Set<String> = [
        "sudo", "grep", "chmod", "chown", "mkdir", "rmdir", "curl", "wget", "ssh", "scp", "rsync", "git", "npm", "npx",
        "pnpm", "yarn", "brew", "pip", "cmd", "ctrl", "clang", "swiftc", "xcrun", "zsh", "bash", "vim", "nvim",
        "kubectl", "docker", "json", "yaml", "yml", "xml", "html", "css", "svg", "png", "jpg", "jpeg", "gif",
        "pdf", "csv", "tsv", "sql", "src", "tmp", "usr", "env", "dns", "tls", "ssl", "tcp", "udp", "http", "https",
        "url", "uri", "api", "sdk", "cli", "gui", "ide", "cpu", "gpu", "ssd", "hdd", "usb", "hdmi", "wifi", "vpn",
        "ios", "macos", "xcode", "github", "gitlab", "async", "await", "struct", "enum", "func", "const",
        "printf", "println", "stdin", "stdout", "stderr", "nil", "null", "bool", "int", "str", "len", "args", "argv",
        "kwargs", "regex", "repo", "config", "localhost", "admin", "login", "logout", "signup", "username",
        "covid", "cyan", "macbook", "iphone", "ipad", "airpods", "trackpad", "passcode", "spreadsheet", "aftermarket",
        "todo", "fixme", "readme", "changelog", "dockerfile", "makefile", "plist", "dylib", "uuid", "utf", "ascii",
        "ipv", "smtp", "imap", "oauth", "jwt", "cors", "cron", "sqlite", "linux", "ubuntu", "debian",
        "homebrew", "chrome", "safari", "firefox", "kakaotalk", "naver", "google", "youtube", "netflix", "wifi",
        // Two-key commands and abbreviations, for rule C9 (rm is 그, db is 유, gh is 호).
        "rm", "cp", "mv", "ls", "cd", "ps", "db", "gh", "sh", "vi", "js", "ts", "py", "ui", "ux", "ok", "pr", "qa",
        "os", "io", "ai", "ml", "vm", "ip", "ci", "fs", "gc",
        // Developer words the list ranks past commonRank, for rule C8a (owner, 2026-11-21: app가, user가).
        "app", "user", "node", "diff",
    ]
    private static let technicalWordRank = 20_000
    /// Names with a digit that are stems of rule C8 (owner Q3, 2026-11-21):
    /// file formats, codecs, protocols, chips and services, chosen by FixDock.
    private static let versionNames: Set<String> = [
        "mp3", "mp4", "h264", "h265", "ipv4", "ipv6", "utf8", "utf16", "x86", "x64", "arm64", "win32",
        "m1", "m2", "m3", "m4", "s3", "ec2", "k8s", "ps4", "ps5",
    ]
    private static let neverInside: Set<Character> = ["@", ":", "/", "\\", "_", "~", "#", "=", "&", "%", ".", "-"]
    /// Capitals after which a late Shift is forgiven: the double consonants.
    private static let doubleConsonantKeys: Set<Character> = ["Q", "W", "E", "R", "T"]
    /// Rule C12: the keys whose Shift gives Korean typing a jamo of its own and
    /// that a chat repeats (ㅃㅃ, ㅉㅉ, ㅖㅖ).
    private static let repeatedShiftKeys: Set<Character> = ["Q", "W", "E", "R", "T", "P"]

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

    /// Rule C7's guard: Korean chat, which no list holds and so scores as
    /// English. Shorthand opens with two consonants, alone or before a
    /// syllable (ㅁㄴㅇㄹ, ㅇㄷ야). A face opens with ㅠ ㅜ or ㅡ and closes with
    /// the same vowel, alone or in an open syllable (ㅠ개ㅠ, ㅠㄱ듀), or with a
    /// laugh (ㅠ갴ㅋ); or it is jamo with no other vowel (ㅜㅜㅇㅁㅇ).
    private static func isChatShape(_ text: String) -> Bool {
        let scalars = Array(text.unicodeScalars)
        let consonant = { (scalar: Unicode.Scalar) in (0x3131...0x314E).contains(scalar.value) }
        let vowel = { (scalar: Unicode.Scalar) in (0x314F...0x3163).contains(scalar.value) }
        // Each tear vowel with its index as a syllable's vowel.
        let tears: [Unicode.Scalar: UInt32] = ["ㅜ": 13, "ㅠ": 17, "ㅡ": 18]
        if scalars.prefix(2).allSatisfy(consonant) { return true }
        if let first = scalars.first, let last = scalars.last, let tear = tears[first] {
            if last == first || last == "ㅋ" || last == "ㅎ" { return true }
            let syllable = last.value &- 0xAC00
            if syllable < 11_172, syllable % 28 == 0, syllable % 588 / 28 == tear { return true }
        }
        return scalars.allSatisfy { consonant($0) || vowel($0) } && scalars.filter(vowel).allSatisfy { tears[$0] != nil }
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

    /// Rules C8 and M9: the front of a token as an English word. A list word
    /// of three letters or more, written as lowercase, capitalised or a known
    /// command; an acronym of two to six capitals (PR, API); or a known
    /// version name (owner Q3, 2026-11-21): v and digits (v2, V10), or one of
    /// `versionNames`. Other letters with a digit (a1, x2) may be a password
    /// or an id, and stay.
    private func isEnglishStem(_ stem: String) -> Bool {
        guard let first = stem.first, first.isLetter else { return false }
        if stem.contains(where: \.isNumber) {
            let lower = stem.lowercased()
            if lower.first == "v", (2...5).contains(lower.count), lower.dropFirst().allSatisfy(\.isNumber) { return true }
            return Self.versionNames.contains(lower)
        }
        if stem.count >= 2, stem.count <= 6, stem.allSatisfy(\.isUppercase) { return true }
        guard stem.count >= 3, stem.dropFirst().allSatisfy(\.isLowercase) else { return false }
        let lower = stem.lowercased()
        if Self.technicalWords.contains(lower) { return true }
        return latin.rank(of: Array(lower.utf8)).map { $0 <= thresholds.whileTypingMaxRank } ?? false
    }

    /// C8 typed in the Korean source, M8b and M3a (P2, owner 2026-11-21): a
    /// stem of three or four lowercase letters that is a command or a list
    /// word within `commonRank` (push, bug, node).
    private func isShortStemOn2Set(_ stem: String) -> Bool {
        guard stem.count >= 3, stem.count < 5, stem.allSatisfy(\.isLowercase) else { return false }
        return Self.technicalWords.contains(stem) || latin.rank(of: Array(stem.utf8)).map { $0 <= thresholds.commonRank } ?? false
    }

    /// P2 (owner rule P2-3: no Korean slip may change): the keys, in key space,
    /// are one slip from a Korean word, a key added, dropped or two neighbours
    /// swapped (gladdmf is 힘을 with ㅇ twice); `prefix`: from the start of one.
    private func readsAsKoreanSlip(_ keySpace: [Character], prefix: Bool = false) -> Bool {
        let isKorean = { (variant: [Character]) -> Bool in
            let bytes = Array(String(variant).utf8)
            return prefix ? self.hangul.hasWord(startingWith: bytes) : self.hangulReading(bytes).rank != nil
        }
        let alphabet = Array("qwertyuiopasdfghjklzxcvbnmQWERTOP")
        for i in 0...keySpace.count {
            for key in alphabet {
                var added = keySpace; added.insert(key, at: i)
                if isKorean(added) { return true }
            }
            guard i < keySpace.count else { continue }
            var dropped = keySpace; dropped.remove(at: i)
            if !dropped.isEmpty, isKorean(dropped) { return true }
            if i + 1 < keySpace.count {
                var swapped = keySpace; swapped.swapAt(i, i + 1)
                if isKorean(swapped) { return true }
            }
        }
        return false
    }

    /// Rule C8a (P1, 2026-11-20): right after a word that ended in Korean,
    /// 가 나 요 야 behind a lowercase stem that is a command, a list word within
    /// `commonRank` or five letters long is a tail, though English words end
    /// with or hold its keys (`tailEndings`, `tailInside`). Not when the whole
    /// token reads as whole Hangul syllables: that is Korean typed on ABC (C5).
    /// A word typed in the Korean source counts as Korean context too
    /// (2026-11-22: push가 typed on 2-Set alone); callers pass `.hangul2` then.
    private func isSentenceTail(stem: String, tail: String, previous: TypedSource?) -> Bool {
        guard previous == .hangul2, stem.count >= 3, stem.allSatisfy(\.isLowercase), Self.sentenceTails.contains(tail),
              !Self.isHangulSyllables(HangulTwoSet.hangul(fromKeySpace: stem + tail)) else { return false }
        return stem.count >= 5 || Self.technicalWords.contains(stem)
            || latin.rank(of: Array(stem.utf8)).map { $0 <= thresholds.commonRank } ?? false
    }

    /// Rule C8: the token as an English stem with a whole Korean tail glued
    /// on, the longest stem first, and the token as the learned set keeps it.
    /// A two-key tail behind a short lowercase stem must end at most
    /// `tailEndings` English words (bendy is no ben요, forgo no for해).
    /// Typed in the Korean source, a slip reads as a short English word too often (내ㅐ가 is soo가): the
    /// stem needs five letters, or capitals, and must read as Korean with a
    /// jamo left over; one of consonants alone needs two different ones
    /// (server is ㄴㄷㄱㅍㄷㄱ), so a laugh (ㅋㅋㅋㅋ했어) is never split. nil when
    /// no split reads so.
    private func splitReading(_ token: LayoutToken, previous: TypedSource? = nil) -> (text: String, learned: LearnedKey)? {
        let keys = token.keys
        guard keys.count >= 4, !keys.contains(where: { $0.stroke.option || $0.isRepeat }) else { return nil }
        let characters = keys.compactMap { $0.typed.count == 1 ? $0.typed.first : nil }
        guard characters.count == keys.count, characters.allSatisfy({ $0.isASCII ? $0.isLetter || $0.isNumber : HangulTwoSet.isJamo($0) })
        else { return nil }
        let jamo = characters.contains(where: HangulTwoSet.isJamo)
        if jamo, characters.contains(where: { $0.isASCII && $0.isLetter }) { return nil }
        let typedIn: TypedSource = jamo ? .hangul2 : .latin
        // Each key as English reads it, and in key space for the tail (nil: no jamo key).
        var english: [Character] = []
        var korean: [Character?] = []
        for (character, key) in zip(characters, keys) {
            if let letter = HangulTwoSet.key(typing: character) {
                english.append(key.stroke.shift ? Character(letter.uppercased()) : Character(letter.lowercased()))
                korean.append(letter)
            } else if character.isLetter {
                english.append(character)
                korean.append(character.isLowercase || HangulTwoSet.shiftedKeyLetters.contains(character) ? character : nil)
            } else {
                english.append(character)
                korean.append(nil)
            }
        }
        let whole = String(english).lowercased()
        if latin.rank(of: Array(whole.utf8)) != nil || Self.technicalWords.contains(whole) { return nil }
        for split in stride(from: keys.count - 2, through: 2, by: -1) {
            let tailKeys = korean[split...].compactMap { $0 }
            guard tailKeys.count == keys.count - split else { continue }
            let tail = HangulTwoSet.hangul(fromKeySpace: String(tailKeys))
            let stem = String(english[..<split])
            guard Self.tailSet.contains(tail), isEnglishStem(stem) else { continue }
            if stem.count < 5, tailKeys.count == 2, stem.allSatisfy(\.isLowercase),
               !isSentenceTail(stem: stem, tail: String(tailKeys).lowercased(), previous: typedIn == .hangul2 ? .hangul2 : previous),
               latin.count(holding: Array(String(tailKeys).lowercased().utf8), atEnd: true) > Self.tailEndings { continue }
            if typedIn == .hangul2 {
                let shortStem = stem.count < 5 && !stem.allSatisfy(\.isUppercase) && !stem.contains(where: \.isNumber)
                guard !shortStem || isShortStemOn2Set(stem) else { continue }
                if shortStem, readsAsKoreanSlip(korean.compactMap { $0 }) { continue }
                let read = HangulTwoSet.hangul(fromKeySpace: String(korean[..<split].map { $0.map(String.init) ?? "" }.joined()))
                // A version name (v2, ㅍ2) is no laugh: the digit says so.
                let consonantsOnly = !stem.contains(where: \.isNumber)
                    && read.unicodeScalars.allSatisfy { (0x3131...0x314E).contains($0.value) }
                guard !Self.isHangulSyllables(read),
                      !consonantsOnly || (split >= 4 && Set(english[..<split].map { $0.lowercased() }).count >= 2)
                else { continue }
            }
            let learned = typedIn == .latin ? String(characters) : String(characters.map { HangulTwoSet.key(typing: $0) ?? $0 })
            return (stem + tail, LearnedKey(keys: learned, source: typedIn))
        }
        return nil
    }

    /// Rule C11 (2026-11-22): two to six keys typed in the Korean source, each
    /// with Shift, are capitals (PR is ㅖㄲ, API ㅁㅖㅑ), unless the jamo read
    /// as Korean: whole syllables (a late Shift, 싸), a list or chat word, one
    /// key repeated (ㅖㅖ, ㅃㅃ), or chat shorthand in which each key's Shift gave it
    /// its double consonant or ㅒ ㅖ or was released late after one (ㄲㅆ, ㅃㅇ typed
    /// QD, as C3 forgives in ABC). nil otherwise.
    private func capitalsOn2Set(_ token: LayoutToken) -> (text: String, learned: LearnedKey)? {
        let keys = token.keys
        guard (2...6).contains(keys.count), keys.allSatisfy({ $0.stroke.shift && !$0.stroke.option && !$0.isRepeat })
        else { return nil }
        let letters = keys.compactMap { $0.typed.count == 1 ? $0.typed.first.flatMap(HangulTwoSet.key(typing:)) : nil }
        guard letters.count == keys.count, Set(letters).count > 1 else { return nil }
        let keySpace = String(letters)
        let korean = hangulReading(Array(keySpace.utf8))
        guard korean.rank == nil, !Self.isHangulSyllables(korean.text),
              !(letters.indices.allSatisfy({ letters[$0].isUppercase || ($0 > 0 && letters[$0 - 1].isUppercase) })
                && Self.isChatShape(korean.text))
        else { return nil }
        return (keySpace.uppercased(), LearnedKey(keys: keySpace, source: .hangul2))
    }

    /// Rule C12 (owner, 2026-11-23): typed in the Latin source, one key
    /// repeated two to four times with Shift where Shift gives Korean typing
    /// its own jamo, is that chat (QQ is ㅃㅃ, PP ㅖㅖ); no command or common
    /// English word is spelled so (ee, at 13,273, is the only list word). nil otherwise.
    private func repeatedShiftOnABC(_ token: LayoutToken) -> (text: String, learned: LearnedKey)? {
        let keys = token.keys
        guard (2...4).contains(keys.count), keys.allSatisfy({ $0.stroke.shift && !$0.stroke.option && !$0.isRepeat }),
              let first = keys.first?.typed, first.count == 1, Self.repeatedShiftKeys.contains(first.first!),
              keys.allSatisfy({ $0.typed == first })
        else { return nil }
        let typed = keys.map(\.typed).joined()
        return (HangulTwoSet.hangul(fromKeySpace: typed), LearnedKey(keys: typed, source: .latin))
    }

    /// The token exactly as typed, the key the learned set is kept by.
    func learnedKey(of token: LayoutToken) -> LearnedKey? {
        readings(of: token).readings?.learnedKey ?? splitReading(token)?.learned ?? capitalsOn2Set(token)?.learned
            ?? repeatedShiftOnABC(token)?.learned
    }

    /// Rules N1–N12 and C1–C12, at a whitespace key after `token`.
    /// `previous`: the language the word before it in the same field ended in.
    func decideAtWordEnd(_ token: LayoutToken, anchored: Bool, earlier: EarlierClaim,
                         previous: TypedSource? = nil) -> LayoutFixDecision {
        guard anchored else { return .keep(.n1) }
        let (found, reason) = readings(of: token)
        guard let readings = found else {
            // C8 where the readings refuse the stem: capitals (API에, Github에) or a digit (v2에).
            if reason == .n5 || reason == .n2, earlier == .none, let split = splitReading(token, previous: previous),
               !learned.contains(split.learned) {
                return .change(to: .hangul2, text: split.text)
            }
            // C11: the source stays Korean, as for C8: Shift held on 2-Set
            // is no switch to English (PR 올려줘).
            if reason == .n4, earlier == .none, let capitals = capitalsOn2Set(token), !learned.contains(capitals.learned) {
                return .change(to: .hangul2, text: capitals.text)
            }
            // C12: Shift held for a double consonant in the Latin source (QQ is ㅃㅃ).
            if reason == .n4, earlier == .none, let repeated = repeatedShiftOnABC(token), !learned.contains(repeated.learned) {
                return .change(to: .hangul2, text: repeated.text)
            }
            return .keep(reason ?? .n8)
        }
        let korean = hangulReading(readings.korean)
        var minKeys = thresholds.minKeys
        if readings.typedIn == .latin, !korean.text.allSatisfy(HangulTwoSet.isJamo) {
            minKeys = max(minKeys, thresholds.minKeysFromLatin)
        }
        if token.keys.count < minKeys {
            // C9 (2026-11-20): right after a Korean word, two keys typed in the
            // Latin source that read as a common Korean word and as no English
            // one (dl 이, rj 거) are Korean too. (zz is ㅋㅋ by C1, word before or not.)
            if previous == .hangul2, readings.typedIn == .latin, token.keys.count >= thresholds.minKeys, earlier == .none,
               !learned.contains(readings.learnedKey), let rank = korean.rank, rank <= thresholds.commonRank,
               latin.rank(of: readings.english) == nil,
               !Self.technicalWords.contains(String(decoding: readings.english, as: UTF8.self)) {
                return .change(to: .hangul2, text: korean.text)
            }
            // C12 (owner, 2026-11-23): two keys typed in the Latin source, a
            // double consonant's Shift and a vowel, one whole syllable (Tk is
            // 싸) that no English word or command spells. Two keys reach here
            // only as one syllable: two jamo are no shorter than minKeys.
            if readings.typedIn == .latin, earlier == .none, !learned.contains(readings.learnedKey),
               let first = readings.englishText.first, Self.doubleConsonantKeys.contains(first),
               latin.rank(of: readings.english) == nil,
               !Self.technicalWords.contains(String(decoding: readings.english, as: UTF8.self)) {
                return .change(to: .hangul2, text: korean.text)
            }
            return .keep(.n10)
        }
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
        // C8 (2026-11-20): neither reading a word, but an English word with a
        // Korean tail (stagingdp, ㅇ데ㅣㅐㅛ할게요): the stem stays English, the
        // tail becomes Korean, from either source.
        if typed == nil, other == nil, let split = splitReading(token, previous: previous) {
            return .change(to: .hangul2, text: split.text)
        }
        // C5: typed in the Latin source, not an English word, and the keys
        // compose into nothing but whole syllables. The Korean list holds
        // spaced subtitle words and misses most inflected forms; English
        // letters almost never fall into whole syllables by chance.
        if typed == nil, other == nil, readings.typedIn == .latin, let needed = thresholds.wholeSyllables,
           korean.text.count >= needed, Self.isHangulSyllables(korean.text) {
            return .change(to: .hangul2, text: korean.text)
        }
        // C7: typed in the Korean source, a jamo left over, neither reading a
        // list word (herdr is ㅗㄷㄱㅇㄱ). A slip or a chat tail (안녕ㅎ, 웃겨ㅋㅋ)
        // still reads as Korean typing. Five keys at least: a slip in a short
        // word (ㄷ구 for 두) reads as English too often.
        if typed == nil, other == nil, readings.typedIn == .hangul2, let margin = thresholds.keyScoreMargin,
           token.keys.count >= 5, !Self.isChatShape(korean.text),
           latin.keyModel.score(readings.english) - hangul.keyModel.score(readings.english) > margin {
            return .change(to: .latin, text: readings.englishText)
        }
        guard let otherRank = other else { return .keep(typed == nil ? .n8 : .typedIsAWord) }
        if let typedRank = typed {
            if token.keys.count <= thresholds.shortTokenKeys {
                // C12 (owner, 2026-11-23): consonant chat typed in the Latin
                // source (de is ㅇㄷ) wins over a short English word. No command
                // spells a chat word (rm cp cd db gh stay).
                if readings.typedIn == .latin, Self.chatWords.contains(korean.text) {
                    return .change(to: .hangul2, text: korean.text)
                }
                return .keep(.n6)
            }
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
        let short = token.keys.count < thresholds.minKeysWhileTyping
        if short, token.keys.count != thresholds.shortKeysWhileTyping { return .keep(.m1) }
        if short, readings.typedIn == .hangul2 {
            // M8b: three keys on 2-Set that are a whole command and read as no Korean (sdk, not app: 메ㅔ).
            let english = String(decoding: readings.english, as: UTF8.self)
            let typed = HangulTwoSet.hangul(fromKeySpace: String(decoding: readings.korean, as: UTF8.self))
            let command = Self.technicalWords.contains(english) && !hangul.hasWord(startingWith: readings.korean)
                && !Self.isHangulSyllables(typed)
                && !readsAsKoreanSlip(Array(String(decoding: readings.korean, as: UTF8.self)), prefix: true)
            // M8c: a common English word starts with the keys, and the Korean
            // reading opens with a jamo on its own (ㄴㅅㅁ sta, ㅛㅐㅕ you, ㅎㄷㅅ get),
            // which no Korean word typed on purpose does, unless it is chat:
            // consonants that open or close with a chat word
            // (ㅇㄷㅁ, ㅎㄷㄷ) or end as they start (ㅇㅁㅇ), or a face (ㅠㅁㅅ);
            // and unless the keys are one slip from the start of a Korean word
            // (ㅈㅁㅅ is 점심 with ㅓ dropped, ㅗ디 되 with two keys swapped).
            // A word that opens with a syllable (새ㅐㅐ, 늠) waits for the fourth key.
            let word = thresholds.shortWhileTypingEnglishRank.map { limit in
                guard typed.first.map(HangulTwoSet.isJamo) ?? false,
                      latin.bestRank(startingWith: readings.english).map({ $0 <= limit }) ?? false else { return false }
                if typed.unicodeScalars.allSatisfy({ (0x3131...0x314E).contains($0.value) }) {
                    guard typed.first != typed.last, !Self.chatWords.contains(String(typed.prefix(2))),
                          !Self.chatWords.contains(String(typed.suffix(2))) else { return false }
                } else if Self.isChatShape(typed) {
                    return false
                }
                return !readsAsKoreanSlip(Array(String(decoding: readings.korean, as: UTF8.self)), prefix: true)
            } ?? false
            guard command || word else { return .keep(.m1) }
        }
        if earlier != .none { return .keep(.n11) }
        let typedKeys = readings.learnedKey.keys
        if learned.contains(where: { $0.source == readings.typedIn && $0.keys.hasPrefix(typedKeys) }) { return .keep(.n9) }
        if token.keys.last?.stroke.shift ?? false { return .keep(.m7) }

        switch readings.typedIn {
        case .latin:
            if latin.hasWord(startingWith: readings.english)
                || Self.technicalWords.contains(where: { $0.utf8.starts(with: readings.english) }) { return .keep(.m2) }
            guard hangul.hasCommonWord(startingWith: readings.korean) else { return .keep(.m3) }
            // Everything before the syllable still open has to be whole.
            let text = HangulTwoSet.hangul(fromKeySpace: String(decoding: readings.korean, as: UTF8.self))
            let settled = String(text.dropLast())
            guard settled.isEmpty || Self.isHangulSyllables(settled) else { return .keep(.m3) }
            if short {
                // M8: one whole syllable with a final consonant (밥, 갈) that
                // is itself a common word, so the word end would change it too.
                guard text.count == 1, Self.isHangulSyllables(text),
                      (text.unicodeScalars.first!.value - 0xAC00) % 28 != 0,
                      let rank = hangul.rank(of: readings.korean), rank <= thresholds.shortWhileTypingKoreanRank
                else { return .keep(.m8) }
            }
            return .change(to: .hangul2, text: text)
        case .hangul2:
            if hangul.hasWord(startingWith: readings.korean) { return .keep(.m2) }
            // M3a: a whole command counts too (node), unless the keys are a Korean slip.
            guard latin.hasCommonWord(startingWith: readings.english)
                    || (Self.technicalWords.contains(String(decoding: readings.english, as: UTF8.self))
                        && !readsAsKoreanSlip(Array(String(decoding: readings.korean, as: UTF8.self)), prefix: true))
            else { return .keep(.m3) }
            return .change(to: .latin, text: readings.englishText)
        }
    }

    /// Rule M9 (2026-11-20), on a letter key typed in the Latin source,
    /// `token` including it: no English word starts with the keys, but an
    /// English stem (`isEnglishStem`) does, with the start of a Korean tail of
    /// two keys or more behind it (deploy + gk of 할게요) that sits in few English
    /// words. A lowercase stem needs four letters (dea + dp of deadpan). Returns
    /// the stem's key count; the tail goes to Korean while it is still typed.
    /// `previous`: the language the word before ended in (C8a); `changed`:
    /// M changed the word while it was typed, so it was typed in the Korean
    /// source and counts as Korean context for C8a.
    func boundaryWhileTyping(_ token: LayoutToken, earlier: EarlierClaim, previous: TypedSource? = nil,
                             changed: Bool = false) -> Int? {
        let keys = token.keys
        guard earlier == .none, keys.count >= 4, !(keys.last?.stroke.shift ?? false),
              !keys.contains(where: { $0.stroke.option || $0.isRepeat }) else { return nil }
        let characters = keys.compactMap { $0.typed.count == 1 ? $0.typed.first : nil }
        guard characters.count == keys.count, characters.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        let text = String(characters)
        if learned.contains(where: { $0.source == .latin && $0.keys.hasPrefix(text) }) { return nil }
        let lower = text.lowercased()
        if latin.hasWord(startingWith: Array(lower.utf8)) || Self.technicalWords.contains(where: { $0.hasPrefix(lower) }) { return nil }
        for split in stride(from: keys.count - 2, through: 2, by: -1) {
            let tail = characters[split...]
            let stem = String(characters[..<split])
            guard tail.allSatisfy({ $0.isLowercase || HangulTwoSet.shiftedKeyLetters.contains($0) }),
                  Self.tailKeys.contains(where: { $0.hasPrefix(String(tail)) }),
                  isEnglishStem(stem)
            else { continue }
            let sentenceTail = (changed ? Self.sentenceTails : Self.sentenceTailsAtAKey).contains(String(tail))
                && isSentenceTail(stem: stem, tail: String(tail), previous: changed ? .hangul2 : previous)
            guard split >= 4 || !stem.allSatisfy(\.isLowercase) || sentenceTail || (changed && isShortStemOn2Set(stem)),
                  sentenceTail || latin.count(holding: Array(String(tail).lowercased().utf8), atEnd: false) <= Self.tailInside
            else { continue }
            return split
        }
        return nil
    }
}

/// Turns a decision into what the tap's executor does to the screen.
enum LayoutFixPlanner {
    /// A change at a word end, with the finished text injected: the
    /// delimiter was swallowed, so the word and the punctuation behind it
    /// are the last things in the field. They are erased, the other reading
    /// and the same punctuation typed, then the delimiter. Punctuation in
    /// front of the word stays where it is. Then the input source is asked
    /// for the target (D14), where the fast switch can give it. A word typed
    /// since an edit (`sinceEdit`, 7.10) is checked from its start: the field
    /// must show its punctuation in front too, after a space or the field's
    /// start.
    static func wordEnd(_ token: LayoutToken, to target: TypedSource, text: String, delimiter: TypedKey,
                        sinceEdit: Bool = false) -> ReplacementPlan {
        let erased = token.keys + token.trailing
        let typed = erased.map(\.typed).joined()
        let trailing = token.trailing.map(\.typed).joined()
        let backspaces: PlanStep
        let shown: String
        // The source it was typed in, not the opposite of the target: rule C8
        // sends a word typed in the Korean source to Korean too.
        if !token.keys.contains(where: { $0.typed.first.map(HangulTwoSet.isJamo) ?? false }) {
            // Typed in the Latin source: one backspace per key.
            backspaces = .backspaces(erased.count, completionCheck: typed)
            shown = typed
        } else {
            // Typed in the Korean source: the field shows composed
            // syllables. The count starts clean, at the whitespace or the
            // punctuation in front of the word.
            backspaces = .backspaces(HangulTwoSet.backspaces(erasing: typed), completionCheck: nil)
            shown = render(token.keys, in: .hangul2) + trailing
        }
        let leading = token.leading.map(\.typed).joined()
        return ReplacementPlan(steps: [sinceEdit ? .expectWordStart(leading + shown) : .expect(shown),
                                       backspaces,
                                       .text(text + trailing),
                                       .key(delimiter.stroke),
                                       .handOff(target)])
    }

    /// Rule C10: the field shows `before`, the Space and the word (`shown`,
    /// as `token`'s keys put it there); both are erased, then typed as they
    /// end, then the delimiter, and the source goes to Korean.
    static func beforeAndWordEnd(before: String, beforeText: String, space: TypedKey, token: LayoutToken, shown: String,
                                 text: String, delimiter: TypedKey) -> ReplacementPlan {
        let erased = token.keys + token.trailing
        let typed = erased.map(\.typed).joined()
        let backspaces: [PlanStep]
        if !token.keys.contains(where: { $0.typed.first.map(HangulTwoSet.isJamo) ?? false }) {
            // All typed in the Latin source: one backspace per key.
            backspaces = [.backspaces(before.count + space.typed.count + erased.count, completionCheck: before + space.typed + typed)]
        } else {
            // The word as the input method composed it, counted from the Space; then the Space and the word before.
            backspaces = [.backspaces(HangulTwoSet.backspaces(erasing: typed), completionCheck: nil),
                          .backspaces(before.count + space.typed.count, completionCheck: nil)]
        }
        return ReplacementPlan(steps: [.expect(before + space.typed + shown)] + backspaces
                               + [.text(beforeText + space.typed + text), .key(delimiter.stroke), .handOff(.hangul2)])
    }

    /// Whether the field shows `word` at a word's start (7.10). `read` is the
    /// text right before the caret: `word` and the one UTF-16 unit in front
    /// of it, or `word` alone where the field starts (`atFieldStart`). In
    /// front counts as a start: whitespace, a line break, or a zero-width
    /// mark (a contenteditable field keeps one where it is empty).
    static func showsWordStart(_ word: String, read: String, atFieldStart: Bool) -> Bool {
        if atFieldStart { return read == word }
        let units = Array(read.utf16)
        guard units.count == word.utf16.count + 1,
              String(utf16CodeUnits: Array(units.dropFirst()), count: units.count - 1) == word,
              let before = Unicode.Scalar(units[0]) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(before) || before == "\u{FEFF}" || before == "\u{200B}"
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
                                .text(record.original)]
                            + (record.delimiter.map { [.key($0)] } ?? [])
                            + [.handOff(record.learned.source)])
    }

    /// A change while typing (3.4), at the key that decided it, which is
    /// swallowed: the field must show the word so far from its start (as
    /// 7.10 checks an edited word), then the word is erased, and the rest
    /// of the plan (`MidWordStep`) sends every key of it again once the
    /// source is the target (R2). With the claim come the reducer's record
    /// of it and the undo record, live once the keys are out.
    static func midWord(_ token: LayoutToken, to target: TypedSource, text: String, app: String?)
        -> (plan: ReplacementPlan, claim: MidWordClaim, undo: LayoutFixUndo) {
        let typedIn: TypedSource = target == .latin ? .hangul2 : .latin
        let onScreen = Array(token.keys.dropLast())
        let typed = onScreen.map(\.typed).joined()
        let backspaces: PlanStep = typedIn == .latin
            // One per key; a completion selected behind them is checked as at a word end.
            ? .backspaces(onScreen.count, completionCheck: typed)
            // The composed count, from the clean start the check saw.
            : .backspaces(HangulTwoSet.backspaces(erasing: typed), completionCheck: nil)
        let leading = token.leading.map(\.typed).joined()
        let original = render(token.keys, in: typedIn)
        let plan = ReplacementPlan(steps: [.expectWordStart(leading + render(onScreen, in: typedIn)), backspaces],
                                   midWord: MidWordStep(target: target, typedIn: typedIn, keys: token.keys.map(\.stroke),
                                                        original: original, interrupted: text, needsHandOff: true))
        let claim = MidWordClaim(leading: token.leading, keys: token.keys, typedIn: typedIn, target: target,
                                 before: typedIn, reverts: nil)
        let undo = LayoutFixUndo(app: app, shown: render(token.keys, in: target), original: original, delimiter: nil,
                                 learned: learnedKey(token.keys, typedIn: typedIn),
                                 word: MidWordRecord(leading: token.leading, keys: token.keys, typedIn: typedIn, target: target))
        return (plan, claim, undo)
    }

    /// ⌘Z in the middle of a word changed while it was typed (5.7): once ⌘
    /// is up and the field still shows the changed word from its start, it
    /// is erased, the source it was typed in is asked for, and its keys go
    /// out again there, so it is back exactly as typed, a last syllable
    /// still open, and can be typed on. With no hand-off it goes back as text.
    static func undoInWord(_ record: LayoutFixUndo, _ word: MidWordRecord) -> (plan: ReplacementPlan, claim: MidWordClaim) {
        // A stem left as typed (M9) is Latin, one backspace a key.
        let shownKeys = word.keys[word.lead...].map { $0.reading(in: word.target) }
        let count = word.lead
            + (word.target == .latin ? shownKeys.count : HangulTwoSet.backspaces(erasing: shownKeys.map(\.typed).joined()))
        let plan = ReplacementPlan(steps: [.waitForCommandUp,
                                           .expectWordStart(word.leading.map(\.typed).joined() + record.shown),
                                           .backspaces(count, completionCheck: nil)],
                                   midWord: MidWordStep(target: word.typedIn, typedIn: word.typedIn,
                                                        keys: word.keys.map(\.stroke), original: record.original,
                                                        interrupted: record.original, needsHandOff: false))
        var claim = MidWordClaim(leading: word.leading, keys: word.keys, typedIn: word.typedIn, target: word.typedIn,
                                 before: word.target, reverts: record.learned)
        claim.lead = word.lead
        return (plan, claim)
    }

    /// Rule M9, at the key that decided it, which is swallowed: the field
    /// must show the word so far from its start. The tail typed so far is
    /// erased, and once the source is Korean its keys go out again for the
    /// input method to compose, so the syllable stays open (하, then 할). The
    /// English stem stays where it is. With the reducer's claim and the undo
    /// record, as `midWord` gives them.
    static func boundary(_ token: LayoutToken, stem: Int, app: String?)
        -> (plan: ReplacementPlan, claim: MidWordClaim, undo: LayoutFixUndo) {
        let typed = token.keys.dropLast().map(\.typed).joined()
        let tail = Array(token.keys[stem...])
        let leading = token.leading.map(\.typed).joined()
        let plan = ReplacementPlan(steps: [.expectWordStart(leading + typed),
                                           .backspaces(tail.count - 1, completionCheck: tail.dropLast().map(\.typed).joined())],
                                   midWord: MidWordStep(target: .hangul2, typedIn: .latin, keys: tail.map(\.stroke),
                                                        original: render(tail, in: .latin),
                                                        interrupted: render(tail, in: .hangul2), needsHandOff: true))
        var claim = MidWordClaim(leading: token.leading, keys: token.keys, typedIn: .latin, target: .hangul2,
                                 before: .latin, reverts: nil)
        claim.lead = stem
        var word = MidWordRecord(leading: token.leading, keys: token.keys, typedIn: .latin, target: .hangul2)
        word.lead = stem
        let undo = LayoutFixUndo(app: app, shown: word.shown, original: render(token.keys, in: .latin), delimiter: nil,
                                 learned: learnedKey(token.keys, typedIn: .latin), word: word)
        return (plan, claim, undo)
    }

    /// What a mid-word plan sends once the hand-off has ended, by the source
    /// live then (`live`, nil for one the rules do not read). In either of
    /// the word's two sources its keys go out again and the input method
    /// composes them there: in the target that is the change (or the undo),
    /// in the source they were typed in it is the word as typed (5.5: the
    /// time limit, a pulse refused). Anywhere else the word goes back as text.
    static func afterHandOff(_ step: MidWordStep, live: TypedSource?) -> (steps: [PlanStep], result: MidWordResult) {
        guard let live, live == step.target || live == step.typedIn else { return ([.text(step.original)], .text) }
        return (step.keys.map { .key($0) }, .keys(live))
    }

    /// `keys` as the field shows them when `source` typed them.
    static func render(_ keys: [TypedKey], in source: TypedSource) -> String {
        switch source {
        case .latin:
            return keys.map { $0.reading(in: .latin).typed }.joined()
        case .hangul2:
            return HangulTwoSet.hangul(fromKeySpace: keys.map { $0.keySpaceLetter.map(String.init) ?? $0.typed }.joined())
        }
    }

    /// The learned-set key of a word's keys read in `typedIn`, as
    /// `LayoutFixRules.learnedKey` spells it.
    static func learnedKey(_ keys: [TypedKey], typedIn: TypedSource) -> LearnedKey {
        let word = LayoutToken(keys).keys
        let text = typedIn == .latin ? word.map(\.typed).joined() : String(word.compactMap(\.keySpaceLetter))
        return LearnedKey(keys: text, source: typedIn)
    }
}

/// The layout fix as a tool of the shared typing tap: at a whitespace key it
/// judges the finished word and, for a change, answers with a plan.
struct LayoutFixConsumer {
    struct Config {
        let rules: LayoutFixRules
        /// Bundle identifiers of the apps the person turned the tool off for.
        let ignoredApps: Set<String>
        /// Rule 3.4 is on (off by default, D6) and the fast switch is
        /// installed to hand the source over (M5, D3).
        var whileTyping = false
    }

    var config: Config

    /// `chunk` is the finished word. `earlier` is rule N11's signal. A claim
    /// ended by Space comes with the record ⌘Z would take it back by; a word
    /// left as typed, with why.
    func consider(_ event: TypingEvent, chunk: TypingChunk, earlier: EarlierClaim, frontApp: String?,
                  previous: TypedSource? = nil) -> (verdict: Verdict, undo: LayoutFixUndo?, skip: LayoutFixSkip?) {
        guard case .boundary(let delimiter) = event else { return (.pass, nil, nil) }
        // Changed while it was typed, or that change taken back: judged once.
        if chunk.midWord == .changed { return (.pass, nil, .rule(.m6)) }
        if let frontApp, config.ignoredApps.contains(frontApp) { return (.pass, nil, .ignoredApp) }
        let token = LayoutToken(chunk.keys)
        // Typed since an edit: judged like any word, and the plan asks the
        // field where the word starts (7.10).
        let sinceEdit = !chunk.anchored && chunk.sinceEdit
        let target: TypedSource, text: String
        switch config.rules.decideAtWordEnd(token, anchored: chunk.anchored || sinceEdit, earlier: earlier, previous: previous) {
        case .keep(let reason): return (.pass, nil, .rule(reason))
        case .change(let to, let changed): (target, text) = (to, changed)
        }
        let plan = LayoutFixPlanner.wordEnd(token, to: target, text: text, delimiter: delimiter, sinceEdit: sinceEdit)
        // Only after Space: a Tab may have moved to another field and a
        // Return may have sent a message or run a command, so what is in
        // front of the caret then is not the changed word.
        guard delimiter.typed == " ", let learned = config.rules.learnedKey(of: token) else { return (.claim(plan), nil, nil) }
        let trailing = token.trailing.map(\.typed).joined()
        let original = learned.source == .latin ? learned.keys : HangulTwoSet.hangul(fromKeySpace: learned.keys)
        let undo = LayoutFixUndo(app: frontApp, shown: text + trailing + " ", original: original + trailing,
                                 delimiter: delimiter.stroke, learned: learned)
        return (.claim(plan), undo, nil)
    }

    /// Rule C10 (P3, owner 2026-11-21) at the Space that ends `chunk`, a word
    /// ending in Korean: `before`, the word right before it, which N10 kept,
    /// changes on C9's terms. `undo`: the record of the change this Space
    /// makes to `chunk` itself, if any. One plan for both words, and one
    /// record, so ⌘Z takes both back.
    func considerBefore(_ before: LayoutToken, space: TypedKey, chunk: TypingChunk, undo: LayoutFixUndo?,
                        delimiter: TypedKey, frontApp: String?) -> (plan: ReplacementPlan, undo: LayoutFixUndo)? {
        if let frontApp, config.ignoredApps.contains(frontApp) { return nil }
        let rules = config.rules
        guard case .change(.hangul2, let first) = rules.decideAtWordEnd(before, anchored: true, earlier: .none, previous: .hangul2),
              let learned = rules.learnedKey(of: before)
        else { return nil }
        let token = LayoutToken(chunk.keys)
        guard token.leading.isEmpty, !token.keys.isEmpty else { return nil }
        let trailing = token.trailing.map(\.typed).joined()
        let korean = token.keys.contains { $0.typed.first.map(HangulTwoSet.isJamo) ?? false }
        let shown = (korean ? LayoutFixPlanner.render(token.keys, in: .hangul2) : token.keys.map(\.typed).joined()) + trailing
        // How the word itself ends, and how it was typed.
        let text: String, original: String
        if let undo {
            text = String(undo.shown.dropLast())
            original = undo.original
        } else {
            text = shown
            original = chunk.midWord == .changed ? LayoutFixPlanner.render(token.keys, in: .latin) + trailing : shown
        }
        let typedBefore = before.keys.map(\.typed).joined()
        let plan = LayoutFixPlanner.beforeAndWordEnd(before: typedBefore, beforeText: first, space: space, token: token,
                                                     shown: shown, text: text, delimiter: delimiter)
        let record = LayoutFixUndo(app: frontApp, shown: first + space.typed + text + " ", original: typedBefore + space.typed + original,
                                   delimiter: delimiter.stroke, learned: learned)
        return (plan, record)
    }

    /// Rule 3.4 on a letter key, `chunk` including it, with the switch on:
    /// the word so far is changed before it ends. Once per word (M6); the
    /// field has to show the word from its start.
    func considerWhileTyping(chunk: TypingChunk, earlier: EarlierClaim, frontApp: String?)
        -> (plan: ReplacementPlan, claim: MidWordClaim, undo: LayoutFixUndo)? {
        guard chunk.midWord == .none, chunk.anchored || chunk.sinceEdit else { return nil }
        if let frontApp, config.ignoredApps.contains(frontApp) { return nil }
        let token = LayoutToken(chunk.keys)
        // A closing mark on this key: the word was judged at the key before.
        guard token.trailing.isEmpty,
              case .change(let target, let text) = config.rules.decideWhileTyping(token, anchored: true, earlier: earlier)
        else { return nil }
        return LayoutFixPlanner.midWord(token, to: target, text: text, app: frontApp)
    }

    /// Rule M9 on a letter key, `chunk` including it, with the switch on: the
    /// Korean tail starting behind an English word goes to Korean. The caller
    /// asks once per word: before any other change while typing, or right
    /// after the one that made the word English.
    func considerBoundary(chunk: TypingChunk, earlier: EarlierClaim, frontApp: String?, previous: TypedSource? = nil)
        -> (plan: ReplacementPlan, claim: MidWordClaim, undo: LayoutFixUndo)? {
        guard chunk.anchored || chunk.sinceEdit else { return nil }
        if let frontApp, config.ignoredApps.contains(frontApp) { return nil }
        let token = LayoutToken(chunk.keys)
        guard token.trailing.isEmpty, let stem = config.rules.boundaryWhileTyping(token, earlier: earlier, previous: previous,
                                                                                      changed: chunk.midWord == .changed)
        else { return nil }
        return LayoutFixPlanner.boundary(token, stem: stem, app: frontApp)
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

    /// The layout an input source types, of the two the rules read.
    static func source(ofID id: String?) -> TypedSource? {
        guard let id, knownSourceIDs.contains(id) else { return nil }
        return id.hasPrefix("com.apple.inputmethod.Korean") ? .hangul2 : .latin
    }

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
