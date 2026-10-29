// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import AppKit
import SwiftUI

/// The text snippets page: the enable toggle, the snippet list and a simple
/// editor sheet. Edits persist to defaults and nudge the service, so a change
/// works on the very next keystroke. Adapted from upstream without the
/// library, sound, folder and date-builder controls.
struct TextSnippetsSettings: View {
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var permissions = Permissions.shared
    @AppStorage(DefaultsKey.textSnippetsEnabled) private var enabled = false
    /// Nil when stored snippets exist but cannot be read. Every write path
    /// checks it, so an unreadable store is never replaced by an empty list.
    @State private var snippets: [TextSnippet]? = TextSnippetSupport.decodeStored(
        UserDefaults.standard.data(forKey: DefaultsKey.textSnippets))
    @State private var editing: TextSnippet?
    @State private var creating = false
    private var s: Strings { l10n.s }

    var body: some View {
        Form {
            Section {
                Toggle(s.snippetsEnable, isOn: $enabled)
                    .onChange(of: enabled) { _, _ in
                        TextSnippetService.shared.syncWithPreferences()
                    }
                Text(s.snippetsEnableCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(s.snippetsSecureNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if enabled, !permissions.accessibility {
                    Label(s.snippetsNeedsAccessibility, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Button(s.permissionRequest) { permissions.request(.accessibility) }
                }
            }

            Section {
                if let snippets {
                    if snippets.isEmpty {
                        Text(s.snippetsEmptyList)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(TextSnippetSupport.sortedForDisplay(snippets)) { snippet in
                        SnippetRow(snippet: snippet,
                                   modeLabel: snippet.expansion == .immediate
                                       ? s.snippetsExpansionImmediate
                                       : s.snippetsExpansionDelimiter,
                                   toggle: { setEnabled($0, id: snippet.id) },
                                   edit: { editing = snippet })
                    }
                    Button {
                        creating = true
                    } label: {
                        Label(s.snippetsAddButton, systemImage: "plus")
                    }
                } else {
                    Label(s.snippetsUnreadable, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } footer: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.snippetsVariablesHint)
                    Text(s.snippetsVariablesCaption)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { permissions.refresh() }
        .sheet(isPresented: $creating) {
            SnippetEditor(snippet: TextSnippet(),
                          isNew: true,
                          others: snippets ?? [],
                          save: { upsert($0) },
                          delete: nil)
        }
        .sheet(item: $editing) { snippet in
            SnippetEditor(snippet: snippet,
                          isNew: false,
                          others: (snippets ?? []).filter { $0.id != snippet.id },
                          save: { upsert($0) },
                          delete: { remove(id: snippet.id) })
        }
    }

    private func upsert(_ snippet: TextSnippet) {
        guard var list = snippets else { return }
        if let index = list.firstIndex(where: { $0.id == snippet.id }) {
            list[index] = snippet
        } else {
            list.append(snippet)
        }
        persist(list)
    }

    private func remove(id: UUID) {
        guard var list = snippets else { return }
        list.removeAll { $0.id == id }
        persist(list)
    }

    private func setEnabled(_ on: Bool, id: UUID) {
        guard var list = snippets,
              let index = list.firstIndex(where: { $0.id == id }) else { return }
        list[index].enabled = on
        persist(list)
    }

    /// Re-reads the store before writing: if it became unreadable since the
    /// page opened, nothing is written.
    private func persist(_ list: [TextSnippet]) {
        guard TextSnippetSupport.decodeStored(
            UserDefaults.standard.data(forKey: DefaultsKey.textSnippets)) != nil,
              let data = TextSnippetSupport.encode(list)
        else {
            snippets = nil
            return
        }
        UserDefaults.standard.set(data, forKey: DefaultsKey.textSnippets)
        snippets = list
        TextSnippetService.shared.syncWithPreferences()
    }
}

private struct SnippetRow: View {
    let snippet: TextSnippet
    let modeLabel: String
    let toggle: (Bool) -> Void
    let edit: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: edit) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(snippet.name.isEmpty ? snippet.trigger : snippet.name)
                            .fontWeight(.medium)
                        Text(snippet.trigger)
                            .font(.caption.monospaced())
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(Color.primary.opacity(0.07))
                            )
                    }
                    Text(snippet.replacement.replacingOccurrences(of: "\n", with: " "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer(minLength: 8)
            Text(modeLabel)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Toggle("", isOn: Binding(get: { snippet.enabled }, set: toggle))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .padding(.vertical, 1)
    }
}

private struct SnippetEditor: View {
    @State var snippet: TextSnippet
    let isNew: Bool
    let others: [TextSnippet]
    let save: (TextSnippet) -> Void
    let delete: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var l10n = L10n.shared
    private var s: Strings { l10n.s }

    private var sanitizedTrigger: String {
        TextSnippetSupport.sanitizedTrigger(snippet.trigger)
    }

    private var triggerTooShort: Bool {
        sanitizedTrigger.count < 2
    }

    private var duplicateTrigger: Bool {
        others.contains { other in
            if snippet.ignoresCase || other.ignoresCase {
                return other.trigger.compare(sanitizedTrigger, options: .caseInsensitive) == .orderedSame
            }
            return other.trigger == sanitizedTrigger
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isNew ? s.snippetsNewTitle : s.snippetsEditTitle)
                .font(.headline)
            Form {
                TextField(s.snippetsNameLabel, text: $snippet.name, prompt: Text(s.snippetsNamePlaceholder))
                TextField(s.snippetsTriggerLabel, text: $snippet.trigger, prompt: Text(s.snippetsTriggerPlaceholder))
                    .font(.body.monospaced())
                Picker(s.snippetsExpansionLabel, selection: $snippet.expansion) {
                    Text(s.snippetsExpansionDelimiter).tag(TextSnippet.Expansion.afterDelimiter)
                    Text(s.snippetsExpansionImmediate).tag(TextSnippet.Expansion.immediate)
                }
                Toggle(s.snippetsIgnoreCaseLabel, isOn: $snippet.ignoresCase)
                VStack(alignment: .leading, spacing: 4) {
                    Text(s.snippetsReplacementLabel)
                    TextEditor(text: $snippet.replacement)
                        .font(.body)
                        .frame(minHeight: 76)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.12))
                        )
                    Text(s.snippetsVariablesHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.columns)
            if triggerTooShort, !snippet.trigger.isEmpty {
                Text(s.snippetsTriggerTooShort)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if duplicateTrigger {
                Text(s.snippetsDuplicateTrigger)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            HStack {
                if let delete {
                    Button(role: .destructive) {
                        delete()
                        dismiss()
                    } label: {
                        Text(s.snippetsDeleteButton)
                    }
                }
                Spacer()
                Button(s.snippetsCancelButton) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(s.snippetsSaveButton) {
                    var saved = snippet
                    saved.trigger = sanitizedTrigger
                    saved.name = snippet.name.trimmingCharacters(in: .whitespaces)
                    save(saved)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(triggerTooShort || duplicateTrigger || snippet.replacement.isEmpty)
            }
        }
        .padding(18)
        .frame(width: 440)
    }
}
