// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import AppKit
import SwiftUI

/// An icon from the bundled Reicon set (MIT, see Resources/Icons), drawn as
/// a template so it takes the surrounding foreground color. Falls back to
/// the given SF Symbol when the file is missing, as in a bare `swift build`.
struct ReiconImage: View {
    enum Name: String {
        case lock = "reicon-lock"
        case shield = "reicon-shield"
        case shieldFill = "reicon-shield-fill"
        case folder = "reicon-folder"

        var fallbackSymbol: String {
            switch self {
            case .lock: return "lock.fill"
            case .shield: return "shield"
            case .shieldFill: return "shield.fill"
            case .folder: return "folder"
            }
        }
    }

    let name: Name
    var size: CGFloat = 14

    var body: some View {
        if let image = Self.image(name) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        } else {
            Image(systemName: name.fallbackSymbol)
                .font(.system(size: size * 0.85))
                .frame(width: size, height: size)
        }
    }

    private static var cache: [Name: NSImage] = [:]

    private static func image(_ name: Name) -> NSImage? {
        if let cached = cache[name] { return cached }
        guard let url = Bundle.main.url(forResource: name.rawValue, withExtension: "svg", subdirectory: "Icons"),
              let image = NSImage(contentsOf: url)
        else { return nil }
        image.isTemplate = true
        cache[name] = image
        return image
    }
}
