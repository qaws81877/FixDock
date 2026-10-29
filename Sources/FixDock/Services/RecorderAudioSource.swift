// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import AVFoundation

/// The two sound sources a take can carry. Their stable identifiers live in
/// track metadata so new recordings never depend on track order.
enum RecorderAudioSource: String, CaseIterable, Hashable {
    /// The writer stamps this on each audio track and the editor matches on
    /// it, so both sides must use this one constant.
    static let identifierPrefix = "io.github.qaws81877.fixdock.recorder.audio."

    case system
    case microphone

    private var contentIdentifier: String {
        RecorderAudioSource.identifierPrefix + rawValue
    }

    var trackMetadata: [AVMetadataItem] {
        let item = AVMutableMetadataItem()
        item.identifier = .quickTimeMetadataContentIdentifier
        item.value = contentIdentifier as NSString
        item.dataType = kCMMetadataBaseDataType_UTF8 as String
        return [item]
    }

    static func tracks(in asset: AVAsset) async -> [RecorderAudioSource: AVAssetTrack] {
        let tracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        var result: [RecorderAudioSource: AVAssetTrack] = [:]
        var unmatched: [AVAssetTrack] = []

        for track in tracks {
            let metadata = (try? await track.load(.metadata)) ?? []
            var source: RecorderAudioSource?
            for item in metadata where item.identifier == .quickTimeMetadataContentIdentifier {
                guard let value = try? await item.load(.stringValue) else { continue }
                source = allCases.first { $0.contentIdentifier == value }
                if source != nil { break }
            }
            if let source, result[source] == nil {
                result[source] = track
            } else {
                unmatched.append(track)
            }
        }

        // Takes from before track metadata existed carried only system sound.
        // The fallback also keeps hand-authored files usable in the editor.
        for source in allCases where result[source] == nil {
            guard !unmatched.isEmpty else { break }
            result[source] = unmatched.removeFirst()
        }
        return result
    }
}
