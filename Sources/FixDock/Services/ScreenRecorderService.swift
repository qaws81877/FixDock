// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import AVFoundation
import AppKit
import CoreMedia
import ScreenCaptureKit

/// One recording, from the first frame to the closed file. Everything that
/// only exists while recording lives here and dies with it, so the service
/// itself keeps nothing running between recordings.
private final class RecorderSession: NSObject, RecorderCaptureEngineDelegate {
    let take: RecorderTakeStore.Take
    let region: RecorderSupport.Region
    private let engine = RecorderCaptureEngine()
    private let pauseClock: RecorderPauseClock
    private let microphone: RecorderMicrophoneCapture?
    /// The Mac's sound read once per process, when the audio system grants
    /// one. Both it and the stream's audio run whenever the Mac's sound is
    /// wanted; which of the two the file receives is settled in `start()`.
    private var systemAudioTap: RecorderSystemAudioTap?
    private var writesTapAudio = false
    /// Raised when a device or process change costs the tap its reader mid
    /// recording. One way, and read from the audio threads, so it is the flag
    /// type rather than a plain Bool.
    private let tapReaderLost = RecorderAudioFlag()
    /// Whether the stream heard sound at all, and whether it heard sound the
    /// tap was there to hear. They differ only for an app's tap, which can be
    /// built after the stream first hears the app.
    private let streamHeard = RecorderAudioFlag()
    private let streamHeardSinceTap = RecorderAudioFlag()
    /// FixDock: each track is optional (Settings), so a sampler exists only
    /// when its track was asked for.
    private let pointer: RecorderPointerSampler?
    private let typing: RecorderTypingSampler?
    private let writerQueue = DispatchQueue(label: "io.github.qaws81877.fixdock.recorder.writer",
                                            qos: .userInitiated)
    private let startGate = RecorderStartGate()
    /// Immutable for the whole session, which is what makes it safe to touch
    /// from the capture queue while the main thread watches the clock.
    private let writer: RecorderWriter

    var onUnexpectedStop: ((RecorderFailure) -> Void)?
    var onMicrophoneUnavailable: (() -> Void)?

    init(take: RecorderTakeStore.Take,
         region: RecorderSupport.Region,
         writer: RecorderWriter,
         pauseClock: RecorderPauseClock,
         capturesMicrophone: Bool,
         recordsPointer: Bool,
         recordsTyping: Bool) {
        self.take = take
        self.region = region
        self.writer = writer
        self.pauseClock = pauseClock
        microphone = capturesMicrophone ? RecorderMicrophoneCapture() : nil
        pointer = recordsPointer ? RecorderPointerSampler(region: region, pauseClock: pauseClock) : nil
        typing = recordsTyping ? RecorderTypingSampler(pauseClock: pauseClock) : nil
        super.init()
        engine.delegate = self
        microphone?.onSample = { [weak self] sampleBuffer in
            self?.append(sampleBuffer, kind: .microphone)
        }
    }

    func start(frameRate: Int,
               capturesSystemAudio: Bool,
               excludedWindowNumbers: [Int]) async -> RecorderFailure? {
        guard startGate.begin() else { return .streamFailed }
        defer { startGate.finish() }
        guard writer.start() else {
            _ = startGate.claimStartFailure()
            return .writerFailed
        }
        if capturesSystemAudio {
            systemAudioTap = await RecorderSystemAudioTap.make(hearing: await Self.windowOwner(of: region))
        }
        let tap = systemAudioTap
        // A tap that has not yet heard sound on this Mac may be waiting on a
        // permission, and it answers that with silence, not an error. The
        // stream's sound is written until the tap has proven itself.
        writesTapAudio = tap != nil
            && UserDefaults.standard.bool(forKey: DefaultsKey.recorderSystemAudioTapVerified)
        tap?.onSample = { [weak self] sampleBuffer in
            self?.appendTapSample(sampleBuffer)
        }
        tap?.onReaderLost = { [weak self] in self?.tapReaderLost.raise() }
        if let failure = await engine.start(region: region,
                                            frameRate: frameRate,
                                            capturesSystemAudio: capturesSystemAudio,
                                            showsCursor: pointer == nil,
                                            excludedWindowNumbers: excludedWindowNumbers,
                                            willStartCapture: { [writerQueue, writer] time in
                                                writerQueue.sync { writer.beginSession(at: time) }
                                            },
                                            isCancelled: { [weak self] in
                                                self?.startGate.isAuthorized != true
                                            }) {
            if startGate.claimStartFailure() { writer.cancel() }
            await tap?.stop()
            return failure
        }
        guard startGate.isAuthorized else {
            await tap?.stop()
            await engine.stop()
            return .streamFailed
        }
        // The tap starts before the microphone so the Mac's sound has the
        // shortest possible gap at the head of the file while it comes up.
        let clock = CMClockGetHostTimeClock()
        if let tap {
            let started = await tap.start(synchronizingTo: clock)
            // A trusted tap that could not build a reader this time (no output
            // device, or a permission just revoked) would otherwise leave the
            // file's sound silent, since the stream's copy is being dropped.
            if writesTapAudio, !started { writesTapAudio = false }
        }
        guard startGate.isAuthorized else {
            await tap?.stop()
            await engine.stop()
            return .streamFailed
        }
        if let microphone {
            if await microphone.start(synchronizingTo: clock) == false {
                onMicrophoneUnavailable?()
            }
            guard startGate.isAuthorized else {
                await tap?.stop()
                await microphone.stop()
                await engine.stop()
                return .streamFailed
            }
        }
        // This method is nonisolated and async, so its body runs on the
        // cooperative pool however main-actor the caller was (SE-0338). The
        // two samplers install AppKit event monitors, which belong to the
        // main thread's dispatch, so they are started and stopped there.
        await MainActor.run {
            pointer?.start()
            typing?.start()
        }
        return nil
    }

    /// The app whose window is being recorded, so the sound follows the
    /// picture. Nothing for a display, and nothing for a window of our own:
    /// this process plays nothing a recording wants. FixDock reads the owner
    /// from `SCWindow.owningApplication` instead of upstream's window-server
    /// lookup.
    private static func windowOwner(of region: RecorderSupport.Region) async -> pid_t? {
        guard let windowID = region.windowID,
              let content = try? await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true)
        else { return nil }
        let owner = content.windows.first { $0.windowID == windowID }?.owningApplication?.processID
        return RecorderSupport.systemAudioApp(windowOwner: owner,
                                              ownProcess: ProcessInfo.processInfo.processIdentifier)
    }

    var isPaused: Bool { pauseClock.isPaused }

    func pause(at time: CFTimeInterval) -> Bool {
        pauseClock.pause(at: time)
    }

    func resume(at time: CFTimeInterval) -> Bool {
        pauseClock.resume(at: time)
    }

    func elapsed(at time: CFTimeInterval) -> Double {
        pauseClock.elapsed(at: time)
    }

    /// Stops the stream first and waits for it, so the file is closed knowing
    /// no further frame can arrive.
    func stop() async -> Bool {
        let end = CMClockGetTime(CMClockGetHostTimeClock())
        let ownsFinalization = startGate.cancelAndClaimStop()
        await startGate.waitUntilFinished()
        guard ownsFinalization else { return false }
        let tap = systemAudioTap
        async let tapStop: Void = { if let tap { await tap.stop() } }()
        if let microphone {
            async let microphoneStop: Void = microphone.stop()
            await engine.stop()
            await microphoneStop
        } else {
            await engine.stop()
        }
        await tapStop
        // A tap that lost its reader was cut short by a device or process
        // change, not by a missing permission, so this recording proves
        // nothing either way.
        if let tap, !tapReaderLost.value {
            UserDefaults.standard.set(
                RecorderSupport.trustsSystemAudioTap(previously: writesTapAudio,
                                                     tapHeardSound: tap.heardSound,
                                                     streamHeardSound: streamHeardSound(against: tap)),
                forKey: DefaultsKey.recorderSystemAudioTapVerified)
        }
        let (track, typingTrack) = await MainActor.run { (pointer?.stop(), typing?.stop()) }
        writerQueue.sync {}
        let written = await writer.finish(at: end)
        // Both land inside the take folder, never anywhere else.
        if written, let track, !track.isEmpty {
            PrivateFileStore.write(track.encoded(), to: take.pointerURL)
        }
        if written, let typingTrack, !typingTrack.isEmpty, let data = typingTrack.encoded() {
            PrivateFileStore.write(data, to: take.typingURL)
        }
        return written
    }

    /// Whether the stream heard sound the tap should have heard too. An app's
    /// tap that never ran through a recording in which the stream heard the
    /// app cannot hear that app at all, so all of the stream's sound counts
    /// against it, as against the whole Mac's tap.
    private func streamHeardSound(against tap: RecorderSystemAudioTap) -> Bool {
        tap.ranPipeline ? streamHeardSinceTap.value : streamHeard.value
    }

    func captureEngine(_ engine: RecorderCaptureEngine,
                       didOutput sampleBuffer: CMSampleBuffer,
                       of kind: RecorderCaptureEngine.Kind) {
        if kind == .systemAudio {
            // The stream keeps listening even when the tap is written: a tap
            // that stays silent through sound the stream heard has lost its
            // permission, and the next recording goes back to the stream.
            if !streamHeardSinceTap.value, RecorderAudioProbe.containsSound(sampleBuffer) {
                streamHeard.raise()
                let tap = systemAudioTap
                let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                if RecorderSupport.streamSoundCountsAgainstTap(at: time,
                                                               hearsOneApp: tap?.hearsOneApp == true,
                                                               pipelineStart: tap?.pipelineStart ?? 0) {
                    streamHeardSinceTap.raise()
                }
            }
            if writesTapAudio, !tapReaderLost.value { return }
        }
        append(sampleBuffer, kind: kind)
    }

    private func appendTapSample(_ sampleBuffer: CMSampleBuffer) {
        guard writesTapAudio, !tapReaderLost.value else { return }
        append(sampleBuffer, kind: .systemAudio)
    }

    func captureEngine(_ engine: RecorderCaptureEngine, didStopWith failure: RecorderFailure) {
        onUnexpectedStop?(failure)
    }

    private func append(_ sampleBuffer: CMSampleBuffer, kind: RecorderCaptureEngine.Kind) {
        writerQueue.async { [writer] in
            writer.append(sampleBuffer, kind: kind)
        }
    }
}

/// The screen recorder: records the region the capture overlay hands over
/// (key 2), with the Mac's sound and the microphone when asked, and leaves a
/// movie in the screenshot folder plus a preview.
///
/// At rest it holds no recorder resource. The stream, writer, floating
/// indicator and the one timer that draws elapsed time are created only while
/// recording. Ported from upstream with FixDock's delivery: the take's master
/// is copied (never moved) to the save folder, the preview holds the take
/// until it closes or hands it to the editor, and a failed recording leaves
/// its take for the sweep instead of deleting it on the spot.
final class ScreenRecorderService: ObservableObject {
    static let shared = ScreenRecorderService()

    @Published private(set) var isRecording = false
    @Published private(set) var isPaused = false
    @Published private(set) var elapsedSeconds = 0
    /// The last saved movie, or the last failure, for the panel row.
    @Published private(set) var lastMessage: String?
    private var session: RecorderSession?
    private var indicator: RecorderIndicator?
    private var preview: ScreenRecorderPreviewController?
    private var elapsedTimer: Timer?
    private var countdown: DispatchWorkItem?
    private var countdownRemaining = 0
    private var pendingStartGeneration = 0
    private var isAwaitingMicrophone = false
    private var isPreparingRecording = false
    private var sleepActivity: NSObjectProtocol?
    /// Set while a stop is being finalized, so a second press of the shortcut
    /// cannot start a recording on top of one still closing its file.
    private var isFinishing = false
    /// Set while the disk is being asked how much room is left, so a slow
    /// answer cannot pile the next second's question on top of it.
    private var isCheckingDisk = false

    private var strings: Strings { L10n.shared.s }

    private init() {}

    // MARK: - Preferences

    /// The catalog binding: install, uninstall and launch.
    func syncWithPreferences() {
        guard AppFeature.screenRecorder.isAvailable else {
            teardownSurfaces()
            return
        }
        sweepTakes()
    }

    /// Uninstalling the feature in the hub has to take everything off the
    /// screen, but a recording in progress still finishes into a file: losing
    /// what was already recorded would be worse than the delay.
    private func teardownSurfaces() {
        invalidatePendingStart()
        preview?.close()
        RecorderEditorEntry.closeAll()
        if session != nil {
            stop()
        }
    }

    // MARK: - State

    /// Where the recorder is, for the capture shortcuts.
    var captureState: ScreenRecorderSupport.CaptureState {
        if isFinishing { return .finishing }
        if isRecording || session != nil { return .recording }
        if countdown != nil || isAwaitingMicrophone || isPreparingRecording { return .countdown }
        return .idle
    }

    /// Control-Option-Command-4 while the recorder is busy: stops a
    /// recording, cancels a countdown, beeps while a file is being closed.
    /// False when the recorder is idle and the overlay should open.
    func handleOverlayShortcut() -> Bool {
        switch ScreenRecorderSupport.overlayShortcut(in: captureState) {
        case .openOverlay:
            return false
        case .cancelCountdown:
            invalidatePendingStart()
        case .stopRecording:
            stop()
        case .beep:
            NSSound.beep()
        }
        return true
    }

    // MARK: - Entry

    /// Checks made before a region is recorded. Screen Recording is required;
    /// Accessibility is asked for only when the typing track is on, and a
    /// recording without it simply has no typing track.
    private func prepareToRecord() -> Bool {
        guard AppFeature.screenRecorder.isAvailable, captureState == .idle else { return false }
        Permissions.shared.refresh()
        guard Permissions.shared.screenRecording else {
            Permissions.shared.request(.screenRecording)
            return false
        }
        if UserDefaults.standard.bool(forKey: DefaultsKey.recorderTypingTrack),
           !Permissions.shared.accessibility {
            Permissions.shared.request(.accessibility)
        }
        guard RecorderSupport.canStart(freeBytes: RecorderTakeStore.shared.freeBytes()) else {
            reportNoSpace()
            return false
        }
        return true
    }

    /// The overlay's recording result. The overlay is already off screen.
    func record(_ region: RecorderSupport.Region) {
        // A new recording replaces an open preview, whose take goes with it.
        preview?.close()
        guard prepareToRecord() else { return }
        let indicator = RecorderIndicator(
            onPause: { [weak self] in self?.togglePause() },
            onStop: { [weak self] in self?.stop() })
        indicator.showRegionGuide(for: region)
        self.indicator = indicator
        pendingStartGeneration &+= 1
        let generation = pendingStartGeneration
        let wantsMicrophone = UserDefaults.standard.bool(forKey: DefaultsKey.recorderMicrophone)
        prepareCountdown(for: region, wantsMicrophone: wantsMicrophone, generation: generation)
    }

    private func prepareCountdown(for region: RecorderSupport.Region,
                                  wantsMicrophone: Bool,
                                  generation: Int) {
        guard pendingStartIsAuthorized(generation) else { return }
        Permissions.shared.refresh()
        guard wantsMicrophone, !Permissions.shared.microphone else {
            startCountdown(for: region, generation: generation)
            return
        }
        if Permissions.shared.microphoneUndetermined {
            isAwaitingMicrophone = true
            Permissions.shared.requestMicrophone { [weak self] granted in
                guard let self, self.pendingStartIsAuthorized(generation) else { return }
                self.isAwaitingMicrophone = false
                if !granted { self.showMessage(symbol: "mic.slash", self.strings.recorderMicrophoneUnavailable) }
                self.startCountdown(for: region, generation: generation)
            }
        } else {
            showMessage(symbol: "mic.slash", strings.recorderMicrophoneUnavailable)
            startCountdown(for: region, generation: generation)
        }
    }

    // MARK: - Countdown

    private func startCountdown(for region: RecorderSupport.Region, generation: Int) {
        guard pendingStartIsAuthorized(generation), session == nil, !isFinishing else { return }
        let delay = ScreenRecorderSupport.sanitizedCountdown(
            UserDefaults.standard.integer(forKey: DefaultsKey.recorderCountdown))
        guard delay > 0 else {
            beginRecording(region: region, generation: generation)
            return
        }
        countdownRemaining = delay
        tickCountdown(region: region, generation: generation)
    }

    private func tickCountdown(region: RecorderSupport.Region, generation: Int) {
        guard pendingStartIsAuthorized(generation) else { return }
        guard countdownRemaining > 0 else {
            countdown = nil
            RecorderHUD.shared.hide()
            beginRecording(region: region, generation: generation)
            return
        }
        RecorderHUD.shared.showCountdown(countdownRemaining, on: screen(of: region))
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.pendingStartIsAuthorized(generation) else { return }
            self.countdownRemaining -= 1
            self.tickCountdown(region: region, generation: generation)
        }
        countdown = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    // MARK: - Recording

    private func beginRecording(region: RecorderSupport.Region, generation: Int) {
        guard pendingStartIsAuthorized(generation), session == nil,
              !isFinishing, let take = RecorderTakeStore.shared.makeTake() else {
            indicator?.hide()
            indicator = nil
            showMessage(symbol: "record.circle", strings.recorderRecordFailed)
            return
        }
        let defaults = UserDefaults.standard
        let frameRate = RecorderSupport.sanitizedFrameRate(
            defaults.integer(forKey: DefaultsKey.recorderFrameRate))
        let capturesSystemAudio = defaults.bool(forKey: DefaultsKey.recorderSystemAudio)
        Permissions.shared.refresh()
        let capturesMicrophone = defaults.bool(forKey: DefaultsKey.recorderMicrophone)
            && Permissions.shared.microphone
        let recordsPointer = defaults.bool(forKey: DefaultsKey.recorderPointerTrack)
        let recordsTyping = defaults.bool(forKey: DefaultsKey.recorderTypingTrack)
            && Permissions.shared.accessibility
        let pauseClock = RecorderPauseClock()
        isPreparingRecording = true
        RecorderWriter.prepare(url: take.videoURL, pixelSize: region.pixelSize, frameRate: frameRate,
                               capturesSystemAudio: capturesSystemAudio,
                               capturesMicrophone: capturesMicrophone, pauseClock: pauseClock) { [weak self] writer in
            // Every way out below leaves the take for the sweep: a take with
            // no finished master is removed an hour after it was made.
            guard let self, self.pendingStartIsAuthorized(generation), self.session == nil,
                  !self.isFinishing else {
                writer?.cancel()
                return
            }
            self.isPreparingRecording = false
            guard let writer else {
                self.indicator?.hide()
                self.indicator = nil
                self.showMessage(symbol: "record.circle", self.strings.recorderRecordFailed)
                return
            }
            let session = RecorderSession(take: take, region: region, writer: writer,
                                          pauseClock: pauseClock,
                                          capturesMicrophone: capturesMicrophone,
                                          recordsPointer: recordsPointer,
                                          recordsTyping: recordsTyping)
            self.startPreparedRecording(session, frameRate: frameRate,
                                        capturesSystemAudio: capturesSystemAudio, generation: generation)
        }
    }

    private func startPreparedRecording(_ session: RecorderSession, frameRate: Int,
                                        capturesSystemAudio: Bool, generation: Int) {
        let region = session.region
        session.onUnexpectedStop = { [weak self] _ in
            // The stream ended without being asked to. Whatever was recorded
            // is still worth keeping, so this closes the file rather than
            // throwing the take away.
            self?.stop()
        }
        session.onMicrophoneUnavailable = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.showMessage(symbol: "mic.slash", self.strings.recorderMicrophoneUnavailable)
            }
        }
        self.session = session

        // The indicator goes up BEFORE the stream is asked to start, because
        // the capture filter names the windows it leaves out and can only name
        // the ones that already exist.
        let indicator = indicator ?? RecorderIndicator(
            onPause: { [weak self] in self?.togglePause() },
            onStop: { [weak self] in self?.stop() })
        indicator.show(on: screen(of: region),
                       tooltip: strings.recorderIndicatorTooltip,
                       pauseTooltip: strings.recorderPause,
                       resumeTooltip: strings.recorderResume,
                       stopTooltip: strings.recorderStop)
        indicator.update(elapsed: RecorderSupport.elapsedLabel(seconds: 0))
        self.indicator = indicator

        Task { @MainActor [weak self] in
            guard let self else { return }
            // The overlay panels have just left the screen; the stream is
            // told to start only once the window server has caught up, so the
            // first frames are of the desktop and not of a fading overlay.
            try? await Task.sleep(nanoseconds: ScreenRecorderSupport.overlayClearDelayNanoseconds)
            guard self.session === session,
                  self.pendingStartIsAuthorized(generation) else { return }
            var chrome = Set(indicator.excludedWindowNumbers)
            if let number = RecorderHUD.shared.windowNumber { chrome.insert(number) }
            let failure = await session.start(frameRate: frameRate,
                                              capturesSystemAudio: capturesSystemAudio,
                                              excludedWindowNumbers: Array(chrome))
            guard self.session === session, !self.isFinishing,
                  self.pendingStartIsAuthorized(generation) else { return }
            if let failure {
                // The take stays for the sweep.
                self.session = nil
                self.indicator?.hide()
                self.indicator = nil
                self.report(failure)
                return
            }
            self.recordingDidStart()
        }
    }

    private func pendingStartIsAuthorized(_ generation: Int) -> Bool {
        RecorderSupport.pendingStartIsAuthorized(
            requestGeneration: generation,
            currentGeneration: pendingStartGeneration,
            featureIsAvailable: AppFeature.screenRecorder.isAvailable)
    }

    private func invalidatePendingStart() {
        pendingStartGeneration &+= 1
        isAwaitingMicrophone = false
        isPreparingRecording = false
        if countdown != nil { RecorderHUD.shared.hide() }
        countdown?.cancel()
        countdown = nil
        indicator?.hide()
        indicator = nil
    }

    private func recordingDidStart() {
        isRecording = true
        isPaused = false
        elapsedSeconds = Int(session?.elapsed(at: CACurrentMediaTime()) ?? 0)
        indicator?.update(elapsed: RecorderSupport.elapsedLabel(seconds: elapsedSeconds))
        sleepActivity = ProcessInfo.processInfo.beginActivity(
            options: .idleSystemSleepDisabled,
            reason: "Recording the screen")

        let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.tickElapsed()
        }
        timer.tolerance = 0.1
        elapsedTimer = timer
    }

    private func tickElapsed() {
        guard isRecording, let session else { return }
        elapsedSeconds = Int(session.elapsed(at: CACurrentMediaTime()))
        indicator?.update(elapsed: RecorderSupport.elapsedLabel(seconds: elapsedSeconds))
        checkDiskSpace()
    }

    func togglePause() {
        guard isRecording, let session else { return }
        let now = CACurrentMediaTime()
        if session.isPaused {
            guard session.resume(at: now) else { return }
            isPaused = false
        } else {
            guard session.pause(at: now) else { return }
            isPaused = true
        }
        elapsedSeconds = Int(session.elapsed(at: now))
        indicator?.update(elapsed: RecorderSupport.elapsedLabel(seconds: elapsedSeconds))
        indicator?.update(paused: isPaused)
    }

    /// A recording that fills the disk is a much worse failure than one that
    /// stopped early, so the free space is checked while it runs, off the
    /// main thread: only the decision to stop comes back.
    private func checkDiskSpace() {
        guard !isCheckingDisk, let asked = session?.take.id else { return }
        isCheckingDisk = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let low = RecorderSupport.shouldStopForDisk(
                freeBytes: RecorderTakeStore.shared.freeBytes())
            DispatchQueue.main.async {
                guard let self else { return }
                self.isCheckingDisk = false
                // The answer belongs to the recording that asked for it.
                guard low, self.isRecording, self.session?.take.id == asked else { return }
                self.stop(reason: self.strings.recorderStoppedNoSpace)
            }
        }
    }

    // MARK: - Stopping

    func stop(reason: String? = nil) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.stop(reason: reason) }
            return
        }
        guard let session, !isFinishing else {
            if isPreparingRecording { invalidatePendingStart() }
            return
        }
        isFinishing = true
        invalidatePendingStart()
        endRecordingSurfaces()

        Task { @MainActor [weak self] in
            let written = await session.stop()
            guard let self else { return }
            self.session = nil
            self.isFinishing = false
            Permissions.shared.refresh()
            if written {
                self.deliver(session.take, region: session.region, reason: reason)
            } else {
                // Empty or failed: nothing to save, and the take stays for
                // the sweep rather than being deleted here.
                self.fail(self.strings.recorderRecordFailed)
            }
            self.sweepTakes()
        }
    }

    private func endRecordingSurfaces() {
        isRecording = false
        isPaused = false
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        if let sleepActivity {
            ProcessInfo.processInfo.endActivity(sleepActivity)
            self.sleepActivity = nil
        }
    }

    // MARK: - Output

    /// Copies the master to the screenshot folder under a new unique name and
    /// shows the preview holding the take. A missing or unwritable folder
    /// saves nothing anywhere else: a beep and a message, and the take stays
    /// for the sweep.
    private func deliver(_ take: RecorderTakeStore.Take, region: RecorderSupport.Region, reason: String?) {
        let folder = ScreenshotService.saveFolder
        guard ScreenshotService.saveFolderIsUsable(folder),
              let destination = ScreenRecorderSupport.recordingDestination(
                in: folder, prefix: strings.recorderFilePrefix, date: Date(),
                exists: { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) })
        else {
            fail(strings.recorderFolderUnavailable)
            return
        }
        do {
            // `copyItem` refuses an existing destination: nothing is replaced.
            try RecorderTakeStore.shared.saveCopy(take, to: destination)
        } catch {
            fail(strings.recorderFolderUnavailable)
            return
        }
        let saved = String(format: strings.recorderSavedFormat, destination.lastPathComponent)
        lastMessage = reason ?? saved
        if let reason { showMessage(symbol: "record.circle", reason) }
        guard AppFeature.screenRecorder.isAvailable else {
            // Uninstalled while recording: the file is saved, no preview
            // comes up, and nothing else needs the take.
            RecorderTakeStore.shared.delete(take)
            return
        }
        showPreview(take: take, file: destination, anchor: region.anchorRect)
    }

    private func showPreview(take: RecorderTakeStore.Take, file: URL, anchor: CGRect) {
        preview?.close()
        let controller = ScreenRecorderPreviewController(
            file: file, anchor: anchor,
            canEdit: RecorderEditorEntry.isAvailable,
            edit: { RecorderEditorEntry.open(take) },
            onClose: { [weak self] handedOver in
                guard let self else { return }
                self.preview = nil
                // Closing without Edit: nothing needs the take any more.
                if !handedOver { RecorderTakeStore.shared.delete(take) }
            })
        preview = controller
        previewTakeID = take.id
        controller.show()
    }

    /// The take the open preview holds, so a sweep leaves it alone.
    private var previewTakeID: UUID?

    // MARK: - Failures

    private func report(_ failure: RecorderFailure) {
        switch failure {
        case .permissionDenied:
            Permissions.shared.request(.screenRecording)
        case .diskFull:
            reportNoSpace()
        case .noContent, .streamFailed, .writerFailed:
            fail(strings.recorderRecordFailed)
        }
    }

    private func reportNoSpace() {
        let alert = NSAlert()
        alert.messageText = strings.recorderNoSpaceTitle
        alert.informativeText = strings.recorderNoSpaceMessage
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func fail(_ message: String) {
        NSSound.beep()
        lastMessage = message
        showMessage(symbol: "record.circle", message)
    }

    private func showMessage(symbol: String, _ message: String) {
        RecorderHUD.shared.show(symbol: symbol, message: message)
    }

    private func screen(of region: RecorderSupport.Region) -> NSScreen? {
        NSScreen.screens.first { $0.displayID == region.displayID }
    }

    // MARK: - Retention

    /// Removes takes nothing holds once they pass upstream's ages. Read on
    /// the main thread and handed over as a value: the recording under way,
    /// the preview's take and every editor's take are never swept.
    private func sweepTakes() {
        if preview == nil { previewTakeID = nil }
        let kept = ScreenRecorderSupport.takesToKeep(session: session?.take.id,
                                                     preview: previewTakeID,
                                                     editors: RecorderEditorEntry.ownedTakeIDs)
        DispatchQueue.global(qos: .utility).async {
            RecorderTakeStore.shared.sweep(keeping: kept)
        }
    }
}
