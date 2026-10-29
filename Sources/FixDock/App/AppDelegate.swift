// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import AppKit
import SwiftUI

func appDelegate() -> AppDelegate? {
    NSApp.delegate as? AppDelegate
}

/// Menu bar app lifecycle: status item, panel, settings, onboarding, and the
/// global shortcut. Feature services are not started here; the catalog only
/// records which tools a later build should load.
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?

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
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func closePopover() {
        popover?.performClose(nil)
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

    func popoverDidClose(_ notification: Notification) {
        MediaService.shared.setVisible(false, on: .panel)
    }

    func togglePopover() {
        guard let button = statusItem?.button else { return }
        let popover = self.popover ?? makePopover()
        self.popover = popover
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        MenuPanelExpansion.shared.resetToDefaults()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate()
    }

    func openSettings() {
        popover?.performClose(nil)
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

    /// Waits until this process is gone, then opens the same bundle. Screen
    /// Recording only applies to the new process.
    func relaunch() {
        let path = Bundle.main.bundlePath
        let pid = String(ProcessInfo.processInfo.processIdentifier)
        let script = """
        waited=0
        while kill -0 "$1" 2>/dev/null && [ "$waited" -lt 100 ]; do
          sleep 0.2
          waited=$((waited + 1))
        done
        kill -0 "$1" 2>/dev/null || /usr/bin/open "$2"
        """
        _ = try? DetachedProcess.spawn("/bin/sh", ["-c", script, "fixdock-relaunch", pid, path])
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
            let image = NSImage(systemSymbolName: "wrench.and.screwdriver",
                                accessibilityDescription: AppInfo.name)
                ?? NSImage(systemSymbolName: "wrench.fill",
                           accessibilityDescription: AppInfo.name)
            if let image {
                image.isTemplate = true
                image.size = NSSize(width: 18, height: 18)
                button.image = image
            }
            button.toolTip = statusTooltip
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item
    }

    private var statusTooltip: String {
        AppInfo.isDeveloperBuild ? "\(AppInfo.name) (Developer)" : L10n.shared.s.statusTooltip
    }

    private func makePopover() -> NSPopover {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        popover.animates = true
        popover.contentSize = NSSize(width: 320, height: 560)
        popover.contentViewController = NSHostingController(rootView: MenuPanelView())
        return popover
    }

    private func showContextMenu() {
        popover?.performClose(nil)
        let strings = L10n.shared.s
        let menu = NSMenu()
        let settings = NSMenuItem(title: strings.menuSettings,
                                  action: #selector(openSettingsFromMenu(_:)),
                                  keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
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
