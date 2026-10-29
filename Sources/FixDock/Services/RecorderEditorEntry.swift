// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import Foundation

/// The seam between the recorder and its editor, which are built on separate
/// branches. The recorder calls only these. The list of open editors lives
/// here; upstream kept it in `ScreenRecorderService`.
enum RecorderEditorEntry {
    /// Main thread only, like every editor window.
    private static var editors: [RecorderEditorController] = []

    /// Whether an editor exists to open, so the preview can offer Edit.
    static var isAvailable: Bool { true }

    /// Opens the editor on a finished take and hands the take over: from then
    /// on the editor deletes it when its window closes. False means nothing
    /// opened and the caller still owns the take. Main thread only.
    static func open(_ take: RecorderTakeStore.Take) -> Bool {
        guard RecorderTakeStore.shared.owns(take) else { return false }
        // Scratch an earlier GIF export left behind (a crash or a quit) is
        // released with its lock, so it can be swept now.
        DispatchQueue.global(qos: .utility).async { RecorderGIFWorkspace.sweep() }
        let editor = RecorderEditorController(take: take)
        editors.append(editor)
        editor.show()
        return true
    }

    /// Takes held by an open editor, which a sweep must leave alone.
    /// Main thread only.
    static var ownedTakeIDs: Set<UUID> { Set(editors.map(\.takeID)) }

    /// Closes every editor, for when the recorder is uninstalled. As upstream,
    /// `NSWindow.close` does not ask first: each editor deletes its take.
    static func closeAll() {
        for editor in editors { editor.close() }
    }

    /// Called by the editor from `windowWillClose`, after it deleted its take.
    static func editorDidClose(_ editor: RecorderEditorController) {
        editors.removeAll { $0 === editor }
    }
}
