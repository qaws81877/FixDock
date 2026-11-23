// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings page for the Korean/English layout fix: the switch and its
/// shortcut, why the tool is resting when it is, the apps it is turned off
/// for, and the person's two word lists, the learned words among the
/// never-change ones.
struct LayoutFixSettings: View {
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var permissions = Permissions.shared
    @ObservedObject private var service = LayoutFixService.shared
    @AppStorage(DefaultsKey.layoutFixEnabled) private var enabled = false
    @AppStorage(DefaultsKey.layoutFixWhileTyping) private var whileTyping = false
    private var s: Strings { l10n.s }

    var body: some View {
        Form {
            Section {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    BetaBadge()
                    Text(s.layoutFixBetaCaption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Toggle(s.layoutFixEnable, isOn: $enabled)
                    .onChange(of: enabled) { _, _ in
                        LayoutFixService.shared.syncWithPreferences()
                    }
                Text(s.layoutFixEnableCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(s.layoutFixLimitsCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if service.mode == .resting(.needsAccessibility) {
                    Label(s.layoutFixNeedsAccessibility, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Button(s.permissionRequest) { permissions.request(.accessibility) }
                } else if let status = LayoutFixStatus.text(service.mode, s) {
                    Label(status, systemImage: service.mode == .active ? "checkmark.circle.fill" : "pause.circle")
                        .font(.caption)
                        .foregroundStyle(service.mode == .active ? Color.green : Color.orange)
                }
                KeyTapStatusView(client: .layoutFix)
                ShortcutRecorderRow(role: .layoutFixToggle, title: s.layoutFixToggleShortcut,
                                    enabledKey: DefaultsKey.layoutFixToggleShortcutEnabled)
                Text(s.layoutFixToggleShortcutCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle(s.layoutFixWhileTyping, isOn: $whileTyping)
                    .disabled(!enabled)
                    .onChange(of: whileTyping) { _, _ in
                        LayoutFixService.shared.syncWithPreferences()
                    }
                Text(s.layoutFixWhileTypingCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if whileTyping, !AppFeature.inputSwitch.isAvailable {
                    Label(s.layoutFixWhileTypingNeedsSwitch, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section(s.layoutFixExcludedTitle) {
                if service.ignoredApps.isEmpty {
                    Text(s.layoutFixExcludedNone)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(service.ignoredApps, id: \.self) { bundleID in
                    HStack(spacing: 8) {
                        let app = ClipboardHistorySourceApp.info(for: bundleID)
                        Image(nsImage: app.icon)
                            .resizable()
                            .frame(width: 20, height: 20)
                        Text(app.name)
                        Spacer()
                        Button {
                            service.stopIgnoring(bundleID)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(s.layoutFixExcludedRemove)
                    }
                }
                Button {
                    pickApplication()
                } label: {
                    Label(s.layoutFixExcludedAdd, systemImage: "plus")
                }
                Text(s.layoutFixExcludedCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            LayoutFixWordSection(kind: .alwaysFix)
            LayoutFixWordSection(kind: .neverChange)
        }
        .formStyle(.grouped)
        .onAppear {
            permissions.refresh()
            LayoutFixService.shared.syncWithPreferences()
        }
    }

    private func pickApplication() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.prompt = s.layoutFixExcludedAdd
        guard panel.runModal() == .OK,
              let url = panel.url,
              let bundleID = Bundle(url: url)?.bundleIdentifier
        else { return }
        service.ignore(bundleID)
    }
}

/// One of the person's word lists: its words, a field to add one, and why a
/// word was refused. The never-change list shows the learned words too.
private struct LayoutFixWordSection: View {
    let kind: LayoutFixWord.Kind
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var service = LayoutFixService.shared
    @State private var text = ""
    @State private var problem: LayoutFixWord.Problem?
    private var s: Strings { l10n.s }

    var body: some View {
        let words = service.words.filter { $0.kind == kind }
        let learned = kind == .neverChange ? service.learnedWords : []
        Section(kind == .alwaysFix ? s.layoutFixAlwaysTitle : s.layoutFixNeverTitle) {
            if words.isEmpty, learned.isEmpty {
                Text(s.layoutFixWordsNone)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(words, id: \.self) { word in
                row(word.text, learned: false) { service.remove(word) }
            }
            ForEach(learned, id: \.self) { key in
                // As the field showed it when it was typed.
                row(key.source == .latin ? key.keys : HangulTwoSet.hangul(fromKeySpace: key.keys), learned: true) {
                    service.forget(key)
                }
            }
            if !learned.isEmpty {
                Button(s.layoutFixLearnedRemoveAll) { service.forgetAll() }
            }
            HStack(spacing: 8) {
                TextField(s.layoutFixWordPlaceholder, text: $text)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                    .onChange(of: text) { _, _ in problem = nil }
                Button(s.layoutFixWordAdd, action: add)
                    .disabled(LayoutFixWord.normalized(text).isEmpty)
            }
            .disabled(!service.wordsEditable)
            if !service.wordsEditable {
                Label(s.layoutFixWordsUnavailable, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if let problem {
                Text(message(problem))
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Text(kind == .alwaysFix ? s.layoutFixAlwaysCaption : s.layoutFixNeverCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func row(_ text: String, learned: Bool, remove: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Text(text)
            if learned {
                Text(s.layoutFixWordLearned)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: remove) {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(!service.wordsEditable)
            .accessibilityLabel(s.layoutFixExcludedRemove)
        }
    }

    private func add() {
        guard !LayoutFixWord.normalized(text).isEmpty else { return }
        problem = service.add(text, as: kind)
        if problem == nil { text = "" }
    }

    private func message(_ problem: LayoutFixWord.Problem) -> String {
        switch problem {
        case .empty, .notTypable: return s.layoutFixWordNotTypable
        case .tooShort: return s.layoutFixWordTooShort
        case .tooLong: return String(format: s.layoutFixWordTooLongFormat, LayoutFixWord.maxLength)
        case .already(.alwaysFix): return s.layoutFixWordAlreadyAlways
        case .already(.neverChange): return s.layoutFixWordAlreadyNever
        case .learned: return s.layoutFixWordLearnedAlready
        case .conflict: return s.layoutFixWordConflict
        case .full: return String(format: s.layoutFixWordFullFormat, LayoutFixWord.limit)
        }
    }
}

/// The one line that says what the tool is doing. nil while it is off.
enum LayoutFixStatus {
    static func text(_ mode: LayoutFixMode, _ s: Strings) -> String? {
        switch mode {
        case .off: return nil
        case .active: return s.layoutFixActiveNow
        case .resting(.needsAccessibility): return s.layoutFixNeedsAccessibility
        case .resting(.otherFixer(let name)): return String(format: s.layoutFixRestOtherFixerFormat, name)
        case .resting(.developerBuild): return s.layoutFixRestDeveloperBuild
        case .resting(.unknownLayout): return s.layoutFixRestUnknownLayout
        case .resting(.listsMissing): return s.layoutFixRestListsMissing
        case .resting(.listsLoading): return s.layoutFixRestListsLoading
        }
    }
}

struct LayoutFixPanelRow: View {
    let isEditing: Bool
    let visibility: Binding<Bool>
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var service = LayoutFixService.shared
    @AppStorage(DefaultsKey.layoutFixEnabled) private var enabled = false

    var body: some View {
        let s = l10n.s
        let waiting = service.mode == .resting(.needsAccessibility)
        let resting: String? = {
            if case .resting = service.mode { return LayoutFixStatus.text(service.mode, s) }
            return nil
        }()
        PanelToggleRow(title: AppFeature.layoutFix.title(s),
                       caption: resting ?? AppFeature.layoutFix.summary(s),
                       systemImage: AppFeature.layoutFix.symbolName,
                       isOn: $enabled,
                       isEditing: isEditing,
                       showsDragHandle: true,
                       visibility: visibility,
                       isActive: service.mode == .active,
                       activeText: s.layoutFixActiveNow,
                       needsAttention: resting != nil,
                       permissionButtonTitle: s.permissionRequest,
                       permissionAction: waiting ? { Permissions.shared.request(.accessibility) } : nil)
            .onChange(of: enabled) { _, _ in
                LayoutFixService.shared.syncWithPreferences()
            }
    }
}
