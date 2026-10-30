// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import AppKit
import SwiftUI

/// The FixDock app icon at a given size, read from the bundle's AppIcon.icns.
/// A bare `swift build` has no bundle icon and shows the generic app icon.
struct AppIconImage: View {
    var size: CGFloat = 32

    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// The menu bar mark (Resources/Icons/fixdock-mark.svg) as a template image,
/// or nil when the file is missing, as in a bare `swift build`.
enum FixDockMark {
    static func templateImage(size: CGFloat) -> NSImage? {
        guard let url = Bundle.main.url(forResource: "fixdock-mark", withExtension: "svg", subdirectory: "Icons"),
              let image = NSImage(contentsOf: url)
        else { return nil }
        image.isTemplate = true
        image.size = NSSize(width: size, height: size)
        return image
    }
}
