// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import SwiftUI

/// A note plus `DiagnosticsReport`, shown in full before it is copied. Copy
/// is the only way out: FixDock sends nothing.
struct FeedbackSheet: View {
    @ObservedObject private var l10n = L10n.shared
    @Environment(\.dismiss) private var dismiss
    @State private var comment = ""
    @State private var snapshot = ""
    @State private var copiedReport: String?
    private var s: Strings { l10n.s }

    var body: some View {
        let report = DiagnosticsReport.compose(comment: comment, snapshot: snapshot)
        VStack(alignment: .leading, spacing: 10) {
            Text(s.feedbackTitle).font(.title3.weight(.semibold))
            Text(s.feedbackCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(s.feedbackCommentPrompt).font(.callout.weight(.medium))
            TextEditor(text: $comment)
                .font(.body)
                .frame(height: 90)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))

            Text(s.feedbackPreviewLabel).font(.callout.weight(.medium))
            ScrollView {
                Text(report)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
            }
            .frame(height: 220)
            .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.5)))

            HStack {
                if copiedReport == report {
                    Label(s.feedbackCopied, systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
                Spacer()
                Button(s.feedbackClose) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(s.feedbackCopyButton) {
                    ScreenshotService.copyText(report)
                    copiedReport = report
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear { snapshot = DiagnosticsReport.snapshot() }
    }
}
