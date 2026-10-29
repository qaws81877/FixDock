// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import AppKit
import ScreenCaptureKit

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}

/// Raw pixels for the screenshot tool, through ScreenCaptureKit only. Every
/// window FixDock owns is left out, so a capture never shows the overlay,
/// the panel or Settings. Adapted from upstream, without its private
/// window-server route and attached-sheet compositing.
enum ScreenshotCaptureEngine {

    /// Every display at its own pixel scale, keyed by display id. A display
    /// that fails is absent; the caller decides what that means.
    static func captureAllDisplays() async -> [CGDirectDisplayID: CGImage] {
        guard let content = await shareableContent() else { return [:] }
        let own = ownWindows(in: content)
        var result: [CGDirectDisplayID: CGImage] = [:]
        for (id, scale) in await screenScales() {
            guard let display = content.displays.first(where: { $0.displayID == id }) else { continue }
            if let image = await capture(display, scale: scale, excluding: own) {
                result[id] = image
            }
        }
        return result
    }

    static func captureDisplay(_ displayID: CGDirectDisplayID) async -> CGImage? {
        guard let content = await shareableContent(),
              let display = content.displays.first(where: { $0.displayID == displayID })
        else { return nil }
        let scale = await screenScales()[displayID] ?? 2
        return await capture(display, scale: scale, excluding: ownWindows(in: content))
    }

    /// One window on its own at the best resolution, without its shadow.
    static func captureWindow(_ windowID: CGWindowID) async -> CGImage? {
        guard let content = await shareableContent(),
              let window = content.windows.first(where: { $0.windowID == windowID })
        else { return nil }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        configuration.width = max(1, Int((filter.contentRect.width * scale).rounded()))
        configuration.height = max(1, Int((filter.contentRect.height * scale).rounded()))
        configuration.captureResolution = .best
        configuration.ignoreShadowsSingleWindow = true
        configuration.showsCursor = false
        configuration.colorSpaceName = CGColorSpace.sRGB
        return try? await SCScreenshotManager.captureImage(contentFilter: filter,
                                                           configuration: configuration)
    }

    /// A reusable capture of one display region, for scrolling capture, which
    /// takes many frames of the same rect. `localPoints` is in the display's
    /// own points with a top-left origin.
    final class RegionCapture: @unchecked Sendable {
        private let filter: SCContentFilter
        private let configuration: SCStreamConfiguration

        fileprivate init(filter: SCContentFilter, configuration: SCStreamConfiguration) {
            self.filter = filter
            self.configuration = configuration
        }

        func image() async -> CGImage? {
            try? await SCScreenshotManager.captureImage(contentFilter: filter,
                                                       configuration: configuration)
        }
    }

    static func prepareRegion(displayID: CGDirectDisplayID, localPoints: CGRect) async -> RegionCapture? {
        guard let content = await shareableContent(),
              let display = content.displays.first(where: { $0.displayID == displayID })
        else { return nil }
        let scale = await screenScales()[displayID] ?? 2
        let bounds = CGRect(x: 0, y: 0, width: CGFloat(display.width), height: CGFloat(display.height))
        let rect = ScreenshotSupport.clamp(localPoints, to: bounds)
        guard rect.width >= 1, rect.height >= 1 else { return nil }
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = rect
        configuration.width = max(1, Int((rect.width * scale).rounded()))
        configuration.height = max(1, Int((rect.height * scale).rounded()))
        configuration.showsCursor = false
        configuration.colorSpaceName = CGColorSpace.sRGB
        let filter = SCContentFilter(display: display, excludingWindows: ownWindows(in: content))
        return RegionCapture(filter: filter, configuration: configuration)
    }

    /// Windows a click can pick, front to back, in window-server points.
    static func pickableWindows() -> [ScreenshotSupport.PickableWindow] {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        return ScreenshotSupport.pickableWindows(in: info, ownPID: getpid())
    }

    private static func shareableContent() async -> SCShareableContent? {
        try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    }

    private static func ownWindows(in content: SCShareableContent) -> [SCWindow] {
        let pid = getpid()
        return content.windows.filter { $0.owningApplication?.processID == pid }
    }

    @MainActor
    private static func screenScales() -> [CGDirectDisplayID: CGFloat] {
        Dictionary(NSScreen.screens.map { ($0.displayID, $0.backingScaleFactor) },
                   uniquingKeysWith: { first, _ in first })
    }

    private static func capture(_ display: SCDisplay, scale: CGFloat,
                                excluding own: [SCWindow]) async -> CGImage? {
        let filter = SCContentFilter(display: display, excludingWindows: own)
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int((CGFloat(display.width) * scale).rounded()))
        configuration.height = max(1, Int((CGFloat(display.height) * scale).rounded()))
        configuration.showsCursor = false
        configuration.colorSpaceName = CGColorSpace.sRGB
        return try? await SCScreenshotManager.captureImage(contentFilter: filter,
                                                           configuration: configuration)
    }
}
