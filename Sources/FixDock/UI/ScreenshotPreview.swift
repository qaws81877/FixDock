// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// What the preview's buttons show: what already happened, what a scan
/// found, and a short line after Copy text.
final class ScreenshotPreviewModel: ObservableObject {
    @Published var copied = false
    @Published var code: ScreenshotRecognition.CodeReading?
    @Published var readingText = false
    @Published var notice: String?
}

/// The small window after a capture: the thumbnail with close, QR (when a
/// code is found), Copy text, Share and Pin on it, then Trash, Save, Copy and
/// Edit. The thumbnail can be dragged into Finder or another app; a click on
/// it opens the editor. A file is written only by Save or a drop; closing,
/// Esc and Trash leave nothing on disk. Save, Copy, Pin, Edit, a share target
/// and a drop close the preview, as upstream. QR and Copy text keep it open,
/// since closing would drop an unsaved capture. Adapted from the upstream
/// quick preview, without its upload link and notch.
final class ScreenshotPreviewController: NSObject, NSSharingServicePickerDelegate {
    enum Action { case save, copy, pin, edit, discard }

    private let image: CGImage
    private let png: Data
    private let anchor: CGRect?
    private let model = ScreenshotPreviewModel()
    private let perform: (Action) -> Bool
    private let onClose: () -> Void
    private let shareAnchor = ShareAnchor()
    private var panel: ScreenshotPreviewPanel?
    private var keyMonitor: Any?
    private var closeWork: DispatchWorkItem?
    private var noticeWork: DispatchWorkItem?
    private var closed = false
    private var sharing = false
    private var dragging = false
    private var pointerInside = false

    static let size = CGSize(width: 350, height: 210)

    /// `perform` runs one action and reports whether it worked. `anchor` is
    /// the captured area in Cocoa screen points, for the automatic position.
    init(image: CGImage, png: Data, anchor: CGRect?, copied: Bool,
         perform: @escaping (Action) -> Bool, onClose: @escaping () -> Void) {
        self.image = image
        self.png = png
        self.anchor = anchor
        self.perform = perform
        self.onClose = onClose
        model.copied = copied
    }

    func show() {
        guard panel == nil, !closed else { return }
        let content = ScreenshotPreviewView(
            image: Self.thumbnail(for: image), model: model, shareAnchor: shareAnchor,
            dragSource: { [weak self] in self?.makeDragWriter() },
            dragEnded: { [weak self] dropped in self?.dragEnded(dropped) },
            dragBegan: { [weak self] in self?.dragging = true; self?.closeWork?.cancel() },
            clicked: { [weak self] in self?.run(.edit) },
            run: { [weak self] action in self?.run(action) },
            share: { [weak self] in self?.share() },
            showCode: { [weak self] in self?.showCode() },
            copyText: { [weak self] in self?.copyText() },
            hover: { [weak self] inside in self?.hoverChanged(inside) },
            dismiss: { [weak self] in self?.close() })
        let panel = ScreenshotPreviewPanel(contentRect: CGRect(origin: .zero, size: Self.size),
                                           styleMask: [.borderless, .nonactivatingPanel],
                                           backing: .buffered, defer: false)
        panel.contentViewController = NSHostingController(rootView: content)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.setFrame(frame(), display: false)
        self.panel = panel
        installKeyMonitor(for: panel)
        panel.orderFrontRegardless()
        // Esc, ⌘S and ⌘C work at once, as upstream's default.
        panel.makeKey()
        scanForCode()
        scheduleClose()
    }

    func close() {
        guard !closed else { return }
        closed = true
        closeWork?.cancel()
        noticeWork?.cancel()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        panel?.orderOut(nil)
        panel = nil
        onClose()
    }

    private func run(_ action: Action) {
        guard !closed, !sharing else { return }
        if action == .copy, model.copied { return }
        if perform(action) { close() }
    }

    // MARK: - Automatic close

    /// The chosen delay, paused while the pointer is over the preview or a
    /// share, drag or code panel is open. Off by default.
    private func scheduleClose() {
        closeWork?.cancel()
        closeWork = nil
        let seconds = UserDefaults.standard.integer(forKey: DefaultsKey.screenshotPreviewCloseSeconds)
        guard seconds > 0, !closed, !pointerInside, !sharing, !dragging,
              !ScreenshotQRResultController.shared.isShown else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // The code panel may have opened since; wait for it.
            if ScreenshotQRResultController.shared.isShown { self.scheduleClose() } else { self.close() }
        }
        closeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(seconds), execute: work)
    }

    private func hoverChanged(_ inside: Bool) {
        pointerInside = inside
        if inside { closeWork?.cancel() } else { scheduleClose() }
    }

    // MARK: - Codes and text

    /// Off the main thread, so the preview never waits on detection; the QR
    /// button appears when a code is found.
    private func scanForCode() {
        let image = image
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let reading = ScreenshotRecognition.readCodes(image) else { return }
            DispatchQueue.main.async {
                guard let self, !self.closed else { return }
                withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) { self.model.code = reading }
            }
        }
    }

    private func showCode() {
        guard let code = model.code else { return }
        closeWork?.cancel()
        ScreenshotQRResultController.shared.show(code)
    }

    private func copyText() {
        guard !closed, !model.readingText else { return }
        model.readingText = true
        let image = image
        let languages = ScreenshotRecognition.preferredLanguages(for: L10n.shared.language)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let text = ScreenshotRecognition.readText(image, languages: languages)
            DispatchQueue.main.async {
                guard let self, !self.closed else { return }
                self.model.readingText = false
                let s = L10n.shared.s
                if text.isEmpty {
                    self.showNotice(s.screenshotPreviewNoText)
                } else {
                    ScreenshotService.copyText(text)
                    // The clipboard now holds text, so Copy can put the image back.
                    self.model.copied = false
                    self.showNotice(s.screenshotPreviewTextCopied)
                }
            }
        }
    }

    private func showNotice(_ text: String) {
        model.notice = text
        noticeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.model.notice = nil }
        noticeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }

    // MARK: - Share and drag

    /// The system share sheet with the image itself, so nothing temporary is
    /// written. A chosen target closes the preview without saving.
    private func share() {
        guard !closed, !sharing, let view = shareAnchor.view else { return }
        let picker = NSSharingServicePicker(items: [NSImage(cgImage: image, size: .zero)])
        picker.delegate = self
        sharing = true
        closeWork?.cancel()
        picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }

    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker,
                              didChoose service: NSSharingService?) {
        sharing = false
        if service != nil { close() } else { scheduleClose() }
    }

    /// A file promise: the receiver names the folder and the PNG is written
    /// there, new, so nothing temporary is left behind. Apps that take image
    /// data get the PNG directly.
    private func makeDragWriter() -> NSPasteboardWriting {
        let name = ScreenshotSupport.fileName(prefix: L10n.shared.s.screenshotFilePrefix, date: Date())
        return ScreenshotPromiseProvider(png: png, fileName: name)
    }

    private func dragEnded(_ dropped: Bool) {
        dragging = false
        if dropped { close() } else { scheduleClose() }
    }

    // MARK: - Panel

    private func frame() -> CGRect {
        let pointer = NSEvent.mouseLocation
        let center = anchor.map { CGPoint(x: $0.midX, y: $0.midY) } ?? pointer
        let screen = NSScreen.screens.first { NSMouseInRect(center, $0.frame, false) }
            ?? NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let raw = UserDefaults.standard.string(forKey: DefaultsKey.screenshotPreviewPosition) ?? ""
        let position = ScreenshotSupport.PreviewPosition(rawValue: raw) ?? .bottomRight
        return ScreenshotSupport.previewFrame(size: Self.size, anchor: anchor, pointer: pointer,
                                              visibleFrame: visible, position: position)
    }

    private func installKeyMonitor(for panel: NSPanel) {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak panel] event in
            guard let self, !self.closed, let panel, event.window === panel else { return event }
            let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
            let key = Int(event.keyCode)
            if flags == .command {
                switch key {
                case kVK_ANSI_S: self.run(.save)
                case kVK_ANSI_C: self.run(.copy)
                case kVK_ANSI_W: self.close()
                case kVK_Delete, kVK_ForwardDelete: self.run(.discard)
                default: return event
                }
                return nil
            }
            guard flags.isEmpty else { return event }
            switch key {
            case kVK_Escape: self.close()
            case kVK_Delete, kVK_ForwardDelete: self.run(.discard)
            case kVK_Return, kVK_ANSI_KeypadEnter, kVK_ANSI_E: self.run(.edit)
            default: return event
            }
            return nil
        }
    }

    /// At most 1200 pixels on the long side, enough for a 320-point thumbnail.
    private static func thumbnail(for image: CGImage) -> CGImage {
        let maximum: CGFloat = 1_200
        let longest = CGFloat(max(image.width, image.height))
        guard longest > maximum else { return image }
        let factor = maximum / longest
        let width = max(1, Int((CGFloat(image.width) * factor).rounded()))
        let height = max(1, Int((CGFloat(image.height) * factor).rounded()))
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

/// A dragged capture: a file promise for Finder and folders, plus PNG data
/// for apps that take an image.
private final class ScreenshotPromiseProvider: NSFilePromiseProvider, NSFilePromiseProviderDelegate {
    private let png: Data
    private let name: String

    init(png: Data, fileName: String) {
        self.png = png
        self.name = fileName
        super.init()
        fileType = UTType.png.identifier
        delegate = self
    }

    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        super.writableTypes(for: pasteboard) + [.png]
    }

    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        type == .png ? png : super.pasteboardPropertyList(forType: type)
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        name
    }

    /// Writes a new file only. When the name is taken in the drop folder, the
    /// next free ` (2)` name is used instead of replacing anything.
    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL,
                             completionHandler: @escaping (Error?) -> Void) {
        let folder = url.deletingLastPathComponent()
        let manager = FileManager.default
        let target: URL
        if manager.fileExists(atPath: url.path) {
            guard let free = ScreenshotSupport.uniqueFileName(url.lastPathComponent, exists: {
                manager.fileExists(atPath: folder.appendingPathComponent($0).path)
            }) else {
                completionHandler(CocoaError(.fileWriteFileExists))
                return
            }
            target = folder.appendingPathComponent(free)
        } else {
            target = url
        }
        do {
            try png.write(to: target, options: .withoutOverwriting)
            ScreenshotSupport.markAsScreenCapture(target)
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
    }
}

/// Holds the share button's view so the picker can open beside it.
final class ShareAnchor {
    weak var view: NSView?
}

private struct ShareAnchorView: NSViewRepresentable {
    let anchor: ShareAnchor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        anchor.view = nsView
    }
}

/// A transparent view over the thumbnail that starts an AppKit drag, since a
/// file promise needs a dragging session rather than SwiftUI's item provider.
private struct DragSourceView: NSViewRepresentable {
    let writer: () -> NSPasteboardWriting?
    let image: CGImage
    let began: () -> Void
    let ended: (Bool) -> Void
    let clicked: () -> Void

    func makeNSView(context: Context) -> DragSourceNSView {
        let view = DragSourceNSView()
        update(view)
        return view
    }

    func updateNSView(_ nsView: DragSourceNSView, context: Context) {
        update(nsView)
    }

    private func update(_ view: DragSourceNSView) {
        view.writer = writer
        view.image = image
        view.began = began
        view.ended = ended
        view.clicked = clicked
    }
}

private final class DragSourceNSView: NSView, NSDraggingSource {
    var writer: (() -> NSPasteboardWriting?)?
    var image: CGImage?
    var began: (() -> Void)?
    var ended: ((Bool) -> Void)?
    var clicked: (() -> Void)?
    private var downAt: CGPoint?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        downAt = event.locationInWindow
        window?.makeKey()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = downAt, let writer = writer?(), let image else { return }
        let point = event.locationInWindow
        guard hypot(point.x - start.x, point.y - start.y) > 3 else { return }
        downAt = nil
        let item = NSDraggingItem(pasteboardWriter: writer)
        let ratio = CGFloat(image.width) / CGFloat(max(1, image.height))
        let side: CGFloat = 120
        let size = ratio >= 1 ? CGSize(width: side, height: side / ratio) : CGSize(width: side * ratio, height: side)
        let local = convert(point, from: nil)
        item.setDraggingFrame(CGRect(x: local.x - size.width / 2, y: local.y - size.height / 2,
                                     width: size.width, height: size.height),
                              contents: NSImage(cgImage: image, size: size))
        began?()
        beginDraggingSession(with: [item], event: event, source: self)
    }

    /// A drag clears `downAt` once it starts, so a press still recorded here
    /// never became a drag: it is a click.
    override func mouseUp(with event: NSEvent) {
        let wasClick = downAt != nil
        downAt = nil
        if wasClick { clicked?() }
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        ended?(!operation.isEmpty)
    }
}

/// Becomes key on a click too, so the keys reach it after focus moved away.
private final class ScreenshotPreviewPanel: OverlayPanel {
    override var canBecomeKey: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, !isKeyWindow { makeKey() }
        super.sendEvent(event)
    }
}

private struct ScreenshotPreviewView: View {
    let image: CGImage
    @ObservedObject var model: ScreenshotPreviewModel
    let shareAnchor: ShareAnchor
    let dragSource: () -> NSPasteboardWriting?
    let dragEnded: (Bool) -> Void
    let dragBegan: () -> Void
    let clicked: () -> Void
    let run: (ScreenshotPreviewController.Action) -> Void
    let share: () -> Void
    let showCode: () -> Void
    let copyText: () -> Void
    let hover: (Bool) -> Void
    let dismiss: () -> Void
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        let s = l10n.s
        VStack(spacing: 10) {
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 320, height: 138)
                .background(Color.black.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
                .overlay(DragSourceView(writer: dragSource, image: image, began: dragBegan, ended: dragEnded,
                                        clicked: clicked)
                    .help(s.screenshotPreviewDragHint))
                .overlay(alignment: .topLeading) {
                    circleButton("xmark", s.screenshotPreviewClose + "  (⎋)", action: dismiss)
                        .padding(6)
                }
                .overlay(alignment: .topTrailing) {
                    HStack(spacing: 5) {
                        if model.code != nil {
                            circleButton("qrcode", s.screenshotPreviewQR, action: showCode)
                                .transition(.scale.combined(with: .opacity))
                        }
                        circleButton(model.readingText ? "ellipsis" : "text.viewfinder",
                                     s.screenshotPreviewCopyText, enabled: !model.readingText,
                                     action: copyText)
                        circleButton("square.and.arrow.up", s.screenshotPreviewShare, action: share)
                            .background(ShareAnchorView(anchor: shareAnchor))
                        circleButton("pin", s.screenshotPreviewPin) { run(.pin) }
                    }
                    .padding(6)
                }
                .overlay(alignment: .bottom) {
                    if let notice = model.notice {
                        Text(notice)
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(.regularMaterial, in: Capsule())
                            .padding(6)
                            .transition(.opacity)
                    }
                }

            HStack(spacing: 5) {
                Button { run(.discard) } label: {
                    Image(systemName: "trash").frame(width: 22, height: 18)
                }
                .help(s.screenshotPreviewDiscard + "  (⌫)")
                actionButton("square.and.arrow.down", s.screenshotPreviewSave, "⌘S", disabled: false) {
                    run(.save)
                }
                actionButton("doc.on.doc", s.screenshotPreviewCopy, "⌘C", disabled: model.copied) {
                    run(.copy)
                }
                Spacer(minLength: 4)
                Button(s.screenshotPreviewEdit) { run(.edit) }
                    .buttonStyle(.borderedProminent)
                    .help(s.screenshotPreviewEdit + "  (⏎)")
            }
            .controlSize(.small)
        }
        .padding(10)
        .frame(width: ScreenshotPreviewController.size.width, height: ScreenshotPreviewController.size.height)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1))
        .onHover(perform: hover)
    }

    private func actionButton(_ symbol: String, _ title: String, _ shortcut: String, disabled: Bool,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
        }
        .disabled(disabled)
        .help("\(title)  (\(shortcut))")
    }

    private func circleButton(_ symbol: String, _ title: String, enabled: Bool = true,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 24, height: 24)
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .help(title)
    }
}
