// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import AppKit

extension NSPasteboard.PasteboardType {
    /// The nspasteboard.org mark naming the app that wrote the pasteboard.
    static let source = NSPasteboard.PasteboardType("org.nspasteboard.source")
    /// Added by the system to a copy that arrived from another device.
    static let remoteClipboard = NSPasteboard.PasteboardType("com.apple.is-remote-clipboard")
}

extension NSPasteboard {
    /// Signs a write this app makes for itself, so a later reader can tell the
    /// cleaned link came from FixDock. Called after the pasteboard is cleared.
    func declareAppSource() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        setString(bundleID, forType: .source)
    }
}
