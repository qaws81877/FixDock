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
    private static let commandFlag: UInt64 = 1 << 20
    private static let deleteKey: UInt16 = 0x33
    /// Left, Right, Down, Up, Escape, Home, End, Page Up, Page Down, forward delete.
    private static let caretKeys: Set<UInt16> = [0x7B, 0x7C, 0x7D, 0x7E, 0x35, 0x73, 0x77, 0x74, 0x79, 0x75]

    var shift: Bool { rawFlags & Self.shiftFlag != 0 }
    var commandOrControl: Bool { rawFlags & (Self.commandFlag | Self.controlFlag) != 0 }
    var isDelete: Bool { keyCode == Self.deleteKey }
    var movesCaret: Bool { Self.caretKeys.contains(keyCode) }
}

/// `.output` is what the typing tap posted itself and is never judged.
enum KeyOrigin: Equatable { case physical, output }

/// One event as the tap saw it, already free of CGEvent.
struct RawKey: Equatable {
    enum Kind: Equatable { case keyDown, mouseDown }
    let kind: Kind
    let origin: KeyOrigin
    let stroke: KeyStroke
    /// The characters the key event carries, at most four UTF-16 units.
    let characters: String
}

struct TypedKey: Equatable {
    let stroke: KeyStroke
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
    case caretMove             // arrows, Home, End, Page keys, Escape, forward delete
    case chord                 // ⌘ or ⌃ held: a command, not text
    case nonText               // a key that carries no character
    case pointer               // mouse down
    case reset                 // secure input

    /// nil for the tap's own output. The order of the checks is the order
    /// the snippet tap has always made them in.
    init?(_ raw: RawKey, secureInput: Bool) {
        // Clicks move the caret somewhere unknown.
        if raw.kind == .mouseDown {
            self = .pointer
            return
        }
        guard raw.origin != .output else { return nil }
        // Password fields: typing there must stay exactly as typed, and
        // nothing may remember any of it.
        if secureInput {
            self = .reset
        } else if raw.stroke.commandOrControl {
            self = .chord
        } else if raw.stroke.isDelete {
            self = .delete
        } else if raw.stroke.movesCaret {
            self = .caretMove
        } else if let first = raw.characters.first {
            let key = TypedKey(stroke: raw.stroke, typed: raw.characters)
            self = TextSnippetSupport.delimiters.contains(first) ? .boundary(key) : .text(key)
        } else {
            self = .nonText
        }
    }
}

/// The one buffer: what was typed since the last break, twice over. The two
/// strings run character for character.
struct TypingChunk: Equatable {
    /// The keys as Latin letters.
    private(set) var keyedText = ""
    /// The keys as the field received them, jamo where the Korean input
    /// method typed them, so the backspaces can be counted.
    private(set) var typedText = ""

    mutating func append(_ key: TypedKey) {
        keyedText = TextSnippetSupport.bufferAppending(keyedText, typed: key.keyed)
        typedText = TextSnippetSupport.bufferAppending(typedText, typed: key.typed)
    }

    mutating func removeLast() {
        if !keyedText.isEmpty { keyedText.removeLast() }
        if !typedText.isEmpty { typedText.removeLast() }
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
    var snippets: SnippetConsumer?
    private(set) var chunk = TypingChunk()

    /// Whatever was half-typed is no longer where the backspaces would land.
    mutating func reset() {
        chunk = TypingChunk()
    }

    mutating func receive(_ raw: RawKey, secureInput: Bool) -> TapResponse {
        guard let event = TypingEvent(raw, secureInput: secureInput) else { return TapResponse() }
        switch event {
        case .pointer, .reset, .chord, .caretMove:
            reset()
        case .delete:
            chunk.removeLast()
        case .nonText:
            break
        case .boundary:
            // The chunk a tool sees at a boundary is the finished word.
            let verdict = snippets?.consider(event, chunk: chunk) ?? .pass
            reset()
            if case .claim(let plan) = verdict { return TapResponse(plan: plan) }
        case .text(let key):
            // For a text key it includes the key itself.
            chunk.append(key)
            switch snippets?.consider(event, chunk: chunk) ?? .pass {
            case .pass:
                break
            case .passAndForget:
                reset()
            case .claim(let plan):
                reset()
                return TapResponse(plan: plan)
            }
        }
        return TapResponse()
    }
}
