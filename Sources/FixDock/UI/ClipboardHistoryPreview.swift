// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import AppKit
import SwiftUI

struct ClipboardHistoryPictureView: View {
    let item: ClipboardHistoryItem
    let size: ClipboardHistoryMedia.Size
    let media: ClipboardHistoryMedia
    var contentMode: ContentMode = .fit
    @State private var loaded: (id: UUID, image: CGImage?)?

    private struct LoadID: Hashable {
        let id: UUID
        let size: ClipboardHistoryMedia.Size
    }

    var body: some View {
        Group {
            if let image = shown {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: contentMode)
            } else {
                placeholder
            }
        }
        .task(id: LoadID(id: item.id, size: size)) {
            let image = await media.picture(item.entry.content, size)
            guard !Task.isCancelled else { return }
            loaded = (item.id, image)
        }
    }

    private var shown: CGImage? {
        if let loaded, loaded.id == item.id { return loaded.image }
        return media.cached(item.entry.content, size)
    }

    @ViewBuilder
    private var placeholder: some View {
        switch item.entry.content {
        case .file(let file):
            Image(nsImage: ClipboardHistoryMedia.placeholderIcon(for: file))
                .resizable()
                .aspectRatio(1, contentMode: .fit)
        case .image(let ref):
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.primary.opacity(0.06))
                .aspectRatio(ref.pixelHeight > 0 ? CGFloat(ref.pixelWidth) / CGFloat(ref.pixelHeight) : 1,
                             contentMode: contentMode)
        case .text:
            Color.clear
        }
    }
}

extension ClipboardHistoryKind {
    var symbol: String {
        switch self {
        case .image: return "photo"
        case .text: return "doc.text"
        case .link: return "link"
        case .color: return "paintpalette"
        case .file: return "doc"
        case .email: return "envelope"
        }
    }

    func title(_ s: Strings) -> String {
        switch self {
        case .image: return s.clipboardHistoryKindImage
        case .text: return s.clipboardHistoryKindText
        case .link: return s.clipboardHistoryKindLink
        case .color: return s.clipboardHistoryKindColor
        case .file: return s.clipboardHistoryKindFile
        case .email: return s.clipboardHistoryKindEmail
        }
    }

    func empty(_ s: Strings) -> String {
        switch self {
        case .image: return s.clipboardHistoryEmptyImages
        case .text: return s.clipboardHistoryEmptyText
        case .link: return s.clipboardHistoryEmptyLinks
        case .color: return s.clipboardHistoryEmptyColors
        case .file: return s.clipboardHistoryEmptyFiles
        case .email: return s.clipboardHistoryEmptyEmails
        }
    }
}

extension ClipboardHistoryFilter {
    var symbol: String {
        switch self {
        case .all: return "list.bullet"
        case .only(let kind): return kind.symbol
        }
    }

    func title(_ s: Strings) -> String {
        switch self {
        case .all: return s.clipboardHistoryAllTypes
        case .only(let kind): return kind.title(s)
        }
    }
}

extension ClipboardHistorySection {
    func title(_ s: Strings) -> String {
        switch self {
        case .pinned: return s.clipboardHistoryPinnedSection
        case .today: return s.clipboardHistoryTodaySection
        case .yesterday: return s.clipboardHistoryYesterdaySection
        case .thisWeek: return s.clipboardHistoryThisWeekSection
        case .earlier: return s.clipboardHistoryEarlierSection
        }
    }
}

extension ClipboardHistoryAction {
    func title(for entry: ClipboardHistoryEntry, _ s: Strings) -> String {
        switch self {
        case .paste: return s.clipboardHistoryPaste
        case .copyOnly: return s.clipboardHistoryCopy
        case .swapLayout: return s.clipboardHistorySwapLayout
        case .togglePin: return entry.isPinned ? s.clipboardHistoryUnpin : s.clipboardHistoryPin
        case .showInFinder: return s.clipboardHistoryRevealFile
        case .delete: return s.clipboardHistoryDelete
        }
    }

    var keyEquivalent: (key: String, modifiers: NSEvent.ModifierFlags)? {
        switch self {
        case .paste: return ("\r", [])
        case .copyOnly: return ("\r", [.command])
        case .togglePin: return ("p", [.option])
        case .swapLayout, .showInFinder: return nil
        case .delete: return ("\u{8}", [.command])
        }
    }
}

extension ClipboardHistoryColor {
    var swiftUIColor: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha) }
}

struct ClipboardHistoryPreviewPane: View {
    let item: ClipboardHistoryItem
    let media: ClipboardHistoryMedia
    @ObservedObject private var l10n = L10n.shared
    @State private var file: (id: UUID, facts: ClipboardHistoryFileFacts?)?
    @State private var counts: (id: UUID, characters: Int, words: Int)?

    private static let previewCharacters = 20_000

    private var s: Strings { l10n.s }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            preview
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 10)
            info
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
        }
        .task(id: item.id) { await loadFacts() }
    }

    private var fileFacts: ClipboardHistoryFileFacts? {
        guard let file, file.id == item.id else { return nil }
        return file.facts
    }

    @ViewBuilder
    private var preview: some View {
        switch item.entry.content {
        case .image:
            ClipboardHistoryPictureView(item: item, size: .preview, media: media)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12)))
        case .file:
            if fileFacts?.exists == false {
                VStack(spacing: 8) {
                    Image(systemName: "questionmark.folder")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text(s.clipboardHistoryToastUnavailable)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            } else {
                ClipboardHistoryPictureView(item: item, size: .preview, media: media)
                    .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
            }
        case .text(let text):
            if item.kind == .color, let color = ClipboardHistoryColor.parse(text) {
                VStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(color.swiftUIColor)
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.15)))
                        .frame(width: 120, height: 120)
                    Text(text)
                        .font(.system(size: 13, design: .monospaced))
                        .textSelection(.enabled)
                }
            } else {
                let shown = text.prefix(Self.previewCharacters)
                ScrollView {
                    Text(shown.endIndex == text.endIndex ? text : String(shown) + "…")
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        }
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(s.clipboardHistoryInfoTitle)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)
            ForEach(rows) { row in
                Divider()
                HStack(spacing: 6) {
                    Text(row.title)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 12)
                    if let icon = row.icon {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 14, height: 14)
                    }
                    Text(row.value)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                .font(.system(size: 11.5))
                .padding(.vertical, 5)
            }
        }
    }

    private struct Row: Identifiable {
        let id: Int
        let title: String
        let value: String
        var icon: NSImage?
    }

    private var rows: [Row] {
        let entry = item.entry
        let locale = Locale(identifier: l10n.language.rawValue)
        var rows: [Row] = []
        func add(_ title: String, _ value: String?, icon: NSImage? = nil) {
            guard let value else { return }
            rows.append(Row(id: rows.count, title: title, value: value, icon: icon))
        }
        if let source = entry.source {
            let app = ClipboardHistorySourceApp.info(for: source)
            add(s.clipboardHistoryInfoSource, app.name, icon: app.icon)
        }
        switch entry.content {
        case .text:
            add(s.clipboardHistoryInfoKind, item.kind.title(s))
            if item.kind == .text, let counts, counts.id == item.id {
                add(s.clipboardHistoryInfoCharacters, counts.characters.formatted(.number.locale(locale)))
                add(s.clipboardHistoryInfoWords, counts.words.formatted(.number.locale(locale)))
            }
        case .image(let ref):
            add(s.clipboardHistoryInfoKind, item.kind.title(s))
            add(s.clipboardHistoryInfoDimensions, "\(ref.pixelWidth)×\(ref.pixelHeight)")
            add(s.clipboardHistoryInfoSize, Self.bytes(ref.byteCount, locale: locale))
        case .file(let file):
            add(s.clipboardHistoryInfoKind, fileFacts?.kind ?? item.kind.title(s))
            add(s.clipboardHistoryInfoPath, (file.path as NSString).abbreviatingWithTildeInPath)
            add(s.clipboardHistoryInfoSize, fileFacts?.byteCount.map { Self.bytes($0, locale: locale) })
        }
        add(s.clipboardHistoryInfoCopied, Self.copiedFormatter(locale).string(from: entry.copiedAt))
        return rows
    }

    private func loadFacts() async {
        let id = item.id
        switch item.entry.content {
        case .file(let ref):
            let facts = await media.facts(ref)
            guard !Task.isCancelled else { return }
            file = (id, facts)
        case .text(let text) where item.kind == .text:
            let counted = await Task.detached(priority: .userInitiated) { () -> (Int, Int) in
                var words = 0
                text.enumerateSubstrings(in: text.startIndex..., options: [.byWords, .substringNotRequired]) { _, _, _, _ in
                    words += 1
                }
                return (text.count, words)
            }.value
            guard !Task.isCancelled else { return }
            counts = (id, counted.0, counted.1)
        default:
            return
        }
    }

    private static func bytes(_ count: Int, locale: Locale) -> String {
        Int64(count).formatted(.byteCount(style: .file).locale(locale))
    }

    private static var copiedFormatters: [String: DateFormatter] = [:]

    private static func copiedFormatter(_ locale: Locale) -> DateFormatter {
        if let formatter = copiedFormatters[locale.identifier] { return formatter }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        formatter.doesRelativeDateFormatting = true
        copiedFormatters[locale.identifier] = formatter
        return formatter
    }
}
