// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import Foundation

/// The editor's preference keys, kept out of `DefaultsKey` and
/// `Defaults.register` while the recorder branch is changing those files.
/// Names and defaults are upstream's. `recorderQuality` and
/// `recorderSystemAudio` belong to the recorder's settings; the editor only
/// reads them for a recording's first look. At the merge these move into
/// `DefaultsKey` and `Defaults.register`.
enum RecorderEditorDefaults {
    static let recorderQuality = "recorderQuality"
    static let recorderSystemAudio = "recorderSystemAudio"
    static let recorderAutomaticZoom = "recorderAutomaticZoom"
    static let recorderGIFSize = "recorderGIFSize"
    static let recorderGIFFrameRate = "recorderGIFFrameRate"
    static let recorderEditorPresets = "recorderEditorPresets"

    /// Registered values are only fallbacks, so registering again is harmless.
    static func register() {
        UserDefaults.standard.register(defaults: [
            recorderQuality: RecorderSupport.Quality.balanced.rawValue,
            recorderSystemAudio: true,
            recorderAutomaticZoom: true,
            recorderGIFSize: RecorderSupport.GIFSize.medium.rawValue,
            recorderGIFFrameRate: 12,
            recorderEditorPresets: Data(),
        ])
    }
}
