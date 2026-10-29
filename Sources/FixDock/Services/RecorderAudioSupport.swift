// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import Accelerate
import AppKit
import CoreAudio
import CoreMedia
import Darwin
import os

// The parts of upstream's volume mixer that the recorder's system audio tap
// reads through: CoreAudio property reads, the tap buffer pick, the level
// correction for outputs wider than stereo and the listener bookkeeping.
// FixDock has no mixer, so only what the tap calls is ported, under recorder
// names. Upstream's atomics (`OSAtomic*`, deprecated) are replaced with
// `OSAllocatedUnfairLock`, and the responsible-process lookup with a public
// parent-process walk.

// MARK: - Shared values

/// A flag the audio thread raises and another thread reads later.
final class RecorderAudioFlag: @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: false)

    var value: Bool { state.withLock { $0 } }

    func raise() {
        state.withLock { $0 = true }
    }
}

/// A host time one thread stores and others read, 0 for none.
final class RecorderAudioHostTime: @unchecked Sendable {
    private let state = OSAllocatedUnfairLock<UInt64>(initialState: 0)

    var value: UInt64 {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }
}

/// A float the audio thread reads while another thread replaces it, one
/// whole value at a time.
final class RecorderAtomicFloat: @unchecked Sendable {
    private let state: OSAllocatedUnfairLock<Float>

    init(_ value: Float) {
        state = OSAllocatedUnfairLock(initialState: value)
    }

    var value: Float {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }
}

/// Whether linear float audio holds anything but silence.
enum RecorderAudioProbe {
    static func containsSound(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let stream = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
              stream.mFormatID == kAudioFormatLinearPCM,
              stream.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              stream.mBitsPerChannel == 32
        else { return false }
        let heard = try? sampleBuffer.withAudioBufferList(blockBufferMemoryAllocator: nil,
                                                          flags: []) { list, _ in
            list.contains { containsSound($0) }
        }
        return heard ?? false
    }

    /// One vectorised pass and no allocation, so the audio thread can ask.
    static func containsSound(_ buffer: AudioBuffer) -> Bool {
        guard let samples = buffer.mData?.assumingMemoryBound(to: Float.self) else { return false }
        let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
        guard count > 0 else { return false }
        var peak: Float = 0
        vDSP_maxmgv(samples, 1, &peak, vDSP_Length(count))
        return peak > 0
    }
}

// MARK: - Render helpers

/// The realtime pieces of upstream's `MixerRender` the tap uses: no
/// allocation, no locks, one pass over the samples.
enum RecorderTapRender {
    /// How many frames a buffer holds.
    static func frames(bytes: UInt32, channels: UInt32) -> Int {
        guard channels > 0 else { return 0 }
        return Int(bytes) / (MemoryLayout<Float>.size * Int(channels))
    }

    /// Which input buffer carries the tap. An aggregate presents what its
    /// sub-device records first and the tap after it, so on an output that
    /// also has a microphone the tap is not buffer zero. The tap is the last
    /// buffer with the shape the tap announced; a lone buffer with data is
    /// claimed when nothing matches, and among several nothing is guessed.
    static func tapBufferIndex(in buffers: UnsafeMutableAudioBufferListPointer,
                               tapChannels: Int) -> Int? {
        var lone: Int?
        for index in stride(from: buffers.count - 1, through: 0, by: -1)
        where buffers[index].mNumberChannels > 0 {
            if Int(buffers[index].mNumberChannels) == tapChannels {
                return buffers[index].mData == nil ? nil : index
            }
            if buffers.count == 1, buffers[index].mData != nil { lone = index }
        }
        return lone
    }

    /// Silences every output byte. The aggregate's output buffer arrives
    /// holding whatever CoreAudio last put there, and the device beneath the
    /// aggregate would otherwise play it.
    static func silence(_ output: UnsafeMutableAudioBufferListPointer) {
        for buffer in output {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }
    }
}

// MARK: - Level correction

/// The pure rules of upstream's tap level correction (`MixerRoutingSupport`).
enum RecorderTapLevel {
    static let maximumCompensation: Double = 4

    /// The stereo mixdown tap divides what it hears by the number of channel
    /// pairs of the output a process plays to, a known system issue
    /// (FB13479345). The narrowest output decides, an unreadable one counts
    /// as stereo, and nothing is ever lifted above the level it plays at.
    static func compensation(streamChannels: [Int?]) -> Double {
        guard let fewest = streamChannels.map({ $0 ?? 2 }).filter({ $0 > 0 }).min() else { return 1 }
        return min(max(Double(fewest) / 2, 1), maximumCompensation)
    }

    /// What a watch stores before it reads the outputs, or nil to keep the
    /// correction it has. A move stores no correction first, since no
    /// correction is the level that is never too loud.
    static func levelBeforeReading(devices: Set<AudioObjectID>,
                                   lastDevices: Set<AudioObjectID>,
                                   defaultOutputDevices: Set<AudioObjectID>) -> Double? {
        if devices.isEmpty {
            guard !defaultOutputDevices.isEmpty,
                  defaultOutputDevices.isSubset(of: lastDevices) else { return 1 }
            return nil
        }
        return devices == lastDevices ? nil : 1
    }

    static let backstopInterval: Double = 1

    static func readIsDue(immediately: Bool, sinceLastRead: Double) -> Bool {
        immediately || sinceLastRead >= backstopInterval
    }

    static let rampDuration: Double = 0.03
    static let dropDuration: Double = 0.005

    /// The correction applied in a cycle of `seconds`: quickly on the way
    /// down, gently on the way up, so neither direction steps the level.
    static func rampStep(applied: Float?, target: Float, seconds: Double) -> Float {
        guard let applied, applied > 0 else { return target }
        let duration = target < applied ? dropDuration : rampDuration
        let limit = Float(pow(maximumCompensation, min(max(seconds, 0) / duration, 1)))
        return min(max(target, applied / limit), applied * limit)
    }

    /// An output as a process's own outputs list it: the devices inside an
    /// aggregate, down through nested aggregates, the device itself otherwise.
    static func outputDevices(of output: AudioObjectID,
                              subDeviceUIDs: (AudioObjectID) -> [String],
                              deviceForUID: (String) -> AudioObjectID?,
                              depth: Int = 0) -> Set<AudioObjectID> {
        let inside = subDeviceUIDs(output).compactMap(deviceForUID)
        guard !inside.isEmpty, depth < 4 else { return [output] }
        return inside.reduce(into: Set<AudioObjectID>()) { devices, device in
            devices.formUnion(outputDevices(of: device, subDeviceUIDs: subDeviceUIDs,
                                            deviceForUID: deviceForUID, depth: depth + 1))
        }
    }

    static func listenerChanges<Object: Hashable>(listened: Set<Object>, wanted: Set<Object>)
        -> (add: Set<Object>, remove: Set<Object>) {
        (wanted.subtracting(listened), listened.subtracting(wanted))
    }

    /// Channels of the stream holding the output's preferred stereo pair,
    /// whose left channel counts from 1; the first stream otherwise.
    static func stereoStreamChannels(streamChannels: [Int], preferredLeftChannel: Int) -> Int? {
        var firstChannel = 1
        for channels in streamChannels where channels > 0 {
            if preferredLeftChannel >= firstChannel, preferredLeftChannel < firstChannel + channels {
                return channels
            }
            firstChannel += channels
        }
        return streamChannels.first { $0 > 0 }
    }

    static let owningAppSearchDepth = 8

    /// The nearest regular app up the parent chain, starting at `pid`.
    static func owningRegularAppPid(of pid: pid_t,
                                    isRegularApp: (pid_t) -> Bool,
                                    parentPid: (pid_t) -> pid_t) -> pid_t? {
        guard pid > 0 else { return nil }
        if isRegularApp(pid) { return pid }
        var current = pid
        for _ in 0..<owningAppSearchDepth {
            current = parentPid(current)
            guard current > 1 else { return nil }
            if isRegularApp(current) { return current }
        }
        return nil
    }
}

/// The correction as one IO proc applies it, eased by `rampStep`. Touched
/// only by that IO proc; timed by the host clock.
final class RecorderTapLevelRamp {
    private var applied: Float?
    private var lastHostTime: UInt64?

    func next(toward target: Float, hostTime: UInt64) -> Float {
        let elapsed = lastHostTime.map { hostTime > $0 ? hostTime - $0 : 0 } ?? 0
        lastHostTime = hostTime
        let value = RecorderTapLevel.rampStep(
            applied: applied, target: target,
            seconds: Double(AudioConvertHostTimeToNanos(elapsed)) / 1_000_000_000)
        applied = value
        return value
    }
}

// MARK: - Listener clients

/// Names CoreAudio listener registrations by number, so a callback still on
/// its way after its owner went away finds nothing rather than freed memory.
enum RecorderAudioListenerClients {
    private struct Entry {
        weak var owner: AnyObject?
    }

    private static let lock = NSLock()
    private static var entries: [UInt: Entry] = [:]
    private static var counter: UInt = 0

    /// A client pointer no other registration holds. Never dereferenced.
    static func reserve(for owner: AnyObject) -> UnsafeMutableRawPointer {
        lock.withLock {
            counter &+= 1
            if counter == 0 { counter = 1 }
            entries[counter] = Entry(owner: owner)
            return UnsafeMutableRawPointer(bitPattern: counter).unsafelyUnwrapped
        }
    }

    static func owner(of client: UnsafeMutableRawPointer?) -> AnyObject? {
        guard let client else { return nil }
        return lock.withLock { entries[UInt(bitPattern: client)]?.owner }
    }

    static func forget(_ client: UnsafeMutableRawPointer) {
        lock.withLock { entries[UInt(bitPattern: client)] = nil }
    }
}

// MARK: - CoreAudio reads

/// The CoreAudio property reads the tap and its level watch need.
enum RecorderAudioDevices {
    /// Every process object the audio HAL knows about.
    static func audioProcessObjects() -> [AudioObjectID] {
        objectList(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList)
    }

    static func defaultOutputDeviceID() -> AudioObjectID? {
        var device = AudioObjectID(0)
        guard read(AudioObjectID(kAudioObjectSystemObject),
                   kAudioHardwarePropertyDefaultOutputDevice, &device),
              device != 0 else { return nil }
        return device
    }

    /// How many channels each output stream of a device carries, in order.
    static func outputStreamChannels(of deviceID: AudioObjectID) -> [Int] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: kAudioDevicePropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioBufferList>.size) else { return [] }
        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, storage) == noErr else {
            return []
        }
        return UnsafeMutableAudioBufferListPointer(
            storage.assumingMemoryBound(to: AudioBufferList.self)).map { Int($0.mNumberChannels) }
    }

    /// A property holding a list of objects, empty when it cannot be read.
    static func objectList(_ object: AudioObjectID,
                           _ selector: AudioObjectPropertySelector,
                           scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: selector,
                                                 mScope: scope,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioObjectID>.size) else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &objects) == noErr else {
            return []
        }
        return objects.prefix(Int(size) / MemoryLayout<AudioObjectID>.size).filter { $0 != 0 }
    }

    /// The UIDs of every device inside an aggregate, empty for any other.
    static func subDeviceUIDs(of device: AudioObjectID) -> [String] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioAggregateDevicePropertyFullSubDeviceList,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var list: Unmanaged<CFArray>?
        var size = UInt32(MemoryLayout<Unmanaged<CFArray>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &list) == noErr,
              size == UInt32(MemoryLayout<Unmanaged<CFArray>?>.size),
              let list else { return [] }
        return (list.takeRetainedValue() as? [String]) ?? []
    }

    /// The device the HAL knows by this UID, nil when none is connected.
    static func deviceID(forUID uid: String) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var qualifier = uid as CFString
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafePointer(to: &qualifier) { pointer in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                       UInt32(MemoryLayout<CFString>.size), pointer, &size, &device)
        }
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    @discardableResult
    static func read<T>(_ object: AudioObjectID,
                        _ selector: AudioObjectPropertySelector,
                        _ value: inout T,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: selector,
                                                 mScope: scope,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        return withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(object, &address, 0, nil, &size,
                                       UnsafeMutableRawPointer(pointer)) == noErr
        }
    }

    /// The regular app a process plays for: itself, or the nearest regular
    /// app up its parent chain. Upstream also asked the undocumented
    /// responsibility lookup, which FixDock does not use, so a helper started
    /// by launchd (Safari's media helpers) has no owner here.
    static func regularAppOwner(of pid: pid_t) -> pid_t? {
        RecorderTapLevel.owningRegularAppPid(
            of: pid,
            isRegularApp: { NSRunningApplication(processIdentifier: $0)?.activationPolicy == .regular },
            parentPid: parent(of:))
    }

    private static func parent(of pid: pid_t) -> pid_t {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return 0 }
        return pid_t(info.pbi_ppid)
    }
}

// MARK: - Level watch

/// Keeps the tap's level correction right for where the processes it hears
/// play, and follows them as they come and go. Upstream's
/// `LevelCompensationWatch`, reduced to the recorder's two uses: a list of
/// one app's processes, or every process but a few.
final class RecorderLevelCompensationWatch: @unchecked Sendable {
    /// Touched only on `queue` once the watch follows the process list.
    private var objects: [AudioObjectID]
    private let excluded: Set<AudioObjectID>?
    private let store: (Float) -> Void
    private let listenLock = NSLock()
    private var listenedObjects: [AudioObjectID] = []
    private var listensToProcessList = false
    private var client: UnsafeMutableRawPointer?
    private let pendingLock = NSLock()
    private var refreshPending = false
    private var immediatePending = false
    private let queue = DispatchQueue(label: "io.github.qaws81877.fixdock.recorder.level",
                                      qos: .userInitiated)
    private var lastDevices = Set<AudioObjectID>()
    private var lastReadAt: CFAbsoluteTime = 0

    private static let firstReadWait = DispatchTimeInterval.milliseconds(50)
    private let firstRead = DispatchSemaphore(value: 0)

    /// Listener removals can park inside a wedged HAL, so they never run on
    /// a queue anything waits for.
    private static let teardownQueue = DispatchQueue(
        label: "io.github.qaws81877.fixdock.recorder.level.teardown", qos: .utility)

    private init(objects: [AudioObjectID], excluded: Set<AudioObjectID>? = nil,
                 store: @escaping (Float) -> Void) {
        self.objects = objects
        self.excluded = excluded
        self.store = store
    }

    static func started(objects: [AudioObjectID],
                        store: @escaping (Float) -> Void) -> RecorderLevelCompensationWatch {
        let watch = RecorderLevelCompensationWatch(objects: objects, store: store)
        let client = Unmanaged.passRetained(watch).toOpaque()
        for object in objects {
            var address = Self.address
            if AudioObjectAddPropertyListener(object, &address, Self.listener, client) == noErr {
                watch.listenedObjects.append(object)
            }
        }
        if watch.listenedObjects.isEmpty {
            Unmanaged<RecorderLevelCompensationWatch>.fromOpaque(client).release()
        } else {
            watch.client = client
        }
        watch.queue.async {
            watch.read()
            watch.firstRead.signal()
        }
        return watch
    }

    static func started(everyProcessExcept excluded: [AudioObjectID],
                        store: @escaping (Float) -> Void) -> RecorderLevelCompensationWatch {
        let watch = RecorderLevelCompensationWatch(objects: [], excluded: Set(excluded), store: store)
        let client = Unmanaged.passRetained(watch).toOpaque()
        watch.client = client
        var address = Self.processListAddress
        watch.listensToProcessList = AudioObjectAddPropertyListener(
            AudioObjectID(kAudioObjectSystemObject), &address, Self.listener, client) == noErr
        watch.queue.async {
            _ = watch.followProcessList()
            watch.read()
            watch.firstRead.signal()
        }
        return watch
    }

    /// Briefly, so the head of the file already has its level.
    func waitForFirstRead() {
        _ = firstRead.wait(timeout: .now() + Self.firstReadWait)
    }

    func refresh(immediately: Bool) {
        let queued = pendingLock.withLock { () -> Bool in
            immediatePending = immediatePending || immediately
            guard !refreshPending else { return false }
            refreshPending = true
            return true
        }
        guard queued else { return }
        queue.async { [self] in
            let immediately = pendingLock.withLock { () -> Bool in
                defer {
                    refreshPending = false
                    immediatePending = false
                }
                return immediatePending
            }
            guard RecorderTapLevel.readIsDue(
                immediately: immediately,
                sinceLastRead: CFAbsoluteTimeGetCurrent() - lastReadAt) else { return }
            read()
        }
    }

    func stop() {
        Self.teardownQueue.async { [weak self] in self?.stopListening() }
    }

    /// A removal the HAL refuses keeps this small object alive: a late
    /// callback is safer than one into released memory.
    private func stopListening() {
        let (client, listened, processList) = listenLock.withLock {
            defer {
                self.client = nil
                listenedObjects.removeAll()
                listensToProcessList = false
            }
            return (self.client, listenedObjects, listensToProcessList)
        }
        guard let client else { return }
        var removedAll = true
        for object in listened {
            var address = Self.address
            let status = AudioObjectRemovePropertyListener(object, &address, Self.listener, client)
            if status != noErr && status != kAudioHardwareBadObjectError {
                removedAll = false
            }
        }
        if processList {
            var address = Self.processListAddress
            if AudioObjectRemovePropertyListener(AudioObjectID(kAudioObjectSystemObject), &address,
                                                 Self.listener, client) != noErr {
                removedAll = false
            }
        }
        if removedAll { Unmanaged<RecorderLevelCompensationWatch>.fromOpaque(client).release() }
    }

    /// Runs on `queue` only.
    private func followProcessList() -> Bool {
        guard let excluded else { return false }
        let current = RecorderAudioDevices.audioProcessObjects().filter { $0 != 0 && !excluded.contains($0) }
        guard Set(current) != Set(objects) else { return false }
        objects = current
        listenLock.withLock {
            guard let client else { return }
            let changes = RecorderTapLevel.listenerChanges(listened: Set(listenedObjects),
                                                           wanted: Set(current))
            listenedObjects.removeAll { object in
                guard changes.remove.contains(object) else { return false }
                var address = Self.address
                let status = AudioObjectRemovePropertyListener(object, &address, Self.listener, client)
                return status == noErr || status == kAudioHardwareBadObjectError
            }
            for object in changes.add {
                var address = Self.address
                if AudioObjectAddPropertyListener(object, &address, Self.listener, client) == noErr {
                    listenedObjects.append(object)
                }
            }
        }
        return true
    }

    /// Runs on `queue` only.
    private func read() {
        lastReadAt = CFAbsoluteTimeGetCurrent()
        var devices = Set<AudioObjectID>()
        for object in objects { devices.formUnion(Self.processOutputDevices(of: object)) }
        if let first = RecorderTapLevel.levelBeforeReading(
            devices: devices,
            lastDevices: lastDevices,
            defaultOutputDevices: devices.isEmpty ? Self.defaultOutputDevices() : []) {
            store(Float(first))
        }
        guard !devices.isEmpty else { return }
        lastDevices = devices
        store(Float(RecorderTapLevel.compensation(
            streamChannels: devices.map { Self.stereoStreamChannels(of: $0) })))
    }

    private static func processOutputDevices(of process: AudioObjectID) -> [AudioObjectID] {
        RecorderAudioDevices.objectList(process, address.mSelector, scope: address.mScope)
    }

    private static func defaultOutputDevices() -> Set<AudioObjectID> {
        guard let output = RecorderAudioDevices.defaultOutputDeviceID() else { return [] }
        return RecorderTapLevel.outputDevices(of: output,
                                              subDeviceUIDs: RecorderAudioDevices.subDeviceUIDs(of:),
                                              deviceForUID: RecorderAudioDevices.deviceID(forUID:))
    }

    private static func stereoStreamChannels(of deviceID: AudioObjectID) -> Int? {
        let streams = RecorderAudioDevices.outputStreamChannels(of: deviceID)
        guard !streams.isEmpty else { return nil }
        var stereoPair: (UInt32, UInt32) = (1, 2)
        _ = RecorderAudioDevices.read(deviceID, kAudioDevicePropertyPreferredChannelsForStereo,
                                      &stereoPair, scope: kAudioObjectPropertyScopeOutput)
        return RecorderTapLevel.stereoStreamChannels(streamChannels: streams,
                                                     preferredLeftChannel: Int(stereoPair.0))
    }

    /// The device list announces changes only on the output scope.
    private static let address = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyDevices,
                                                            mScope: kAudioObjectPropertyScopeOutput,
                                                            mElement: kAudioObjectPropertyElementMain)

    private static let processListAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyProcessObjectList,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    private static let listener: AudioObjectPropertyListenerProc = { object, _, _, client in
        guard let client else { return noErr }
        let watch = Unmanaged<RecorderLevelCompensationWatch>.fromOpaque(client).takeUnretainedValue()
        if object == AudioObjectID(kAudioObjectSystemObject) {
            watch.queue.async {
                if watch.followProcessList() { watch.refresh(immediately: true) }
            }
        } else {
            watch.refresh(immediately: true)
        }
        return noErr
    }
}
