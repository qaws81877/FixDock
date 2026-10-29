// swift-tools-version:5.9
// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import PackageDescription

// FixDock is built with build.sh, which pins the macOS SDK and assembles the
// .app bundle. `swift build` compiles the executable only.
let package = Package(
    name: "FixDock",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "FixDock", targets: ["FixDock"])
    ],
    targets: [
        .executableTarget(
            name: "FixDock",
            path: "Sources/FixDock"
        )
    ]
)
