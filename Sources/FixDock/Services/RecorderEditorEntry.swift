// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import Foundation

/// The seam between the recorder and its editor, which are built on separate
/// branches. The recorder calls only these; the editor fills in the bodies.
/// Until it does, there is no editor: the recorder keeps every take it
/// finishes and decides itself when to delete it.
enum RecorderEditorEntry {
    /// Whether an editor exists to open, so the preview can offer Edit.
    static var isAvailable: Bool { false }

    /// Opens the editor on a finished take and hands the take over: from then
    /// on the editor deletes it when its window closes. False means nothing
    /// opened and the caller still owns the take. Main thread only.
    static func open(_ take: RecorderTakeStore.Take) -> Bool { false }

    /// Takes held by an open editor, which a sweep must leave alone.
    /// Main thread only.
    static var ownedTakeIDs: Set<UUID> { [] }

    /// Closes every editor, for when the recorder is uninstalled.
    static func closeAll() {}
}
