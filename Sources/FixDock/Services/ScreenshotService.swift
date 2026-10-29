// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import AppKit
import Combine
import UniformTypeIdentifiers

/// The screenshot tool: its two shortcuts, the overlay session and what
/// happens to a capture. A capture is saved as a new PNG in the chosen folder
/// and copied to the clipboard as image data, each when switched on. Nothing
/// existing is ever overwritten, moved or removed. New in FixDock; the save
/// and copy rules follow upstream.
final class ScreenshotService: ObservableObject {
    static let shared = ScreenshotService()

    enum Outcome: Equatable {
        case saved(URL)
        case copied
        case failed(String)
    }

    @Published private(set) var lastOutcome: Outcome?
    @Published private(set) var isCapturing = false

    private var overlay: ScreenshotOverlayController?
    private var scrolling: ScreenshotScrollingSession?
    private var preview: ScreenshotPreviewController?
    /// Open editors, dropped as each window closes.
    private var editors: [ScreenshotEditorController] = []

    private init() {}

    /// Called on install, uninstall, launch and when a setting changes.
    func syncWithPreferences() {
        let hotkeys = HotkeyManager.shared
        if AppFeature.screenshot.isAvailable {
            hotkeys.actions[.captureOverlay] = { [weak self] in self?.overlayShortcutPressed() }
            hotkeys.actions[.captureFullScreen] = { [weak self] in self?.captureFullScreen() }
        } else {
            hotkeys.actions[.captureOverlay] = nil
            hotkeys.actions[.captureFullScreen] = nil
            cancelOverlay()
            preview?.close()
            // Uninstalling tears the tool down at once, edits included, as
            // it does the preview.
            editors.forEach { $0.closeWithoutAsking() }
        }
        hotkeys.sync()
    }

    // MARK: - Starting a capture

    /// Control-Option-Command-4. While the recorder is busy it stops the
    /// recording or cancels its countdown instead of opening the overlay.
    private func overlayShortcutPressed() {
        if ScreenRecorderService.shared.handleOverlayShortcut() { return }
        openOverlay()
    }

    /// Screenshots are blocked from a recording's countdown until its file
    /// is closed: Control-Option-Command-3 and the panel buttons beep.
    private func recorderAllowsCapture() -> Bool {
        guard ScreenRecorderSupport.allowsScreenshot(in: ScreenRecorderService.shared.captureState) else {
            NSSound.beep()
            return false
        }
        return true
    }

    /// The overlay: region, window or whole display, with the bottom bar.
    func openOverlay() {
        guard prepareToCapture() else { return }
        isCapturing = true
        Task { @MainActor [weak self] in
            let images = await ScreenshotCaptureEngine.captureAllDisplays()
            guard let self else { return }
            // Uninstalled while the displays were being read.
            guard self.isCapturing, AppFeature.screenshot.isAvailable else { return }
            guard !images.isEmpty else {
                self.isCapturing = false
                self.fail(L10n.shared.s.screenshotCaptureFailed)
                return
            }
            let controller = ScreenshotOverlayController(frozen: images,
                                                         windows: ScreenshotCaptureEngine.pickableWindows())
            controller.onFinish = { [weak self] result in self?.finishOverlay(result) }
            self.overlay = controller
            controller.present()
        }
    }

    /// The display under the pointer, at once.
    func captureFullScreen() {
        guard prepareToCapture() else { return }
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main
        guard let displayID = screen?.displayID else { return }
        isCapturing = true
        Task { @MainActor in
            let image = await ScreenshotCaptureEngine.captureDisplay(displayID)
            self.isCapturing = false
            guard let image else {
                self.fail(L10n.shared.s.screenshotCaptureFailed)
                return
            }
            self.deliver(image, anchor: screen?.frame)
        }
    }

    func cancelOverlay() {
        overlay?.cancel()
        overlay = nil
        scrolling?.cancel()
        isCapturing = false
    }

    /// False when a session is already running or the grant is missing; the
    /// guide takes over in the second case.
    private func prepareToCapture() -> Bool {
        guard AppFeature.screenshot.isAvailable, overlay == nil, scrolling == nil, !isCapturing,
              recorderAllowsCapture()
        else { return false }
        Permissions.shared.refresh()
        guard Permissions.shared.screenRecording else {
            Permissions.shared.request(.screenRecording)
            return false
        }
        appDelegate()?.closePopover()
        return true
    }

    private func finishOverlay(_ result: ScreenshotOverlayController.Result) {
        overlay = nil
        isCapturing = false
        switch result {
        case .cancelled:
            break
        case .image(let image, let anchor):
            deliver(image, anchor: anchor)
        case .scrolling(let displayID, let localRect):
            startScrolling(displayID: displayID, localRect: localRect)
        case .recording(let region):
            // The overlay panels are already ordered out; the recorder waits
            // a moment more before its stream starts.
            ScreenRecorderService.shared.record(region)
        case .failed:
            fail(L10n.shared.s.screenshotCaptureFailed)
        }
    }

    private func startScrolling(displayID: CGDirectDisplayID, localRect: CGRect) {
        guard let session = ScreenshotScrollingSession(displayID: displayID, localRect: localRect) else {
            fail(L10n.shared.s.screenshotCaptureFailed)
            return
        }
        isCapturing = true
        session.onFinish = { [weak self] result in
            guard let self else { return }
            self.scrolling = nil
            self.isCapturing = false
            switch result {
            case .image(let image, _):
                self.deliver(image, anchor: session.screenRect)
            case .cancelled:
                break
            case .failed:
                self.fail(L10n.shared.s.screenshotCaptureFailed)
            }
        }
        scrolling = session
        session.start()
    }

    // MARK: - Output

    /// `anchor` is the captured area in Cocoa screen points: where the
    /// automatic preview sits, and the scale a pin is drawn at.
    func deliver(_ image: CGImage, anchor: CGRect? = nil) {
        let defaults = UserDefaults.standard
        let save = defaults.bool(forKey: DefaultsKey.screenshotSaveToFile)
        let copy = defaults.bool(forKey: DefaultsKey.screenshotCopyToClipboard)
        guard let png = Self.pngData(image) else {
            fail(L10n.shared.s.screenshotCaptureFailed)
            return
        }
        if defaults.bool(forKey: DefaultsKey.screenshotShowPreview) {
            showPreview(image, png: png, copy: copy, anchor: anchor)
            return
        }
        var outcome: Outcome = .copied
        if save {
            switch Self.write(png, to: Self.saveFolder) {
            case .success(let url):
                outcome = .saved(url)
            case .failure:
                // A copy still happens: the picture is not lost to the folder.
                if copy { copyToClipboard(image, png: png) }
                fail(L10n.shared.s.screenshotFolderUnavailable)
                return
            }
        }
        if copy { copyToClipboard(image, png: png) }
        if save || copy {
            lastOutcome = outcome
        }
    }

    /// With the preview on, only the copy is automatic. The file is written
    /// when Save is pressed there; closing the preview keeps nothing on disk.
    /// A new capture replaces a preview still on screen.
    private func showPreview(_ image: CGImage, png: Data, copy: Bool, anchor: CGRect?) {
        preview?.close()
        if copy {
            copyToClipboard(image, png: png)
            lastOutcome = .copied
        }
        let controller = ScreenshotPreviewController(
            image: image, png: png, anchor: anchor, copied: copy,
            perform: { [weak self] action in
                guard let self else { return false }
                switch action {
                case .save:
                    switch Self.write(png, to: Self.saveFolder) {
                    case .success(let url):
                        self.lastOutcome = .saved(url)
                        return true
                    case .failure:
                        self.fail(L10n.shared.s.screenshotFolderUnavailable)
                        return false
                    }
                case .copy:
                    self.copyToClipboard(image, png: png)
                    self.lastOutcome = .copied
                    return true
                case .pin:
                    ScreenshotPinController.shared.pin(image: image, scale: Self.scale(of: image, anchor: anchor))
                    return true
                case .edit:
                    // The preview closes without saving; the editor owns the
                    // capture from here.
                    self.openEditor(image: image, scale: Self.scale(of: image, anchor: anchor))
                    return true
                case .discard:
                    // Nothing was written: Save closes the preview, so a
                    // discard never has a file to remove.
                    return true
                }
            },
            onClose: { [weak self] in self?.preview = nil })
        preview = controller
        controller.show()
    }

    /// Pixels per point of a capture: from the area it came from, else the
    /// main display's.
    private static func scale(of image: CGImage, anchor: CGRect?) -> CGFloat {
        let scale = anchor.map { $0.width > 0 ? CGFloat(image.width) / $0.width : 2 }
            ?? (NSScreen.main?.backingScaleFactor ?? 2)
        return max(1, scale)
    }

    // MARK: - Editor

    func openEditor(image: CGImage, scale: CGFloat) {
        guard AppFeature.screenshot.isAvailable else { return }
        let editor = ScreenshotEditorController(image: image, scale: scale)
        editors.append(editor)
        editor.show()
    }

    func editorDidClose(_ editor: ScreenshotEditorController) {
        editors.removeAll { $0 === editor }
    }

    /// The editor's Save: a new file in the chosen folder, as the preview's
    /// Save. False after the beep and message when the folder is unusable.
    func saveEdited(_ png: Data) -> Bool {
        switch Self.write(png, to: Self.saveFolder) {
        case .success(let url):
            lastOutcome = .saved(url)
            return true
        case .failure:
            fail(L10n.shared.s.screenshotFolderUnavailable)
            return false
        }
    }

    /// Save As wrote `url` after the save panel's own replace question.
    func editorSaved(_ url: URL) {
        lastOutcome = .saved(url)
    }

    /// The edited image on the clipboard, image data only.
    func copyEdited(_ image: CGImage) -> Bool {
        guard copyImage(image) else { return false }
        lastOutcome = .copied
        return true
    }

    private func fail(_ message: String) {
        NSSound.beep()
        lastOutcome = .failed(message)
    }

    /// The chosen folder, or the Desktop when none is set.
    static var saveFolder: URL {
        let path = UserDefaults.standard.string(forKey: DefaultsKey.screenshotSaveFolder) ?? ""
        if !path.isEmpty { return URL(fileURLWithPath: path, isDirectory: true) }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop")
    }

    static func saveFolderIsUsable(_ folder: URL = saveFolder) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
            && FileManager.default.isWritableFile(atPath: folder.path)
    }

    enum WriteError: Error { case folderUnavailable, nameExhausted, writeFailed }

    /// Writes a new file only: the name is made unique and the write itself
    /// refuses to replace an existing file, so a race cannot overwrite one.
    static func write(_ png: Data, to folder: URL, date: Date = Date()) -> Result<URL, WriteError> {
        guard saveFolderIsUsable(folder) else { return .failure(.folderUnavailable) }
        let base = ScreenshotSupport.fileName(prefix: L10n.shared.s.screenshotFilePrefix, date: date)
        guard let name = ScreenshotSupport.uniqueFileName(base, exists: {
            FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
        }) else { return .failure(.nameExhausted) }
        let url = folder.appendingPathComponent(name)
        do {
            try png.write(to: url, options: .withoutOverwriting)
        } catch {
            return .failure(.writeFailed)
        }
        ScreenshotSupport.markAsScreenCapture(url)
        return .success(url)
    }

    /// The image on the clipboard, for a pin's and the editor's Copy.
    @discardableResult
    func copyImage(_ image: CGImage) -> Bool {
        guard let png = Self.pngData(image) else {
            NSSound.beep()
            return false
        }
        copyToClipboard(image, png: png)
        return true
    }

    /// Text on the clipboard (a QR payload, recognized text, a colour), marked
    /// as FixDock's so the URL cleaner leaves it alone.
    static func copyText(_ text: String) {
        GeneralPasteboardAccess.shared.async {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.declareAppSource()
            pasteboard.setString(text, forType: .string)
            let changeCount = pasteboard.changeCount
            DispatchQueue.main.async {
                URLCleanerService.shared.ignoreChanges(upTo: changeCount)
            }
        }
    }

    /// Image data only, no file URL, so the URL cleaner never sees a path and
    /// nothing temporary is left to clean up.
    private func copyToClipboard(_ image: CGImage, png: Data) {
        let tiff = NSBitmapImageRep(cgImage: image).tiffRepresentation
        GeneralPasteboardAccess.shared.async {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.declareAppSource()
            pasteboard.setData(png, forType: .png)
            if let tiff { pasteboard.setData(tiff, forType: .tiff) }
            let changeCount = pasteboard.changeCount
            DispatchQueue.main.async {
                URLCleanerService.shared.ignoreChanges(upTo: changeCount)
            }
        }
    }

    static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
