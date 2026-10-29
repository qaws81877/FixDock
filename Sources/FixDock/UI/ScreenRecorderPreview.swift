// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import AVFoundation
import AppKit
import Carbon.HIToolbox
import SwiftUI

/// The small window after a recording, like the screenshot preview: the
/// movie's first frame with close at the top left and Share at the top right,
/// then Show in Finder and, once the editor exists, Edit. The movie is
/// already saved when this appears; the window only holds the take behind it.
/// Show in Finder, a chosen share target, a drop and Edit close it, as the
/// screenshot preview does. Nothing here writes or deletes a file: the
/// service deletes the take when this closes without Edit. New in FixDock.
final class ScreenRecorderPreviewController: NSObject, NSSharingServicePickerDelegate {
    private final class Model: ObservableObject {
        @Published var thumbnail: CGImage?
    }

    private let file: URL
    private let anchor: CGRect?
    private let canEdit: Bool
    private let edit: () -> Bool
    private let onClose: (Bool) -> Void
    private let model = Model()
    private let shareAnchor = ShareAnchor()
    private var panel: RecorderPreviewPanel?
    private var keyMonitor: Any?
    private var closed = false
    private var sharing = false

    static let size = CGSize(width: 350, height: 210)

    /// `edit` opens the editor and answers whether it took the take;
    /// `onClose` is told whether the take was handed over.
    init(file: URL, anchor: CGRect?, canEdit: Bool,
         edit: @escaping () -> Bool, onClose: @escaping (Bool) -> Void) {
        self.file = file
        self.anchor = anchor
        self.canEdit = canEdit
        self.edit = edit
        self.onClose = onClose
    }

    func show() {
        guard panel == nil, !closed else { return }
        let content = PreviewView(
            model: model, fileName: file.lastPathComponent, canEdit: canEdit,
            shareAnchor: shareAnchor, file: file,
            dragEnded: { [weak self] dropped in if dropped { self?.close() } },
            showInFinder: { [weak self] in self?.showInFinder() },
            share: { [weak self] in self?.share() },
            edit: { [weak self] in self?.openEditor() },
            dismiss: { [weak self] in self?.close() })
        let panel = RecorderPreviewPanel(contentRect: CGRect(origin: .zero, size: Self.size),
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
        panel.makeKey()
        loadThumbnail()
    }

    /// Closes without handing the take over.
    func close() {
        finish(handedOver: false)
    }

    private func finish(handedOver: Bool) {
        guard !closed else { return }
        closed = true
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        panel?.orderOut(nil)
        panel = nil
        onClose(handedOver)
    }

    private func showInFinder() {
        guard !closed, !sharing else { return }
        NSWorkspace.shared.activateFileViewerSelecting([file])
        close()
    }

    private func openEditor() {
        guard !closed, !sharing, canEdit else { return }
        if edit() { finish(handedOver: true) } else { NSSound.beep() }
    }

    /// The saved movie itself goes to the share sheet; nothing is copied.
    private func share() {
        guard !closed, !sharing, let view = shareAnchor.view else { return }
        let picker = NSSharingServicePicker(items: [file])
        picker.delegate = self
        sharing = true
        picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }

    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker,
                              didChoose service: NSSharingService?) {
        sharing = false
        if service != nil { close() }
    }

    /// The first frame, off the main thread.
    private func loadThumbnail() {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: file))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1_200, height: 1_200)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 10)
        generator.requestedTimeToleranceBefore = .zero
        generator.generateCGImageAsynchronously(for: .zero) { [weak self] image, _, _ in
            guard let image else { return }
            DispatchQueue.main.async {
                guard let self, !self.closed else { return }
                self.model.thumbnail = image
            }
        }
    }

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
            if flags == .command, key == kVK_ANSI_W {
                self.close()
                return nil
            }
            guard flags.isEmpty else { return event }
            switch key {
            case kVK_Escape: self.close()
            case kVK_Return, kVK_ANSI_KeypadEnter, kVK_ANSI_E:
                guard self.canEdit else { return event }
                self.openEditor()
            default: return event
            }
            return nil
        }
    }

    // MARK: - Views

    private struct PreviewView: View {
        @ObservedObject var model: Model
        let fileName: String
        let canEdit: Bool
        let shareAnchor: ShareAnchor
        let file: URL
        let dragEnded: (Bool) -> Void
        let showInFinder: () -> Void
        let share: () -> Void
        let edit: () -> Void
        let dismiss: () -> Void
        @ObservedObject private var l10n = L10n.shared

        var body: some View {
            let s = l10n.s
            VStack(spacing: 10) {
                ZStack {
                    Color.black.opacity(0.12)
                    if let thumbnail = model.thumbnail {
                        Image(decorative: thumbnail, scale: 1)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                    } else {
                        Image(systemName: "film")
                            .font(.system(size: 28))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 320, height: 138)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
                .overlay(MovieDragSource(file: file, image: model.thumbnail, ended: dragEnded)
                    .help(s.recorderPreviewDragHint))
                .overlay(alignment: .topLeading) {
                    circleButton("xmark", s.recorderPreviewClose + "  (⎋)", action: dismiss)
                        .padding(6)
                }
                .overlay(alignment: .topTrailing) {
                    circleButton("square.and.arrow.up", s.recorderPreviewShare, action: share)
                        .background(RecorderShareAnchorView(anchor: shareAnchor))
                        .padding(6)
                }

                HStack(spacing: 6) {
                    Button(action: showInFinder) {
                        Label(s.recorderPreviewShowInFinder, systemImage: "folder")
                    }
                    Text(fileName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    if canEdit {
                        Button(s.recorderPreviewEdit, action: edit)
                            .buttonStyle(.borderedProminent)
                            .help(s.recorderPreviewEdit + "  (⏎)")
                    }
                }
                .controlSize(.small)
            }
            .padding(10)
            .frame(width: ScreenRecorderPreviewController.size.width,
                   height: ScreenRecorderPreviewController.size.height)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.regularMaterial))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1))
        }

        private func circleButton(_ symbol: String, _ title: String,
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
            .help(title)
        }
    }
}

/// Becomes key on a click too, so Esc reaches it after focus moved away.
private final class RecorderPreviewPanel: OverlayPanel {
    override var canBecomeKey: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, !isKeyWindow { makeKey() }
        super.sendEvent(event)
    }
}

private struct RecorderShareAnchorView: NSViewRepresentable {
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

/// Drags the saved movie's file URL. The drag pasteboard is not the general
/// pasteboard, and the receiver copies the file: the source stays put.
private struct MovieDragSource: NSViewRepresentable {
    let file: URL
    let image: CGImage?
    let ended: (Bool) -> Void

    func makeNSView(context: Context) -> MovieDragSourceView {
        let view = MovieDragSourceView()
        update(view)
        return view
    }

    func updateNSView(_ nsView: MovieDragSourceView, context: Context) {
        update(nsView)
    }

    private func update(_ view: MovieDragSourceView) {
        view.file = file
        view.image = image
        view.ended = ended
    }
}

private final class MovieDragSourceView: NSView, NSDraggingSource {
    var file: URL?
    var image: CGImage?
    var ended: ((Bool) -> Void)?
    private var downAt: CGPoint?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        downAt = event.locationInWindow
        window?.makeKey()
    }

    override func mouseUp(with event: NSEvent) {
        downAt = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = downAt, let file else { return }
        let point = event.locationInWindow
        guard hypot(point.x - start.x, point.y - start.y) > 3 else { return }
        downAt = nil
        let item = NSDraggingItem(pasteboardWriter: file as NSURL)
        let side: CGFloat = 120
        var size = CGSize(width: side, height: side * 0.6)
        if let image {
            let ratio = CGFloat(image.width) / CGFloat(max(1, image.height))
            size = ratio >= 1 ? CGSize(width: side, height: side / ratio) : CGSize(width: side * ratio, height: side)
        }
        let local = convert(point, from: nil)
        let contents: NSImage = image.map { NSImage(cgImage: $0, size: size) }
            ?? NSWorkspace.shared.icon(forFile: file.path)
        item.setDraggingFrame(CGRect(x: local.x - size.width / 2, y: local.y - size.height / 2,
                                     width: size.width, height: size.height),
                              contents: contents)
        beginDraggingSession(with: [item], event: event, source: self)
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
