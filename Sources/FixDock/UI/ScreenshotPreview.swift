// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

/// Which of the preview's actions already happened, so their buttons gray out.
final class ScreenshotPreviewModel: ObservableObject {
    @Published var copied = false
}

/// The small window in the corner after a capture: the thumbnail with Share
/// (and Pin, later) on it, then Trash, Save, Copy and Edit (later). A file is
/// written only when Save is pressed; closing, Esc and Trash leave nothing on
/// disk. A successful action closes the preview, as upstream. Layout and keys
/// adapted from the upstream quick preview, without its upload link, notch,
/// QR and text recognition.
final class ScreenshotPreviewController: NSObject, NSSharingServicePickerDelegate {
    enum Action { case save, copy, discard }

    private let image: CGImage
    private let model = ScreenshotPreviewModel()
    private let perform: (Action) -> Bool
    private let onClose: () -> Void
    private let shareAnchor = ShareAnchor()
    private var panel: ScreenshotPreviewPanel?
    private var keyMonitor: Any?
    private var closed = false
    private var sharing = false

    static let size = CGSize(width: 350, height: 210)

    /// `perform` runs one action and reports whether it worked.
    init(image: CGImage, copied: Bool, perform: @escaping (Action) -> Bool,
         onClose: @escaping () -> Void) {
        self.image = image
        self.perform = perform
        self.onClose = onClose
        model.copied = copied
    }

    func show() {
        guard panel == nil, !closed else { return }
        let content = ScreenshotPreviewView(
            image: Self.thumbnail(for: image), model: model, shareAnchor: shareAnchor,
            run: { [weak self] action in self?.run(action) },
            share: { [weak self] in self?.share() },
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
        panel.setFrame(Self.frame(), display: false)
        self.panel = panel
        installKeyMonitor(for: panel)
        panel.orderFrontRegardless()
        // Esc, ⌘S and ⌘C work at once, as upstream's default.
        panel.makeKey()
    }

    func close() {
        guard !closed else { return }
        closed = true
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

    /// The system share sheet with the image itself, so nothing temporary is
    /// written. A chosen target closes the preview without saving.
    private func share() {
        guard !closed, !sharing, let view = shareAnchor.view else { return }
        let picker = NSSharingServicePicker(items: [NSImage(cgImage: image, size: .zero)])
        picker.delegate = self
        sharing = true
        picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }

    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker,
                              didChoose service: NSSharingService?) {
        sharing = false
        if service != nil { close() }
    }

    /// Bottom right of the display under the pointer.
    private static func frame() -> CGRect {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        return CGRect(x: visible.maxX - size.width - 16, y: visible.minY + 16,
                      width: size.width, height: size.height)
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
    let run: (ScreenshotPreviewController.Action) -> Void
    let share: () -> Void
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
                .overlay(alignment: .topLeading) {
                    circleButton("xmark", s.screenshotPreviewClose + "  (⎋)", action: dismiss)
                        .padding(6)
                }
                .overlay(alignment: .topTrailing) {
                    HStack(spacing: 5) {
                        circleButton("square.and.arrow.up", s.screenshotPreviewShare, action: share)
                            .background(ShareAnchorView(anchor: shareAnchor))
                        circleButton("pin", s.screenshotPreviewPinLater, enabled: false) {}
                    }
                    .padding(6)
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
                Button(s.screenshotPreviewEdit) {}
                    .buttonStyle(.borderedProminent)
                    .disabled(true)
                    .help(s.screenshotPreviewEditLater)
            }
            .controlSize(.small)
        }
        .padding(10)
        .frame(width: ScreenshotPreviewController.size.width, height: ScreenshotPreviewController.size.height)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1))
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
