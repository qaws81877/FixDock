// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors
// Portions adapted from gksdud, Copyright (c) 2026 CodingNoye, MIT License (full text in NOTICE).

import Foundation

// Pure decisions for the fast Korean/English switch (`docs/input-switch.md`).
// Every rule that decides "is this system value ours" lives here and nowhere
// else. `Services/InputSwitchSystem.swift` performs what these plans say.

/// The key the person presses. HID page-7 usages.
enum SwitchKey: String, CaseIterable, Identifiable, Codable {
    case capsLock, rightCommand, rightOption, rightControl

    static let `default` = SwitchKey.capsLock

    var id: String { rawValue }

    var hidUsage: UInt64 {
        switch self {
        case .capsLock: return 0x7_0000_0039
        case .rightCommand: return 0x7_0000_00e7
        case .rightOption: return 0x7_0000_00e6
        case .rightControl: return 0x7_0000_00e4
        }
    }
}

/// F13–F19. F20 is never used: input-source shortcuts do not fire on it (gksdud).
enum FunctionKey: Int, CaseIterable, Codable {
    case f13 = 13, f14, f15, f16, f17, f18, f19

    var hidUsage: UInt64 { 0x7_0000_0068 + UInt64(rawValue - 13) }

    var virtualKeyCode: Int {
        switch self {
        case .f13: return 105
        case .f14: return 107
        case .f15: return 113
        case .f16: return 106
        case .f17: return 64
        case .f18: return 79
        case .f19: return 80
        }
    }

    /// F19 first (gksdud's default). A live key is kept while it stays free.
    static let automaticOrder: [FunctionKey] = [.f19, .f18, .f17, .f16, .f15, .f14, .f13]

    static var allVirtualKeyCodes: Set<Int> { Set(allCases.map(\.virtualKeyCode)) }

    init?(virtualKeyCode: Int) {
        guard let key = Self.allCases.first(where: { $0.virtualKeyCode == virtualKeyCode }) else { return nil }
        self = key
    }
}

struct InputSwitchConfig: Equatable {
    var key: SwitchKey
    /// Bare F13–F19 FixDock shortcuts, stepped around by the automatic pick.
    var appReservedKeyCodes: Set<Int>
}

/// What macOS should look like. Derived on every sync, never stored.
enum SystemWant: Equatable {
    /// Nothing of ours anywhere.
    case restored
    /// Lock screen or another user on console: keyboards get their keys back, id 60 stays.
    case away(InputSwitchConfig)
    case applied(InputSwitchConfig)
}

enum InputSwitchPolicy {
    /// Without the tap, id 60 would switch on release and a mapped Caps Lock
    /// would be dead, so anything short of a working tap restores everything.
    static func want(installed: Bool, enabled: Bool, accessibility: Bool, onConsole: Bool,
                     screenLocked: Bool, otherSwitcherRunning: Bool,
                     config: InputSwitchConfig) -> SystemWant {
        guard installed, enabled, accessibility, !otherSwitcherRunning else { return .restored }
        return onConsole && !screenLocked ? .applied(config) : .away(config)
    }

    /// The normal build always may. The developer build only when launched
    /// with `-inputSwitchDeveloperClaim YES`, so two builds never fight.
    static func mayOwnSystemState(isDeveloperBuild: Bool, developerClaim: Bool) -> Bool {
        !isDeveloperBuild || developerClaim
    }

    static let otherSwitcherBundleIDs: Set<String> = ["io.gksdud.inputswitch"]
}

enum InputSwitchProblem: Error, Equatable {
    case noFreeFunctionKey
    case hotkeyWriteFailed
    case activationFailed
    /// The person took id 60 back while live: stop, never fight.
    case hotkeyChangedInSystemSettings
    case keyboardsPending(Int)
    case otherSwitcherRunning(String)
}

// MARK: HID mappings

/// One `UserKeyMapping` row, parsed at the IOKit boundary.
struct KeyMapping: Hashable, Codable {
    let source: UInt64
    let destination: UInt64
}

/// The per-keyboard undo. `ownedTargets` holds the target and, during a
/// change, the pending one, so a crash between write and readback still
/// recognises either as ours.
struct KeyboardUndo: Codable, Equatable {
    var source: UInt64
    /// Destination before our first write; nil means the key had no mapping.
    var original: UInt64?
    var ownedTargets: [UInt64]
    /// Given back for the lock screen or another session. While away the
    /// keys are not ours to touch: another session may map them.
    var away: Bool
}

enum HIDPlan {
    enum Step: Equatable {
        case unchanged(KeyboardUndo)
        /// The record names another key: restore it first, then apply again.
        case restoreFirst
        /// Save `pending`, write `desired`, read back, then save `committed`.
        case write(pending: KeyboardUndo, desired: Set<KeyMapping>, committed: KeyboardUndo)
        /// Another key already emits the target and is not ours. Nothing is written.
        case conflict
    }

    /// Ours iff the source is the record's and the destination one of its targets.
    static func owns(_ undo: KeyboardUndo?, _ mapping: KeyMapping) -> Bool {
        guard let undo else { return false }
        return mapping.source == undo.source && undo.ownedTargets.contains(mapping.destination)
    }

    static func apply(current: Set<KeyMapping>, undo: KeyboardUndo?, key: UInt64, target: UInt64) -> Step {
        if let undo, undo.source != key { return .restoreFirst }
        if current.contains(where: { $0.destination == target && $0.source != key }) { return .conflict }

        let existing = current.first { $0.source == key }
        let original: UInt64?
        if let undo {
            // The record's original survives, also when coming back from away
            // (the row may now be another session's).
            original = undo.original
        } else if let existing, existing.destination != target {
            original = existing.destination
        } else {
            // No mapping, or a leftover of ours with no record: that has no original.
            original = nil
        }

        var desired = current.filter { $0.source != key }
        desired.insert(KeyMapping(source: key, destination: target))
        let committed = KeyboardUndo(source: key, original: original, ownedTargets: [target], away: false)
        if desired == current, undo == committed { return .unchanged(committed) }

        var owned = undo?.ownedTargets ?? []
        if !owned.contains(target) { owned.append(target) }
        let pending = KeyboardUndo(source: key, original: original, ownedTargets: owned, away: false)
        return .write(pending: pending, desired: desired, committed: committed)
    }

    /// THE GUARD for every HID restore: writes only when the key still emits
    /// one of our targets. Anything else was changed by someone else, so the
    /// record is dropped and nothing is written. `away` keeps the record.
    static func restore(current: Set<KeyMapping>, undo: KeyboardUndo, away: Bool)
        -> (desired: Set<KeyMapping>?, after: KeyboardUndo?) {
        if undo.away { return (nil, away ? undo : nil) }
        guard let row = current.first(where: { $0.source == undo.source }), owns(undo, row) else {
            return (nil, nil)
        }
        var desired = current
        desired.remove(row)
        if let original = undo.original {
            desired.insert(KeyMapping(source: undo.source, destination: original))
        }
        var kept = undo
        kept.away = true
        return (desired, away ? kept : nil)
    }

    /// F-keys other mappings emit, which the automatic pick avoids.
    static func foreignTargets(current: Set<KeyMapping>, undo: KeyboardUndo?) -> Set<UInt64> {
        let fKeys = Set(FunctionKey.allCases.map(\.hidUsage))
        return Set(current.filter { fKeys.contains($0.destination) && !owns(undo, $0) }.map(\.destination))
    }
}

// MARK: Symbolic hotkey 60 ("Select the previous input source")

/// An `AppleSymbolicHotKeys` entry as read. `raw` is the dictionary as a
/// binary plist, written back unchanged; comparisons use the parsed fields.
struct HotkeyEntry: Equatable {
    static let functionFlag = 0x80_0000   // SecondaryFn; macOS may add it to a bare F-key
    static let previousSourceID = "60"

    let raw: Data
    let enabled: Bool
    let isStandard: Bool
    let parameters: [Int]?

    init?(dictionary: [String: Any]) {
        guard let data = try? PropertyListSerialization.data(fromPropertyList: dictionary, format: .binary, options: 0)
        else { return nil }
        raw = data
        enabled = (dictionary["enabled"] as? NSNumber)?.boolValue ?? false
        let value = dictionary["value"] as? [String: Any]
        isStandard = value?["type"] as? String == "standard"
        parameters = (value?["parameters"] as? [NSNumber])?.map(\.intValue)
    }

    init?(raw: Data) {
        guard let dictionary = try? PropertyListSerialization.propertyList(from: raw, options: [], format: nil)
            as? [String: Any] else { return nil }
        self.init(dictionary: dictionary)
    }

    /// The value FixDock writes while live.
    static func bareFunctionKeyDictionary(_ key: FunctionKey) -> [String: Any] {
        ["enabled": true,
         "value": ["type": "standard", "parameters": [65535, key.virtualKeyCode, 0]] as [String: Any]]
    }

    /// macOS's factory value for id 60, Control-Space. Restore writes it when
    /// the original is unknown (owner decision O3, 2026-11-01).
    static let macDefaultDictionary: [String: Any] =
        ["enabled": true,
         "value": ["type": "standard", "parameters": [32, 49, 262_144]] as [String: Any]]

    /// The F-key code when this is an enabled, unmodified F13–F19.
    var bareFunctionKeyCode: Int? {
        guard enabled, isStandard, let p = parameters, p.count == 3, p[0] == 65535,
              FunctionKey.allVirtualKeyCodes.contains(p[1]), [0, Self.functionFlag].contains(p[2])
        else { return nil }
        return p[1]
    }

    func isBareFunctionKey(in codes: Set<Int>) -> Bool {
        bareFunctionKeyCode.map(codes.contains) ?? false
    }

    /// Same shortcut, ignoring the Fn flag macOS adds to a bare F-key and
    /// any byte-level difference from re-encoding.
    func sameShortcut(as other: HotkeyEntry) -> Bool {
        if let mine = bareFunctionKeyCode, let theirs = other.bareFunctionKeyCode { return mine == theirs }
        return enabled == other.enabled && isStandard == other.isStandard && parameters == other.parameters
    }
}

enum HotkeyOriginal: Codable, Equatable {
    /// No "60" key: restore removes it.
    case absent
    case entry(Data)
    /// Already a bare F-key with no record (lost journal, gksdud leftover):
    /// restore writes macOS's default, Control-Space (O3).
    case unknownLeftover

    static func from(_ current: HotkeyEntry?) -> HotkeyOriginal {
        guard let current else { return .absent }
        return current.bareFunctionKeyCode == nil ? .entry(current.raw) : .unknownLeftover
    }

    /// What a restore writes; nil removes the key.
    var restoreDictionary: [String: Any]? {
        switch self {
        case .absent: return nil
        case .entry(let data):
            return (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any]
        case .unknownLeftover: return HotkeyEntry.macDefaultDictionary
        }
    }

    func matches(_ current: HotkeyEntry?) -> Bool {
        guard let wanted = restoreDictionary.flatMap(HotkeyEntry.init(dictionary:)) else { return current == nil }
        return current.map(wanted.sameShortcut(as:)) ?? false
    }
}

/// Ordered: writing -> written -> active -> restoring -> (record removed).
/// `written`: plist verified, `activateSettings` not yet confirmed.
enum HotkeyPhase: String, Codable {
    case writing, written, active, restoring
}

struct HotkeyUndo: Codable, Equatable {
    var original: HotkeyOriginal
    /// The live code, plus the next one during a change.
    var ownedKeyCodes: [Int]
    var phase: HotkeyPhase
}

enum HotkeyPlan {
    enum ApplyStep: Equatable {
        case unchanged
        /// The value is ours already; only (re)run activation, then mark active.
        case activateOnly(HotkeyUndo)
        /// Save `pending`, write the bare F-key, verify, then activate.
        case write(pending: HotkeyUndo)
    }

    static func apply(current: HotkeyEntry?, undo: HotkeyUndo?, keyCode: Int) -> ApplyStep {
        guard let undo else {
            let original = HotkeyOriginal.from(current)
            if current?.isBareFunctionKey(in: [keyCode]) == true {
                return .activateOnly(HotkeyUndo(original: original, ownedKeyCodes: [keyCode], phase: .written))
            }
            return .write(pending: HotkeyUndo(original: original, ownedKeyCodes: [keyCode], phase: .writing))
        }
        let ours = Set(undo.ownedKeyCodes)
        if current?.isBareFunctionKey(in: [keyCode]) == true, ours.contains(keyCode) || undo.phase == .writing {
            if undo.phase == .active, undo.ownedKeyCodes == [keyCode] { return .unchanged }
            return .activateOnly(HotkeyUndo(original: undo.original, ownedKeyCodes: [keyCode], phase: .written))
        }
        if current?.isBareFunctionKey(in: ours) == true || undo.phase == .writing {
            // Ours with another F-key, or a write that may not have landed: keep the original.
            var codes = undo.ownedKeyCodes
            if !codes.contains(keyCode) { codes.append(keyCode) }
            return .write(pending: HotkeyUndo(original: undo.original, ownedKeyCodes: codes, phase: .writing))
        }
        // The person changed it (or a restore landed): their value is the new baseline.
        return .write(pending: HotkeyUndo(original: .from(current), ownedKeyCodes: [keyCode], phase: .writing))
    }

    enum RestoreStep: Equatable {
        case dropRecord
        /// The original is back; activation may still be pending.
        case activateThenDrop
        case write(HotkeyOriginal)
    }

    /// THE GUARD for every id-60 restore: write only while the value is a bare
    /// F-key we own. Anything else is the person's, so nothing is written.
    static func restore(current: HotkeyEntry?, undo: HotkeyUndo) -> RestoreStep {
        if current?.isBareFunctionKey(in: Set(undo.ownedKeyCodes)) == true { return .write(undo.original) }
        if undo.phase == .restoring, undo.original.matches(current) { return .activateThenDrop }
        return .dropRecord
    }
}

enum FunctionKeyPick {
    /// The live key while it stays free, else the first free key in
    /// `automaticOrder`. Taken: a bare-F-key system shortcut (any enabled id
    /// but 60), the destination of a foreign mapping, or a FixDock shortcut.
    static func choose(live: FunctionKey?, systemShortcuts: Set<Int>, foreignMappings: Set<UInt64>,
                       appReserved: Set<Int>) -> FunctionKey? {
        func free(_ key: FunctionKey) -> Bool {
            !systemShortcuts.contains(key.virtualKeyCode) && !appReserved.contains(key.virtualKeyCode)
                && !foreignMappings.contains(key.hidUsage)
        }
        if let live, free(live) { return live }
        return FunctionKey.automaticOrder.first(where: free)
    }
}

// MARK: Journal (one file for both builds, read and written only under the lease)

struct BootScoped<Value: Codable & Equatable>: Codable, Equatable {
    var bootSession: String
    var value: Value
}

struct InputSwitchJournal: Codable, Equatable {
    static let currentVersion = 1

    /// A newer version is unreadable: touch nothing.
    var version = Self.currentVersion
    /// Registry id -> undo. Dies with the boot, as HID mappings do.
    var keyboards: BootScoped<[String: KeyboardUndo]>?
    /// Survives reboot, as the plist write does.
    var hotkey: HotkeyUndo?

    var isEmpty: Bool { (keyboards?.value.isEmpty ?? true) && hotkey == nil }

    enum DecodeError: Error, Equatable { case newerVersion(Int) }

    static func decode(_ data: Data) throws -> InputSwitchJournal {
        struct Header: Decodable { let version: Int }
        let header = try PropertyListDecoder().decode(Header.self, from: data)
        guard header.version <= currentVersion else { throw DecodeError.newerVersion(header.version) }
        return try PropertyListDecoder().decode(InputSwitchJournal.self, from: data)
    }

    func encoded() throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(self)
    }

    /// Drops keyboard records from another boot (mappings are gone, registry
    /// ids get reused) and of keyboards the kernel no longer lists (their
    /// mapping died with the service). A nil boot or kernel list keeps them;
    /// the value guard in `HIDPlan.restore` still protects them.
    mutating func dropStaleKeyboards(boot: String?, present: Set<UInt64>?) {
        guard var scoped = keyboards else { return }
        if let boot, scoped.bootSession != boot {
            keyboards = nil
            return
        }
        if let present {
            scoped.value = scoped.value.filter { UInt64($0.key).map(present.contains) ?? false }
        }
        keyboards = scoped.value.isEmpty ? nil : scoped
    }
}

// MARK: Tap decisions

/// gksdud's PressGate. Tracks only the reserved F-key; never reads typed text.
struct InputSwitchKeyRouter {
    enum Decision: Equatable { case pass, consume, consumeAndSwitch }

    private(set) var held: Set<Int64> = []

    /// A non-repeat down of a held key is a fresh press whose release was
    /// missed (tap disabled, cleaning mode ate the up), so it switches.
    /// Repeats of the live key and its real key-up are consumed.
    mutating func decide(down: Bool, keyCode: Int64, isRepeat: Bool, liveKeyCode: Int64?) -> Decision {
        guard down else { return held.remove(keyCode) != nil ? .consume : .pass }
        guard let liveKeyCode, keyCode == liveKeyCode else {
            return held.contains(keyCode) ? .consume : .pass
        }
        if isRepeat { return .consume }
        held.insert(keyCode)
        return .consumeAndSwitch
    }

    mutating func reset() { held.removeAll() }
}

// MARK: Long press (phase 5)

/// A held switch key (gksdud `LongPressState`). The press still switches at
/// once; held past `delay`, it also ends in English with Caps Lock flipped.
/// 0.5 s is a chosen threshold, not a macOS default.
struct InputSwitchLongPress {
    static let delay: TimeInterval = 0.5

    private(set) var key: Int64?
    private var started: TimeInterval = 0
    private var fired = false
    private var cancelled = false

    mutating func begin(key: Int64, now: TimeInterval) {
        self.key = key
        started = now
        fired = false
        cancelled = false
    }

    /// True once per press, when it has been held long enough.
    mutating func claimLong(now: TimeInterval) -> Bool {
        guard key != nil, !cancelled, !fired, now - started >= Self.delay else { return false }
        fired = true
        return true
    }

    /// The key's release. `long` is a long press the timer had not claimed yet.
    mutating func release(key: Int64, now: TimeInterval) -> (owned: Bool, long: Bool) {
        guard self.key == key else { return (false, false) }
        let long = claimLong(now: now)
        self.key = nil
        return (true, long)
    }

    mutating func cancel() {
        cancelled = true
        key = nil
    }
}

/// The last pulse until macOS acts on it: a second one meanwhile would
/// switch back (gksdud `SentSwitch`).
struct InputSwitchSentPulse: Equatable {
    static let window: TimeInterval = 0.5
    let fromLanguage: String
    let at: TimeInterval

    func inFlight(now: TimeInterval, language: String) -> Bool {
        now - at < Self.window && language == fromLanguage
    }
}

/// How a long press reaches English. A switch still on its way
/// lands on the other source: from Korean it reaches English by itself,
/// from English another pulse has to bring it back.
enum InputSwitchEnglishRoute: Equatable {
    case now, awaitSwitch, sendSwitch

    static func from(language: String, inFlight: Bool) -> InputSwitchEnglishRoute {
        if InputSwitchLanguage.isEnglish(language) { return inFlight ? .sendSwitch : .now }
        return inFlight ? .awaitSwitch : .sendSwitch
    }
}

enum InputSwitchLanguage {
    static func isEnglish(_ language: String) -> Bool { language.hasPrefix("en") }
}
