// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import SwiftUI

/// Why a keyboard tool hears nothing although it is on: another app holds
/// secure input, or macOS refused the tap. Shown on the quit protection and
/// text snippets pages; empty when neither applies.
struct KeyTapStatusView: View {
    let client: KeyTapHealth.Client
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var health = KeyTapHealth.shared
    private var s: Strings { l10n.s }

    var body: some View {
        Group {
            if health.state(of: client) == .failed {
                Label(s.keyTapStartFailed, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if health.state(of: client) != .off, let secure = health.secureInput {
                let name = secure.applicationName ?? s.keyTapUnknownApp
                Label(String(format: secure.holderExited
                                 ? s.keyTapSecureInputExitedFormat
                                 : s.keyTapSecureInputFormat,
                             name),
                      systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .onAppear { health.refreshSecureInput() }
    }
}
