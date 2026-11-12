// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import Foundation

/// Text snippets: typing a trigger replaces it with its expansion, with
/// {{date}}, {{time}}, {{datetime}} and {{clipboard}} filled in. This service
/// only turns the preferences into what the shared typing tap matches
/// against; the tap and the typing live in `TypingTap`, and off means
/// nothing lives. Requires Accessibility (the tap).
///
/// Adapted from upstream without its snippet library, command bar, expansion
/// sound and Accessibility Keyboard handling.
final class TextSnippetService {
    static let shared = TextSnippetService()

    private init() {}

    /// Reloads the stored snippets; called by the settings page after edits.
    func syncWithPreferences() {
        let enabled = AppFeature.textSnippets.isAvailable
            && UserDefaults.standard.bool(forKey: DefaultsKey.textSnippetsEnabled)
        let config = SnippetConsumer.Config(TextSnippetSupport.decode(
            UserDefaults.standard.data(forKey: DefaultsKey.textSnippets)))
        TypingTap.shared.setSnippets(enabled && !config.isEmpty ? config : nil)
    }
}
