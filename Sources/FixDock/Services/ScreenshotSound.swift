// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import AudioToolbox
import Foundation

/// The capture sounds: a short beep when a drag starts and a shutter when a
/// capture is taken. Played as system sounds, so they follow the alert volume
/// and the "Play sound effects through" device (owner decision). Main thread
/// only. New in FixDock.
enum ScreenshotSound: String {
    case focus = "capture-focus"
    case shutter = "capture-shutter"

    func play() {
        guard UserDefaults.standard.bool(forKey: DefaultsKey.screenshotCaptureSounds),
              let id = Self.soundID(for: self)
        else { return }
        AudioServicesPlaySystemSound(id)
    }

    /// Loaded on first use and kept; a missing file is remembered as nil.
    private static var loaded: [ScreenshotSound: SystemSoundID?] = [:]

    private static func soundID(for sound: ScreenshotSound) -> SystemSoundID? {
        if let cached = loaded[sound] { return cached }
        var id: SystemSoundID = 0
        let url = Bundle.main.url(forResource: sound.rawValue, withExtension: "wav", subdirectory: "Sounds")
        let created = url.flatMap {
            AudioServicesCreateSystemSoundID($0 as CFURL, &id) == kAudioServicesNoError ? id : nil
        }
        loaded.updateValue(created, forKey: sound)
        return created
    }
}
