// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

func appDelegate() -> AppDelegate? {
    NSApp.delegate as? AppDelegate
}

/// Menu bar app lifecycle: status item, panel, settings, onboarding, and the
/// global shortcut. Feature services are not started here; the catalog only
/// records which tools a later build should load.
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSPopoverDelegate,
                         NSMenuItemValidation {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    /// Installed while the panel is shown, removed in `popoverDidClose`.
    private var popoverOutsideClickMonitor: Any?
    private var popoverKeyMonitor: Any?
    private var popoverResignObserver: NSObjectProtocol?
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var updateWindow: NSWindow?
    private var updateAttention: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(languageChanged),
            name: .fixDockLanguageChanged,
            object: nil
        )
        installStatusItem()
        HotkeyManager.shared.onActivate = { [weak self] in
            self?.togglePopover()
        }
        HotkeyManager.shared.sync()
        LaunchAtLogin.repairAtStartup()
        Permissions.shared.refresh()
        FeatureRuntime.shared.syncAtLaunch()
        SettingsNavigator.shared.syncAtLaunch()
        if !UserDefaults.standard.bool(forKey: DefaultsKey.onboardingComplete) {
            showOnboarding()
        }
        // Last: a just-installed version confirms here that it launched.
        UpdateService.shared.start()
        updateAttention = UpdateService.shared.$status
            .map(\.wantsAttention)
            .removeDuplicates()
            .sink { [weak self] in self?.applyStatusImage(attention: $0) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Closes the panel whatever it is showing. `close()` rather than
    /// `performClose`: the panel decides its own closing (application-
    /// defined), and a close the app asks for must not be refused.
    func closePopover() {
        guard let popover, popover.isShown else { return }
        popover.close()
    }

    /// Runs a modal (an open panel) started from the menu panel: the panel
    /// steps aside while it is up and comes back when it closes, so the work
    /// the modal starts is in view.
    func hidingPopover<T>(_ body: () -> T) -> T {
        guard let popover, popover.isShown else { return body() }
        popover.close()
        let result = body()
        togglePopover()
        return result
    }

    func popoverDidShow(_ notification: Notification) {
        MediaService.shared.setVisible(true, on: .panel)
    }

    /// A closed popover keeps its SwiftUI views, so nothing in the panel sees
    /// `onDisappear`; everything tied to the panel being up ends here.
    func popoverDidClose(_ notification: Notification) {
        removePopoverMonitors()
        MediaService.shared.setVisible(false, on: .panel)
    }

    func togglePopover() {
        guard let button = statusItem?.button else { return }
        let popover = self.popover ?? makePopover()
        self.popover = popover
        if popover.isShown {
            popover.close()
            return
        }
        // The panel measures itself against this while the popover lays
        // out, so it has to be known before the content is asked its size.
        PanelInteractionState.shared.anchorScreen = button.window?.screen ?? NSScreen.withMenuBar
        Permissions.shared.refresh()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        guard popover.isShown else { return }
        if let window = popover.contentViewController?.view.window {
            // Keep the panel next to full-screen apps and on any Space.
            window.collectionBehavior.insert([.fullScreenAuxiliary, .canJoinAllSpaces])
            window.makeKey()
        }
        NSApp.activate()
        installPopoverMonitors()
        UpdateService.shared.checkIfStale()
    }

    // MARK: - Panel closing (application-defined, as upstream)

    /// A click in another app or on the desktop closes the panel, and so
    /// does switching to another app, unless a sub-view keeps it open (a
    /// file dragged from Finder onto the media drop zone starts with a
    /// click there). Escape in the panel closes it in every case.
    private func installPopoverMonitors() {
        removePopoverMonitors()
        // A global monitor only sees events delivered to other apps.
        popoverOutsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            guard let self else { return }
            if let frame = self.statusItem?.button?.window?.frame,
               NSMouseInRect(NSEvent.mouseLocation, frame, false) { return }
            self.closePopoverUnlessKeptOpen()
        }
        popoverKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handlePopoverKeyDown(event)
        }
        popoverResignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.closePopoverUnlessKeptOpen()
        }
    }

    private func removePopoverMonitors() {
        if let monitor = popoverOutsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            popoverOutsideClickMonitor = nil
        }
        if let monitor = popoverKeyMonitor {
            NSEvent.removeMonitor(monitor)
            popoverKeyMonitor = nil
        }
        if let observer = popoverResignObserver {
            NotificationCenter.default.removeObserver(observer)
            popoverResignObserver = nil
        }
    }

    private func closePopoverUnlessKeptOpen() {
        guard popover?.isShown == true,
              !PanelInteractionState.shared.preventsPopoverDismissal else { return }
        closePopover()
    }

    private func handlePopoverKeyDown(_ event: NSEvent) -> NSEvent? {
        guard let popover, popover.isShown, event.keyCode == UInt16(kVK_Escape),
              let window = popover.contentViewController?.view.window,
              // Escape in another window (Settings, a picker's menu) stays there.
              event.window === window else { return event }
        // While an input method is composing, Escape belongs to it and drops
        // the candidate; the panel closes on the next one.
        if (window.firstResponder as? NSTextView)?.hasMarkedText() == true { return event }
        closePopover()
        return nil
    }

    func openSettings() {
        closePopover()
        SettingsNavigator.shared.resetExpansion()
        let window = settingsWindow ?? makeSettingsWindow()
        settingsWindow = window
        window.title = L10n.shared.s.settingsTitle
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        if case .feature(let page) = SettingsNavigator.shared.destination, page.feature == .mediaTools {
            MediaService.shared.setVisible(true, on: .settings)
        }
    }

    func showOnboarding() {
        PermissionGuideOverlay.suppressed = true
        let window = onboardingWindow ?? makeOnboardingWindow()
        onboardingWindow = window
        window.title = L10n.shared.s.onboardingWelcomeTitle
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func finishOnboarding() {
        UserDefaults.standard.set(true, forKey: DefaultsKey.onboardingComplete)
        PermissionGuideOverlay.suppressed = false
        let window = onboardingWindow
        onboardingWindow = nil
        window?.delegate = nil
        window?.close()
    }

    /// Quits and comes back through `Relauncher`. Screen Recording only
    /// applies to the new process.
    func relaunch() {
        Relauncher.relaunch()
        NSApp.terminate(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === onboardingWindow {
            PermissionGuideOverlay.suppressed = false
            onboardingWindow = nil
        }
        // The window is kept and reused, so its pages never see onDisappear.
        if window === settingsWindow {
            MediaService.shared.setVisible(false, on: .settings)
        }
        if window === updateWindow {
            updateWindow = nil
        }
    }

    // MARK: - Updates

    /// The one entry for the banner, the About button and the menu item: the
    /// release page for a copy that cannot update in place, the preview window
    /// when the person wants the notes first, else the install itself. While
    /// an install runs, the preview window shows its progress.
    func presentUpdate() {
        switch UpdateService.shared.status.phase {
        case .available(let offer, .releasePage):
            closePopover()
            NSWorkspace.shared.open(offer.releasePage)
        case .available(let offer, .inPlace):
            closePopover()
            if UserDefaults.standard.bool(forKey: DefaultsKey.updateShowNotesBeforeInstall) {
                showUpdatePreview(offer)
            } else {
                UpdateService.shared.install()
            }
        case .installing(let offer, _):
            closePopover()
            showUpdatePreview(offer)
        default:
            break
        }
    }

    func showUpdatePreview(_ offer: UpdateOffer) {
        updateWindow?.close()
        let view = UpdatePreviewView(offer: offer) { [weak self] in self?.updateWindow?.close() }
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.styleMask = [.titled, .closable]
        window.title = L10n.shared.s.updatesTitle
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        updateWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// An offer in hand opens it; otherwise Settings › About shows the check.
    @objc func checkForUpdatesFromMenu(_ sender: Any?) {
        if case .available = UpdateService.shared.status.phase {
            presentUpdate()
            return
        }
        SettingsNavigator.shared.open(.shell(.about))
        openSettings()
        UpdateService.shared.checkNow()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(checkForUpdatesFromMenu(_:)) else { return true }
        if case .installing = UpdateService.shared.status.phase { return false }
        return true
    }

    private func applyStatusImage(attention: Bool) {
        guard let button = statusItem?.button, let image = statusImage(attention: attention) else { return }
        button.image = image
    }

    private var updateMenuItem: NSMenuItem? {
        if case .inert = UpdateService.shared.status.mode { return nil }
        let item = NSMenuItem(title: L10n.shared.s.menuCheckForUpdates,
                              action: #selector(checkForUpdatesFromMenu(_:)),
                              keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func languageChanged() {
        installMainMenu()
        statusItem?.button?.toolTip = statusTooltip
        settingsWindow?.title = L10n.shared.s.settingsTitle
        onboardingWindow?.title = L10n.shared.s.onboardingWelcomeTitle
    }

    @objc private func statusItemClicked(_ sender: Any?) {
        guard let event = NSApp.currentEvent else {
            togglePopover()
            return
        }
        if event.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    @objc private func openSettingsFromMenu(_ sender: Any?) {
        openSettings()
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            if let image = statusImage(attention: false) {
                button.image = image
            }
            button.toolTip = statusTooltip
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item
    }

    /// The template mark, with a dot while an update waits.
    private func statusImage(attention: Bool) -> NSImage? {
        let image = (attention ? FixDockMark.attentionImage(size: 18) : FixDockMark.templateImage(size: 18))
            ?? NSImage(systemSymbolName: "wrench.and.screwdriver", accessibilityDescription: AppInfo.name)
        image?.isTemplate = true
        image?.size = NSSize(width: 18, height: 18)
        image?.accessibilityDescription = AppInfo.name
        return image
    }

    private var statusTooltip: String {
        AppInfo.isDeveloperBuild ? "\(AppInfo.name) (Developer)" : L10n.shared.s.statusTooltip
    }

    /// Application-defined, not transient: the panel closes on the outside
    /// clicks the monitors above decide on, so a sub-view can keep it open.
    /// Its size follows SwiftUI's, which `MenuPanelView` caps to the screen.
    private func makePopover() -> NSPopover {
        let popover = NSPopover()
        popover.behavior = .applicationDefined
        popover.delegate = self
        popover.animates = true
        let host = NSHostingController(rootView: MenuPanelView())
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        return popover
    }

    private func showContextMenu() {
        closePopover()
        let strings = L10n.shared.s
        let menu = NSMenu()
        let settings = NSMenuItem(title: strings.menuSettings,
                                  action: #selector(openSettingsFromMenu(_:)),
                                  keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
        if let update = updateMenuItem { menu.addItem(update) }
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: strings.menuQuit,
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "")
        quit.target = NSApp
        if let button = statusItem?.button, let event = NSApp.currentEvent {
            NSMenu.popUpContextMenu(menu, with: event, for: button)
        }
    }

    private func installMainMenu() {
        let strings = L10n.shared.s
        let main = NSMenu()

        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu(title: AppInfo.name)
        appItem.submenu = appMenu
        let settings = NSMenuItem(title: strings.menuSettings,
                                  action: #selector(openSettingsFromMenu(_:)),
                                  keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        if let update = updateMenuItem { appMenu.addItem(update) }
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: strings.menuQuit,
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: strings.menuEdit)
        editItem.submenu = edit
        edit.addItem(withTitle: strings.menuUndo, action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: strings.menuRedo, action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: strings.menuCut, action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: strings.menuCopy, action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: strings.menuPaste, action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: strings.menuSelectAll, action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        NSApp.mainMenu = main
    }

    private func makeSettingsWindow() -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 780, height: 540))
        window.minSize = NSSize(width: 680, height: 440)
        window.title = L10n.shared.s.settingsTitle
        window.isReleasedWhenClosed = false
        window.delegate = self
        return window
    }

    private func makeOnboardingWindow() -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: OnboardingView()))
        window.styleMask = [.titled, .closable]
        window.title = L10n.shared.s.onboardingWelcomeTitle
        window.isReleasedWhenClosed = false
        window.delegate = self
        return window
    }
}
