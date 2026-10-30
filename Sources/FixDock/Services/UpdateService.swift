// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import AppKit
import Combine

/// The effectful shell around UpdatePolicy. It owns the one published
/// `UpdateStatus` (main thread, single writer), the hourly timer and the
/// install pipeline; callers get a few verbs and that value. A shell service,
/// not an AppFeature: updating is not a tool the person installs.
final class UpdateService: ObservableObject {
    static let shared = UpdateService()

    @Published private(set) var status: UpdateStatus

    private let running: RunningCopy
    private let workspace: UpdateWorkspace?
    private let queue = DispatchQueue(label: "io.github.qaws81877.fixdock.update", qos: .utility)
    private var timer: Timer?
    /// The attempt whose download or verification is in flight. A callback for
    /// any other attempt (a cancelled one) only sweeps.
    private var activeAttempt: UpdateWorkspace.Attempt?
    private var started = false

    private init() {
        let workspace = UpdateWorkspace.forRunningApp()
        let running = RunningCopy.inspect(workspace: workspace)
        let defaults = UserDefaults.standard
        self.workspace = workspace
        self.running = running
        status = UpdateStatus(
            mode: running.mode,
            lastChecked: defaults.object(forKey: DefaultsKey.updateLastCheckedAt) as? Date,
            quietVersion: SemanticVersion(defaults.string(forKey: DefaultsKey.updateQuietVersion)))
    }

    // MARK: Verbs

    /// End of applicationDidFinishLaunching. Always settles the last attempt
    /// (confirming this launch when it is the new version); schedules checks
    /// only when the mode is not inert, so those builds never connect.
    func start() {
        guard !started else { return }
        started = true
        reconcileLastAttempt()
        guard status.canStartCheck else { return }
        configureTimer()
        if automaticChecks {
            DispatchQueue.main.asyncAfter(deadline: .now() + UpdatePolicy.firstCheckDelay) { [weak self] in
                self?.check(manual: false)
            }
        }
    }

    /// Settings "Check now" and "Check for Updates…". Failures show.
    func checkNow() { check(manual: true) }

    /// Panel open. Silent, and only when automatic checks are on and the last
    /// good check is stale.
    func checkIfStale() {
        guard started, automaticChecks,
              UpdatePolicy.isStale(lastChecked: status.lastChecked, now: Date()) else { return }
        check(manual: false)
    }

    /// Download, verify, hand off, quit. Every failure before the handoff
    /// leaves the app running with the offer and `problem = .install(...)`.
    func install() {
        guard status.canInstall, let offer = status.offer, let workspace else { return }
        if let busy = blockingWork() {
            send(.installFailed(.busy(busy)))
            return
        }
        send(.installStarted)
        sweep()
        let attempt: UpdateWorkspace.Attempt
        do { attempt = try workspace.beginAttempt() } catch {
            fail(error)
            return
        }
        activeAttempt = attempt
        UpdateTransport.shared.download(offer, into: attempt, progress: { [weak self] fraction in
            guard let self, self.activeAttempt?.token == attempt.token else { return }
            self.send(.installProgressed(.downloading(fraction: fraction)))
        }, completion: { [weak self] result in
            guard let self else { return }
            guard self.activeAttempt?.token == attempt.token else {
                self.sweep()
                return
            }
            switch result {
            case .failure(let failure):
                self.fail(failure)
            case .success(let archive):
                self.send(.installProgressed(.verifying))
                let running = self.running
                self.queue.async {
                    let verified = Result {
                        try UpdateVerifier.extractAndVerify(archive: archive, offer: offer,
                                                            attempt: attempt, running: running)
                    }
                    DispatchQueue.main.async { self.hand(off: verified, workspace: workspace) }
                }
            }
        })
    }

    /// Only while downloading. The attempt is swept once the transfer stops.
    func cancelDownload() {
        guard status.canCancel, activeAttempt != nil else { return }
        activeAttempt = nil
        UpdateTransport.shared.cancelDownload()
        send(.installCancelled)
    }

    /// The About toggle writes the default and calls this.
    func automaticChecksChanged() {
        guard started else { return }
        configureTimer()
        checkIfStale()
    }

    // MARK: Internals

    private var automaticChecks: Bool {
        UserDefaults.standard.bool(forKey: DefaultsKey.updateAutomaticChecks)
    }

    private func check(manual: Bool) {
        guard status.canStartCheck, let current = running.version else { return }
        send(.checkStarted(manual: manual))
        UpdateTransport.shared.fetchFeed { [weak self] result in
            guard let self else { return }
            let outcome: FeedOutcome
            switch result {
            case .failure(let failure):
                outcome = .failed(failure)
            case .success(let response):
                outcome = UpdatePolicy.evaluateFeed(response, running: current,
                                                    location: UpdateTransport.shared.location)
            }
            self.send(.checkFinished(outcome, manual: manual, at: Date()))
            if let date = self.status.lastChecked {
                UserDefaults.standard.set(date, forKey: DefaultsKey.updateLastCheckedAt)
            }
        }
    }

    private func hand(off verified: Result<VerifiedUpdate, Error>, workspace: UpdateWorkspace) {
        guard case .success(let update) = verified else {
            if case .failure(let error) = verified { fail(error) }
            return
        }
        // Something may have started while the download ran.
        if let busy = blockingWork() {
            fail(InstallFailure.busy(busy))
            return
        }
        send(.installProgressed(.restarting))
        do { try Relauncher.replaceAndRelaunch(with: update, workspace: workspace) } catch {
            fail(error)
            return
        }
        NSApp.terminate(nil)
    }

    private func fail(_ error: Error) {
        activeAttempt = nil
        send(.installFailed(error as? InstallFailure ?? .extractFailed))
        sweep()
    }

    /// Hourly on the main run loop, as upstream; off when automatic checks are.
    private func configureTimer() {
        timer?.invalidate()
        timer = nil
        if case .inert = status.mode { return }
        guard automaticChecks else { return }
        let timer = Timer(timeInterval: UpdatePolicy.automaticInterval, repeats: true) { [weak self] _ in
            self?.check(manual: false)
        }
        timer.tolerance = 5 * 60
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Every mode runs this; a build that never installs finds nothing.
    private func reconcileLastAttempt() {
        guard let workspace, let (attempt, record) = workspace.pendingAttempt() else {
            sweep()
            return
        }
        let outcome = UpdatePolicy.launchOutcome(record: record, report: workspace.readReport(in: attempt),
                                                 confirmed: workspace.isConfirmed(attempt),
                                                 running: running.version, now: Date())
        switch outcome {
        case .nothingPending:
            sweep()
        case .confirm(_, let version):
            workspace.confirmLaunch(of: attempt)
            send(.previousAttempt(.updated(version)))
            // The helper is polling for the marker; give it time to report.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.sweep() }
        case .helperMayBeRunning:
            break
        case .finished(let notice):
            send(.previousAttempt(notice))
            if case .rolledBack(let version)? = notice {
                UserDefaults.standard.set(version.description, forKey: DefaultsKey.updateQuietVersion)
                send(.quieted(version))
            }
            sweep()
        }
    }

    /// The one sweep call. The attempt in flight is never removed.
    private func sweep() {
        workspace?.sweep(running: running.version, installTarget: running.bundleURL.path,
                         keeping: activeAttempt?.token, now: Date())
    }

    /// Work that quitting would destroy. Read only for installed tools, so no
    /// service is created here.
    private func blockingWork() -> BusyWork? {
        let installed = Set(FeatureRuntime.shared.installedFeatures)
        if installed.contains(.screenRecorder), ScreenRecorderService.shared.isRecording { return .recording }
        if installed.contains(.mediaTools), MediaService.shared.isRunning { return .mediaJob }
        if installed.contains(.cleaningMode), CleaningModeManager.shared.isActive { return .cleaningMode }
        return nil
    }

    /// The only writer of `status`.
    private func send(_ event: UpdateEvent) {
        dispatchPrecondition(condition: .onQueue(.main))
        status.apply(event)
    }
}
