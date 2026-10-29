// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import AppKit

/// A panel that floats over other apps. A non-activating panel is described
/// to the system as a dialog, which some window managers then track. An
/// undescribed accessible window is left alone. Adapted from upstream.
class OverlayPanel: NSPanel {
    override func accessibilitySubrole() -> NSAccessibility.Subrole? { .unknown }
}
