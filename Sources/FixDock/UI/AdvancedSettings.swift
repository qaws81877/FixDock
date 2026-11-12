// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings › App › Advanced.
struct AdvancedSettingsPage: View {
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        let strings = l10n.s
        // Nil only outside a real bundle; every action here is about this app's own domain.
        let bundleID = Bundle.main.bundleIdentifier
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                Text(strings.backupTitle).font(.headline)
                Text(strings.backupCaption)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button(strings.backupExport) {
                        if let bundleID { SettingsBackupFlow.export(bundleID: bundleID) }
                    }
                    Button(strings.backupImport) {
                        if let bundleID { SettingsBackupFlow.importFile(bundleID: bundleID) }
                    }
                }
                .disabled(bundleID == nil)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .settingsCard()

            VStack(alignment: .leading, spacing: 10) {
                Text(strings.tabPermissions).font(.headline)
                Text(strings.resetPermissionsCaption)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(strings.resetPermissionsButton, role: .destructive) {
                    confirmResetPermissions()
                }
                .disabled(bundleID == nil)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .settingsCard()
        }
    }

    /// The owner approved this reset for Settings › Advanced. Its guard: a
    /// confirmation naming every grant, `tccutil` on this app's own bundle id
    /// only, and a relaunch only after it succeeded.
    private func confirmResetPermissions() {
        let strings = l10n.s
        let confirm = NSAlert()
        confirm.alertStyle = .warning
        confirm.messageText = strings.resetPermissionsConfirmTitle
        confirm.informativeText = strings.resetPermissionsConfirmMessage
        confirm.addButton(withTitle: strings.resetPermissionsConfirm)
        confirm.addButton(withTitle: strings.advancedCancel)
        confirm.buttons.first?.hasDestructiveAction = true
        guard confirm.runModal() == .alertFirstButtonReturn else { return }
        Permissions.shared.resetAll { failure in
            guard let failure else {
                appDelegate()?.relaunch()
                return
            }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = L10n.shared.s.resetPermissionsFailed
            alert.informativeText = failure
            alert.runModal()
        }
    }
}

/// The non-pure half of `SettingsBackup`: panels, alerts and the writes.
private enum SettingsBackupFlow {
    static func export(bundleID: String) {
        let strings = L10n.shared.s
        let now = Date()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.propertyList]
        panel.nameFieldStringValue = SettingsBackup.exportFileName(on: now)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try currentBackup(bundleID: bundleID, at: now).write(to: url, options: .atomic)
        } catch {
            showError(strings.backupExportFailed, detail: error.localizedDescription)
        }
    }

    static func importFile(bundleID: String) {
        let strings = L10n.shared.s
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.propertyList]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let contents: SettingsBackup.Contents
        switch (try? Data(contentsOf: url)).map(SettingsBackup.parse) {
        case .success(let parsed)?:
            contents = parsed
        case .failure?, nil:
            showError(strings.backupImportInvalid, detail: url.lastPathComponent)
            return
        }

        guard let container = PrivateFileStore.containerURL else { return }
        let folder = container.appendingPathComponent("SettingsBackups", isDirectory: true)
        let confirm = NSAlert()
        confirm.messageText = strings.backupImportConfirmTitle
        confirm.informativeText = String(format: strings.backupImportConfirmMessageFormat, folder.path)
        confirm.addButton(withTitle: strings.backupImportConfirm)
        confirm.addButton(withTitle: strings.advancedCancel)
        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        // The safety copy lands before anything is overwritten, or nothing is.
        guard let data = try? currentBackup(bundleID: bundleID, at: Date()),
              PrivateFileStore.createDirectory(at: folder),
              let safety = freshURL(in: folder),
              PrivateFileStore.writeDurably(data, to: safety)
        else {
            showError(strings.backupSafetyFailed, detail: folder.path)
            return
        }

        let defaults = UserDefaults.standard
        for (key, value) in contents.plain {
            defaults.set(value, forKey: key)
        }
        // After the plain keys, so enableOnFirstInstall finds the imported
        // switches and leaves them as they were.
        let features = contents.availability.compactMap { id, on in AppFeature(rawValue: id).map { ($0, on) } }
        FeatureRuntime.shared.setAvailable(features.filter { $0.1 }.map(\.0), true, requestingPermissions: false)
        FeatureRuntime.shared.setAvailable(features.filter { !$0.1 }.map(\.0), false)
        CFPreferencesAppSynchronize(bundleID as CFString)
        appDelegate()?.relaunch()
    }

    private static func currentBackup(bundleID: String, at date: Date) throws -> Data {
        let domain = UserDefaults.standard.persistentDomain(forName: bundleID) ?? [:]
        return try SettingsBackup.exportData(settings: SettingsBackup.portableSettings(domain),
                                             appVersion: AppInfo.version, exportedAt: date)
    }

    /// Never an existing file: the folder only ever gains copies.
    private static func freshURL(in folder: URL) -> URL? {
        let name = SettingsBackup.safetyFileName(at: Date())
        let base = (name as NSString).deletingPathExtension
        for attempt in 1...100 {
            let candidate = folder.appendingPathComponent(attempt == 1 ? name : "\(base)-\(attempt).plist")
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    private static func showError(_ message: String, detail: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = detail
        alert.runModal()
    }
}
