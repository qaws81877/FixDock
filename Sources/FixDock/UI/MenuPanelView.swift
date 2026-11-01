// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import AppKit
import SwiftUI

/// The menu bar panel, after upstream's: a header, one screen of cards with
/// uniform one-line rows ("Quick actions", then "On and off"), and a footer.
/// Media and the URL cleaner open as sub-views in place of the cards. Only
/// installed tools appear. The panel is as tall as its content up to the
/// menu bar screen's usable height, and scrolls only past that.
struct MenuPanelView: View {
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var runtime = FeatureRuntime.shared
    @ObservedObject private var interaction = PanelInteractionState.shared
    @ObservedObject private var updates = UpdateService.shared
    // Read in `body` so a reorder, hide or reset redraws the cards.
    @AppStorage(DefaultsKey.panelQuickActionsOrder) private var quickOrderRaw = ""
    @AppStorage(DefaultsKey.panelOnOffOrder) private var onOffOrderRaw = ""
    @AppStorage(DefaultsKey.panelHiddenRows) private var hiddenRaw = ""
    @State private var measuredHeight: CGFloat = 0
    @State private var editingCard: PanelCard?
    @State private var dragging: AppFeature?

    private static let panelWidth: CGFloat = 332
    private static let contentWidth: CGFloat = 308

    var body: some View {
        _ = (runtime.revision, quickOrderRaw, onOffOrderRaw, hiddenRaw)
        let strings = l10n.s
        return VStack(alignment: .leading, spacing: 12) {
            if updates.status.showsBanner {
                UpdateBanner()
            }
            header(strings)
            OverlayScrollView(measuredHeight: $measuredHeight) {
                content(strings)
                    .frame(width: Self.contentWidth)
            }
            .frame(width: Self.contentWidth, height: scrollHeight)
            footer(strings)
        }
        .padding(12)
        .frame(width: Self.panelWidth, height: panelHeight, alignment: .top)
    }

    // MARK: - Height

    /// Capped against the display the menu bar icon is on, which is not
    /// always the one holding the key window.
    private var maxHeight: CGFloat {
        let anchored = PanelInteractionState.shared.anchorScreen
            .flatMap { $0.isStillAttached ? $0 : nil }
        return PanelLayoutSupport.maxHeight(
            visibleHeight: (anchored ?? NSScreen.withMenuBar)?.visibleFrame.height)
    }

    private var scrollHeight: CGFloat {
        PanelLayoutSupport.scrollHeight(measured: measuredHeight, estimated: estimatedHeight,
                                        maxHeight: maxHeight, chrome: chrome)
    }

    private var panelHeight: CGFloat {
        PanelLayoutSupport.panelHeight(scrollHeight: scrollHeight, maxHeight: maxHeight, chrome: chrome)
    }

    private var chrome: CGFloat {
        PanelLayoutSupport.chromeHeight
            + (updates.status.showsBanner ? PanelLayoutSupport.updateBannerHeight : 0)
    }

    private var estimatedHeight: CGFloat {
        switch interaction.activeHostedTool {
        case .mediaTools: return 460
        case .urlCleaner: return 330
        default:
            return PanelLayoutSupport.estimatedContentHeight(
                rowsPerCard: PanelCard.allCases.map { rows(for: $0).count })
        }
    }

    // MARK: - Content

    @ViewBuilder
    private func content(_ strings: Strings) -> some View {
        if let hosted = interaction.activeHostedTool {
            subview(for: hosted)
        } else if !PanelCard.allCases.contains(where: { !installedOrder(for: $0).isEmpty }) {
            VStack(alignment: .leading, spacing: 4) {
                Text(strings.panelEmptyTitle)
                    .font(.system(size: 13, weight: .semibold))
                Text(strings.panelEmptyBody)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .panelCard()
        } else {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(PanelCard.allCases) { card in
                    if !installedOrder(for: card).isEmpty {
                        cardView(card, strings: strings)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func subview(for tool: AppFeature) -> some View {
        switch tool {
        case .mediaTools:
            PanelMediaView(onBack: closeSubview)
        default:
            PanelURLCleanerView(onBack: closeSubview)
        }
    }

    private func closeSubview() {
        interaction.hostedTool = nil
    }

    private func cardView(_ card: PanelCard, strings: Strings) -> some View {
        let editing = editingCard == card
        return VStack(alignment: .leading, spacing: 8) {
            PanelCardHeader(title: card.title(strings),
                            isEditing: editing,
                            toggleEditing: { editingCard = editing ? nil : card },
                            reset: { PanelLayout.reset(card) })
            PanelRowGroup(items: rows(for: card), showsDragHandles: editing) { feature in
                PanelReorderableItem(item: feature,
                                     isEnabled: editing,
                                     order: orderBinding(card),
                                     dragging: $dragging) {
                    PanelFeatureRow(feature: feature,
                                    isEditing: editing,
                                    visibility: visibilityBinding(feature),
                                    openSubview: { interaction.hostedTool = $0 })
                }
            }
        }
    }

    /// The card's installed tools in the saved order.
    private func installedOrder(for card: PanelCard) -> [AppFeature] {
        PanelLayout.order(card).filter(\.isAvailable)
    }

    /// What the card lists now: hidden rows only while it is edited.
    private func rows(for card: PanelCard) -> [AppFeature] {
        let ids = PanelLayoutSupport.visibleRows(order: installedOrder(for: card).map(\.rawValue),
                                                 hidden: PanelLayout.hidden(),
                                                 editing: editingCard == card)
        return ids.compactMap(AppFeature.init(rawValue:))
    }

    /// The whole saved order, uninstalled tools included, so moving a row
    /// keeps the place of a tool that is installed again later.
    private func orderBinding(_ card: PanelCard) -> Binding<[AppFeature]> {
        Binding {
            PanelLayout.order(card)
        } set: { order in
            PanelLayout.setOrder(order, for: card)
        }
    }

    private func visibilityBinding(_ feature: AppFeature) -> Binding<Bool> {
        Binding {
            !PanelLayout.isHidden(feature)
        } set: { visible in
            PanelLayout.setHidden(!visible, for: feature)
        }
    }

    // MARK: - Header and footer

    private func header(_ strings: Strings) -> some View {
        HStack(spacing: 10) {
            AppIconImage(size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(AppInfo.name)
                    .font(.system(size: 16, weight: .semibold))
                Text(String(format: strings.versionFormat, AppInfo.version))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func footer(_ strings: Strings) -> some View {
        HStack(spacing: 8) {
            footerButton(strings.menuSettings, systemImage: "gearshape") {
                // The hosted tool's own page, or the general one from the
                // cards: the destination is sticky, so it is set every time.
                if let page = PanelInteractionState.shared.hostedSettingsPage {
                    SettingsNavigator.shared.open(.feature(page))
                } else {
                    SettingsNavigator.shared.open(.shell(.general))
                }
                appDelegate()?.openSettings()
            }
            footerButton(strings.menuQuit, systemImage: "power") {
                NSApp.terminate(nil)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 30)
    }

    private func footerButton(_ title: String, systemImage: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .minimumScaleFactor(0.78)
                .labelStyle(.titleAndIcon)
                .padding(.horizontal, 7)
                .frame(maxWidth: .infinity, minHeight: 28)
                .modifier(PanelControlSurface(cornerRadius: 7))
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }
}

/// The small card fill and hairline behind the footer and back buttons.
private struct PanelControlSurface: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(PanelSurface.cardFill(for: colorScheme))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(PanelSurface.border(for: colorScheme), lineWidth: 0.7)
            )
    }
}

/// A sub-view's top line: back to the cards, the tool's name, and an
/// optional quiet note on the right.
struct PanelSubviewHeader: View {
    @ObservedObject private var l10n = L10n.shared
    let title: String
    let systemImage: String
    var note: String? = nil
    let back: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: back) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .modifier(PanelControlSurface(cornerRadius: 7))
            .help(l10n.s.panelBack)
            .accessibilityLabel(l10n.s.panelBack)

            Label(title, systemImage: systemImage)
                .font(.system(size: 12.5, weight: .semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let note {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }
}

// MARK: - Rows

/// One tool's row. Each tool's row is its own view so it observes only the
/// services it reads.
private struct PanelFeatureRow: View {
    let feature: AppFeature
    let isEditing: Bool
    let visibility: Binding<Bool>
    let openSubview: (AppFeature) -> Void

    var body: some View {
        switch feature {
        case .screenshot:
            ScreenshotPanelRow(isEditing: isEditing, visibility: visibility)
        case .screenRecorder:
            RecorderPanelRow(isEditing: isEditing, visibility: visibility)
        case .cleaningMode:
            CleaningModePanelRow(isEditing: isEditing, visibility: visibility)
        case .mediaTools, .urlCleaner:
            SubviewPanelRow(feature: feature, isEditing: isEditing, visibility: visibility,
                            open: { openSubview(feature) })
        case .cleaner:
            CleanerPanelRow(isEditing: isEditing, visibility: visibility)
        case .quitWindowProtection:
            QuitProtectionPanelRow(isEditing: isEditing, visibility: visibility)
        case .textSnippets:
            SnippetsPanelRow(isEditing: isEditing, visibility: visibility)
        case .airdropAutoZip:
            AirDropPanelRow(isEditing: isEditing, visibility: visibility)
        case .inputSwitch:
            InputSwitchPanelRow(isEditing: isEditing, visibility: visibility)
        }
    }
}

private func missingPermission(_ kind: PermissionKind, _ strings: Strings) -> String {
    String(format: strings.panelPermissionMissingFormat, kind.title(strings))
}

/// Closes the panel, then runs `action` once the popover is off screen, so
/// a capture does not catch it fading out.
private func afterClosingPanel(_ action: @escaping () -> Void) {
    appDelegate()?.closePopover()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: action)
}

private func openSettingsPage(of feature: AppFeature) {
    if let page = feature.settingsPage {
        SettingsNavigator.shared.open(.feature(page))
    }
    appDelegate()?.openSettings()
}

private struct ScreenshotPanelRow: View {
    let isEditing: Bool
    let visibility: Binding<Bool>
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var service = ScreenshotService.shared
    @ObservedObject private var permissions = Permissions.shared
    @ObservedObject private var hotkeys = HotkeyManager.shared
    @AppStorage(DefaultsKey.screenshotOverlayShortcutEnabled) private var overlayShortcutEnabled = true
    @AppStorage(DefaultsKey.screenshotOverlayShortcut) private var overlayShortcutRaw = ""

    var body: some View {
        let s = l10n.s
        let granted = permissions.screenRecording
        UtilityActionButton(title: AppFeature.screenshot.title(s),
                            caption: granted ? AppFeature.screenshot.summary(s)
                                : missingPermission(.screenRecording, s),
                            systemImage: AppFeature.screenshot.symbolName,
                            isEditing: isEditing,
                            showsDragHandle: true,
                            visibility: visibility,
                            needsAttention: !granted,
                            permissionButtonTitle: s.permissionRequest,
                            permissionAction: granted ? nil : { Permissions.shared.request(.screenRecording) },
                            shortcutHint: shortcutHint,
                            accessoryTitle: s.screenshotPanelFullScreen,
                            accessorySystemImage: "display",
                            accessoryAction: {
                                afterClosingPanel { ScreenshotService.shared.captureFullScreen() }
                            },
                            action: {
                                afterClosingPanel { ScreenshotService.shared.openOverlay() }
                            })
            .disabled(service.isCapturing && !isEditing)
    }

    /// Only a shortcut that is actually registered, so the hint never
    /// advertises a combination that does nothing.
    private var shortcutHint: String? {
        _ = (overlayShortcutEnabled, overlayShortcutRaw)
        let role = HotkeyRole.captureOverlay
        guard role.wantsRegistration, !hotkeys.failedRoles.contains(role) else { return nil }
        return role.saved.displayString
    }
}

/// Idle: opens the capture overlay on the recording tool. Recording or
/// counting down: the row is the way to stop, through the same path as the
/// capture shortcut.
private struct RecorderPanelRow: View {
    let isEditing: Bool
    let visibility: Binding<Bool>
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var recorder = ScreenRecorderService.shared
    @ObservedObject private var permissions = Permissions.shared

    var body: some View {
        let s = l10n.s
        let busy = recorder.captureState != .idle
        let overlayInstalled = AppFeature.screenshot.isAvailable
        let granted = permissions.screenRecording
        let needsAttention = !busy && overlayInstalled && !granted
        UtilityActionButton(title: busy ? s.recorderStop : AppFeature.screenRecorder.title(s),
                            caption: caption(s, busy: busy, overlayInstalled: overlayInstalled, granted: granted),
                            systemImage: busy ? "stop.circle" : AppFeature.screenRecorder.symbolName,
                            isEditing: isEditing,
                            showsDragHandle: true,
                            visibility: visibility,
                            needsAttention: needsAttention,
                            captionStaysVisible: busy || !overlayInstalled,
                            permissionButtonTitle: s.permissionRequest,
                            permissionAction: needsAttention ? { Permissions.shared.request(.screenRecording) } : nil,
                            action: { run(busy: busy, overlayInstalled: overlayInstalled) })
    }

    private func caption(_ s: Strings, busy: Bool, overlayInstalled: Bool, granted: Bool) -> String {
        if busy { return RecorderSupport.elapsedLabel(seconds: recorder.elapsedSeconds) }
        if !overlayInstalled { return s.recorderNeedsScreenshot }
        if !granted { return missingPermission(.screenRecording, s) }
        return AppFeature.screenRecorder.summary(s)
    }

    private func run(busy: Bool, overlayInstalled: Bool) {
        if busy {
            appDelegate()?.closePopover()
            _ = ScreenRecorderService.shared.handleOverlayShortcut()
        } else if overlayInstalled {
            afterClosingPanel { ScreenshotService.shared.openOverlay(initialTool: .recording) }
        } else {
            // Recording starts from the overlay, which comes with Screenshot.
            SettingsNavigator.shared.open(.shell(.features))
            appDelegate()?.openSettings()
        }
    }
}

/// Starts the lock. The panel closes first so, if the Accessibility prompt
/// has to show, it is not stranded under the open panel.
private struct CleaningModePanelRow: View {
    let isEditing: Bool
    let visibility: Binding<Bool>
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var permissions = Permissions.shared

    var body: some View {
        let s = l10n.s
        let granted = permissions.accessibility
        UtilityActionButton(title: AppFeature.cleaningMode.title(s),
                            caption: granted ? s.cleaningModePanelCaption : missingPermission(.accessibility, s),
                            systemImage: AppFeature.cleaningMode.symbolName,
                            isEditing: isEditing,
                            showsDragHandle: true,
                            visibility: visibility,
                            needsAttention: !granted,
                            permissionButtonTitle: s.permissionRequest,
                            permissionAction: granted ? nil : { Permissions.shared.request(.accessibility) },
                            action: {
                                appDelegate()?.closePopover()
                                CleaningModeManager.shared.activate()
                            })
    }
}

/// Media and the URL cleaner: the row opens the tool's sub-view.
private struct SubviewPanelRow: View {
    let feature: AppFeature
    let isEditing: Bool
    let visibility: Binding<Bool>
    let open: () -> Void
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        let s = l10n.s
        UtilityActionButton(title: feature.title(s),
                            caption: feature.summary(s),
                            systemImage: feature.symbolName,
                            isEditing: isEditing,
                            showsDragHandle: true,
                            visibility: visibility,
                            action: open)
    }
}

/// The review needs the room, so the row opens the cleaner's page.
private struct CleanerPanelRow: View {
    let isEditing: Bool
    let visibility: Binding<Bool>
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var permissions = Permissions.shared

    var body: some View {
        let s = l10n.s
        let granted = permissions.fullDiskAccess
        UtilityActionButton(title: AppFeature.cleaner.title(s),
                            caption: granted ? AppFeature.cleaner.summary(s) : missingPermission(.fullDiskAccess, s),
                            systemImage: AppFeature.cleaner.symbolName,
                            isEditing: isEditing,
                            showsDragHandle: true,
                            visibility: visibility,
                            needsAttention: !granted,
                            permissionButtonTitle: s.permissionRequest,
                            permissionAction: granted ? nil : { Permissions.shared.request(.fullDiskAccess) },
                            accessoryTitle: granted ? nil : s.cleanerOpenButton,
                            accessoryAction: granted ? nil : { openSettingsPage(of: .cleaner) },
                            action: { openSettingsPage(of: .cleaner) })
    }
}

/// The Command-Q switch of quit and close protection.
private struct QuitProtectionPanelRow: View {
    let isEditing: Bool
    let visibility: Binding<Bool>
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var service = QuitProtectionService.shared
    @AppStorage(DefaultsKey.quitProtectionQuitEnabled) private var quitEnabled = false

    var body: some View {
        let s = l10n.s
        let waiting = service.isWaitingForAccessibility
        PanelToggleRow(title: AppFeature.quitWindowProtection.title(s),
                       caption: waiting ? s.quitProtectionNeedsAccessibility
                           : AppFeature.quitWindowProtection.summary(s),
                       systemImage: AppFeature.quitWindowProtection.symbolName,
                       isOn: $quitEnabled,
                       isEditing: isEditing,
                       showsDragHandle: true,
                       visibility: visibility,
                       isActive: service.isRunning,
                       activeText: s.quitProtectionActiveNow,
                       needsAttention: waiting,
                       permissionButtonTitle: s.permissionRequest,
                       permissionAction: waiting ? { Permissions.shared.request(.accessibility) } : nil)
            .onChange(of: quitEnabled) { _, _ in
                QuitProtectionService.shared.syncWithPreferences()
            }
    }
}

private struct SnippetsPanelRow: View {
    let isEditing: Bool
    let visibility: Binding<Bool>
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var permissions = Permissions.shared
    @AppStorage(DefaultsKey.textSnippetsEnabled) private var enabled = false
    @AppStorage(DefaultsKey.textSnippets) private var stored = Data()

    var body: some View {
        let s = l10n.s
        let needsAttention = enabled && !permissions.accessibility
        let count = TextSnippetSupport.decode(stored.isEmpty ? nil : stored).count
        PanelToggleRow(title: AppFeature.textSnippets.title(s),
                       caption: needsAttention ? missingPermission(.accessibility, s)
                           : AppFeature.textSnippets.summary(s),
                       systemImage: AppFeature.textSnippets.symbolName,
                       isOn: $enabled,
                       isEditing: isEditing,
                       showsDragHandle: true,
                       visibility: visibility,
                       needsAttention: needsAttention,
                       permissionButtonTitle: s.permissionRequest,
                       permissionAction: needsAttention ? { Permissions.shared.request(.accessibility) } : nil,
                       accessoryTitle: enabled ? String(format: s.snippetsCountFormat, count) : nil,
                       accessoryAction: { openSettingsPage(of: .textSnippets) })
            .onChange(of: enabled) { _, _ in
                TextSnippetService.shared.syncWithPreferences()
            }
    }
}

private struct AirDropPanelRow: View {
    let isEditing: Bool
    let visibility: Binding<Bool>
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var service = AirDropAutoZipService.shared
    @AppStorage(DefaultsKey.airdropAutoZipEnabled) private var enabled = false

    var body: some View {
        let s = l10n.s
        let blocked = enabled && service.folderUnavailable
        PanelToggleRow(title: AppFeature.airdropAutoZip.title(s),
                       caption: blocked ? s.airdropFolderUnavailable : AppFeature.airdropAutoZip.summary(s),
                       systemImage: AppFeature.airdropAutoZip.symbolName,
                       isOn: $enabled,
                       isEditing: isEditing,
                       showsDragHandle: true,
                       visibility: visibility,
                       isActive: service.isProcessing,
                       activeText: s.airdropProcessing,
                       needsAttention: blocked)
            .onChange(of: enabled) { _, _ in
                AirDropAutoZipService.shared.syncWithPreferences()
            }
    }
}
