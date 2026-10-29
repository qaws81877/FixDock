// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import CoreGraphics
import Vision

/// Offline Vision reads of a capture for the preview: matrix codes (QR and
/// relatives) and text. Nothing leaves the Mac. Adapted from the upstream
/// barcode detector and screen text service.
enum ScreenshotRecognition {
    /// What a scanned code holds, and a web link only when a single code is
    /// a plain http or https address.
    struct CodeReading: Equatable {
        let payload: String
        let url: URL?
    }

    /// Matrix codes only: 1D barcodes misfire on any striped area of a screen.
    private static let symbologies: [VNBarcodeSymbology] = [.qr, .microQR, .aztec, .dataMatrix, .pdf417]

    static func readCodes(_ image: CGImage) -> CodeReading? {
        let request = VNDetectBarcodesRequest()
        request.symbologies = symbologies
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let codes = (request.results ?? []).compactMap { observation -> ScreenshotSupport.RecognizedItem? in
            guard let payload = observation.payloadStringValue, !payload.isEmpty else { return nil }
            return ScreenshotSupport.RecognizedItem(text: payload, x: Double(observation.boundingBox.minX),
                                                    y: Double(observation.boundingBox.midY))
        }
        let payload = ScreenshotSupport.joinedReadingOrder(codes)
        guard !payload.isEmpty else { return nil }
        return CodeReading(payload: payload,
                           url: codes.count == 1 ? ScreenshotSupport.openableURL(from: payload) : nil)
    }

    /// The text in the image in reading order, empty when there is none. The
    /// accurate model first, then the fast one as a second chance.
    static func readText(_ image: CGImage, languages: [String]) -> String {
        let source = scaledForRecognition(image)
        var lines = recognizedLines(source, level: .accurate, detectLanguage: true, languages: languages)
        if lines.isEmpty {
            lines = recognizedLines(source, level: .fast, detectLanguage: false, languages: languages)
        }
        return ScreenshotSupport.joinedReadingOrder(lines)
    }

    /// The app's language first, so Korean text reads as Korean.
    static func preferredLanguages(for language: AppLanguage) -> [String] {
        language == .ko ? ["ko-KR", "en-US"] : ["en-US", "ko-KR"]
    }

    private static func recognizedLines(_ image: CGImage, level: VNRequestTextRecognitionLevel,
                                        detectLanguage: Bool,
                                        languages: [String]) -> [ScreenshotSupport.RecognizedItem] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = level
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = detectLanguage
        if let supported = try? request.supportedRecognitionLanguages() {
            let available = languages.filter { supported.contains($0) }
            if !available.isEmpty { request.recognitionLanguages = available }
        }
        guard (try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])) != nil
        else { return [] }
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return ScreenshotSupport.RecognizedItem(text: candidate.string,
                                                    x: Double(observation.boundingBox.minX),
                                                    y: Double(observation.boundingBox.midY))
        }
    }

    /// A long scrolling capture can run to tens of megapixels; Vision reads a
    /// copy no larger than about 24 megapixels.
    private static func scaledForRecognition(_ image: CGImage) -> CGImage {
        let limit = 24_000_000.0
        let pixels = Double(image.width) * Double(image.height)
        guard pixels > limit else { return image }
        let factor = (limit / pixels).squareRoot()
        let width = max(1, Int(Double(image.width) * factor))
        let height = max(1, Int(Double(image.height) * factor))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }
}
