// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import AppKit

// The relaunch and update helper is this same executable; it must run before
// anything below touches defaults or AppKit.
Relauncher.runIfHelper(CommandLine.arguments)

// Login-item cleanup for Tools/uninstall.sh. The app is still on disk here,
// which is the only moment Service Management will drop the registration.
if CommandLine.arguments.contains("--unregister-login-item") {
    let semaphore = DispatchSemaphore(value: 0)
    LaunchAtLogin.setEnabled(false) { _, _ in
        semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + 5)
    exit(EXIT_SUCCESS)
}

Defaults.register()

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
