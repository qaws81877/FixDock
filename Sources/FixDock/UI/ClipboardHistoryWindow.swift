// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import AppKit
import Combine
import SwiftUI

/// FixDock, so the app the person was in stays frontmost, gets its key
/// window back when this orders out, and receives the paste. What a key, a
/// click or a dismissal does is the service's call.
final class ClipboardHistoryWindow {
    let model: ClipboardHistoryWindowModel
    private unowned let service: ClipboardHistoryService
    private let media: ClipboardHistoryMedia
    private lazy var panel: ClipboardHistoryPanel = makePanel()
    private var keyMonitor: Any?
    private var localClickMonitor: Any?
    private var outsideClickMonitor: Any?
    private var activationObserver: NSObjectProtocol?
    private var menuIsOpen = false
    /// Menu items hold their target weakly.
    private var menuHandler: ClipboardHistoryMenuHandler?

    init(service: ClipboardHistoryService) {
        self.service = service
        model = ClipboardHistoryWindowModel(service: service)
        media = ClipboardHistoryMedia { [unowned service] in service.imageLocator }
    }

    var isVisible: Bool { panel.isVisible }
    var isKey: Bool { panel.isKeyWindow }

    func present() {
        model.reset()
        let frame = ClipboardHistoryPlacement.frame(
            pointer: NSEvent.mouseLocation,
            screens: NSScreen.screens.map { (frame: $0.frame, visible: $0.visibleFrame) })
        panel.setFrame(frame, display: true, animate: false)
        panel.layoutIfNeeded()
        installMonitors()
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    /// Only `ClipboardHistoryService.hideWindow()` calls this, after its
    /// closing check.
    func orderOut() {
        removeMonitors()
        panel.orderOut(nil)
        model.dismiss()
        media.dropPreviews()
    }

    private func popUp(_ menu: NSMenu, from anchor: NSView?, above: Bool) {
        guard let anchor, anchor.window === panel, panel.isVisible, !menuIsOpen else { return }
        let size = menu.size
        let bounds = anchor.bounds
        let gap: CGFloat = 4
        let y: CGFloat
        switch (above, anchor.isFlipped) {
        case (false, false): y = bounds.minY - gap
        case (false, true): y = bounds.maxY + gap
        case (true, false): y = bounds.maxY + gap + size.height
        case (true, true): y = bounds.minY - gap - size.height
        }
        menuIsOpen = true
        menu.popUp(positioning: nil, at: NSPoint(x: bounds.maxX - size.width, y: y), in: anchor)
        menuIsOpen = false
    }

    private func showTypeMenu() {
        let handler = ClipboardHistoryMenuHandler()
        let menu = NSMenu()
        menu.autoenablesItems = false
        let s = L10n.shared.s
        for filter in ClipboardHistoryFilter.menu {
            let item = handler.item(filter.title(s)) { [weak self] in self?.model.filter = filter }
            item.image = NSImage(systemSymbolName: filter.symbol, accessibilityDescription: nil)
            item.state = filter == model.filter ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(handler.closingItem(key: "p"))
        menuHandler = handler
        popUp(menu, from: model.typeMenuAnchor, above: false)
    }

    private func showActionsMenu() {
        guard let selected = model.selected else {
            NSSound.beep()
            return
        }
        let handler = ClipboardHistoryMenuHandler()
        let menu = NSMenu()
        menu.autoenablesItems = false
        let s = L10n.shared.s
        for action in ClipboardHistoryAction.allCases where action.applies(to: selected.entry.content) {
            if action == .delete || action == .showInFinder { menu.addItem(.separator()) }
            let item = handler.item(action.title(for: selected.entry, s)) { [weak self] in
                self?.service.perform(action, on: selected)
            }
            if let key = action.keyEquivalent {
                item.keyEquivalent = key.key
                item.keyEquivalentModifierMask = key.modifiers
            }
            menu.addItem(item)
        }
        menu.addItem(handler.closingItem(key: "k"))
        menuHandler = handler
        popUp(menu, from: model.actionsAnchor, above: true)
    }

    private func installMonitors() {
        removeMonitors()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel, !self.menuIsOpen else { return event }
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
            case .choose(let how): self.perform(how == .paste ? .paste : .copyOnly)
            case .move(let step): self.model.move(step)
            case .togglePin: self.perform(.togglePin)
            case .remove: self.model.removeSelected()
            case .close: self.service.hideWindow()
            case .showActions: DispatchQueue.main.async { self.showActionsMenu() }
            case .showTypeMenu: DispatchQueue.main.async { self.showTypeMenu() }
            }
            return nil
        }
        let mouseEvents: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: mouseEvents) { [weak self] event in
            guard let self, self.panel.isVisible, !self.menuIsOpen else { return event }
            if event.window !== self.panel, !self.mouseIsInside { self.service.hideWindow() }
            return event
        }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseEvents) { [weak self] event in
            guard let self, self.panel.isVisible, !self.menuIsOpen else { return }
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

    private func perform(_ action: ClipboardHistoryAction) {
        guard let selected = model.selected, action.applies(to: selected.entry.content) else { return }
        service.perform(action, on: selected)
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
        let view = ClipboardHistoryWindowView(
            model: model, service: service, media: media,
            showTypeMenu: { [weak self] in self?.showTypeMenu() },
            showActions: { [weak self] in self?.showActionsMenu() })
        let host = NSHostingController(rootView: view)
        // AppKit owns the window size; SwiftUI fills it.
        host.sizingOptions = []
        panel.contentViewController = host
        return panel
    }
}

private final class ClipboardHistoryPanel: OverlayPanel {
    override var canBecomeKey: Bool { true }
}

private final class ClipboardHistoryMenuHandler: NSObject {
    private var actions: [() -> Void] = []

    func item(_ title: String, action: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(run(_:)), keyEquivalent: "")
        item.target = self
        item.tag = actions.count
        actions.append(action)
        return item
    }

    func closingItem(key: String) -> NSMenuItem {
        let item = self.item("") {}
        item.keyEquivalent = key
        item.keyEquivalentModifierMask = [.command]
        item.isHidden = true
        item.allowsKeyEquivalentWhenHidden = true
        return item
    }

    @objc private func run(_ sender: NSMenuItem) {
        guard actions.indices.contains(sender.tag) else { return }
        DispatchQueue.main.async(execute: actions[sender.tag])
    }
}

final class ClipboardHistoryWindowModel: ObservableObject {
    @Published var query = "" {
        didSet { if query != oldValue { selectionID = nil } }
    }
    @Published var filter: ClipboardHistoryFilter = .all {
        didSet { if filter != oldValue { selectionID = nil } }
    }
    @Published private(set) var selectionID: UUID?
    @Published private(set) var presentationID = UUID()
    @Published private(set) var isPresented = false
    weak var typeMenuAnchor: NSView?
    weak var actionsAnchor: NSView?
    private unowned let service: ClipboardHistoryService

    init(service: ClipboardHistoryService) {
        self.service = service
    }

    var results: [ClipboardHistoryItem] { service.results(matching: query, filter: filter) }

    /// The highlighted entry, or the first result when it left the results.
    var selected: ClipboardHistoryItem? {
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
        guard let item = selected else { return }
        let position = results.firstIndex { $0.id == item.id } ?? 0
        service.perform(.delete, on: item)
        let remaining = results
        selectionID = remaining.isEmpty ? nil : remaining[min(position, remaining.count - 1)].id
    }

    func reset() {
        query = ""
        filter = .all
        selectionID = nil
        presentationID = UUID()
        isPresented = true
    }

    func dismiss() {
        isPresented = false
    }
}

struct ClipboardHistoryWindowView: View {
    @ObservedObject var model: ClipboardHistoryWindowModel
    @ObservedObject var service: ClipboardHistoryService
    let media: ClipboardHistoryMedia
    let showTypeMenu: () -> Void
    let showActions: () -> Void
    @ObservedObject private var l10n = L10n.shared
    @FocusState private var searchFocused: Bool

    private static let topID = "clipboard-history-top"

    private var s: Strings { l10n.s }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.isPresented {
                content
            } else {
                Spacer()
            }
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

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
            TextField(s.clipboardHistorySearchPlaceholder, text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 17))
                .focused($searchFocused)
            Button(action: showTypeMenu) {
                HStack(spacing: 5) {
                    Image(systemName: model.filter.symbol)
                    Text(model.filter.title(s))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
                .background(ClipboardHistoryMenuAnchor { model.typeMenuAnchor = $0 })
            }
            .buttonStyle(.plain)
            .help("⌘P")
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private var content: some View {
        if let problem = service.storeProblem {
            ClipboardHistoryProblemView(problem: problem, fileURL: service.storeProblemItemURL)
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let results = model.results
            if let selected = model.selected {
                HStack(spacing: 0) {
                    list(results, selectedID: selected.id)
                        .frame(width: ClipboardHistoryPlacement.listWidth)
                    Divider()
                    ClipboardHistoryPreviewPane(item: selected, media: media)
                        .id(selected.id)
                }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: emptySymbol)
                        .font(.system(size: 27, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text(emptyMessage)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var emptySymbol: String {
        switch model.filter {
        case .all: return "doc.on.clipboard"
        case .only(let kind): return kind.symbol
        }
    }

    private var emptyMessage: String {
        if !ClipboardHistorySearch.searchTokens(for: model.query).isEmpty { return s.clipboardHistoryNoMatches }
        switch model.filter {
        case .all: return s.clipboardHistoryEmpty
        case .only(let kind): return kind.empty(s)
        }
    }

    private func list(_ results: [ClipboardHistoryItem], selectedID: UUID) -> some View {
        let tokens = ClipboardHistorySearch.searchTokens(for: model.query)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    Color.clear.frame(height: 0).id(Self.topID)
                    if tokens.isEmpty {
                        ForEach(Self.sections(results)) { group in
                            Text(group.section.title(s))
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.top, 8)
                                .padding(.bottom, 4)
                            rows(group.items, tokens: tokens, selectedID: selectedID)
                        }
                    } else {
                        rows(results, tokens: tokens, selectedID: selectedID)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
            .onChange(of: model.selectionID) { _, _ in
                if let id = model.selected?.id { proxy.scrollTo(id) }
            }
            .onChange(of: model.presentationID) { _, _ in
                proxy.scrollTo(Self.topID, anchor: .top)
            }
        }
    }

    private func rows(_ items: [ClipboardHistoryItem], tokens: [String], selectedID: UUID) -> some View {
        ForEach(items) { item in
            ClipboardHistoryRow(item: item, tokens: tokens, isSelected: item.id == selectedID,
                                strings: s, media: media,
                                select: { model.select(item.id) },
                                perform: { service.perform($0, on: item) })
                .id(item.id)
        }
    }

    private struct SectionGroup: Identifiable {
        let section: ClipboardHistorySection
        let items: [ClipboardHistoryItem]
        var id: ClipboardHistorySection { section }
    }

    private static func sections(_ items: [ClipboardHistoryItem]) -> [SectionGroup] {
        let now = Date()
        let calendar = Calendar.current
        var buckets: [ClipboardHistorySection: [ClipboardHistoryItem]] = [:]
        for item in items {
            buckets[ClipboardHistorySections.section(for: item.entry, now: now, calendar: calendar), default: []]
                .append(item)
        }
        return ClipboardHistorySection.allCases.compactMap { section in
            buckets[section].map { SectionGroup(section: section, items: $0) }
        }
    }

    private var footer: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            HStack(spacing: 2) {
                Button {
                    if let selected = model.selected { service.perform(.paste, on: selected) }
                } label: {
                    HStack(spacing: 6) {
                        Text(service.pasteTargetName.map { String(format: s.clipboardHistoryPasteToFormat, $0) }
                             ?? s.clipboardHistoryCopy)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                        ClipboardHistoryKeyCap(text: "↵")
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.primary.opacity(0.08), in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                Button(action: showActions) {
                    HStack(spacing: 4) {
                        Text(s.clipboardHistoryActions)
                            .font(.system(size: 12, weight: .medium))
                            .padding(.trailing, 2)
                        ClipboardHistoryKeyCap(text: "⌘")
                        ClipboardHistoryKeyCap(text: "K")
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .contentShape(Capsule())
                    .background(ClipboardHistoryMenuAnchor { model.actionsAnchor = $0 })
                }
                .buttonStyle(.plain)
            }
            .disabled(model.selected == nil)
            .padding(3)
            .background(.thinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1)))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}

private struct ClipboardHistoryMenuAnchor: NSViewRepresentable {
    let register: (NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        register(view)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}

private struct ClipboardHistoryKeyCap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(minWidth: 17, minHeight: 17)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.4)))
    }
}

private struct ClipboardHistoryRow: View {
    let item: ClipboardHistoryItem
    let tokens: [String]
    let isSelected: Bool
    let strings: Strings
    let media: ClipboardHistoryMedia
    let select: () -> Void
    let perform: (ClipboardHistoryAction) -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .center, spacing: 9) {
            leading
                .frame(width: 22, height: 22)
            highlighted(title)
                .font(.system(size: 12.5))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if item.entry.isPinned, !tokens.isEmpty {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(minHeight: 36)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? Color.primary.opacity(0.12)
                      : isHovered ? Color.primary.opacity(0.05) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .gesture(TapGesture(count: 2).onEnded { perform(.paste) })
        .simultaneousGesture(TapGesture().onEnded(select))
        .contextMenu {
            ForEach(ClipboardHistoryAction.allCases.filter { $0.applies(to: item.entry.content) }, id: \.self) { action in
                if action == .delete || action == .showInFinder { Divider() }
                Button(action.title(for: item.entry, strings), role: action == .delete ? .destructive : nil) {
                    perform(action)
                }
            }
        }
    }

    @ViewBuilder
    private var leading: some View {
        switch item.entry.content {
        case .image:
            ClipboardHistoryPictureView(item: item, size: .row, media: media, contentMode: .fill)
                .frame(width: 22, height: 22)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        case .file:
            ClipboardHistoryPictureView(item: item, size: .row, media: media)
        case .text(let text):
            if item.kind == .color, let color = ClipboardHistoryColor.parse(text) {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(color.swiftUIColor)
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.15)))
                    .frame(width: 18, height: 18)
            } else {
                Image(systemName: item.kind.symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var title: String {
        if case .image = item.entry.content { return item.kind.title(strings) }
        return item.entry.preview
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
            attributed[attributedRange].font = .system(size: 12.5, weight: .semibold)
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
        case .imagesWithoutHistory: return s.clipboardHistoryProblemImagesWithoutHistory
        case .imageFolderNotAFolder: return s.clipboardHistoryProblemImageFolderNotAFolder
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
