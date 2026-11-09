// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import AppKit
import QuartzCore

/// Small, non-activating feedback panel. It is intentionally independent from
/// Settings so showing a confirmation never changes the target application.
final class QuitProtectionHUD {
    private static let minimumSize = CGSize(width: 300, height: 48)
    private static let textInset: CGFloat = 12
    private var size = QuitProtectionHUD.minimumSize
    private var panel: NSPanel?
    /// Shows recorded in the diagnostics journal this launch. The first few
    /// tell whether the pill reached the screen; more would only push the
    /// key tap history out of the journal.
    private var recordedShows = 0
    private static let recordedShowLimit = 20

    /// The confirmation lines are localized and formatted with the shortcut
    /// symbol, so their rendered width is only known at show time. The widest
    /// translations need more than the fixed 300pt panel left for text. The
    /// labels are asked rather than the strings measured, so whatever inset
    /// their cells add is inside the answer.
    private static func fittingSize(_ content: ContentView) -> CGSize {
        CGSize(width: max(minimumSize.width, (content.textWidth + textInset * 2).rounded(.up)),
               height: minimumSize.height + (content.showsProgress ? 8 : 0))
    }

    /// Answers the window server's view of a window: listed on screen, and
    /// its alpha. Replaceable so a harness can play a stuck window.
    var windowServerState: (Int) -> (onScreen: Bool, alpha: Double?) = { number in
        let server = (CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(max(number, 0)))
            as? [[String: Any]])?.first
        return ((server?[kCGWindowIsOnscreen as String] as? Bool) ?? false,
                server?[kCGWindowAlpha as String] as? Double)
    }
    /// While the screen is locked or the display sleeps, the window server
    /// keeps answering with the last state it composited, so nothing it says
    /// then is held against the panel.
    var windowServerIsCurrent: () -> Bool = {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        let locked = (session?["CGSSessionScreenIsLocked"] as? Bool) ?? false
        return !locked && CGDisplayIsAsleep(CGMainDisplayID()) == 0
    }
    /// Counts shows, so a check scheduled for one show never acts on a later
    /// one.
    private var showGeneration = 0
    /// Panels replaced this launch, recorded like the shows.
    private var recordedRecoveries = 0
    /// Long enough for the window server to list a freshly ordered window
    /// (about 90 ms on macOS 27), short of the 0.8 s default hold.
    private static let checkDelay: TimeInterval = 0.25
    /// When the last hide ordered the panel out. The window server can list a
    /// window it was just told to remove for a few frames.
    private var hiddenAt = Date.distantPast
    private var observers: [NSObjectProtocol] = []

    init() {
        // A panel kept across sleep, a lock or a display change can come back
        // as a window the window server no longer draws. While hidden it costs
        // nothing to build again, so the next show starts from a new one.
        let drop: (Notification) -> Void = { [weak self] note in
            self?.discardHiddenPanel(because: note.name.rawValue)
        }
        observers = [
            NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil, queue: .main, using: drop),
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.screensDidWakeNotification,
                object: nil, queue: .main, using: drop),
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.sessionDidBecomeActiveNotification,
                object: nil, queue: .main, using: drop),
        ]
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    private static func makePanel(size: CGSize) -> NSPanel {
        let panel = OverlayPanel(contentRect: CGRect(origin: .zero, size: size),
                                 styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered,
                                 defer: false)
        panel.contentView = ContentView(frame: CGRect(origin: .zero, size: size))
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        // No system fade on order in or out: a press shorter than the fade
        // cut it off, and the window server could keep the cut-off alpha
        // while AppKit still read 1, so later shows stayed invisible.
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary,
                                    .stationary, .ignoresCycle]
        return panel
    }

    func show(title: String, detail: String, holdDeadline: Date? = nil) {
        showGeneration += 1
        if let panel, panel.windowNumber <= 0 {
            discard(panel)
        }
        present(title: title, detail: detail, holdDeadline: holdDeadline)
        recordShow()
        let generation = showGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.checkDelay) { [weak self] in
            self?.check(generation: generation, title: title, detail: detail,
                        holdDeadline: holdDeadline)
        }
    }

    /// Puts the pill up from a known state every time: whatever a previous
    /// show, hide or check left behind is set again, not trusted.
    private func present(title: String, detail: String, holdDeadline: Date?) {
        if panel == nil { panel = Self.makePanel(size: size) }
        guard let panel, let content = panel.contentView as? ContentView else { return }
        // Fill the labels first: the width comes out of them, not out of a
        // separate measurement of the same strings.
        content.update(title: title, detail: detail, showsProgress: holdDeadline != nil)
        size = Self.fittingSize(content)
        panel.setContentSize(size)
        positionPanel()
        panel.level = .statusBar
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        content.layoutSubtreeIfNeeded()
        content.animateProgress(until: holdDeadline)
        // Event taps can arrive between normal AppKit drawing passes. Draw now
        // so a short confirmation never waits for another app event to appear.
        panel.display()
    }

    /// A moment after a show, compares what AppKit holds with what the window
    /// server draws. A pill still meant to be up that is not on screen at full
    /// alpha is replaced by a new panel and shown again, once per show. A
    /// hidden pill the window server still lists is dropped, so the next show
    /// builds a new one. Either way the diagnostics journal says so.
    private func check(generation: Int, title: String, detail: String, holdDeadline: Date?) {
        guard generation == showGeneration, let panel, windowServerIsCurrent() else { return }
        let state = windowServerState(panel.windowNumber)
        let alpha = state.alpha.map { String(format: "%.2f", $0) } ?? "none"
        if panel.isVisible {
            guard !state.onScreen || (state.alpha ?? 0) < 0.9 else { return }
            let old = panel.windowNumber
            discard(panel)
            let deadline = holdDeadline.flatMap { $0.timeIntervalSinceNow > 0 ? $0 : nil }
            present(title: title, detail: detail, holdDeadline: deadline)
            recordRecovery("quit HUD recovered: window \(old) shown but window server on screen "
                + "\(state.onScreen) alpha \(alpha); new window \(self.panel?.windowNumber ?? 0)")
        } else if state.onScreen, Date().timeIntervalSince(hiddenAt) >= 0.1 {
            let old = panel.windowNumber
            discard(panel)
            recordRecovery("quit HUD recovered: window \(old) hidden but window server on screen "
                + "alpha \(alpha); dropped for a new panel next time")
        }
    }

    private func discardHiddenPanel(because reason: String) {
        guard let panel, !panel.isVisible else { return }
        discard(panel)
        KeyTapHealth.note("quit HUD panel dropped after \(reason)")
    }

    private func discard(_ old: NSPanel) {
        (old.contentView as? ContentView)?.stopProgress()
        old.orderOut(nil)
        old.close()
        if panel === old { panel = nil }
    }

    private func recordRecovery(_ message: String) {
        guard recordedRecoveries < Self.recordedShowLimit else { return }
        recordedRecoveries += 1
        KeyTapHealth.note(message, error: true)
    }

    /// Whether the pill actually reached the screen, right after the order and
    /// a quarter second later, with the app in front: on one Mac it showed
    /// over Chrome only. Nothing typed is recorded.
    private func recordShow() {
        guard recordedShows < Self.recordedShowLimit else { return }
        recordedShows += 1
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"
        record("shown over \(front) on macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.record("0.25 s later")
        }
    }

    private func record(_ moment: String) {
        guard let panel else { return }
        let number = panel.windowNumber
        let server = (CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(max(number, 0)))
            as? [[String: Any]])?.first
        let onScreen = (server?[kCGWindowIsOnscreen as String] as? Bool) ?? false
        let alpha = (server?[kCGWindowAlpha as String] as? Double).map { String(format: "%.2f", $0) } ?? "none"
        let screen = panel.screen.map { NSStringFromRect($0.frame) } ?? "none"
        KeyTapHealth.note("quit HUD \(moment): window \(number), visible \(panel.isVisible), "
            + "occlusion visible \(panel.occlusionState.contains(.visible)), "
            + "window server on screen \(onScreen) alpha \(alpha), "
            + "frame \(NSStringFromRect(panel.frame)), screen \(screen)")
    }

    func hide() {
        (panel?.contentView as? ContentView)?.stopProgress()
        panel?.orderOut(nil)
        hiddenAt = Date()
    }

    private func positionPanel() {
        guard let panel,
              let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) })
                ?? NSScreen.main
                ?? NSScreen.screens.first
        else { return }
        let frame = screen.visibleFrame
        panel.setFrameOrigin(CGPoint(x: (frame.midX - size.width / 2).rounded(),
                                     y: (frame.minY + 18).rounded()))
    }

    private final class ContentView: NSView {
        private let title = NSTextField(labelWithString: "")
        private let detail = NSTextField(labelWithString: "")
        private let progressTrack = CALayer()
        private let progressFill = CALayer()

        var showsProgress: Bool { !progressTrack.isHidden }

        /// Width the two labels need for what they currently hold, straight
        /// from the cells that draw them.
        var textWidth: CGFloat {
            max(title.fittingSize.width, detail.fittingSize.width)
        }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            title.font = .systemFont(ofSize: 13, weight: .semibold)
            title.textColor = .white
            title.alignment = .center
            detail.font = .systemFont(ofSize: 10.5)
            detail.textColor = .white.withAlphaComponent(0.68)
            detail.alignment = .center
            addSubview(title)
            addSubview(detail)
            progressTrack.backgroundColor = NSColor.white.withAlphaComponent(0.16).cgColor
            progressTrack.cornerRadius = 1.5
            progressTrack.masksToBounds = true
            // Visibility must change with the labels, even for a 250 ms hold.
            progressTrack.actions = ["hidden": NSNull()]
            progressTrack.isHidden = true
            progressFill.backgroundColor = NSColor.white.withAlphaComponent(0.8).cgColor
            progressFill.anchorPoint = CGPoint(x: 0, y: 0.5)
            progressTrack.addSublayer(progressFill)
            layer?.addSublayer(progressTrack)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        override func layout() {
            super.layout()
            let inset = QuitProtectionHUD.textInset
            let offset: CGFloat = showsProgress ? 8 : 0
            title.frame = CGRect(x: inset, y: 23 + offset, width: bounds.width - inset * 2, height: 17)
            detail.frame = CGRect(x: inset, y: 7 + offset, width: bounds.width - inset * 2, height: 14)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            progressTrack.frame = CGRect(x: 24, y: 7, width: bounds.width - 48, height: 3)
            progressFill.frame = progressTrack.bounds
            CATransaction.commit()
        }

        func update(title: String, detail: String, showsProgress: Bool) {
            stopProgress()
            progressTrack.isHidden = !showsProgress
            self.title.stringValue = title
            self.detail.stringValue = detail
            setAccessibilityLabel([title, detail].filter { !$0.isEmpty }.joined(separator: ". "))
            needsLayout = true
            // The pill is drawn from bounds, so a width change has to repaint.
            needsDisplay = true
        }

        func animateProgress(until deadline: Date?) {
            guard let deadline else { return }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return }
            let animation = CABasicAnimation(keyPath: "transform.scale.x")
            animation.fromValue = 0
            animation.toValue = 1
            animation.duration = remaining
            animation.timingFunction = CAMediaTimingFunction(name: .linear)
            progressFill.add(animation, forKey: "holdProgress")
        }

        func stopProgress() {
            progressFill.removeAnimation(forKey: "holdProgress")
            progressTrack.isHidden = true
        }

        override func draw(_ dirtyRect: NSRect) {
            let body = bounds.insetBy(dx: 0.5, dy: 0.5)
            let path = NSBezierPath(roundedRect: body,
                                    xRadius: body.height / 2,
                                    yRadius: body.height / 2)
            NSColor(calibratedWhite: 0.09, alpha: 0.95).setFill()
            path.fill()
            NSColor.white.withAlphaComponent(0.16).setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }
}
