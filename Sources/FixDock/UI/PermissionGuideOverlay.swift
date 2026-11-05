// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import AppKit
import ApplicationServices
import Combine
import SwiftUI

/// The guide shown after a permission request sends the person to System
/// Settings. Accessibility, Screen Recording and Full Disk Access get a card
/// with the running app's icon to drag into the privacy list, placed beside
/// the Settings window and with the list spotlit when it can be found. A
/// refused microphone and system audio keep the three-step card. Hidden
/// while onboarding is up.
///
/// The guide only reads System Settings: window bounds and the geometry of
/// its scroll areas. It never moves the window, presses a control or sets
/// an accessibility value, and it never reads row names or switch values,
/// so the person, not the app, decides what the list shows.
final class PermissionGuideOverlay {
    static let shared = PermissionGuideOverlay()
    static var suppressed = false

    private var session: GuideSession?

    private init() {}

    /// Asking again for the kind on screen (a second click, Start over)
    /// resets that card in place.
    func show(for kind: PermissionKind) {
        guard !Self.suppressed else { return }
        if let session, session.kind == kind {
            session.restart()
            return
        }
        session?.end()
        let next = GuideSession(kind: kind) { [weak self] finished in
            // A replaced session must not close its successor.
            guard let self, self.session === finished else { return }
            self.dismiss()
        }
        session = next
        next.start()
    }

    func dismiss() {
        session?.end()
        session = nil
    }
}

// MARK: - Route

private struct GuideRoute {
    enum Style { case drag, steps }
    enum AfterGrant: Equatable {
        case close(after: TimeInterval)
        case relaunch
    }

    let style: Style
    let afterGrant: AfterGrant
    /// Drag: find the icon and drop (about 5 s), then Touch ID or a
    /// password (5 to 15 s), then one poll (2.5 s). 12 s fired during
    /// authentication; 30 s clears it and still helps someone stuck on a
    /// dead switch. Re-armed on every drop.
    let staleAfter: TimeInterval
    /// The privacy list System Settings opens. System audio opens the
    /// Screen Recording list.
    let listName: KeyPath<Strings, String>
    let granted: Published<Bool>.Publisher

    init(_ kind: PermissionKind) {
        let permissions = Permissions.shared
        switch kind {
        case .accessibility:
            style = .drag
            afterGrant = .close(after: 1.6)
            staleAfter = 30
            listName = \.permissionAccessibility
            granted = permissions.$accessibility
        case .screenRecording:
            style = .drag
            afterGrant = .relaunch
            staleAfter = 30
            listName = \.permissionScreenRecording
            granted = permissions.$screenRecording
        case .fullDiskAccess:
            style = .drag
            afterGrant = .relaunch
            staleAfter = 30
            listName = \.permissionFullDiskAccess
            granted = permissions.$fullDiskAccess
        case .microphone:
            // Reaches the guide only when already refused; the first ask is
            // the system prompt.
            style = .steps
            afterGrant = .relaunch
            staleAfter = 12
            listName = \.recorderPermissionMicrophone
            granted = permissions.$microphone
        case .audioCapture:
            style = .steps
            afterGrant = .relaunch
            staleAfter = 12
            listName = \.permissionScreenRecording
            granted = permissions.$audioCapture
        }
    }
}

// MARK: - Scene

extension PermissionGuideOverlay {
    /// One tick's view of the System Settings window, in AppKit global
    /// coordinates. Geometry only: there is no field for a row's name or a
    /// switch's value.
    struct Sighting: Equatable {
        enum ListArea: Equatable {
            /// The list's scroll area (needs Accessibility).
            case found(CGRect)
            /// A finished walk found no list: another pane is open.
            case absent
            /// No Accessibility, or the walk failed or ran out of budget.
            case unread
        }

        var window: CGRect
        var list: ListArea
        var sheetOpen: Bool
        /// Same frame as the previous tick.
        var settled: Bool
        var frontmost: Bool
    }

    struct Display: Equatable {
        var frame: CGRect
        var visibleFrame: CGRect
    }

    struct Scene: Equatable {
        struct Dim: Equatable {
            /// The display holding most of the Settings window.
            var screen: CGRect
            var hole: CGRect
        }

        /// nil: leave the card where it is.
        var cardOrigin: CGPoint?
        var dim: Dim?

        /// Measured on macOS 27.2; used only when Accessibility is missing.
        static let assumedSidebarWidth: CGFloat = 232
        static let holeOutset: CGFloat = 4
        static let cardGap: CGFloat = 12
        static let cornerInset: CGFloat = 20

        static func compute(granted: Bool,
                            sighting: Sighting?,
                            cardSize: CGSize,
                            displays: [Display],
                            fallback: Display) -> Scene {
            guard let sighting,
                  let display = displays.max(by: {
                      overlap($0.frame, sighting.window) < overlap($1.frame, sighting.window)
                  }),
                  overlap(display.frame, sighting.window) > 0
            else {
                return Scene(cardOrigin: corners(card: cardSize, in: fallback.visibleFrame)[0], dim: nil)
            }

            let hole: CGRect?
            switch sighting.list {
            case .found(let rect): hole = rect
            case .unread: hole = contentArea(of: sighting.window)
            case .absent: hole = nil
            }

            var dim: Dim?
            if !granted, sighting.frontmost, sighting.settled, !sighting.sheetOpen, let hole {
                let cut = hole.insetBy(dx: -holeOutset, dy: -holeOutset).intersection(display.frame)
                if !cut.isEmpty { dim = Dim(screen: display.frame, hole: cut) }
            }

            guard sighting.settled else { return Scene(cardOrigin: nil, dim: dim) }
            let origin = beside(sighting.window, card: cardSize, in: display.visibleFrame)
                ?? firstCorner(avoiding: hole ?? sighting.window, card: cardSize, in: display.visibleFrame)
            return Scene(cardOrigin: origin, dim: dim)
        }

        /// The window minus the sidebar, or the whole window when the
        /// assumed sidebar would take half of it or more.
        static func contentArea(of window: CGRect) -> CGRect {
            guard assumedSidebarWidth * 2 < window.width else { return window }
            return CGRect(x: window.minX + assumedSidebarWidth, y: window.minY,
                          width: window.width - assumedSidebarWidth, height: window.height)
        }

        /// Right of the window, else left, top edges aligned and kept inside
        /// the visible frame; nil when neither side has room.
        static func beside(_ window: CGRect, card: CGSize, in visible: CGRect) -> CGPoint? {
            let right = window.maxX + cardGap
            let left = window.minX - cardGap - card.width
            let x: CGFloat
            if right + card.width <= visible.maxX {
                x = right
            } else if left >= visible.minX {
                x = left
            } else {
                return nil
            }
            let y = min(max(window.maxY - card.height, visible.minY), visible.maxY - card.height)
            return CGPoint(x: x.rounded(), y: y.rounded())
        }

        /// Top right, bottom right, top left, bottom left: the first that does
        /// not cover `hole`, else top right.
        static func firstCorner(avoiding hole: CGRect, card: CGSize, in visible: CGRect) -> CGPoint {
            let options = corners(card: card, in: visible)
            return options.first {
                !CGRect(origin: $0, size: card).intersects(hole)
            } ?? options[0]
        }

        private static func corners(card: CGSize, in visible: CGRect) -> [CGPoint] {
            let left = (visible.minX + cornerInset).rounded()
            let right = (visible.maxX - card.width - cornerInset).rounded()
            let bottom = (visible.minY + cornerInset).rounded()
            let top = (visible.maxY - card.height - cornerInset).rounded()
            return [CGPoint(x: right, y: top), CGPoint(x: right, y: bottom),
                    CGPoint(x: left, y: top), CGPoint(x: left, y: bottom)]
        }

        private static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
            let cut = a.intersection(b)
            return cut.isNull ? 0 : cut.width * cut.height
        }
    }
}

private extension PermissionGuideOverlay.Display {
    init(_ screen: NSScreen) {
        self.init(frame: screen.frame, visibleFrame: screen.visibleFrame)
    }

    static var main: Self {
        (NSScreen.main ?? NSScreen.screens.first).map(Self.init)
            ?? Self(frame: .zero, visibleFrame: .zero)
    }
}

// MARK: - Locator

/// Reads the System Settings window on each tick. Keeps only the chosen
/// window number, the last frame, and the accessibility window with its
/// last list read.
private struct SettingsLocator {
    typealias Sighting = PermissionGuideOverlay.Sighting

    static let bundleID = "com.apple.systempreferences"
    private static let listRereadAfter: TimeInterval = 1
    private static let messagingTimeout: Float = 0.2
    private static let walkDepth = 8
    private static let walkNodes = 300
    private static let walkTime: TimeInterval = 0.3

    private var windowNumber: CGWindowID?
    private var lastFrame: CGRect?
    private var axWindow: AXUIElement?
    private var listRead: (area: Sighting.ListArea, at: Date)?

    static var settingsIsFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID
    }

    mutating func sight() -> Sighting? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first else {
            forget()
            return nil
        }
        let pid = app.processIdentifier
        let windows = Self.layerZeroWindows(pid: pid)
        // An authentication sheet can be a second window of the same app, so
        // keep the window already chosen rather than the first match.
        guard let main = windows.first(where: { $0.number == windowNumber })
                ?? windows.max(by: { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height })
        else {
            forget()
            return nil
        }
        if main.number != windowNumber {
            axWindow = nil
            listRead = nil
        }
        windowNumber = main.number
        let settled = main.bounds == lastFrame
        lastFrame = main.bounds

        var sheetOpen = windows.contains { $0.number != main.number && main.bounds.contains($0.bounds) }
        var list = Sighting.ListArea.unread
        if AXIsProcessTrusted() {
            if axWindow == nil { axWindow = Self.axWindow(pid: pid, matching: main.bounds) }
            if let axWindow {
                sheetOpen = sheetOpen || Self.hasSheet(axWindow)
                if !settled || listRead.map({ Date().timeIntervalSince($0.at) >= Self.listRereadAfter }) ?? true {
                    listRead = (Self.readList(window: axWindow), Date())
                }
                list = listRead?.area ?? .unread
            }
        }

        let height = NSScreen.screens.first?.frame.height ?? 0
        if case .found(let rect) = list {
            list = .found(ScreenshotSupport.flipped(rect, mainScreenHeight: height))
        }
        return Sighting(window: ScreenshotSupport.flipped(main.bounds, mainScreenHeight: height),
                        list: list,
                        sheetOpen: sheetOpen,
                        settled: settled,
                        frontmost: app.isActive)
    }

    mutating func forget() {
        windowNumber = nil
        lastFrame = nil
        axWindow = nil
        listRead = nil
    }

    /// Bounds and owner are readable without Screen Recording; titles are
    /// not, and are never read.
    private static func layerZeroWindows(pid: pid_t) -> [(number: CGWindowID, bounds: CGRect)] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        return info.compactMap { entry in
            guard (entry[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (entry[kCGWindowLayer as String] as? Int) == 0,
                  (entry[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let number = entry[kCGWindowNumber as String] as? CGWindowID,
                  let bounds = (entry[kCGWindowBounds as String] as? NSDictionary)
                      .flatMap({ CGRect(dictionaryRepresentation: $0 as CFDictionary) }),
                  bounds.width > 100, bounds.height > 100
            else { return nil }
            return (number, bounds)
        }
    }

    /// Accessibility frames are top-left global, the same space as window
    /// bounds.
    private static func axWindow(pid: pid_t, matching bounds: CGRect) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        guard case .value(let value) = copy(app, kAXWindowsAttribute),
              let windows = value as? [AXUIElement] else { return nil }
        return windows.first { window in
            guard let frame = frame(of: window) else { return false }
            return abs(frame.minX - bounds.minX) <= 2 && abs(frame.minY - bounds.minY) <= 2
                && abs(frame.width - bounds.width) <= 2 && abs(frame.height - bounds.height) <= 2
        }
    }

    private static func hasSheet(_ window: AXUIElement) -> Bool {
        guard case .value(let value) = copy(window, kAXChildrenAttribute),
              let children = value as? [AXUIElement] else { return false }
        return children.contains { role(of: $0) == kAXSheetRole }
    }

    /// Breadth first from the window. The list is the first outline whose
    /// parent is a scroll area nested in another scroll area; the sidebar's
    /// outline sits in a scroll area that is not nested. Reads roles and
    /// frames only: titles are localized and rows are not the app's to read.
    private static func readList(window: AXUIElement) -> Sighting.ListArea {
        struct Node {
            let element: AXUIElement
            let depth: Int
            /// Scroll areas above this node, its parent included.
            let scrollAncestors: Int
            let parentIsScrollArea: Bool
            let parent: AXUIElement?
        }
        let deadline = Date().addingTimeInterval(walkTime)
        var queue = [Node(element: window, depth: 0, scrollAncestors: 0, parentIsScrollArea: false, parent: nil)]
        var next = 0
        while next < queue.count {
            guard next < walkNodes, Date() < deadline else { return .unread }
            let node = queue[next]
            next += 1
            guard let role = role(of: node.element) else { return .unread }
            if role == kAXOutlineRole, node.parentIsScrollArea, node.scrollAncestors >= 2, let parent = node.parent {
                return frame(of: parent).map { .found($0) } ?? .unread
            }
            guard node.depth < walkDepth else { continue }
            let children: [AXUIElement]
            switch copy(node.element, kAXChildrenAttribute) {
            case .value(let value): children = value as? [AXUIElement] ?? []
            case .missing: children = []
            case .failed: return .unread
            }
            let isScrollArea = role == kAXScrollAreaRole
            for child in children {
                queue.append(Node(element: child,
                                  depth: node.depth + 1,
                                  scrollAncestors: node.scrollAncestors + (isScrollArea ? 1 : 0),
                                  parentIsScrollArea: isScrollArea,
                                  parent: node.element))
            }
        }
        return .absent
    }

    private enum Read {
        case value(CFTypeRef)
        case missing
        case failed
    }

    /// The timeout keeps a busy Settings from stalling the main thread.
    private static func copy(_ element: AXUIElement, _ attribute: String) -> Read {
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        var value: CFTypeRef?
        switch AXUIElementCopyAttributeValue(element, attribute as CFString, &value) {
        case .success: return value.map { .value($0) } ?? .missing
        case .noValue, .attributeUnsupported: return .missing
        default: return .failed
        }
    }

    private static func role(of element: AXUIElement) -> String? {
        guard case .value(let value) = copy(element, kAXRoleAttribute) else { return nil }
        return value as? String
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        guard case .value(let position) = copy(element, kAXPositionAttribute),
              case .value(let size) = copy(element, kAXSizeAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID()
        else { return nil }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
              AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: origin, size: extent)
    }
}

// MARK: - Session

/// One guide on screen. `end()` is the only teardown.
private final class GuideSession {
    typealias Scene = PermissionGuideOverlay.Scene
    typealias Sighting = PermissionGuideOverlay.Sighting
    typealias Display = PermissionGuideOverlay.Display

    let kind: PermissionKind
    private let route: GuideRoute
    private let model = GuideModel()
    private let onFinish: (GuideSession) -> Void

    private var card: OverlayPanel?
    private var dim: DimPanel?
    private var locator = SettingsLocator()
    private var lastSighting: Sighting?
    private var lastScene: Scene?
    /// Where the session last put the card. A card found elsewhere was moved
    /// by the person, and stays where they put it.
    private var placedOrigin: CGPoint?
    private var personMovedCard = false

    private var tick: Timer?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var grantWatch: AnyCancellable?
    private var sizeWatch: AnyCancellable?
    private var staleWork: DispatchWorkItem?
    private var closeWork: DispatchWorkItem?
    private var ended = false

    private static let tickInterval: TimeInterval = 0.25
    private static let minimumCardSize = CGSize(width: 320, height: 180)

    init(kind: PermissionKind, onFinish: @escaping (GuideSession) -> Void) {
        self.kind = kind
        self.route = GuideRoute(kind)
        self.onFinish = onFinish
    }

    func start() {
        let card = makeCard()
        self.card = card
        fitCard()
        let scene = Scene.compute(granted: false, sighting: nil, cardSize: card.frame.size,
                                  displays: [], fallback: .main)
        if let origin = scene.cardOrigin { place(card, at: origin) }
        card.orderFrontRegardless()
        Permissions.shared.setGuideVisible(true)

        grantWatch = route.granted
            .removeDuplicates()
            .filter { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.grantSeen() }
        sizeWatch = model.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.fitCard() }
        armStale()

        if route.style == .drag {
            observeWorkspace()
            startTracking()
        }
    }

    func restart() {
        guard !ended else { return }
        closeWork?.cancel()
        closeWork = nil
        model.granted = Permissions.shared.isGranted(kind)
        model.stale = false
        model.dropped = false
        personMovedCard = false
        lastScene = nil
        armStale()
        card?.orderFrontRegardless()
        startTracking()
    }

    func end() {
        guard !ended else { return }
        ended = true
        stopTracking()
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceObservers = []
        staleWork?.cancel()
        staleWork = nil
        closeWork?.cancel()
        closeWork = nil
        grantWatch = nil
        sizeWatch = nil
        card?.orderOut(nil)
        card = nil
        dim?.orderOut(nil)
        dim = nil
        Permissions.shared.setGuideVisible(false)
    }

    // MARK: Tracking

    private func startTracking() {
        guard !ended, route.style == .drag, !model.granted, tick == nil,
              SettingsLocator.settingsIsFrontmost else { return }
        let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            self?.onTick()
        }
        tick = timer
        // `.common` keeps ticking while the icon is being dragged.
        RunLoop.main.add(timer, forMode: .common)
        onTick()
    }

    private func stopTracking() {
        tick?.invalidate()
        tick = nil
        dim?.orderOut(nil)
        lastScene = nil
    }

    private func onTick() {
        guard let card else { return }
        let sighting = locator.sight()
        lastSighting = sighting
        guard sighting != nil else {
            apply(Scene(cardOrigin: nil, dim: nil))
            return
        }
        apply(Scene.compute(granted: model.granted,
                            sighting: sighting,
                            cardSize: card.frame.size,
                            displays: NSScreen.screens.map(Display.init),
                            fallback: .main))
    }

    private func apply(_ scene: Scene) {
        guard scene != lastScene, let card else { return }
        lastScene = scene
        if let placed = placedOrigin,
           abs(card.frame.minX - placed.x) > 1 || abs(card.frame.minY - placed.y) > 1 {
            personMovedCard = true
        }
        if !personMovedCard, let origin = scene.cardOrigin {
            place(card, at: origin)
        }
        if let wanted = scene.dim {
            dimPanel().show(wanted)
        } else {
            dim?.orderOut(nil)
        }
    }

    private func place(_ card: NSPanel, at origin: CGPoint) {
        card.setFrameOrigin(origin)
        placedOrigin = origin
    }

    private func observeWorkspace() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if app?.bundleIdentifier == SettingsLocator.bundleID {
                self?.startTracking()
            } else {
                self?.stopTracking()
            }
        })
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == SettingsLocator.bundleID else { return }
            self?.stopTracking()
            self?.locator.forget()
            self?.lastSighting = nil
        })
    }

    // MARK: Events

    private func grantSeen() {
        guard !ended else { return }
        model.granted = true
        model.stale = false
        staleWork?.cancel()
        staleWork = nil
        stopTracking()
        if case .close(let delay) = route.afterGrant {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.onFinish(self)
            }
            closeWork?.cancel()
            closeWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    /// A drop outside the Settings window (Finder, the desktop) is not a
    /// grant attempt and changes nothing.
    private func dragEnded(at point: NSPoint) {
        guard !ended, !model.granted else { return }
        if let window = lastSighting?.window, !window.contains(point) { return }
        model.dropped = true
        model.stale = false
        armStale()
    }

    private func armStale() {
        staleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.model.stale = true }
        staleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + route.staleAfter, execute: work)
    }

    /// Keeps the card's top edge where it was.
    private func fitCard() {
        guard let card, let host = card.contentView else { return }
        let fitted = host.fittingSize
        let size = CGSize(width: max(fitted.width, Self.minimumCardSize.width),
                          height: max(fitted.height, Self.minimumCardSize.height))
        let old = card.frame
        guard old.size != size else { return }
        let wasPlaced = placedOrigin.map { abs($0.x - old.minX) <= 1 && abs($0.y - old.minY) <= 1 } ?? false
        card.setFrame(CGRect(x: old.minX, y: old.maxY - size.height, width: size.width, height: size.height),
                      display: true)
        if wasPlaced { placedOrigin = card.frame.origin }
        lastScene = nil
    }

    private func makeCard() -> OverlayPanel {
        let close: () -> Void = { [weak self] in
            guard let self else { return }
            self.onFinish(self)
        }
        let kind = kind
        let root: AnyView
        switch route.style {
        case .drag:
            root = AnyView(DragGuideCard(
                listName: route.listName,
                detail: kind.detail,
                relaunchAfterGrant: route.afterGrant == .relaunch,
                model: model,
                onDragEnded: { [weak self] point in self?.dragEnded(at: point) },
                onStartOver: { Permissions.shared.startOver(kind) },
                onRelaunch: { appDelegate()?.relaunch() },
                onClose: close))
        case .steps:
            root = AnyView(StepsGuideCard(
                listName: route.listName,
                relaunchAfterGrant: route.afterGrant == .relaunch,
                model: model,
                onStartOver: { Permissions.shared.startOver(kind) },
                onRelaunch: { appDelegate()?.relaunch() },
                onClose: close))
        }
        let host = NSHostingView(rootView: root)
        host.frame.size = Self.minimumCardSize
        let panel = OverlayPanel(contentRect: CGRect(origin: .zero, size: Self.minimumCardSize),
                                 styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered,
                                 defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .utilityWindow
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = host
        return panel
    }

    private func dimPanel() -> DimPanel {
        if let dim { return dim }
        let panel = DimPanel()
        dim = panel
        return panel
    }
}

private final class GuideModel: ObservableObject {
    @Published var granted = false
    /// Drag: emphasize "on, but nothing changes". Steps: show the hint.
    @Published var stale = false
    /// Drag: a drop landed on the Settings window; authentication is next.
    @Published var dropped = false
}

// MARK: - Dim

/// Click-through dim with a hole over the list. One level above normal
/// windows, so it covers System Settings and stays under the card.
private final class DimPanel: OverlayPanel {
    private let view = DimView()

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        ignoresMouseEvents = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        contentView = view
        setAccessibilityElement(false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show(_ dim: PermissionGuideOverlay.Scene.Dim) {
        if frame != dim.screen { setFrame(dim.screen, display: false) }
        view.hole = dim.hole.offsetBy(dx: -dim.screen.minX, dy: -dim.screen.minY)
        if !isVisible { orderFrontRegardless() }
    }
}

private final class DimView: NSView {
    var hole: CGRect = .zero {
        didSet { if hole != oldValue { needsDisplay = true } }
    }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let radius: CGFloat = 10
        let shade = NSBezierPath(rect: bounds)
        shade.appendRoundedRect(hole, xRadius: radius, yRadius: radius)
        shade.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(dark ? 0.45 : 0.35).setFill()
        shade.fill()
        let ring = NSBezierPath(roundedRect: hole.insetBy(dx: -1, dy: -1), xRadius: radius + 1, yRadius: radius + 1)
        ring.lineWidth = 2
        NSColor.controlAccentColor.setStroke()
        ring.stroke()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - Drag source

/// Drags the running bundle: the developer and the /Applications copies are
/// signed differently and each is granted on its own.
private struct AppIconDragSource: NSViewRepresentable {
    let ended: (NSPoint) -> Void

    func makeNSView(context: Context) -> AppIconDragView {
        let view = AppIconDragView()
        view.ended = ended
        return view
    }

    func updateNSView(_ nsView: AppIconDragView, context: Context) {
        nsView.ended = ended
    }
}

private final class AppIconDragView: NSView, NSDraggingSource {
    var ended: ((NSPoint) -> Void)?
    private var downAt: CGPoint?
    private let bundle = Bundle.main.bundleURL
    private let icon = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        toolTip = bundle.path
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(GuideApp.name)
    }

    required init?(coder: NSCoder) { nil }

    /// The card moves by its background; the icon must drag instead.
    override var mouseDownCanMoveWindow: Bool { false }
    /// The card never becomes key, so the first click has to start a drag.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func draw(_ dirtyRect: NSRect) {
        icon.draw(in: bounds)
    }

    override func mouseDown(with event: NSEvent) {
        downAt = event.locationInWindow
    }

    override func mouseUp(with event: NSEvent) {
        downAt = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = downAt else { return }
        let point = event.locationInWindow
        guard hypot(point.x - start.x, point.y - start.y) > 3 else { return }
        downAt = nil
        let item = NSDraggingItem(pasteboardWriter: bundle as NSURL)
        item.setDraggingFrame(bounds, contents: icon)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    /// Copy only: a stray drop on Finder or the Trash must never move or
    /// delete the running app.
    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        guard !operation.isEmpty else { return }
        ended?(screenPoint)
    }
}

private enum GuideApp {
    /// What the privacy list shows for this copy.
    static let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
        ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
        ?? AppInfo.name
}

// MARK: - Cards

private struct DragGuideCard: View {
    let listName: KeyPath<Strings, String>
    let detail: (Strings) -> String
    let relaunchAfterGrant: Bool
    @ObservedObject var model: GuideModel
    let onDragEnded: (NSPoint) -> Void
    let onStartOver: () -> Void
    let onRelaunch: () -> Void
    let onClose: () -> Void
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        let s = l10n.s
        VStack(alignment: .leading, spacing: 10) {
            GuideHeader(name: s[keyPath: listName], onClose: onClose)
            if model.granted {
                granted(s)
            } else {
                HStack(spacing: 12) {
                    AppIconDragSource(ended: onDragEnded)
                        .frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(GuideApp.name)
                            .font(.system(size: 13, weight: .semibold))
                        Text(s.guideDragLead)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    caseRow("plus.circle.fill", s.guideCaseMissingTitle, s.guideCaseMissingAction)
                    caseRow("switch.2", s.guideCaseOffTitle, s.guideCaseOffAction)
                    caseRow("arrow.counterclockwise.circle.fill", s.guideCaseStuckTitle, s.guideCaseStuckAction,
                            emphasized: model.stale) {
                        Button(s.guideStartOver, action: onStartOver)
                            .controlSize(.small)
                    }
                }
                HStack(spacing: 7) {
                    if model.dropped {
                        Image(systemName: "touchid")
                            .foregroundStyle(Color.accentColor)
                        Text(s.guideDragConfirm)
                            .font(.system(size: 12))
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        ProgressView().controlSize(.small)
                        Text(s.guideWaiting)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 340, alignment: .leading)
        .background(GuideCardBackground())
    }

    @ViewBuilder
    private func granted(_ s: Strings) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(s.guideGranted)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.green)
        }
        if relaunchAfterGrant {
            Text(detail(s))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(s.guideRelaunch, action: onRelaunch)
                .controlSize(.small)
        }
    }

    private func caseRow(_ symbol: String, _ title: String, _ action: String,
                         emphasized: Bool = false) -> some View {
        caseRow(symbol, title, action, emphasized: emphasized) { EmptyView() }
    }

    private func caseRow<Trailing: View>(_ symbol: String, _ title: String, _ action: String,
                                         emphasized: Bool = false,
                                         @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(Color.accentColor)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Text(action)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                trailing()
            }
        }
        .padding(emphasized ? 6 : 0)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.accentColor.opacity(emphasized ? 0.14 : 0))
        )
    }
}

/// A refused microphone and system audio: the three steps, the grant, and a
/// hint with Start over once the wait looks stale.
private struct StepsGuideCard: View {
    let listName: KeyPath<Strings, String>
    let relaunchAfterGrant: Bool
    @ObservedObject var model: GuideModel
    let onStartOver: () -> Void
    let onRelaunch: () -> Void
    let onClose: () -> Void
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        let guide = l10n.s
        VStack(alignment: .leading, spacing: 10) {
            GuideHeader(name: guide[keyPath: listName], onClose: onClose)
            VStack(alignment: .leading, spacing: 6) {
                stepRow(1, guide.guideStepOpen)
                stepRow(2, guide.guideStepToggle)
                stepRow(3, guide.guideStepReturn)
            }
            HStack(spacing: 7) {
                if model.granted {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(guide.guideGranted)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.green)
                    if relaunchAfterGrant {
                        Spacer(minLength: 8)
                        Button(guide.guideRelaunch, action: onRelaunch)
                            .controlSize(.small)
                    }
                } else {
                    ProgressView().controlSize(.small)
                    Text(guide.guideWaiting)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            if model.stale, !model.granted {
                VStack(alignment: .leading, spacing: 6) {
                    Text(guide.guideStaleHint)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(guide.guideStartOver, action: onStartOver)
                        .controlSize(.small)
                }
            }
        }
        .padding(14)
        .frame(width: 320, alignment: .leading)
        .background(GuideCardBackground())
    }

    private func stepRow(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number)")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 16, height: 16)
                .background(Circle().fill(Color.accentColor))
            Text(text)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct GuideHeader: View {
    let name: String
    let onClose: () -> Void
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "hand.raised.fill")
                .foregroundStyle(Color.accentColor)
            Text(l10n.s.guideTitle)
                .font(.system(size: 13, weight: .semibold))
            Text(name)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help(l10n.s.guideClose)
        }
    }
}

private struct GuideCardBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(.regularMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
            )
    }
}
