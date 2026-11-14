// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import Foundation

// The pure half of the shared typing tap (`Services/TypingTap.swift`): what
// a key event is, the text typed since the last break, and the reducer that
// asks the typing tools what to do with a key. No CGEvent here, so a harness
// can replay keys through it.

/// Key code plus the raw event flag bits, so a key sent again keeps what the
/// physical key had.
struct KeyStroke: Hashable {
    let keyCode: UInt16
    let rawFlags: UInt64

    // CGEventFlags bits and virtual key codes, spelled out because this file
    // imports Foundation only.
    private static let shiftFlag: UInt64 = 1 << 17
    private static let controlFlag: UInt64 = 1 << 18
    private static let optionFlag: UInt64 = 1 << 19
    private static let commandFlag: UInt64 = 1 << 20
    private static let deleteKey: UInt16 = 0x33
    private static let zKey: UInt16 = 0x06
    /// Left, Right, Down, Up, Escape, Home, End, Page Up, Page Down, forward delete.
    private static let caretKeys: Set<UInt16> = [0x7B, 0x7C, 0x7D, 0x7E, 0x35, 0x73, 0x77, 0x74, 0x79, 0x75]

    var shift: Bool { rawFlags & Self.shiftFlag != 0 }
    var option: Bool { rawFlags & Self.optionFlag != 0 }
    var commandOrControl: Bool { rawFlags & (Self.commandFlag | Self.controlFlag) != 0 }
    var isDelete: Bool { keyCode == Self.deleteKey }
    var movesCaret: Bool { Self.caretKeys.contains(keyCode) }
    /// ⌘Z with no other modifier.
    var isCommandZ: Bool {
        keyCode == Self.zKey
            && rawFlags & (Self.commandFlag | Self.controlFlag | Self.optionFlag | Self.shiftFlag) == Self.commandFlag
    }
}

/// Who posted a key. `.output` is the typing tap's own replacement text and
/// is never judged. `.relay` is a key the person typed that the tap gave
/// back after a hold it had to give up; it passes unjudged, or a trigger in
/// it would be claimed again and again. `.otherOwn` is another FixDock tool's
/// event (the fast switch's pulse, quit protection's copy) and passes
/// untouched.
enum KeyOrigin: Equatable { case physical, relay, output, otherOwn }

/// One event as the tap saw it, already free of CGEvent.
struct RawKey: Equatable {
    enum Kind: Equatable { case keyDown, mouseDown }
    let kind: Kind
    let origin: KeyOrigin
    let stroke: KeyStroke
    let isRepeat: Bool
    /// The characters the key event carries, at most four UTF-16 units.
    let characters: String
}

/// The input source a key was typed in, as the key event itself shows it.
enum TypedSource: String, Codable, Hashable { case latin, hangul2 }

struct TypedKey: Equatable {
    let stroke: KeyStroke
    let isRepeat: Bool
    /// What the field received: jamo under 2-Set, the letter under Latin.
    let typed: String
    /// The same key as its Latin letter, which Latin triggers match in
    /// either input source.
    var keyed: String { HangulTwoSet.latinKeys(typed, shifted: stroke.shift) }
}

enum TypingEvent: Equatable {
    case text(TypedKey)        // a key that puts a character in the field
    case boundary(TypedKey)    // space, Tab, Return
    case delete                // backspace
    case deleteMore            // backspace with Option: it takes a whole word
    case caretMove             // arrows, Home, End, Page keys, Escape, forward delete
    case chord                 // ⌘ or ⌃ held: a command, not text
    case nonText               // a key that carries no character
    case pointer               // mouse down
    case reset                 // secure input

    /// nil for an event that is not typing. The order of the checks is the order
    /// the snippet tap has always made them in.
    init?(_ raw: RawKey, secureInput: Bool) {
        // Clicks move the caret somewhere unknown.
        if raw.kind == .mouseDown {
            self = .pointer
            return
        }
        guard raw.origin == .physical else { return nil }
        // Password fields: typing there must stay exactly as typed, and
        // nothing may remember any of it.
        if secureInput {
            self = .reset
        } else if raw.stroke.commandOrControl {
            self = .chord
        } else if raw.stroke.isDelete {
            self = raw.stroke.option ? .deleteMore : .delete
        } else if raw.stroke.movesCaret {
            self = .caretMove
        } else if let first = raw.characters.first {
            let key = TypedKey(stroke: raw.stroke, isRepeat: raw.isRepeat, typed: raw.characters)
            self = TextSnippetSupport.delimiters.contains(first) ? .boundary(key) : .text(key)
        } else {
            self = .nonText
        }
    }
}

/// The one buffer: what was typed since the last break. Text snippets read
/// the two strings, which run character for character and forget everything
/// past `TextSnippetSupport.bufferLimit`. The layout fix reads `keys`, the
/// whole word key by key, and only while its start on screen is known.
struct TypingChunk: Equatable {
    /// The keys as Latin letters.
    private(set) var keyedText = ""
    /// The keys as the field received them, jamo where the Korean input
    /// method typed them, so the backspaces can be counted.
    private(set) var typedText = ""
    /// The keys since the last whitespace key, click or app change.
    private(set) var keys: [TypedKey] = []
    /// Whether `keys` begins where the word begins on screen. Nothing that
    /// was typed before the tap looked counts as known.
    private(set) var anchored = false

    /// A word longer than this is no word; its keys are not kept.
    private static let keyLimit = 64

    init(anchored: Bool = false) {
        self.anchored = anchored
    }

    mutating func append(_ key: TypedKey) {
        keyedText = TextSnippetSupport.bufferAppending(keyedText, typed: key.keyed)
        typedText = TextSnippetSupport.bufferAppending(typedText, typed: key.typed)
        guard anchored else { return }
        if keys.count < Self.keyLimit {
            keys.append(key)
        } else {
            unanchor()
        }
    }

    mutating func removeLast() {
        if !keyedText.isEmpty { keyedText.removeLast() }
        if !typedText.isEmpty { typedText.removeLast() }
        // One backspace is one key only where nothing was composed. On an
        // empty word it removed something from before the word's start, and
        // in the Korean source it can remove a whole syllable.
        if keys.isEmpty || keys.contains(where: { $0.typed.contains(where: HangulTwoSet.isJamo) }) {
            unanchor()
        } else {
            keys.removeLast()
        }
    }

    /// The snippet strings start over; the word's start is lost until the
    /// next whitespace key, click or app change.
    mutating func forget() {
        self = TypingChunk()
    }

    /// The field no longer shows what `keys` says: the word is not judged.
    /// The snippet strings stay as they are.
    mutating func unanchor() {
        keys = []
        anchored = false
    }
}

/// A snippet expansion as plain data: the backspaces, the text they clear,
/// and what is typed afterwards.
struct SnippetInsert: Equatable {
    let deleteCount: Int
    /// The text the `deleteCount` backspaces clear.
    let typedTrigger: String
    /// The replacement with its variables still unfilled.
    let template: String
    /// The delimiter that completed the trigger, typed again after the text.
    let trailing: KeyStroke?
    let trailingText: String
    /// The swallowed key, sent on if the paste path fails.
    let failure: KeyStroke?
}

enum PlanStep: Equatable {
    case snippet(SnippetInsert)
    /// Backspaces. `completionCheck` is the text they clear, as typed, when
    /// a completion the field shows after it would eat the first one.
    case backspaces(Int, completionCheck: String?)
    /// Finished text, typed as Unicode-string events.
    case text(String)
    /// A key down and up.
    case key(KeyStroke)
    /// Nothing until ⌘ is up: ⌘Z starts an undo with ⌘ still down. Only as
    /// a plan's first step.
    case waitForCommandUp
    /// The field shows exactly this right before the caret, or the plan
    /// erases nothing and its key goes on: the keys the tap read can differ
    /// from what the field's input method made of them.
    case expect(String)
    /// After the plan's output, the input source is handed to this one
    /// through the fast switch (D14). Only as a plan's last step.
    case handOff(TypedSource)
}

/// What a typing tool wants done to the text on screen. The tap's executor
/// runs it; the tools themselves post nothing.
struct ReplacementPlan: Equatable {
    let steps: [PlanStep]
}

enum Verdict: Equatable {
    case pass
    /// A trigger completed but cannot be expanded safely.
    case passAndForget
    case claim(ReplacementPlan)
}

struct TapResponse: Equatable {
    /// The key is swallowed if the executor accepts this plan.
    var plan: ReplacementPlan?
}

/// The reducer: one key in, the chunk updated, at most one plan out.
struct TypingState {
    /// The typing tools, in the order they are asked: snippets first.
    var snippets: SnippetConsumer?
    var layoutFix: LayoutFixConsumer? {
        didSet {
            // Off now: no undo of what it did. Snippets keep their typing.
            if oldValue != nil, layoutFix == nil {
                undo = nil
                dropClaim()
            }
        }
    }
    /// Bundle identifier of the app in front, for a tool's per-app switch.
    var frontApp: String?
    private(set) var chunk = TypingChunk()
    /// The layout fix's last change while ⌘Z can take it back (5.7). Any
    /// key or click ends it.
    private(set) var undo: LayoutFixUndo?
    /// Set with a layout-fix claim and taken up when its plan ends: the
    /// change's record, or the word an undo puts back.
    private var claimedChange: LayoutFixUndo?
    private var claimedRevert: LearnedKey?

    /// An app change or a click: whatever was half-typed is no longer where
    /// the backspaces would land, and the next word starts fresh.
    mutating func reset() {
        chunk = TypingChunk(anchored: true)
        undo = nil
    }

    /// The tap stopped looking: nothing typed from here on is known.
    mutating func interrupt() {
        chunk.forget()
        undo = nil
        dropClaim()
    }

    /// The plan of the last claim will not end.
    mutating func dropClaim() {
        claimedChange = nil
        claimedRevert = nil
    }

    /// The last claim's plan ended. With output on screen a change becomes
    /// undoable and an undo is told to the layout fix's service.
    mutating func planEnded(posted: Bool, now: TimeInterval) -> [LayoutFixNotice] {
        defer { dropClaim() }
        guard posted, let layoutFix else { return [] }
        if var change = claimedChange {
            change.expires = now + layoutFix.config.rules.thresholds.undoWindowSeconds
            undo = change
        }
        return claimedRevert.map { [.reverted($0)] } ?? []
    }

    /// ⌘Z takes the last change back only while nothing happened since it
    /// (any key or click ends the record), in the same app and in time. Keys
    /// that went where the tap could not see them are the undo plan's
    /// `expect` step's to catch: the field must still show the change.
    private func takesBack(_ raw: RawKey, now: TimeInterval) -> LayoutFixUndo? {
        guard raw.kind == .keyDown, raw.origin == .physical, raw.stroke.isCommandZ, !raw.isRepeat,
              layoutFix != nil, let undo, undo.app == frontApp, now < undo.expires
        else { return nil }
        return undo
    }

    /// The input source changed or may have: the input method settles its
    /// open syllable, so a count of keys no longer says what a backspace
    /// takes, and the rest of the word arrives in another layout.
    mutating func sourceChanged() {
        // Nothing typed since a whitespace key, a click or an app change:
        // nothing is open to settle, and the next key shows its own source.
        // So the word after a hand-off is judged.
        if chunk.anchored, chunk.keys.isEmpty { return }
        chunk.unanchor()
    }

    /// `now` matters only to ⌘Z after a change.
    mutating func receive(_ raw: RawKey, secureInput: Bool, now: TimeInterval = 0) -> TapResponse {
        guard let event = TypingEvent(raw, secureInput: secureInput) else { return TapResponse() }
        if let record = secureInput ? nil : takesBack(raw, now: now) {
            // The screen ends with the delimiter again: the next word starts there.
            reset()
            claimedRevert = record.learned
            return TapResponse(plan: LayoutFixPlanner.undo(record))
        }
        undo = nil
        switch event {
        case .pointer:
            reset()
        case .reset, .chord, .caretMove:
            chunk.forget()
        case .delete:
            chunk.removeLast()
        case .deleteMore:
            // More than one character went; how many is not known.
            chunk.removeLast()
            chunk.unanchor()
        case .nonText:
            // A dead key shows a mark and types nothing yet.
            if raw.stroke.option { chunk.unanchor() }
        case .boundary:
            // The chunk a tool sees at a boundary is the finished word. One
            // tool acts on it: a snippet trigger that completed here, expanded
            // or not, keeps the layout fix away from the word (rule N11).
            var verdict = snippets?.consider(event, chunk: chunk) ?? .pass
            if verdict == .pass, let layoutFix {
                (verdict, claimedChange) = layoutFix.consider(event, chunk: chunk, earlier: .none, frontApp: frontApp)
            }
            reset()
            if case .claim(let plan) = verdict { return TapResponse(plan: plan) }
        case .text(let key):
            // For a text key it includes the key itself.
            chunk.append(key)
            switch snippets?.consider(event, chunk: chunk) ?? .pass {
            case .pass:
                break
            case .passAndForget:
                chunk.forget()
            case .claim(let plan):
                chunk.forget()
                return TapResponse(plan: plan)
            }
        }
        return TapResponse()
    }
}

// MARK: - The hold

struct PlanID: Hashable { let raw: UInt64 }

struct ClaimedPlan: Equatable {
    let id: PlanID
    let plan: ReplacementPlan
}

/// One thing the executor asks the tap to post as its own output.
enum OutputEvent: Equatable {
    /// A key down and its key up.
    case key(KeyStroke)
    case keyDown(KeyStroke)
    case keyUp(KeyStroke)
    /// Text as one Unicode-string key down and up.
    case text(String)
}

/// What the tap does with events, in order. A ticket names an event the tap
/// kept a copy of when `GateResponse.keep` said so.
enum GateCommand: Equatable {
    case output(OutputEvent)
    /// Send the kept event on as it was.
    case sendOn(Int)
    /// The kept event was replaced by output; forget it.
    case discard(Int)
}

struct GateResponse: Equatable {
    /// false: the current event is swallowed.
    var pass = true
    /// Keep a copy of the current event under this ticket. With `start` it
    /// names the plan's key, which the tap may be keeping already.
    var keep: Int?
    var commands: [GateCommand] = []
    /// A plan for the executor; the current or a kept event is its key.
    var start: ClaimedPlan?
    /// For the layout fix's service, on the main thread.
    var notices: [LayoutFixNotice] = []
}

/// Keeps what the person types in order around a replacement.
///
/// From the key that claims a plan until the plan's last output, every key
/// that arrives is held: swallowed, kept by the tap, and neither judged nor
/// shown to the field. The plan's output and the held keys then leave
/// together, output first, and each held key is judged as it leaves, as if
/// it had been typed then. So nothing typed during a replacement can land
/// before it, and no typing tool sees a key between a claim and its outcome.
///
/// The executor works on the main thread and never posts: it hands its
/// output to `submit` and wakes the tap with a kick, and the tap posts from
/// inside that callback, ahead of everything it has not seen yet.
struct TypingGate {
    private struct Hold {
        let plan: PlanID
        /// Ticket of the key that claimed the plan.
        let swallowed: Int
        let since: TimeInterval
        var begun = false
        /// Some output has left; the plan can no longer be taken back.
        var posted = false
        var held: [(ticket: Int, raw: RawKey)] = []
        var pending: (events: [OutputEvent], last: Bool, abandoned: Bool, unjudged: Bool)?
        /// The output is out and the input source is being handed over.
        var handingOff = false
    }

    private(set) var state = TypingState()
    private var hold: Hold?
    private var nextTicket = 0
    private var nextPlan: UInt64 = 0

    /// A stalled main thread must not hold typing: this long to pick a plan
    /// up, this long to finish it.
    static let pickUpLimit: TimeInterval = 1
    static let finishLimit: TimeInterval = 3
    /// More keys than this in one hold means something is wrong.
    static let heldLimit = 64
    /// F13–F20. The fast switch owns one of these keys and must never get
    /// it back from here, late or changed.
    private static let functionKeys: Set<UInt16> = [105, 107, 113, 106, 64, 79, 80, 90]

    var snippets: SnippetConsumer? {
        get { state.snippets }
        set { state.snippets = newValue }
    }

    var layoutFix: LayoutFixConsumer? {
        get { state.layoutFix }
        set { state.layoutFix = newValue }
    }

    var frontApp: String? {
        get { state.frontApp }
        set { state.frontApp = newValue }
    }

    var isHolding: Bool { hold != nil }

    func isHolding(_ id: PlanID) -> Bool { hold?.plan == id }

    /// An app change.
    mutating func reset() { state.reset() }

    // MARK: Tap thread

    mutating func receive(_ raw: RawKey, secureInput: Bool, now: TimeInterval) -> GateResponse {
        if raw.kind == .mouseDown {
            // A click moves the caret: the held keys were typed before it.
            let response = GateResponse(commands: letGo())
            // A plan that goes on after the click is not undone: the caret moved.
            state.dropClaim()
            _ = state.receive(raw, secureInput: secureInput)
            return response
        }
        switch raw.origin {
        case .output:
            return GateResponse()
        case .relay:
            // Typing the tools did not get to judge: what they had is stale.
            state.interrupt()
            return GateResponse()
        case .otherOwn:
            // The fast switch's pulse changes the layout the held keys
            // would be read in, so they go first. During a hand-off it is
            // the change they wait for. Quit protection's copy of a
            // command is not: what was typed before it still goes first.
            if hold?.handingOff == true, Self.functionKeys.contains(raw.stroke.keyCode) {
                state.sourceChanged()
                return GateResponse()
            }
            return GateResponse(commands: sourceMayChange())
        case .physical:
            break
        }
        if Self.functionKeys.contains(raw.stroke.keyCode), hold == nil {
            // It may be the key that switches the source. Judged as before
            // for snippets; the layout fix lets go of the word.
            let response = judge(raw, ticket: nil, secureInput: secureInput, now: now)
            state.sourceChanged()
            return response
        }
        guard let current = hold else { return judge(raw, ticket: nil, secureInput: secureInput, now: now) }
        if Self.functionKeys.contains(raw.stroke.keyCode) {
            // Never held, and it may be the key that switches the source.
            return GateResponse(commands: sourceMayChange())
        }
        if raw.stroke.commandOrControl {
            // A command is not typing and must not arrive late, with its
            // modifier long released. What was typed before it goes first.
            return judge(raw, ticket: nil, secureInput: secureInput, now: now, after: sourceMayChange())
        }
        guard current.held.count < Self.heldLimit else {
            var response = GateResponse(commands: release())
            let judged = judge(raw, ticket: nil, secureInput: secureInput, now: now)
            response.pass = judged.pass
            response.keep = judged.keep
            response.start = judged.start
            return response
        }
        let ticket = takeTicket()
        hold?.held.append((ticket, raw))
        return GateResponse(pass: false, keep: ticket)
    }

    /// Something is about to pass that changes how or where keys land (a
    /// click, a command, a switch of input source): the held keys were
    /// typed before it, so they are sent on ahead of it, unjudged, and a
    /// plan that has posted nothing is given up with its key sent on too.
    private mutating func letGo() -> [GateCommand] {
        guard let current = hold else { return [] }
        var commands: [GateCommand] = []
        if current.posted {
            hold?.held = []
        } else {
            commands.append(.sendOn(current.swallowed))
            hold = nil
            state.dropClaim()
        }
        return commands + current.held.map { .sendOn($0.ticket) }
    }

    /// The input source may be about to change (the fast switch's key or
    /// pulse, Caps Lock, the Globe key) or has changed (the system's
    /// notice). The word being typed is no longer judged; held keys go
    /// ahead of the change.
    mutating func sourceMayChange() -> [GateCommand] {
        state.sourceChanged()
        guard hold != nil else { return [] }
        state.interrupt()
        return letGo()
    }

    /// macOS says the input source has changed: the word being typed is no
    /// longer judged. A hold is left alone; its keys were typed before.
    mutating func sourceDidChange() {
        state.sourceChanged()
    }

    /// The executor's kick arrived: post what it submitted and, after the
    /// last output, let the held keys go.
    mutating func kick(secureInput: Bool, now: TimeInterval) -> GateResponse {
        var response = GateResponse(pass: false)
        guard var current = hold, let batch = current.pending else { return response }
        current.pending = nil
        response.commands = batch.events.map { .output($0) }
        if !batch.events.isEmpty { current.posted = true }
        guard batch.last else {
            hold = current
            return response
        }
        hold = nil
        response.notices = state.planEnded(posted: current.posted && !batch.abandoned, now: now)
        response.commands.append(batch.abandoned ? .sendOn(current.swallowed) : .discard(current.swallowed))
        if batch.unjudged {
            // A hand-off's pulse went out: their characters were read in the
            // source before it. They go on as typed and the word they start
            // is not judged.
            if !current.held.isEmpty { state.interrupt() }
            response.commands += current.held.map { .sendOn($0.ticket) }
            return response
        }
        var rest = current.held[...]
        while let next = rest.popFirst() {
            let judged = judge(next.raw, ticket: next.ticket, secureInput: secureInput, now: now)
            if let start = judged.start {
                // A held key completed another trigger: the keys behind it wait for that plan.
                hold?.held = Array(rest)
                response.keep = judged.keep
                response.start = start
                break
            }
            response.commands.append(.sendOn(next.ticket))
        }
        return response
    }

    /// Whether the main thread has let a plan sit too long.
    func expired(now: TimeInterval) -> Bool {
        guard let hold else { return false }
        return now - hold.since > (hold.begun ? Self.finishLimit : Self.pickUpLimit)
    }

    /// Ends a hold without the executor: the watchdog, a disabled tap, a
    /// stop. The keys are sent on unjudged, the plan's own key too unless
    /// its output is already out. What was half-typed is forgotten.
    mutating func release() -> [GateCommand] {
        state.interrupt()
        guard let current = hold else { return [] }
        hold = nil
        return [current.posted ? .discard(current.swallowed) : .sendOn(current.swallowed)]
            + current.held.map { .sendOn($0.ticket) }
    }

    // MARK: Main thread

    /// The executor picked the plan up. false: the hold is gone, do nothing.
    mutating func begin(_ id: PlanID) -> Bool {
        guard hold?.plan == id else { return false }
        hold?.begun = true
        return true
    }

    /// The plan's output is out and the input source is being handed over
    /// (D14): until the plan ends, the fast switch's pulse and key pass
    /// without letting the held keys go, so they land in the new source.
    /// false: the hold is gone.
    mutating func handingOff(_ id: PlanID) -> Bool {
        guard hold?.plan == id else { return false }
        hold?.handingOff = true
        return true
    }

    /// Output for the tap to post at the next kick. `last` ends the plan;
    /// `abandoned` (with no output) sends its key on instead; `unjudged`
    /// sends the held keys on without asking the tools. false: the hold is
    /// gone, post no kick.
    mutating func submit(_ id: PlanID, _ events: [OutputEvent], last: Bool, abandoned: Bool = false,
                         unjudged: Bool = false) -> Bool {
        guard hold?.plan == id else { return false }
        let earlier = hold?.pending?.events ?? []
        hold?.pending = (earlier + events, last, abandoned, unjudged)
        return true
    }

    // MARK: Private

    private mutating func takeTicket() -> Int {
        nextTicket += 1
        return nextTicket
    }

    /// One key through the typing tools. A claim starts a hold; `ticket` is
    /// the key's own when the tap already keeps it.
    private mutating func judge(_ raw: RawKey, ticket: Int?, secureInput: Bool, now: TimeInterval,
                                after commands: [GateCommand] = []) -> GateResponse {
        guard let plan = state.receive(raw, secureInput: secureInput, now: now).plan else {
            return GateResponse(commands: commands)
        }
        let swallowed = ticket ?? takeTicket()
        nextPlan += 1
        let id = PlanID(raw: nextPlan)
        hold = Hold(plan: id, swallowed: swallowed, since: now)
        return GateResponse(pass: false, keep: swallowed, commands: commands, start: ClaimedPlan(id: id, plan: plan))
    }
}
