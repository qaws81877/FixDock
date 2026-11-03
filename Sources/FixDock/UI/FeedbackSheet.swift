// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import SwiftUI

/// A bug note plus `DiagnosticsReport`, or an idea with optional system
/// info. Send posts it through `FeedbackTransport`; Copy keeps it local.
struct FeedbackSheet: View {
    enum Kind: CaseIterable {
        case bug, idea
    }

    /// What the status line shows, tied to the report it was about so an
    /// edit clears it.
    private enum Outcome: Equatable {
        case copied(String), sending(String), sent(String), failed(String)

        var report: String {
            switch self {
            case .copied(let r), .sending(let r), .sent(let r), .failed(let r): return r
            }
        }
    }

    @ObservedObject private var l10n = L10n.shared
    @Environment(\.dismiss) private var dismiss
    @State private var kind = Kind.bug
    @State private var bugComment = ""
    @State private var ideaComment = ""
    @State private var includesSystemInfo = false
    @State private var snapshot = ""
    @State private var systemInfo = ""
    @State private var outcome: Outcome?
    private var s: Strings { l10n.s }

    private var report: String {
        switch kind {
        case .bug:
            return DiagnosticsReport.compose(comment: bugComment, snapshot: snapshot)
        case .idea:
            return DiagnosticsReport.composeIdea(comment: ideaComment, systemInfo: includesSystemInfo ? systemInfo : nil)
        }
    }

    private var note: String {
        (kind == .bug ? bugComment : ideaComment).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        let report = report
        let current = outcome?.report == report ? outcome : nil
        VStack(alignment: .leading, spacing: 12) {
            Text(s.feedbackTitle).font(.title3.weight(.semibold))
            Picker(s.feedbackTitle, selection: $kind) {
                Text(s.feedbackKindBug).tag(Kind.bug)
                Text(s.feedbackKindIdea).tag(Kind.idea)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Divider()

            switch kind {
            case .bug: bugForm(report)
            case .idea: ideaForm
            }

            Text(kind == .bug ? s.feedbackCaption : s.feedbackIdeaNotice)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            HStack {
                status(current)
                Spacer()
                Button(s.feedbackClose) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(s.feedbackCopyButton) {
                    ScreenshotService.copyText(report)
                    outcome = .copied(report)
                }
                Button(s.feedbackSendButton) { send(report) }
                    .buttonStyle(.borderedProminent)
                    .disabled(note.isEmpty || current == .sending(report) || current == .sent(report))
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            snapshot = DiagnosticsReport.snapshot()
            systemInfo = DiagnosticsReport.systemInfo()
        }
    }

    @ViewBuilder
    private func status(_ current: Outcome?) -> some View {
        switch current {
        case .copied:
            Label(s.feedbackCopied, systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green)
        case .sending:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(s.feedbackSending).font(.caption).foregroundStyle(.secondary)
            }
        case .sent:
            Label(s.feedbackSent, systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green)
        case .failed:
            Label(s.feedbackSendFailed, systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange)
        case nil:
            EmptyView()
        }
    }

    private func send(_ report: String) {
        outcome = .sending(report)
        FeedbackTransport.send(kind, note: note, report: report) { accepted in
            guard outcome == .sending(report) else { return }
            outcome = accepted ? .sent(report) : .failed(report)
        }
    }

    private func bugForm(_ report: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(s.feedbackCommentPrompt).font(.callout.weight(.medium))
            editor($bugComment, height: 90)

            Text(s.feedbackPreviewLabel).font(.callout.weight(.medium))
                .padding(.top, 4)
            ScrollView {
                Text(report)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
            }
            .frame(height: 220)
            .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.5)))
        }
    }

    private var ideaForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(s.feedbackIdeaPrompt).font(.callout.weight(.medium))
            editor($ideaComment, height: 200)
            Toggle(s.feedbackIncludeTechInfo, isOn: $includesSystemInfo)
                .toggleStyle(.checkbox)
                .padding(.top, 4)
        }
    }

    private func editor(_ text: Binding<String>, height: CGFloat) -> some View {
        TextEditor(text: text)
            .font(.body)
            .frame(height: height)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
    }
}
