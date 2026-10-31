// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import AppKit
import SwiftUI

// Upstream's update UI (the About section, the panel banner and the preview
// window) in FixDock's shell style. Every view reads `UpdateService.shared.status`
// and switches over its `phase`, so each state is spelled out once.

/// About page, second card. An inert build shows one line and nothing that
/// could start a request.
struct UpdatesSection: View {
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var updates = UpdateService.shared
    @AppStorage(DefaultsKey.updateAutomaticChecks) private var automaticChecks = true
    @AppStorage(DefaultsKey.updateShowNotesBeforeInstall) private var showNotesFirst = true

    var body: some View {
        let strings = l10n.s
        let status = updates.status
        VStack(alignment: .leading, spacing: 8) {
            Text(strings.updatesTitle).font(.headline)
            if case .inert = status.phase {
                Text(strings.updateInertCaption)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Toggle(strings.updateAutomaticToggle, isOn: $automaticChecks)
                    .onChange(of: automaticChecks) { _, _ in updates.automaticChecksChanged() }
                if status.mode == .inPlace {
                    Toggle(strings.updateShowNotesToggle, isOn: $showNotesFirst)
                }
                UpdateStatusRow(status: status)
                HStack {
                    Button(strings.updateCheckNow) { updates.checkNow() }
                        .disabled(!status.canStartCheck)
                    if case .available(_, let route) = status.phase {
                        Button(route == .inPlace ? strings.updateInstallButton : strings.updateOpenReleasePage) {
                            appDelegate()?.presentUpdate()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(route == .inPlace && !status.canInstall)
                    }
                    if status.canCancel {
                        Button(strings.updatePreviewCancel) { updates.cancelDownload() }
                    }
                    if showsReleasePageForRestore(status) {
                        Button(strings.updateOpenReleasePage) {
                            NSWorkspace.shared.open(AppInfo.repositoryURL.appendingPathComponent("releases"))
                        }
                    }
                }
                if let date = status.lastChecked {
                    Text(String(format: strings.updateLastCheckedFormat,
                                date.formatted(date: .abbreviated, time: .shortened)))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .settingsCard()
    }

    /// An available offer already has its own release-page or install button.
    private func showsReleasePageForRestore(_ status: UpdateStatus) -> Bool {
        guard case .restoreFailed? = status.notice else { return false }
        if case .available = status.phase { return false }
        return true
    }
}

/// Upstream's status row (tinted icon, callout text), then the reason a copy
/// cannot update in place, an install problem, and what the last attempt
/// ended in.
struct UpdateStatusRow: View {
    let status: UpdateStatus
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        let strings = l10n.s
        VStack(alignment: .leading, spacing: 4) {
            primary(strings)
            if case .available(_, .releasePage(let reason)) = status.phase {
                Text(strings.updateCaption(reason))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if case .install(let failure)? = status.problem {
                label(String(format: strings.updateInstallFailedFormat, strings.updateReason(failure)),
                      system: "exclamationmark.triangle.fill", tint: .orange)
            }
            if let notice = status.notice {
                noticeLine(notice, strings)
            }
        }
    }

    @ViewBuilder
    private func primary(_ strings: Strings) -> some View {
        switch status.phase {
        case .inert, .neverChecked:
            EmptyView()
        case .checking:
            label(strings.updateCheckingStatus, system: "arrow.triangle.2.circlepath", tint: .secondary)
        case .upToDate:
            label(strings.updateUpToDateStatus, system: "checkmark.circle.fill", tint: .green)
        case .checkFailed(let failure):
            label(String(format: strings.updateCheckFailedFormat, strings.updateReason(failure)),
                  system: "exclamationmark.triangle.fill", tint: .orange)
        case .available(let offer, _):
            label(String(format: strings.updateAvailableFormat, offer.version.description),
                  system: "arrow.down.circle.fill", tint: .accentColor)
        case .installing(_, .downloading(let fraction)):
            HStack(spacing: 8) {
                if let fraction {
                    ProgressView(value: fraction).frame(width: 120)
                    Text(String(format: strings.updateDownloadingFormat, Int(fraction * 100))).font(.callout)
                } else {
                    ProgressView().controlSize(.small)
                    Text(strings.updateDownloadingStatus).font(.callout)
                }
                Spacer()
            }
        case .installing(_, .verifying):
            spinner(strings.updateVerifyingStatus)
        case .installing(_, .restarting):
            spinner(strings.updateRestartingStatus)
        }
    }

    @ViewBuilder
    private func noticeLine(_ notice: UpdateNotice, _ strings: Strings) -> some View {
        switch notice {
        case .updated(let version):
            label(String(format: strings.updateUpdatedNoticeFormat, version.description),
                  system: "checkmark.circle.fill", tint: .green)
        case .rolledBack(let version):
            label(String(format: strings.updateRolledBackNoticeFormat, version.description, AppInfo.version),
                  system: "exclamationmark.triangle.fill", tint: .orange)
        case .notApplied(let version, _):
            label(String(format: strings.updateNotAppliedNoticeFormat, version.description),
                  system: "exclamationmark.triangle.fill", tint: .orange)
        case .restoreFailed:
            label(strings.updateRestoreFailedNotice, system: "exclamationmark.triangle.fill", tint: .orange)
        }
    }

    private func label(_ text: String, system: String, tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: system).foregroundStyle(tint)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private func spinner(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).font(.callout)
            Spacer()
        }
    }
}

/// Top of the menu panel while an offer is available or installing, as
/// upstream. A fixed height, so `PanelLayoutSupport.updateBannerHeight` is exact.
struct UpdateBanner: View {
    static let height: CGFloat = 44

    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var updates = UpdateService.shared

    var body: some View {
        let strings = l10n.s
        let phase = updates.status.phase
        Button { appDelegate()?.presentUpdate() } label: {
            HStack(spacing: 9) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.white)
                VStack(alignment: .leading, spacing: 1) {
                    Text(strings.updateBannerTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                    if let version = Self.version(of: phase) {
                        Text(String(format: strings.versionFormat, version))
                            .font(.system(size: 10.5))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }
                Spacer()
                trailing(phase, strings)
            }
            .padding(.horizontal, 12)
            .frame(height: Self.height)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.accentColor))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func trailing(_ phase: UpdatePhase, _ strings: Strings) -> some View {
        switch phase {
        case .installing(_, .downloading(let fraction?)):
            capsule("\(Int(fraction * 100))%")
        case .installing:
            ProgressView().controlSize(.small).tint(.white)
        default:
            capsule(strings.updateBannerAction)
        }
    }

    private func capsule(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(.white))
    }

    private static func version(of phase: UpdatePhase) -> String? {
        switch phase {
        case .available(let offer, _), .installing(let offer, _): return offer.version.description
        default: return nil
        }
    }
}

/// The pre-install window (`AppDelegate.showUpdatePreview`): the release notes,
/// then Download and install. After the click it stays open with the progress,
/// or with the failure and the button enabled again. Cancel stops a download
/// in progress and otherwise only closes the window.
struct UpdatePreviewView: View {
    let offer: UpdateOffer
    let close: () -> Void
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var updates = UpdateService.shared
    @State private var skipNextTime = false

    var body: some View {
        let strings = l10n.s
        let status = updates.status
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(String(format: strings.updatePreviewTitleFormat, offer.version.description))
                    .font(.system(size: 20, weight: .bold))
                Text(String(format: strings.updatePreviewCurrentFormat, AppInfo.version))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 14)

            Divider()

            ScrollView {
                ReleaseNotesText(markdown: offer.notes)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(24)
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                if showsStatus(status) {
                    UpdateStatusRow(status: status)
                }
                HStack(spacing: 12) {
                    Toggle(strings.updatePreviewSkipNotes, isOn: $skipNextTime)
                        .toggleStyle(.checkbox)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button(strings.updatePreviewCancel) {
                        if status.canCancel { updates.cancelDownload() } else { close() }
                    }
                    .keyboardShortcut(.cancelAction)
                    Button(strings.updateInstallButton) {
                        // Saved only on install: ticking the box and then
                        // cancelling must not make the next update silent.
                        if skipNextTime {
                            UserDefaults.standard.set(false, forKey: DefaultsKey.updateShowNotesBeforeInstall)
                        }
                        updates.install()
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!status.canInstall)
                }
            }
            .padding(16)
        }
        .frame(width: 520, height: 460)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func showsStatus(_ status: UpdateStatus) -> Bool {
        if case .installing = status.phase { return true }
        if case .install? = status.problem { return true }
        return false
    }
}

/// GitHub release bodies use headings, lists and code fences, which
/// `AttributedString(markdown:)` keeps only as inline text, so blocks are
/// split here and each line's inline Markdown is still parsed.
struct ReleaseNotesText: View {
    let markdown: String

    enum Block: Equatable {
        case heading(level: Int, text: String)
        case item(marker: String, depth: Int, text: String)
        case paragraph(String)
        case code(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(Self.blocks(markdown).enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let text):
                    Text(Self.inline(text))
                        .font(level <= 2 ? .headline : .subheadline.weight(.semibold))
                        .padding(.top, 4)
                case .item(let marker, let depth, let text):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(marker).foregroundStyle(.secondary)
                        Text(Self.inline(text)).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, CGFloat(depth) * 16)
                case .paragraph(let text):
                    Text(Self.inline(text)).fixedSize(horizontal: false, vertical: true)
                case .code(let text):
                    Text(text)
                        .font(.system(.callout, design: .monospaced))
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
                }
            }
        }
        .textSelection(.enabled)
    }

    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text,
                               options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    static func blocks(_ markdown: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var code: [String]?
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))) }
            paragraph = []
        }
        for raw in markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if let lines = code {
                    blocks.append(.code(lines.joined(separator: "\n")))
                    code = nil
                } else {
                    flush()
                    code = []
                }
                continue
            }
            if code != nil { code?.append(raw); continue }
            if line.isEmpty { flush(); continue }
            let hashes = line.prefix { $0 == "#" }.count
            if (1...6).contains(hashes), line.dropFirst(hashes).first == " " {
                flush()
                blocks.append(.heading(level: hashes, text: String(line.dropFirst(hashes + 1))))
                continue
            }
            let depth = (raw.prefix { $0 == " " }.count) / 2
            if let first = line.first, "-*+".contains(first), line.dropFirst().first == " " {
                flush()
                blocks.append(.item(marker: "•", depth: depth, text: String(line.dropFirst(2))))
                continue
            }
            if let dot = line.firstIndex(of: "."), line[..<dot].allSatisfy(\.isNumber), !line[..<dot].isEmpty,
               line[line.index(after: dot)...].first == " " {
                flush()
                blocks.append(.item(marker: String(line[...dot]), depth: depth,
                                    text: String(line[line.index(dot, offsetBy: 2)...])))
                continue
            }
            paragraph.append(line)
        }
        if let lines = code { blocks.append(.code(lines.joined(separator: "\n"))) }
        flush()
        return blocks
    }
}

private extension Strings {
    func updateReason(_ failure: CheckFailure) -> String {
        switch failure {
        case .unreachable: return updateFailureUnreachable
        case .rateLimited: return updateFailureRateLimited
        case .server: return updateFailureServer
        case .unreadable: return updateFailureUnreadable
        case .releaseIncomplete: return updateFailureReleaseIncomplete
        }
    }

    func updateReason(_ failure: InstallFailure) -> String {
        switch failure {
        case .busy(.recording): return updateFailureBusyRecording
        case .busy(.mediaJob): return updateFailureBusyMedia
        case .busy(.cleaningMode): return updateFailureBusyCleaning
        case .unreachable, .http, .insecureRedirect, .sizeMismatch: return updateFailureDownload
        case .digestMismatch: return updateFailureDigest
        case .diskWrite: return updateFailureDisk
        case .archiveRejected, .extractFailed, .stagedMismatch: return updateFailureArchive
        case .signatureRejected: return updateFailureSignature
        case .handoffFailed: return updateFailureHandoff
        }
    }

    func updateCaption(_ reason: ManualReason) -> String {
        switch reason {
        case .translocated: return updateManualTranslocated
        case .outsideApplications: return updateManualOutsideApplications
        case .notWritable: return updateManualNotWritable
        case .otherVolume: return updateManualOtherVolume
        }
    }
}
