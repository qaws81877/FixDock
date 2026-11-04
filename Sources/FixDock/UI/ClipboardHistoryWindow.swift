// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import AppKit
import Combine
import SwiftUI

/// The Command-Shift-V window: a non-activating key panel, restored from
/// upstream's quick window with the list layout only. It never activates
/// FixDock, so the app the person was in stays frontmost, gets its key
/// window back when this orders out, and receives the paste. What a key, a
/// click or a dismissal does is the service's call.
final class ClipboardHistoryWindow {
    let model: ClipboardHistoryWindowModel
    private unowned let service: ClipboardHistoryService
    private lazy var panel: ClipboardHistoryPanel = makePanel()
    private var keyMonitor: Any?
    private var localClickMonitor: Any?
    private var outsideClickMonitor: Any?
    private var activationObserver: NSObjectProtocol?

    init(service: ClipboardHistoryService) {
        self.service = service
        model = ClipboardHistoryWindowModel(service: service)
    }

    var isVisible: Bool { panel.isVisible }
    var isKey: Bool { panel.isKeyWindow }

    func present() {
        model.reset()
        let frame = ClipboardHistoryPlacement.frame(
            pointer: NSEvent.mouseLocation,
            screens: NSScreen.screens.map { (frame: $0.frame, visible: $0.visibleFrame) })
        panel.setFrame(frame, display: true, animate: false)
        installMonitors()
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    /// Only `ClipboardHistoryService.hideWindow()` calls this, after its
    /// closing check.
    func orderOut() {
        removeMonitors()
        panel.orderOut(nil)
    }

    private func installMonitors() {
        removeMonitors()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            if let field = self.panel.firstResponder as? NSTextView,
               ClipboardHistoryFocus.textViewOwnsKeys(isComposing: field.hasMarkedText(),
                                                      isFieldEditor: field.isFieldEditor,
                                                      isEditable: field.isEditable) {
                return event
            }
            guard let action = ClipboardHistoryKeyAction.action(
                keyCode: event.keyCode,
                modifiers: Self.modifiers(event.modifierFlags),
                key: event.charactersIgnoringModifiers?.lowercased()) else { return event }
            switch action {
            case .choose(let how): self.model.selected.map { self.service.choose($0, how) }
            case .move(let step): self.model.move(step)
            case .togglePin: self.model.selected.map(self.service.togglePin)
            case .remove: self.model.removeSelected()
            case .close: self.service.hideWindow()
            }
            return nil
        }
        let mouseEvents: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: mouseEvents) { [weak self] event in
            guard let self, self.panel.isVisible else { return event }
            if event.window !== self.panel, !self.mouseIsInside { self.service.hideWindow() }
            return event
        }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseEvents) { [weak self] event in
            guard let self, self.panel.isVisible else { return }
            if event.windowNumber != self.panel.windowNumber, !self.mouseIsInside { self.service.hideWindow() }
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
            self?.service.hideWindow()
        }
    }

    private func removeMonitors() {
        for monitor in [keyMonitor, localClickMonitor, outsideClickMonitor].compactMap({ $0 }) {
            NSEvent.removeMonitor(monitor)
        }
        keyMonitor = nil
        localClickMonitor = nil
        outsideClickMonitor = nil
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
            self.activationObserver = nil
        }
    }

    private var mouseIsInside: Bool {
        panel.frame.insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation)
    }

    private static func modifiers(_ flags: NSEvent.ModifierFlags) -> ClipboardHistoryModifiers {
        var modifiers: ClipboardHistoryModifiers = []
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.command) { modifiers.insert(.command) }
        return modifiers
    }

    private func makePanel() -> ClipboardHistoryPanel {
        let panel = ClipboardHistoryPanel(contentRect: CGRect(origin: .zero, size: ClipboardHistoryPlacement.contentSize),
                                          styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
                                          backing: .buffered,
                                          defer: false)
        panel.title = L10n.shared.s.featureClipboardHistoryName
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let host = NSHostingController(rootView: ClipboardHistoryListView(model: model, service: service))
        // AppKit owns the window size; SwiftUI fills it.
        host.sizingOptions = []
        panel.contentViewController = host
        return panel
    }
}

private final class ClipboardHistoryPanel: OverlayPanel {
    override var canBecomeKey: Bool { true }
}

/// The window's state. The selection is the entry itself, not a row, so a
/// copy landing while the window is open never changes what Return pastes.
final class ClipboardHistoryWindowModel: ObservableObject {
    @Published var query = "" {
        didSet { if query != oldValue { selectionID = nil } }
    }
    @Published private(set) var selectionID: UUID?
    @Published private(set) var presentationID = UUID()
    private unowned let service: ClipboardHistoryService

    init(service: ClipboardHistoryService) {
        self.service = service
    }

    var results: [ClipboardHistoryEntry] { service.filteredEntries(matching: query) }

    /// The highlighted entry, or the first result when it left the results.
    var selected: ClipboardHistoryEntry? {
        let results = results
        return results.first { $0.id == selectionID } ?? results.first
    }

    func move(_ step: Int) {
        let results = results
        guard !results.isEmpty else { return }
        let current = results.firstIndex { $0.id == selected?.id } ?? 0
        selectionID = results[min(max(current + step, 0), results.count - 1)].id
    }

    func select(_ id: UUID?) {
        selectionID = id
    }

    /// The highlight stays where the removed entry was.
    func removeSelected() {
        guard let entry = selected else { return }
        let position = results.firstIndex { $0.id == entry.id } ?? 0
        service.remove(entry)
        let remaining = results
        selectionID = remaining.isEmpty ? nil : remaining[min(position, remaining.count - 1)].id
    }

    func reset() {
        query = ""
        selectionID = nil
        presentationID = UUID()
    }
}

struct ClipboardHistoryListView: View {
    @ObservedObject var model: ClipboardHistoryWindowModel
    @ObservedObject var service: ClipboardHistoryService
    @ObservedObject private var l10n = L10n.shared
    @FocusState private var searchFocused: Bool

    /// A plain stack for an ordinary history scrolls smoothest; only a very
    /// long result list goes lazy.
    private static let eagerRowLimit = 300
    private static let topID = "clipboard-history-top"

    private var s: Strings { l10n.s }

    var body: some View {
        VStack(spacing: 0) {
            TextField(s.clipboardHistorySearchPlaceholder, text: $model.query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 9)
            Divider()
            content
            Divider()
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.regularMaterial)
        .ignoresSafeArea(.container, edges: .top)
        .onAppear { DispatchQueue.main.async { searchFocused = true } }
        .onChange(of: model.presentationID) { _, _ in
            DispatchQueue.main.async { searchFocused = true }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let problem = service.storeProblem {
            ClipboardHistoryProblemView(problem: problem, fileURL: service.storeFileURL)
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let results = model.results
            if results.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 27, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text(service.entries.isEmpty ? s.clipboardHistoryEmpty : s.clipboardHistoryNoMatches)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list(results)
            }
        }
    }

    private func list(_ results: [ClipboardHistoryEntry]) -> some View {
        let selectedID = model.selected?.id
        let tokens = ClipboardHistorySearch.searchTokens(for: model.query)
        return ScrollViewReader { proxy in
            ScrollView {
                Group {
                    if results.count <= Self.eagerRowLimit {
                        VStack(alignment: .leading, spacing: 0) { rows(results, tokens: tokens, selectedID: selectedID) }
                    } else {
                        LazyVStack(alignment: .leading, spacing: 0) { rows(results, tokens: tokens, selectedID: selectedID) }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .onChange(of: model.selectionID) { _, _ in
                if let id = model.selected?.id { proxy.scrollTo(id) }
            }
            .onChange(of: model.presentationID) { _, _ in
                proxy.scrollTo(Self.topID, anchor: .top)
            }
        }
    }

    /// Pinned first under their own header, then the rest. A search lists its
    /// matches by relevance with no headers.
    @ViewBuilder
    private func rows(_ results: [ClipboardHistoryEntry], tokens: [String], selectedID: UUID?) -> some View {
        Color.clear.frame(height: 0).id(Self.topID)
        if tokens.isEmpty {
            let pinned = results.filter(\.isPinned)
            let recent = results.filter { !$0.isPinned }
            section(title: s.clipboardHistoryPinnedSection, pinned, tokens: tokens, selectedID: selectedID)
            if !pinned.isEmpty, !recent.isEmpty {
                Divider().padding(.horizontal, 6).padding(.vertical, 5)
            }
            section(title: s.clipboardHistoryRecentSection, recent, tokens: tokens, selectedID: selectedID)
        } else {
            section(title: nil, results, tokens: tokens, selectedID: selectedID)
        }
    }

    @ViewBuilder
    private func section(title: String?, _ entries: [ClipboardHistoryEntry], tokens: [String],
                         selectedID: UUID?) -> some View {
        if !entries.isEmpty {
            if let title {
                Text(title.uppercased())
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .tracking(0.6)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
            }
            ForEach(entries) { entry in
                ClipboardHistoryRow(entry: entry, tokens: tokens, isSelected: entry.id == selectedID,
                                    strings: s, service: service)
                    .id(entry.id)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(s.clipboardHistoryFooterHint)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            HStack(spacing: 5) {
                Image(systemName: "doc.on.clipboard")
                Text("\(service.entries.count)")
            }
        }
        .font(.system(size: 10.5, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

private struct ClipboardHistoryRow: View {
    let entry: ClipboardHistoryEntry
    let tokens: [String]
    let isSelected: Bool
    let strings: Strings
    let service: ClipboardHistoryService
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .center, spacing: 9) {
            Image(systemName: entry.isPinned ? "pin.fill" : "text.alignleft")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(entry.isPinned ? Color.accentColor : Color.secondary)
                .frame(width: 20)
            highlighted(entry.preview)
                .font(.system(size: 12))
                .lineLimit(2)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if isHovered {
                Button {
                    service.togglePin(entry)
                } label: {
                    Image(systemName: entry.isPinned ? "pin.slash" : "pin")
                        .font(.system(size: 10.5, weight: .semibold))
                        .frame(width: 24, height: 24)
                        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help(entry.isPinned ? strings.clipboardHistoryUnpin : strings.clipboardHistoryPin)
                .accessibilityLabel(entry.isPinned ? strings.clipboardHistoryUnpin : strings.clipboardHistoryPin)
            } else {
                Text(entry.copiedAt, style: .time)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(minHeight: 40)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.16)
                      : isHovered ? Color.primary.opacity(0.05) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture { service.choose(entry, .paste) }
        .contextMenu {
            Button(strings.clipboardHistoryPaste) { service.choose(entry, .paste) }
            Button(strings.clipboardHistoryCopy) { service.choose(entry, .copyOnly) }
            Divider()
            Button(entry.isPinned ? strings.clipboardHistoryUnpin : strings.clipboardHistoryPin) {
                service.togglePin(entry)
            }
            Divider()
            Button(strings.clipboardHistoryDelete, role: .destructive) { service.remove(entry) }
        }
    }

    /// Searched and styled only as far as a row can show, so typing in a
    /// history of long texts stays cheap.
    private func highlighted(_ string: String) -> Text {
        guard !tokens.isEmpty else { return Text(string) }
        let visible = string.count > 500 ? String(string.prefix(500)) + "…" : string
        var attributed = AttributedString(visible)
        for range in ClipboardHistorySearch.highlightRanges(in: visible, tokens: tokens) {
            guard let attributedRange = Range(range, in: attributed) else { continue }
            attributed[attributedRange].foregroundColor = .accentColor
            attributed[attributedRange].font = .system(size: 12, weight: .semibold)
        }
        return Text(attributed)
    }
}

/// Shown in the window and in Settings while the history file cannot be
/// used. The only action is to show the file; FixDock never repairs, moves
/// or deletes it.
struct ClipboardHistoryProblemView: View {
    let problem: ClipboardHistoryStoreProblem
    let fileURL: URL?
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        let s = l10n.s
        VStack(alignment: .leading, spacing: 8) {
            Label(s.clipboardHistoryStoreProblemTitle, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(problem.message(s))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let fileURL, problem != .noContainer {
                Button(s.clipboardHistoryRevealFile) {
                    NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                }
            }
        }
    }
}

extension ClipboardHistoryStoreProblem {
    func message(_ s: Strings) -> String {
        switch self {
        case .noContainer: return s.clipboardHistoryProblemNoContainer
        case .unreadable(let reason): return String(format: s.clipboardHistoryProblemUnreadableFormat, reason)
        case .notARegularFile: return s.clipboardHistoryProblemNotAFile
        case .tooLarge: return s.clipboardHistoryProblemTooLarge
        case .newerFormat: return s.clipboardHistoryProblemNewerFormat
        case .undecodable: return s.clipboardHistoryProblemDamaged
        }
    }
}

extension ClipboardHistoryRetention {
    func label(_ s: Strings) -> String {
        switch self {
        case .forever: return s.clipboardHistoryRetentionForever
        case .oneDay: return s.clipboardHistoryRetentionOneDay
        case .week, .month, .quarter: return String(format: s.clipboardHistoryRetentionDaysFormat, rawValue)
        }
    }
}
