// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import CoreGraphics

/// Recognises keyboard events this app posts itself, so a filter meant for
/// physical typing can leave them alone.
///
/// Quit Protection confirms a press by posting a copy of the hardware key
/// down, which starts with the hardware source's process id of 0, so the
/// copy carries this marker in its user data instead. Text Snippets types
/// through a source carrying its own marker.
enum OwnKeyEvent {
    static let quitProtectionMarker: Int64 = 0x464958444F434B51 // "FIXDOCKQ"
    static let textSnippetMarker: Int64 = 0x464958444F434B53 // "FIXDOCKS"
}
