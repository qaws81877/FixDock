// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors
// Portions adapted from gksdud, Copyright (c) 2026 CodingNoye, MIT License (full text in NOTICE).

import Darwin
import Foundation
import IOKit
import IOKit.hid
import os

/// What the input switch has done to macOS, for the service and the page.
struct InputSwitchReport: Equatable {
    enum InertReason: Equatable { case developerBuild, ownedBy(String), journalUnreadable }
    enum State: Equatable { case off, inert(InertReason), preparing, live(FunctionKey), away, restoring }

    var state: State
    var mappedKeyboards = 0
    var problem: InputSwitchProblem?
    /// Set once a restore had no record of id 60's original and wrote macOS's default (O3).
    var restoredToMacDefault = false

    static let off = InputSwitchReport(state: .off)

    /// The tap's F-key. Non-nil only while id 60 is active and keys are mapped.
    var liveKeyCode: Int64? {
        if case .live(let key) = state { return Int64(key.virtualKeyCode) }
        return nil
    }
}

enum InputSwitchExitOutcome: Equatable { case clean, leftBehind, ownedByOther(String) }

/// The only code that changes macOS for the input switch: `UserKeyMapping`
/// on keyboards, `AppleSymbolicHotKeys` id 60, and the journal that remembers
/// both (`docs/input-switch.md`). Main thread only.
///
/// Invariants:
/// 1. No system write without a `Lease`, and none before the journal holding
///    its undo is durably saved.
/// 2. No keyboard emits our F-key unless id 60 is active on it: HID is applied
///    after activation succeeds and restored before id 60 is.
/// 3. A restore writes only values still recognised as ours
///    (`HIDPlan.restore` / `HotkeyPlan.restore`).
/// 4. An unreadable or newer journal freezes the tool: zero writes.
final class InputSwitchSystem {
    static let shared = InputSwitchSystem()
    /// `log show --predicate 'category == "inputSwitch"' --info --last 10m`.
    static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "io.github.qaws81877.fixdock",
                            category: "inputSwitch")

    private(set) var report = InputSwitchReport.off
    /// Called after a change that arrived on its own (activation finished).
    var onReportChange: ((InputSwitchReport) -> Void)?
    /// True while the lease is held: something of ours may be on the system.
    var holdsSystemState: Bool { lease != nil }

    private var lease: Lease?
    private var lastWant: SystemWant = .restored
    /// Set when the person took id 60 back while live. The hotkey step is
    /// skipped while the want stays the same; any other want clears it.
    private var heldOffWant: SystemWant?
    private var activation: Activation?
    private var activationProblem: InputSwitchProblem?
    private var restoredToMacDefault = false
    /// The headless uninstall restore runs in either build.
    private var ignoresDeveloperGate = false
    /// Set by `restoreBeforeExit`; every later converge restores.
    private var exiting = false

    private init() {}

    // MARK: Public operations

    /// Brings macOS to `want`. Idempotent; cheap when nothing changed.
    @discardableResult
    func converge(to requested: SystemWant) -> InputSwitchReport {
        // Once exit restore starts, nothing may re-apply: activation finishing
        // calls back into the service, which still sees the tool enabled.
        let want = exiting ? SystemWant.restored : requested
        let developerClaim = UserDefaults.standard.bool(forKey: DefaultsKey.inputSwitchDeveloperClaim)
        guard ignoresDeveloperGate || InputSwitchPolicy.mayOwnSystemState(
            isDeveloperBuild: AppInfo.isDeveloperBuild, developerClaim: developerClaim)
        else { return publish(InputSwitchReport(state: .inert(.developerBuild))) }

        if want != heldOffWant { heldOffWant = nil }
        let wantChanged = want != lastWant
        lastWant = want

        if lease == nil {
            if want == .restored && !JournalFile.exists { return publish(.off) }
            guard let acquired = Lease.acquire() else {
                return publish(InputSwitchReport(state: .inert(.ownedBy(Lease.holderDescription()))))
            }
            lease = acquired
        }
        guard let lease else { return publish(.off) }

        var journal: InputSwitchJournal
        do { journal = try JournalFile.load() ?? InputSwitchJournal() }
        catch { return publish(InputSwitchReport(state: .inert(.journalUnreadable))) }
        journal.dropStaleKeyboards(boot: BootSession.current, present: Keyboards.kernelIDs())

        var run = Run(journal: journal, lease: lease)
        let state: InputSwitchReport.State
        switch want {
        case .applied(let config):
            state = apply(config, wantChanged: wantChanged, want: want, run: &run)
        case .away:
            restoreKeyboards(away: true, run: &run)
            state = .away
        case .restored:
            state = restoreAll(run: &run)
        }

        if run.journal.isEmpty && activation == nil {
            JournalFile.remove(lease)
            lease.release()
            self.lease = nil
            return publish(InputSwitchReport(state: want == .restored ? .off : state,
                                             mappedKeyboards: run.mapped, problem: run.problem ?? activationProblem,
                                             restoredToMacDefault: restoredToMacDefault))
        }
        if !run.saveFailed { run.save() }
        return publish(InputSwitchReport(state: state, mappedKeyboards: run.mapped,
                                         problem: run.problem ?? activationProblem,
                                         restoredToMacDefault: restoredToMacDefault))
    }

    /// Quit, SIGTERM: restore everything, wait for `activateSettings` up to
    /// `timeout`, release the lease. Never cancels a quit; a leftover stays journaled.
    func restoreBeforeExit(timeout: TimeInterval) -> InputSwitchExitOutcome {
        exiting = true
        let deadline = Date().addingTimeInterval(timeout)
        for _ in 0..<8 {
            let outcome = converge(to: .restored)
            if outcome.state == .off { return .clean }
            if case .inert(.ownedBy(let holder)) = outcome.state { return .ownedByOther(holder) }
            // Activation finishing re-runs converge itself (activationFinished).
            guard let activation, Date() < deadline else { break }
            activation.waitSync(until: deadline)
        }
        Self.log.info("exit restore left \(String(describing: self.report.state), privacy: .public)")
        return report.state == .off ? .clean : .leftBehind
    }

    /// Launch with the tool uninstalled: put back a crash's leftovers.
    /// A no-op without a journal file. Never creates the service.
    static func restoreLeftovers() {
        guard JournalFile.exists else { return }
        shared.converge(to: .restored)
    }

    /// `--restore-input-switch` (`Tools/uninstall.sh`). Waits up to 5 s for the
    /// lease, because the app being quit releases it. 0 = nothing of ours left,
    /// 1 = something left (journal kept), 2 = another live process holds the lease.
    static func runHeadlessRestore() -> Int32 {
        guard JournalFile.exists else { return 0 }
        let system = shared
        system.ignoresDeveloperGate = true
        let deadline = Date().addingTimeInterval(5)
        while system.lease == nil {
            if let acquired = Lease.acquire() { system.lease = acquired; break }
            if Date() >= deadline {
                FileHandle.standardError.write(Data("input switch: held by \(Lease.holderDescription())\n".utf8))
                return 2
            }
            usleep(100_000)
        }
        switch system.restoreBeforeExit(timeout: 8) {
        case .clean: return 0
        case .leftBehind: return 1
        case .ownedByOther: return 2
        }
    }

    // MARK: Steps

    /// One converge's working state. The journal is saved before every system
    /// write it guards; a failed save stops the run there.
    private struct Run {
        var journal: InputSwitchJournal
        let lease: Lease
        var mapped = 0
        var problem: InputSwitchProblem?
        var saveFailed = false

        mutating func save() {
            guard !saveFailed else { return }
            if !JournalFile.save(journal, lease) { saveFailed = true }
        }

        func record(_ id: UInt64) -> KeyboardUndo? { journal.keyboards?.value[String(id)] }

        mutating func setRecord(_ id: UInt64, _ undo: KeyboardUndo?) {
            var scoped = journal.keyboards ?? BootScoped(bootSession: BootSession.current ?? "unknown", value: [:])
            scoped.value[String(id)] = undo
            journal.keyboards = scoped.value.isEmpty ? nil : scoped
        }
    }

    private func apply(_ config: InputSwitchConfig, wantChanged: Bool, want: SystemWant,
                       run: inout Run) -> InputSwitchReport.State {
        let keyboards: [Keyboard]
        do { keyboards = try Keyboards.local() }
        catch {
            Keyboards.invalidate()
            run.problem = .keyboardsPending(1)
            return .preparing
        }

        if heldOffWant != nil {
            restoreKeyboards(away: false, run: &run)
            run.problem = .hotkeyChangedInSystemSettings
            return .preparing
        }

        let liveCode = run.journal.hotkey?.ownedKeyCodes.first
        var foreign = Set<UInt64>()
        for keyboard in keyboards {
            if let current = try? keyboard.read() {
                foreign.formUnion(HIDPlan.foreignTargets(current: current, undo: run.record(keyboard.registryID)))
            }
        }
        guard let key = FunctionKeyPick.choose(
            live: liveCode.flatMap(FunctionKey.init(virtualKeyCode:)),
            systemShortcuts: SymbolicHotkeys.bareFunctionKeysInUse(),
            foreignMappings: foreign, appReserved: config.appReservedKeyCodes)
        else {
            restoreKeyboards(away: false, run: &run)
            run.problem = .noFreeFunctionKey
            return .preparing
        }

        // id 60 first.
        if activation == nil {
            let current = SymbolicHotkeys.read60()
            if !wantChanged, let undo = run.journal.hotkey, undo.phase == .active,
               current?.isBareFunctionKey(in: Set(undo.ownedKeyCodes)) != true {
                // The person changed it in System Settings: their value is theirs.
                run.journal.hotkey = nil
                run.save()
                heldOffWant = want
                restoreKeyboards(away: false, run: &run)
                run.problem = .hotkeyChangedInSystemSettings
                return .preparing
            }
            switch HotkeyPlan.apply(current: current, undo: run.journal.hotkey, keyCode: key.virtualKeyCode) {
            case .unchanged:
                break
            case .activateOnly(let undo):
                run.journal.hotkey = undo
                run.save()
                if !run.saveFailed { startActivation() }
            case .write(let pending):
                run.journal.hotkey = pending
                run.save()
                guard !run.saveFailed else { return .preparing }
                // Invariant 2: no key may still emit an F-key id 60 is about to drop.
                restoreKeyboards(away: false, run: &run)
                guard (try? SymbolicHotkeys.write60(HotkeyEntry.bareFunctionKeyDictionary(key), run.lease)) != nil,
                      SymbolicHotkeys.read60()?.isBareFunctionKey(in: [key.virtualKeyCode]) == true
                else {
                    run.problem = .hotkeyWriteFailed
                    return .preparing
                }
                run.journal.hotkey = HotkeyUndo(original: pending.original, ownedKeyCodes: [key.virtualKeyCode],
                                                phase: .written)
                run.save()
                if !run.saveFailed { startActivation() }
            }
        }
        guard let hotkey = run.journal.hotkey, hotkey.phase == .active,
              hotkey.ownedKeyCodes == [key.virtualKeyCode], !run.saveFailed
        else { return .preparing }

        // Then the keyboards.
        var pending = 0
        for keyboard in keyboards {
            do {
                try applyKeyboard(keyboard, key: config.key.hidUsage, target: key.hidUsage, run: &run)
                run.mapped += 1
            } catch {
                pending += 1
            }
        }
        if pending > 0 {
            run.problem = .keyboardsPending(pending)
            return .preparing
        }
        return .live(key)
    }

    private func applyKeyboard(_ keyboard: Keyboard, key: UInt64, target: UInt64, run: inout Run) throws {
        var step = HIDPlan.apply(current: try keyboard.read(), undo: run.record(keyboard.registryID),
                                 key: key, target: target)
        if step == .restoreFirst, let undo = run.record(keyboard.registryID) {
            try restoreKeyboard(keyboard, undo: undo, away: false, run: &run)
            step = HIDPlan.apply(current: try keyboard.read(), undo: run.record(keyboard.registryID),
                                 key: key, target: target)
        }
        switch step {
        case .unchanged:
            return
        case .restoreFirst, .conflict:
            throw KeyboardWriteError.conflict
        case .write(let pending, let desired, let committed):
            run.setRecord(keyboard.registryID, pending)
            run.save()
            guard !run.saveFailed else { throw KeyboardWriteError.journal }
            try keyboard.write(desired, run.lease)
            guard try keyboard.read() == desired else { throw KeyboardWriteError.verification }
            run.setRecord(keyboard.registryID, committed)
            run.save()
        }
    }

    private func restoreKeyboard(_ keyboard: Keyboard, undo: KeyboardUndo, away: Bool, run: inout Run) throws {
        let current = try keyboard.read()
        let result = HIDPlan.restore(current: current, undo: undo, away: away)
        if let desired = result.desired {
            try keyboard.write(desired, run.lease)
            guard try keyboard.read() == desired else { throw KeyboardWriteError.verification }
        }
        run.setRecord(keyboard.registryID, result.after)
        run.save()
    }

    /// Every recorded keyboard gets its key back. With `away` the records stay.
    /// A record whose keyboard is not listed (gone, or another Mac's) is dropped
    /// on a full restore: its mapping is not ours to reach.
    private func restoreKeyboards(away: Bool, run: inout Run) {
        guard let records = run.journal.keyboards?.value, !records.isEmpty else { return }
        guard let keyboards = try? Keyboards.local() else {
            Keyboards.invalidate()
            run.problem = .keyboardsPending(records.count)
            return
        }
        let listed = Dictionary(keyboards.map { (String($0.registryID), $0) }, uniquingKeysWith: { first, _ in first })
        var failed = 0
        for (id, undo) in records {
            guard let keyboard = listed[id] else {
                if !away, let registryID = UInt64(id) { run.setRecord(registryID, nil) }
                continue
            }
            do { try restoreKeyboard(keyboard, undo: undo, away: away, run: &run) }
            catch { failed += 1 }
        }
        if failed > 0 { run.problem = .keyboardsPending(failed) }
    }

    private func restoreAll(run: inout Run) -> InputSwitchReport.State {
        restoreKeyboards(away: false, run: &run)
        guard run.journal.keyboards == nil, !run.saveFailed else { return .restoring }
        guard activation == nil, let undo = run.journal.hotkey else { return run.journal.isEmpty ? .off : .restoring }
        let current = SymbolicHotkeys.read60()
        switch HotkeyPlan.restore(current: current, undo: undo) {
        case .dropRecord:
            run.journal.hotkey = nil
        case .activateThenDrop:
            startActivation()
        case .write(let original):
            var restoring = undo
            restoring.phase = .restoring
            run.journal.hotkey = restoring
            run.save()
            guard !run.saveFailed else { return .restoring }
            guard (try? SymbolicHotkeys.write60(original.restoreDictionary, run.lease)) != nil,
                  original.matches(SymbolicHotkeys.read60())
            else {
                run.problem = .hotkeyWriteFailed
                return .restoring
            }
            if original == .unknownLeftover { restoredToMacDefault = true }
            startActivation()
        }
        return run.journal.isEmpty ? .off : .restoring
    }

    // MARK: Activation

    private func startActivation() {
        guard activation == nil else { return }
        activation = Activation { [weak self] success in self?.activationFinished(success) }
        if activation?.started == false {
            activation = nil
            activationProblem = .activationFailed
        }
    }

    private func activationFinished(_ success: Bool) {
        Self.log.info("activation finished, success \(success, privacy: .public)")
        activation = nil
        activationProblem = success ? nil : .activationFailed
        guard success, let lease, var journal = try? JournalFile.load(), var hotkey = journal.hotkey else {
            converge(to: lastWant)
            onReportChange?(report)
            return
        }
        switch hotkey.phase {
        case .written:
            hotkey.phase = .active
            journal.hotkey = hotkey
        case .restoring:
            journal.hotkey = nil
        case .writing, .active:
            break
        }
        _ = JournalFile.save(journal, lease)
        converge(to: lastWant)
        onReportChange?(report)
    }

    @discardableResult
    private func publish(_ next: InputSwitchReport) -> InputSwitchReport {
        if next.state != report.state || next.problem != report.problem {
            Self.log.info("state \(String(describing: next.state), privacy: .public), problem \(String(describing: next.problem), privacy: .public)")
        }
        report = next
        return next
    }
}

private enum KeyboardWriteError: Error { case conflict, journal, verification, read, write }

// MARK: Adapters (fileprivate: unreachable from other files)

/// `~/Library/Application Support/io.github.qaws81877.fixdock/InputSwitch/`,
/// built from the normal bundle id constant so both builds share it. Never
/// `PrivateFileStore.containerURL`, which reads `Bundle.main` and differs per build.
private enum InputSwitchFolder {
    static var container: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent(AppInfo.bundleID, isDirectory: true)
    }
    static var url: URL? { container?.appendingPathComponent("InputSwitch", isDirectory: true) }
    static func file(_ name: String) -> URL? { url?.appendingPathComponent(name) }
    static func create() -> Bool {
        guard let url, let container else { return false }
        return PrivateFileStore.createDirectory(at: url, container: container)
    }
}

/// `flock(LOCK_EX|LOCK_NB)` on `InputSwitch/lease`, held for as long as
/// anything of ours may be on the system. The kernel drops it when the process
/// dies, so a crash never leaves a stale claim.
private final class Lease {
    private var fd: Int32

    private init(fd: Int32) { self.fd = fd }

    static func acquire() -> Lease? {
        guard InputSwitchFolder.create(), let path = InputSwitchFolder.file("lease")?.path else { return nil }
        let fd = open(path, O_RDWR | O_CREAT, 0o600)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); return nil }
        let owner = "\(Bundle.main.bundleIdentifier ?? "FixDock") \(getpid())\n"
        ftruncate(fd, 0)
        _ = owner.withCString { pwrite(fd, $0, strlen($0), 0) }
        return Lease(fd: fd)
    }

    static func holderDescription() -> String {
        guard let path = InputSwitchFolder.file("lease")?.path,
              let text = try? String(contentsOfFile: path, encoding: .utf8),
              let bundle = text.split(separator: " ").first
        else { return AppInfo.name }
        return bundle == AppInfo.developerBundleID ? "\(AppInfo.name) (Developer)" : AppInfo.name
    }

    func release() {
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN)
        close(fd)
        fd = -1
    }

    deinit { release() }
}

/// `InputSwitch/journal.plist`, binary, 0600, written durably.
private enum JournalFile {
    static var exists: Bool {
        InputSwitchFolder.file("journal.plist").map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }

    static func load() throws -> InputSwitchJournal? {
        guard let url = InputSwitchFolder.file("journal.plist"),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try InputSwitchJournal.decode(try Data(contentsOf: url))
    }

    static func save(_ journal: InputSwitchJournal, _ lease: Lease) -> Bool {
        guard InputSwitchFolder.create(), let url = InputSwitchFolder.file("journal.plist"),
              let data = try? journal.encoded() else { return false }
        return PrivateFileStore.writeDurably(data, to: url)
    }

    static func remove(_ lease: Lease) {
        guard let url = InputSwitchFolder.file("journal.plist") else { return }
        unlink(url.path)
    }
}

/// One keyboard service and the client that created it.
private struct Keyboard {
    static let sourceKey = "HIDKeyboardModifierMappingSrc"
    static let destinationKey = "HIDKeyboardModifierMappingDst"

    let client: IOHIDEventSystemClient
    let service: IOHIDServiceClient
    let registryID: UInt64

    func read() throws -> Set<KeyMapping> {
        guard let value = IOHIDServiceClientCopyProperty(service, "UserKeyMapping" as CFString) else { return [] }
        guard let rows = value as? [[String: NSNumber]] else { throw KeyboardWriteError.read }
        return Set(rows.compactMap { row in
            guard let source = row[Self.sourceKey]?.uint64Value,
                  let destination = row[Self.destinationKey]?.uint64Value else { return nil }
            return KeyMapping(source: source, destination: destination)
        })
    }

    func write(_ mappings: Set<KeyMapping>, _ lease: Lease) throws {
        let rows: [[String: NSNumber]] = mappings.sorted { $0.source < $1.source }.map {
            [Self.sourceKey: NSNumber(value: $0.source), Self.destinationKey: NSNumber(value: $0.destination)]
        }
        guard IOHIDServiceClientSetProperty(service, "UserKeyMapping" as CFString, rows as CFArray)
        else { throw KeyboardWriteError.write }
    }
}

private enum Keyboards {
    /// A client lists its services only when created, so it is kept while the
    /// kernel's keyboard set is unchanged (gksdud).
    private static var cache: (kernel: Set<UInt64>, client: IOHIDEventSystemClient, services: [(IOHIDServiceClient, UInt64)])?

    static func invalidate() { cache = nil }

    /// Local keyboards only: Universal Control's remote keyboards are services
    /// outside the kernel set; their keys are that Mac's to map.
    static func local() throws -> [Keyboard] {
        let kernel = kernelIDs()
        if cache == nil || cache?.kernel != kernel {
            let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
            guard let services = IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient] else {
                cache = nil
                throw KeyboardWriteError.read
            }
            let keyboards: [(IOHIDServiceClient, UInt64)] = services.compactMap { service in
                guard IOHIDServiceClientConformsTo(service, 1, 6) != 0,
                      let id = (IOHIDServiceClientGetRegistryID(service) as? NSNumber)?.uint64Value,
                      kernel?.contains(id) ?? true
                else { return nil }
                return (service, id)
            }
            cache = (kernel ?? [], client, keyboards)
        }
        guard let current = cache else { return [] }
        return current.services.map { Keyboard(client: current.client, service: $0.0, registryID: $0.1) }
    }

    static func kernelIDs() -> Set<UInt64>? {
        let matching = IOServiceMatching("IOHIDEventService") as NSMutableDictionary
        matching["DeviceUsagePairs"] = [["DeviceUsagePage": 1, "DeviceUsage": 6]]
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching as CFDictionary, &iterator) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iterator) }
        var ids = Set<UInt64>()
        while case let service = IOIteratorNext(iterator), service != 0 {
            var id: UInt64 = 0
            if IORegistryEntryGetRegistryEntryID(service, &id) == KERN_SUCCESS { ids.insert(id) }
            IOObjectRelease(service)
        }
        return ids
    }
}

/// `com.apple.symbolichotkeys` through CFPreferences, read-modify-write of the whole dictionary.
private enum SymbolicHotkeys {
    static let domain = "com.apple.symbolichotkeys" as CFString
    static let key = "AppleSymbolicHotKeys" as CFString

    static func all() -> [String: Any] {
        CFPreferencesAppSynchronize(domain)
        return CFPreferencesCopyAppValue(key, domain) as? [String: Any] ?? [:]
    }

    static func read60() -> HotkeyEntry? {
        (all()[HotkeyEntry.previousSourceID] as? [String: Any]).flatMap(HotkeyEntry.init(dictionary:))
    }

    /// F-key codes enabled system shortcuts (other than 60) use with no modifier.
    static func bareFunctionKeysInUse() -> Set<Int> {
        Set(all().compactMap { id, raw -> Int? in
            guard id != HotkeyEntry.previousSourceID, let dictionary = raw as? [String: Any],
                  let entry = HotkeyEntry(dictionary: dictionary), entry.enabled, entry.isStandard,
                  let p = entry.parameters, p.count == 3, [0, HotkeyEntry.functionFlag].contains(p[2])
            else { return nil }
            return p[1]
        })
    }

    /// nil removes the entry.
    static func write60(_ value: [String: Any]?, _ lease: Lease) throws {
        var keys = all()
        keys[HotkeyEntry.previousSourceID] = value
        CFPreferencesSetAppValue(key, keys as CFDictionary, domain)
        guard CFPreferencesAppSynchronize(domain) else { throw KeyboardWriteError.write }
    }
}

/// `activateSettings -u -virtualSession`: applies session shortcuts without
/// re-applying physical-device preferences. Asynchronous; `waitSync` is for exit paths.
private final class Activation {
    private let process = Process()
    private var completion: ((Bool) -> Void)?
    private(set) var started = false

    init(completion: @escaping (Bool) -> Void) {
        self.completion = completion
        process.executableURL = URL(fileURLWithPath:
            "/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings")
        process.arguments = ["-u", "-virtualSession"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] finished in
            let success = finished.terminationStatus == 0
            DispatchQueue.main.async { self?.finish(success) }
        }
        do { try process.run(); started = true } catch { self.completion = nil }
        if started {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self, self.process.isRunning else { return }
                self.process.terminate()
                self.finish(false)
            }
        }
    }

    func waitSync(until deadline: Date) {
        while process.isRunning && Date() < deadline { usleep(20_000) }
        finish(!process.isRunning && process.terminationStatus == 0)
    }

    private func finish(_ success: Bool) {
        guard let completion else { return }
        self.completion = nil
        completion(success)
    }
}

/// `kern.bootsessionuuid`: HID mappings and registry ids do not survive it.
private enum BootSession {
    static var current: String? {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var value = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &value, &size, nil, 0) == 0 else { return nil }
        return String(cString: value)
    }
}
