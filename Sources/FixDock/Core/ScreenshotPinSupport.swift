// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import Carbon.HIToolbox
import CoreGraphics
import Foundation
import ImageIO

// MARK: - Identity and payload

/// One pinned capture. Minted only by `ScreenshotPinStack.push`.
struct ScreenshotPinID: Hashable {
    fileprivate let raw: Int
}

/// One encoded picture. `image` is read without the ImageIO cache, so a
/// picture nobody draws holds only its PNG (twenty decoded 5K captures would
/// hold over a gigabyte). A class because identity is the version: an OCR or
/// QR result whose picture is no longer the pin's is stale.
final class ScreenshotPinPicture {
    let png: Data
    let image: CGImage
    /// Pixels per point, never below 1.
    let scale: CGFloat

    init?(png: Data, scale: CGFloat) {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, options)
        else { return nil }
        self.png = png
        self.image = image
        self.scale = max(1, scale)
    }

    /// Size at 100 %, in points.
    var naturalSize: CGSize {
        CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
    }
}

/// Owner decision (round 2): after an edit the pin shows the edit without the
/// editor's backdrop, and every output carries the backdrop.
struct ScreenshotPinCapture {
    /// What the pin shows, what OCR and QR read, and what Edit reopens.
    let display: ScreenshotPinPicture
    private let backdropped: ScreenshotPinPicture?

    init(display: ScreenshotPinPicture, backdropped: ScreenshotPinPicture? = nil) {
        self.display = display
        self.backdropped = backdropped
    }

    /// What Save, Save As, Copy, Share and drag-out hand out.
    var output: ScreenshotPinPicture { backdropped ?? display }
}

// MARK: - Stack

/// Order and phase of every pin, bottom to top. Frames, opacity and pictures
/// live on the windows, so nothing here is synced back from a drag.
///
/// - Past `capacity` the oldest resting entry drops. An entry under edit is
///   never dropped, since its editor still answers to it.
/// - Only the top entry is on screen, and only while it rests.
/// - Every mutation on an unknown id is a no-op, so a late editor completion
///   after a teardown is harmless.
struct ScreenshotPinStack: Equatable {
    static let capacity = 20

    enum Phase: Equatable { case resting, editing }
    enum Presence: Equatable { case shown, hidden, editing, absent }

    struct Entry: Equatable {
        let id: ScreenshotPinID
        fileprivate(set) var phase: Phase
    }

    private(set) var entries: [Entry] = []
    private var minted = 0

    var visible: ScreenshotPinID? {
        guard let top = entries.last, top.phase == .resting else { return nil }
        return top.id
    }

    /// The Close badge. Pins in an editor are not counted (owner decision, round 2).
    var hiddenCount: Int {
        entries.filter { $0.phase == .resting }.count - (visible == nil ? 0 : 1)
    }

    func presence(of id: ScreenshotPinID) -> Presence {
        guard let entry = entries.first(where: { $0.id == id }) else { return .absent }
        if entry.phase == .editing { return .editing }
        return id == visible ? .shown : .hidden
    }

    /// A new capture on top. Returns the ids dropped past the cap.
    mutating func push() -> (id: ScreenshotPinID, dropped: [ScreenshotPinID]) {
        minted += 1
        let id = ScreenshotPinID(raw: minted)
        entries.append(Entry(id: id, phase: .resting))
        return (id, trim(keeping: id))
    }

    @discardableResult
    mutating func remove(_ id: ScreenshotPinID) -> Bool {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return false }
        entries.remove(at: index)
        return true
    }

    /// Close All. Pins under edit stay with their editors.
    mutating func removeAllResting() -> [ScreenshotPinID] {
        let removed = entries.filter { $0.phase == .resting }.map(\.id)
        entries.removeAll { $0.phase == .resting }
        return removed
    }

    /// Uninstall.
    mutating func removeAll() -> [ScreenshotPinID] {
        let removed = entries.map(\.id)
        entries.removeAll()
        return removed
    }

    @discardableResult
    mutating func beginEdit(_ id: ScreenshotPinID) -> Bool {
        guard let index = entries.firstIndex(where: { $0.id == id && $0.phase == .resting }) else { return false }
        entries[index].phase = .editing
        return true
    }

    /// Any editor exit. The entry rests again on top, over captures taken
    /// meanwhile (owner decision, round 2).
    @discardableResult
    mutating func endEdit(_ id: ScreenshotPinID) -> Bool {
        guard let index = entries.firstIndex(where: { $0.id == id && $0.phase == .editing }) else { return false }
        var entry = entries.remove(at: index)
        entry.phase = .resting
        entries.append(entry)
        trim(keeping: id)
        return true
    }

    /// While every other entry is under edit the stack may sit above the cap;
    /// the first edit to end brings it back.
    @discardableResult
    private mutating func trim(keeping kept: ScreenshotPinID) -> [ScreenshotPinID] {
        var dropped: [ScreenshotPinID] = []
        while entries.count > Self.capacity,
              let oldest = entries.firstIndex(where: { $0.phase == .resting && $0.id != kept }) {
            dropped.append(entries.remove(at: oldest).id)
        }
        return dropped
    }
}

// MARK: - Geometry

/// Every placement decision, in Cocoa screen points (y up). Callers pass the
/// visible frames they mean; nothing here reads a screen.
enum ScreenshotPinLayout {
    /// Owner decision: above 55 % of the visible frame on either axis, a
    /// capture opens scaled down.
    static let screenFraction: CGFloat = 0.55
    static let barGap: CGFloat = 8
    static let satelliteGap: CGFloat = 10
    static let edgeInset: CGFloat = 8
    /// Resize floor only. A tiny capture still opens at its own size.
    static let minimumSide: CGFloat = 24

    /// Pixels per point of a capture: from the area it came from, else
    /// `fallback` (the screen's backing scale).
    static func pixelsPerPoint(imagePixelWidth: Int, anchorWidth: CGFloat?, fallback: CGFloat) -> CGFloat {
        guard let anchorWidth, anchorWidth > 0 else { return max(1, fallback) }
        return max(1, CGFloat(imagePixelWidth) / anchorWidth)
    }

    /// A new pin: over the captured area at its own size, pixel-exact. Above
    /// the threshold, or taller than its area (scrolling), it is scaled to fit
    /// and centred on the area. `anchor == nil` centres on the pointer.
    static func pinFrame(naturalSize: CGSize, anchor: CGRect?, pointer: CGPoint,
                         visibleFrame: CGRect) -> CGRect {
        let limit = CGSize(width: visibleFrame.width * screenFraction,
                           height: visibleFrame.height * screenFraction)
        let fits = naturalSize.width <= limit.width && naturalSize.height <= limit.height
        let ratio = fits ? 1 : min(limit.width / naturalSize.width, limit.height / naturalSize.height)
        let size = CGSize(width: naturalSize.width * ratio, height: naturalSize.height * ratio)
        let origin: CGPoint
        if fits, let anchor, abs(anchor.width - size.width) < 1, abs(anchor.height - size.height) < 1 {
            origin = anchor.origin
        } else {
            let centre = anchor.map { CGPoint(x: $0.midX, y: $0.midY) } ?? pointer
            origin = CGPoint(x: centre.x - size.width / 2, y: centre.y - size.height / 2)
        }
        return clamp(CGRect(origin: origin, size: size), into: visibleFrame)
    }

    /// Moves `frame` inside `visibleFrame`, first shrinking it about its centre
    /// (keeping proportions) if it does not fit.
    static func clamp(_ frame: CGRect, into visibleFrame: CGRect) -> CGRect {
        var size = frame.size
        if size.width > visibleFrame.width || size.height > visibleFrame.height, size.width > 0, size.height > 0 {
            let ratio = min(visibleFrame.width / size.width, visibleFrame.height / size.height)
            size = CGSize(width: size.width * ratio, height: size.height * ratio)
        }
        let x = min(max(frame.midX - size.width / 2, visibleFrame.minX), visibleFrame.maxX - size.width)
        let y = min(max(frame.midY - size.height / 2, visibleFrame.minY), visibleFrame.maxY - size.height)
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    /// After a display change (risk R9): a frame still on some visible frame is
    /// clamped into the one it overlaps most; a frame on none goes to the
    /// nearest. No visible frames leaves it as it is.
    static func clamp(_ frame: CGRect, intoAnyOf visibleFrames: [CGRect]) -> CGRect {
        func overlap(_ visible: CGRect) -> CGFloat {
            let common = frame.intersection(visible)
            return common.isNull ? 0 : common.width * common.height
        }
        func distance(_ visible: CGRect) -> CGFloat {
            hypot(visible.midX - frame.midX, visible.midY - frame.midY)
        }
        let best = visibleFrames.max { overlap($0) < overlap($1) }.flatMap { overlap($0) > 0 ? $0 : nil }
            ?? visibleFrames.min { distance($0) < distance($1) }
        return best.map { clamp(frame, into: $0) } ?? frame
    }

    enum BarEdge: Equatable { case below, above, overlay }

    /// Below the pin when it fits, above when the pin touches the bottom,
    /// overlaid on the pin's bottom edge when neither fits. Centred on the
    /// pin, kept inside horizontally (left-aligned when wider than the screen).
    static func barFrame(pinFrame: CGRect, barSize: CGSize,
                         visibleFrame: CGRect) -> (frame: CGRect, edge: BarEdge) {
        let lowestX = visibleFrame.minX + edgeInset
        let highestX = visibleFrame.maxX - edgeInset - barSize.width
        let x = max(lowestX, min(pinFrame.midX - barSize.width / 2, highestX))
        func at(_ y: CGFloat) -> CGRect { CGRect(origin: CGPoint(x: x, y: y), size: barSize) }

        let below = pinFrame.minY - barGap - barSize.height
        if below >= visibleFrame.minY + edgeInset { return (at(below), .below) }
        let above = pinFrame.maxY + barGap
        if above + barSize.height <= visibleFrame.maxY - edgeInset { return (at(above), .above) }
        return (at(max(pinFrame.minY, visibleFrame.minY) + edgeInset), .overlay)
    }

    /// After an edit came back (crop, canvas expansion): same top-left corner
    /// (owner decision, round 2) and the zoom the person had, capped by
    /// `resizeLimits` and kept inside.
    static func frameAfterEdit(previous: CGRect, previousNatural: CGSize, newNatural: CGSize,
                               visibleFrame: CGRect) -> CGRect {
        let zoom = previousNatural.width > 0 ? previous.width / previousNatural.width : 1
        let limits = resizeLimits(naturalSize: newNatural, visibleFrame: visibleFrame)
        let wanted = newNatural.width * zoom
        let width = min(max(wanted, limits.min.width), limits.max.width)
        let ratio = newNatural.width > 0 ? width / newNatural.width : 1
        let size = CGSize(width: width, height: newNatural.height * ratio)
        let frame = CGRect(x: previous.minX, y: previous.maxY - size.height, width: size.width, height: size.height)
        return clamp(frame, into: visibleFrame)
    }

    /// The extracted-text panel: right of the pin, top-aligned; else left;
    /// else beyond the bar (below it when the bar is below, above it when
    /// above), centred on the pin. Kept inside.
    static func textPanelFrame(pinFrame: CGRect, barFrame: CGRect?, panelSize: CGSize,
                               visibleFrame: CGRect) -> CGRect {
        let inner = visibleFrame.insetBy(dx: edgeInset, dy: edgeInset)
        let top = pinFrame.maxY - panelSize.height
        let right = CGRect(x: pinFrame.maxX + satelliteGap, y: top, width: panelSize.width, height: panelSize.height)
        if right.maxX <= inner.maxX { return clamp(right, into: inner) }
        let left = CGRect(x: pinFrame.minX - satelliteGap - panelSize.width, y: top,
                          width: panelSize.width, height: panelSize.height)
        if left.minX >= inner.minX { return clamp(left, into: inner) }

        let x = pinFrame.midX - panelSize.width / 2
        let y: CGFloat
        if let barFrame, barFrame.minY >= pinFrame.maxY {
            y = barFrame.maxY + satelliteGap
        } else {
            y = (barFrame?.minY ?? pinFrame.minY) - satelliteGap - panelSize.height
        }
        return clamp(CGRect(x: x, y: y, width: panelSize.width, height: panelSize.height), into: inner)
    }

    /// Edge-drag resize limits; the window locks the aspect. Min brings the
    /// shorter side down to `minimumSide` (or its own length when smaller);
    /// max fits the visible frame.
    static func resizeLimits(naturalSize: CGSize, visibleFrame: CGRect) -> (min: CGSize, max: CGSize) {
        guard naturalSize.width > 0, naturalSize.height > 0 else { return (.zero, visibleFrame.size) }
        let shorter = min(naturalSize.width, naturalSize.height)
        let down = min(minimumSide, shorter) / shorter
        let up = min(visibleFrame.width / naturalSize.width, visibleFrame.height / naturalSize.height)
        return (CGSize(width: naturalSize.width * down, height: naturalSize.height * down),
                CGSize(width: naturalSize.width * up, height: naturalSize.height * up))
    }
}

// MARK: - The action catalog

/// A key a pin answers to while selected.
struct ScreenshotPinChord: Equatable {
    let keyCode: Int
    let command: Bool
    let shift: Bool
    let glyphs: String
}

struct ScreenshotPinContext: Equatable {
    var hasCode: Bool
    var isReadingText: Bool
    var opacity: ScreenshotPinOpacity
}

/// Per-pin state set from a submenu, not an action.
enum ScreenshotPinOpacity: Int, CaseIterable {
    case full = 100, high = 85, medium = 70, half = 50

    var label: String { "\(rawValue)%" }
    var alpha: CGFloat { CGFloat(rawValue) / 100 }
}

/// Everything a pin does from the bar, a menu or a key. The bar, the menus,
/// the tooltips, the Shortcuts submenu and key routing all derive from it.
/// Declaration order is bar order, then menu order; no second list restates it.
enum ScreenshotPinAction: CaseIterable, Hashable {
    case save, copy, share, extractText, edit, showCode
    case saveAs
    case openSettings, closeAll
    case close

    /// Bar = [.bar actions] + [.dragHandle, .settings] + [.barEnd actions].
    enum Home: Equatable {
        case bar
        /// After the Settings slot (Close, with the badge).
        case barEnd
        /// The menu on another action's bar button (Save ▸ Save As).
        case menu(of: ScreenshotPinAction)
        /// The Settings slot's menu, after Opacity and Keyboard Shortcuts.
        case settingsMenu
    }

    enum Availability: Equatable {
        case ready
        /// Shown, disabled (OCR running).
        case busy
        /// Not shown (QR before a code was found).
        case absent
    }

    var home: Home {
        switch self {
        case .save, .copy, .share, .extractText, .edit, .showCode: return .bar
        case .saveAs: return .menu(of: .save)
        case .openSettings, .closeAll: return .settingsMenu
        case .close: return .barEnd
        }
    }

    var symbol: String {
        switch self {
        case .save: return "square.and.arrow.down"
        case .copy: return "doc.on.doc"
        case .share: return "square.and.arrow.up"
        case .extractText: return "text.viewfinder"
        case .edit: return "pencil.tip.crop.circle"
        case .showCode: return "qrcode"
        case .saveAs: return "square.and.arrow.down.on.square"
        case .openSettings: return "gearshape"
        case .closeAll: return "xmark.square"
        case .close: return "xmark"
        }
    }

    var title: KeyPath<Strings, String> {
        switch self {
        case .save: return \.screenshotPreviewSave
        case .copy: return \.screenshotPreviewCopy
        case .share: return \.screenshotPreviewShare
        case .extractText: return \.screenshotPinExtractText
        case .edit: return \.screenshotPreviewEdit
        case .showCode: return \.screenshotPreviewQR
        case .saveAs: return \.screenshotPinSaveAs
        case .openSettings: return \.screenshotPinOpenSettings
        case .closeAll: return \.screenshotPinCloseAll
        case .close: return \.screenshotPinClose
        }
    }

    /// Owner decision. Menus show the first chord; tooltips list them all.
    var shortcuts: [ScreenshotPinChord] {
        switch self {
        case .save: return [ScreenshotPinChord(keyCode: kVK_ANSI_S, command: true, shift: false, glyphs: "⌘S")]
        case .saveAs: return [ScreenshotPinChord(keyCode: kVK_ANSI_S, command: true, shift: true, glyphs: "⇧⌘S")]
        case .copy: return [ScreenshotPinChord(keyCode: kVK_ANSI_C, command: true, shift: false, glyphs: "⌘C")]
        case .edit: return [ScreenshotPinChord(keyCode: kVK_ANSI_E, command: true, shift: false, glyphs: "⌘E")]
        case .extractText:
            return [ScreenshotPinChord(keyCode: kVK_ANSI_T, command: true, shift: false, glyphs: "⌘T")]
        case .close:
            return [ScreenshotPinChord(keyCode: kVK_ANSI_W, command: true, shift: false, glyphs: "⌘W"),
                    ScreenshotPinChord(keyCode: kVK_Escape, command: false, shift: false, glyphs: "⎋")]
        case .share, .showCode, .openSettings, .closeAll: return []
        }
    }

    func availability(_ context: ScreenshotPinContext) -> Availability {
        switch self {
        case .showCode: return context.hasCode ? .ready : .absent
        case .extractText: return context.isReadingText ? .busy : .ready
        case .save, .copy, .share, .edit, .saveAs, .openSettings, .closeAll, .close: return .ready
        }
    }

    /// Option or Control held never matches. A held key never repeats: each
    /// revealed pin takes key, so a held ⌘W or Esc would close the whole stack.
    static func forKey(keyCode: Int, command: Bool, shift: Bool, option: Bool,
                       control: Bool, isRepeat: Bool) -> ScreenshotPinAction? {
        guard !option, !control, !isRepeat else { return nil }
        return allCases.first { action in
            action.shortcuts.contains { $0.keyCode == keyCode && $0.command == command && $0.shift == shift }
        }
    }

    var menuActions: [ScreenshotPinAction] {
        Self.allCases.filter { $0.home == .menu(of: self) }
    }
}

/// One slot of the bar, left to right.
enum ScreenshotPinBarSlot: Hashable {
    case action(ScreenshotPinAction)
    /// Drags the output as a file (dragging the pin moves it). No click effect.
    case dragHandle
    /// Opens the Settings menu. No click effect of its own.
    case settings

    static func bar(_ context: ScreenshotPinContext) -> [ScreenshotPinBarSlot] {
        let shown = ScreenshotPinAction.allCases.filter { $0.availability(context) != .absent }
        return shown.filter { $0.home == .bar }.map(Self.action)
            + [.dragHandle, .settings]
            + shown.filter { $0.home == .barEnd }.map(Self.action)
    }

    var symbol: String {
        switch self {
        case .action(let action): return action.symbol
        case .dragHandle: return "hand.draw"
        case .settings: return "gearshape"
        }
    }

    var title: KeyPath<Strings, String> {
        switch self {
        case .action(let action): return action.title
        case .dragHandle: return \.screenshotPreviewDragHint
        case .settings: return \.screenshotPinSettings
        }
    }

    /// "Close  (⌘W, ⎋)", from the catalog, so a tooltip never names a dead key.
    func tooltip(_ strings: Strings) -> String {
        let title = strings[keyPath: self.title]
        guard case .action(let action) = self, !action.shortcuts.isEmpty else { return title }
        return "\(title)  (\(action.shortcuts.map(\.glyphs).joined(separator: ", ")))"
    }
}

// MARK: - Menus as data

indirect enum ScreenshotPinMenuNode: Equatable {
    case action(ScreenshotPinAction, enabled: Bool)
    case opacity(ScreenshotPinOpacity, checked: Bool)
    case submenu(ScreenshotPinSubmenu, [ScreenshotPinMenuNode])
    case separator
}

enum ScreenshotPinSubmenu: Equatable {
    case opacity, shortcuts

    var title: KeyPath<Strings, String> {
        switch self {
        case .opacity: return \.screenshotPinOpacity
        case .shortcuts: return \.screenshotPinShortcuts
        }
    }
}

enum ScreenshotPinMenus {
    /// The menu on an action's bar button (Save ▸ Save As).
    static func button(_ action: ScreenshotPinAction, _ context: ScreenshotPinContext) -> [ScreenshotPinMenuNode] {
        action.menuActions.compactMap { node($0, context) }
    }

    /// Opacity ▸, Keyboard Shortcuts ▸ (every action with a chord), then the
    /// `.settingsMenu` actions.
    static func settings(_ context: ScreenshotPinContext) -> [ScreenshotPinMenuNode] {
        let opacity = ScreenshotPinOpacity.allCases.map { ScreenshotPinMenuNode.opacity($0, checked: $0 == context.opacity) }
        let shortcuts = ScreenshotPinAction.allCases.filter { !$0.shortcuts.isEmpty }.compactMap { node($0, context) }
        return [.submenu(.opacity, opacity), .submenu(.shortcuts, shortcuts), .separator]
            + ScreenshotPinAction.allCases.filter { $0.home == .settingsMenu }.compactMap { node($0, context) }
    }

    /// Right-click: the bar in order, each button followed by its menu, the
    /// drag handle skipped, Settings expanded between separators.
    static func context(_ context: ScreenshotPinContext) -> [ScreenshotPinMenuNode] {
        ScreenshotPinBarSlot.bar(context).flatMap { slot -> [ScreenshotPinMenuNode] in
            switch slot {
            case .action(let action): return (node(action, context).map { [$0] } ?? []) + button(action, context)
            case .dragHandle: return []
            case .settings: return [.separator] + settings(context) + [.separator]
            }
        }
    }

    private static func node(_ action: ScreenshotPinAction, _ context: ScreenshotPinContext) -> ScreenshotPinMenuNode? {
        switch action.availability(context) {
        case .ready: return .action(action, enabled: true)
        case .busy: return .action(action, enabled: false)
        case .absent: return nil
        }
    }
}

// MARK: - Selection

/// Which pin is selected: the one whose bar shows and whose keys work. Key
/// status is one input, not the definition: the pin's family (text panel, QR
/// result) takes key without deselecting it, and transients (Save As, the
/// share picker, our menus) suspend focus loss until they end.
///
/// Measured (macOS 27.2, accessory app): during resign-key `NSApp.keyWindow`
/// is nil and the new key window appears one run-loop turn later, hence
/// `keySettled` is reported after that turn.
struct ScreenshotPinFocus: Equatable {
    private(set) var selected: ScreenshotPinID?
    /// Empty whenever nothing is selected.
    private var transients: Set<Transient> = []

    enum Transient: Hashable { case savePanel, sharePicker, menu }

    enum Event: Equatable {
        /// AppKit made the pin key (capture, reveal, editor return, satellite closed).
        case keyGained(ScreenshotPinID)
        /// Mouse down on the pin, reported before AppKit keys it.
        case clicked(ScreenshotPinID)
        /// One run-loop turn after the pin or a satellite resigned key.
        case keySettled(ScreenshotPinID, keyIsFamily: Bool)
        /// A click another app received, another app activated, or FixDock
        /// resigned active and is still inactive a turn later.
        case focusLeft
        case transientBegan(Transient)
        case transientEnded(Transient)
        /// Hidden, sent to the editor, or closed.
        case gone(ScreenshotPinID)
    }

    enum Change: Equatable {
        /// `emphasize`: the pulse and slide-in, only for a click on an unselected pin.
        case select(ScreenshotPinID, emphasize: Bool)
        case deselect(ScreenshotPinID)
        /// The last transient ended: key the pin again one turn later unless
        /// one of its family has key.
        case restoreKey(ScreenshotPinID)
    }

    /// An event that changes nothing returns [].
    mutating func apply(_ event: Event) -> [Change] {
        switch event {
        case .keyGained(let id):
            return select(id, emphasize: false)
        case .clicked(let id):
            return select(id, emphasize: true)
        case .keySettled(_, keyIsFamily: true):
            return []
        case .keySettled(let id, keyIsFamily: false):
            guard transients.isEmpty, selected == id else { return [] }
            return deselect()
        case .focusLeft:
            guard transients.isEmpty else { return [] }
            return deselect()
        case .transientBegan(let transient):
            if selected != nil { transients.insert(transient) }
            return []
        case .transientEnded(let transient):
            guard transients.remove(transient) != nil, transients.isEmpty, let id = selected else { return [] }
            return [.restoreKey(id)]
        case .gone(let id):
            guard selected == id else { return [] }
            return deselect()
        }
    }

    private mutating func select(_ id: ScreenshotPinID, emphasize: Bool) -> [Change] {
        guard selected != id else { return [] }
        let previous = deselect()
        selected = id
        return previous + [.select(id, emphasize: emphasize)]
    }

    private mutating func deselect() -> [Change] {
        guard let id = selected else { return [] }
        selected = nil
        transients = []
        return [.deselect(id)]
    }
}
