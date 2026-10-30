// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import AppKit
import SwiftUI

/// The cleaner's page: scan, review by category, confirm, remove. Adapted
/// from upstream's CleanerView. Each row carries a lock when its app is
/// running, and a shield (exception) and folder (show in Finder) on the right.
struct CleanerSettings: View {
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var cleaner = CleanerService.shared
    @ObservedObject private var permissions = Permissions.shared
    @State private var confirming = false
    @State private var confirmingBackups = false
    private var s: Strings { l10n.s }

    var body: some View {
        Form {
            Section {
                Text(s.cleanerIntro)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Label(s.cleanerPermanentNote, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                if !permissions.fullDiskAccess {
                    Label(s.cleanerNeedsFullDiskAccess, systemImage: "lock.shield")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Button(s.permissionRequest) { permissions.request(.fullDiskAccess) }
                }
                if cleaner.homeUnusable {
                    Text(s.cleanerHomeUnusable)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                controls
            }

            switch cleaner.phase {
            case .results:
                if cleaner.items.isEmpty {
                    Section { Text(s.cleanerNothingFound).foregroundStyle(.secondary) }
                } else {
                    categorySection(.safe, title: s.cleanerSafeSection)
                    categorySection(.review, title: s.cleanerReviewSection)
                    Section { footer }
                }
            case .done:
                Section { doneSummary }
            case .idle, .scanning, .cleaning:
                EmptyView()
            }
        }
        .formStyle(.grouped)
        .onAppear { permissions.refresh() }
        .alert(String(format: s.cleanerConfirmTitleFormat, cleaner.selectedItems.count),
               isPresented: $confirming) {
            Button(s.cleanerConfirmButton, role: .destructive) {
                if selectedBackups.isEmpty {
                    cleaner.clean()
                } else {
                    confirmingBackups = true
                }
            }
            Button(s.cleanerCancel, role: .cancel) {}
        } message: {
            Text(String(format: s.cleanerConfirmMessageFormat, bytes(selectedSize), selectedCategoryNames))
        }
        .alert(s.cleanerBackupConfirmTitle, isPresented: $confirmingBackups) {
            Button(s.cleanerConfirmButton, role: .destructive) { cleaner.clean() }
            Button(s.cleanerCancel, role: .cancel) {}
        } message: {
            Text(String(format: s.cleanerBackupConfirmMessageFormat,
                        selectedBackups.map { [$0.title, $0.detail].compactMap { $0 }.joined(separator: " · ") }
                            .joined(separator: "\n")))
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch cleaner.phase {
        case .idle:
            Button(s.cleanerScan) { cleaner.scan() }
                .buttonStyle(.borderedProminent)
                .disabled(!permissions.fullDiskAccess)
        case .scanning:
            HStack {
                ProgressView().controlSize(.small)
                Text(s.cleanerScanning).font(.caption)
                Spacer()
                Button(s.cleanerCancel) { cleaner.cancelScan() }.controlSize(.small)
            }
        case .cleaning:
            HStack {
                ProgressView().controlSize(.small)
                Text(s.cleanerRemoving).font(.caption)
            }
        case .results, .done:
            Button(s.cleanerScanAgain) { cleaner.scan() }
                .disabled(!permissions.fullDiskAccess)
        }
    }

    @ViewBuilder
    private func categorySection(_ section: CleanerCategory.Section, title: String) -> some View {
        let categories = CleanerCategory.allCases.filter { category in
            category.section == section && cleaner.items.contains { $0.category == category }
        }
        if !categories.isEmpty {
            Section(title) {
                ForEach(categories) { category in
                    CleanerCategoryGroup(category: category)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Text(String(format: s.cleanerSelectedFormat, cleaner.selectedItems.count, cleaner.items.count,
                        bytes(selectedSize)))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer()
            Button(String(format: s.cleanerRemoveButtonFormat, bytes(selectedSize)), role: .destructive) {
                confirming = true
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(cleaner.selectedItems.isEmpty)
        }
    }

    private var doneSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(String(format: s.cleanerDoneFormat, cleaner.removedCount, bytes(cleaner.freedBytes)),
                  systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            if !cleaner.failures.isEmpty {
                Text(String(format: s.cleanerNotRemovedFormat, cleaner.failures.count))
                    .font(.caption)
                    .foregroundStyle(.orange)
                ForEach(cleaner.failures) { failure in
                    Text("\(Self.abbreviated(failure.path)) — \(failure.skipped ? s.cleanerSkippedLabel : s.cleanerFailedLabel)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }

    private var selectedSize: Int64 { cleaner.selectedItems.reduce(0) { $0 + $1.size } }

    private var selectedBackups: [CleanerItem] { cleaner.selectedItems.filter { $0.category == .deviceBackups } }

    private var selectedCategoryNames: String {
        CleanerCategory.allCases
            .filter { category in cleaner.selectedItems.contains { $0.category == category } }
            .map { CleanerCategoryGroup.title($0, s) }
            .joined(separator: ", ")
    }

    private func bytes(_ value: Int64) -> String { ByteCountFormatter().string(fromByteCount: value) }

    static func abbreviated(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}

/// One category: a group checkbox, its total, and its rows.
struct CleanerCategoryGroup: View {
    let category: CleanerCategory
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var cleaner = CleanerService.shared
    @State private var expanded = false

    static func title(_ category: CleanerCategory, _ s: Strings) -> String {
        switch category {
        case .caches: return s.cleanerCatCaches
        case .logs: return s.cleanerCatLogs
        case .developer: return s.cleanerCatDeveloper
        case .browserCaches: return s.cleanerCatBrowserCaches
        case .downloads: return s.cleanerCatDownloads
        case .leftovers: return s.cleanerCatLeftovers
        case .loginItems: return s.cleanerCatLoginItems
        case .deviceBackups: return s.cleanerCatDeviceBackups
        case .largeDeveloper: return s.cleanerCatLargeDeveloper
        case .trash: return s.cleanerCatTrash
        }
    }

    var body: some View {
        let items = cleaner.items.filter { $0.category == category }
        let selectable = items.filter(cleaner.isSelectable)
        let checked = selectable.filter { cleaner.selected.contains($0.id) }
        DisclosureGroup(isExpanded: $expanded) {
            ForEach(items) { item in
                CleanerItemRow(item: item)
            }
        } label: {
            HStack {
                Toggle(isOn: Binding(
                    get: { !selectable.isEmpty && checked.count == selectable.count },
                    set: { on in selectable.forEach { cleaner.setSelected(on, $0) } }
                )) {
                    Text(Self.title(category, l10n.s))
                }
                .toggleStyle(.checkbox)
                .disabled(selectable.isEmpty)
                Spacer()
                Text(ByteCountFormatter().string(fromByteCount: items.reduce(0) { $0 + $1.size }))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }
}

/// `[checkbox or lock] name ~/path  size [shield] [folder]`
struct CleanerItemRow: View {
    let item: CleanerItem
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var cleaner = CleanerService.shared

    var body: some View {
        let s = l10n.s
        let locked = cleaner.isLocked(item)
        let excepted = cleaner.isException(item)
        HStack(spacing: 8) {
            Group {
                if locked {
                    ReiconImage(name: .lock, size: 13)
                        .foregroundStyle(.secondary)
                        .help(s.cleanerLockedHelp)
                } else {
                    Toggle("", isOn: Binding(
                        get: { cleaner.selected.contains(item.id) },
                        set: { cleaner.setSelected($0, item) }
                    ))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .disabled(excepted)
                }
            }
            .frame(width: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text([item.title, item.detail].compactMap { $0 }.joined(separator: " · "))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(CleanerSettings.abbreviated(item.id))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .opacity(locked || excepted ? 0.55 : 1)

            Spacer(minLength: 8)

            Text(ByteCountFormatter().string(fromByteCount: item.size))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Button {
                cleaner.toggleException(item)
            } label: {
                ReiconImage(name: excepted ? .shieldFill : .shield, size: 14)
                    .foregroundStyle(excepted ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(excepted ? s.cleanerExceptionRemoveHelp : s.cleanerExceptionHelp)

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            } label: {
                ReiconImage(name: .folder, size: 14)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(s.cleanerRevealHelp)
        }
    }
}
