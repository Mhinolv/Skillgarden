import AppKit
import SwiftUI
import SkillgardenCore

/// Markdown blocks with inline styles applied and image references resolved. Build it off the main actor.
/// The assignment brief (`AssignmentLectureView`) uses the same type and `MarkdownBlocksView`.
struct RenderedMarkdown: Sendable {
    enum Block: Sendable {
        case heading(level: Int, text: AttributedString)
        case paragraph(AttributedString)
        case list(ordered: Bool, start: Int, items: [AttributedString])
        case code(String)
        case quote(AttributedString)
        /// `url` is nil when the reference is not a file in the course snapshot.
        case image(url: URL?, alt: String)
        case rule
    }

    let blocks: [Block]
    let readingMinutes: Int

    /// `image` returns the file and the manifest alt text of a reference. The Markdown alt text is the fallback.
    init(document: MarkdownDocument, image: (String) -> (url: URL, alt: String?)?) {
        readingMinutes = document.readingMinutes
        blocks = document.blocks.map { block in
            switch block {
            case let .heading(level, text): .heading(level: level, text: Self.inline(text))
            case let .paragraph(text): .paragraph(Self.inline(text))
            case let .list(ordered, start, items): .list(ordered: ordered, start: start, items: items.map(Self.inline))
            case let .code(text): .code(text)
            case let .quote(text): .quote(Self.inline(text))
            case let .image(source, alt):
                image(source).map { .image(url: $0.url, alt: $0.alt ?? alt) } ?? .image(url: nil, alt: alt)
            case .rule: .rule
            }
        }
    }

    init(article: LectureArticle) throws {
        self.init(document: try article.load(), image: article.image(for:))
    }

    private static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

/// The content block of an article lecture: the reading time, then the Markdown in a card.
/// The Q&A pill is at the right end of the meta row. Its panel is between the meta row and the card (#128).
/// The Notes pill follows the Q&A pill. Its panel shows in the same place (#181).
struct ArticleLectureView: View {
    let article: LectureArticle?
    /// The Q&A pill and panel (#128). Nil shows no pill.
    var qaPanel: LectureQAPanel? = nil
    /// The Notes pill and panel (#181), after Q&A. Nil shows no pill.
    var notesPanel: LectureNotesPanel? = nil
    @Environment(\.imageLoads) private var imageLoads
    @Environment(\.gardenPalette) private var palette
    @State private var content: RenderedMarkdown?
    @State private var unavailable = false

    var body: some View {
        Group {
            if let content {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label("Article · \(content.readingMinutes) min read", systemImage: LectureType.article.symbolName)
                            .gardenText(.meta)
                        Spacer()
                        qaPanel?.pill()
                        notesPanel?.pill()
                    }
                    if let qaPanel, qaPanel.isShown { qaPanel.panel() }
                    if let notesPanel, notesPanel.isShown { notesPanel.panel() }
                    GardenCard(padding: GardenSpacing.l) { MarkdownBlocksView(markdown: content) }
                }
            } else if unavailable {
                ContentUnavailableView("Article unavailable", systemImage: "exclamationmark.triangle")
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .focusedSceneValue(\.showsQA, content == nil ? nil : qaPanel.map { MenuToggle($0.isOn) })
        .focusedSceneValue(\.showsNotes, content == nil ? nil : notesPanel.map { MenuToggle($0.isOn) })
        .task(id: article) {
            content = nil
            unavailable = false
            guard let article else { unavailable = true; return }
            imageLoads?.start()
            // Read and parse the file off the main actor.
            let loaded = await Task.detached { try? RenderedMarkdown(article: article) }.value
            content = loaded
            unavailable = loaded == nil
            imageLoads?.finish(loaded: loaded != nil)
        }
    }
}

/// Draws rendered Markdown in the reading column. Text is selectable. Links open with `openURL`.
struct MarkdownBlocksView: View {
    let markdown: RenderedMarkdown
    @Environment(\.gardenPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(markdown.blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .font(GardenFont.body)
        .lineSpacing(GardenFont.bodyLineSpacing)
        .foregroundStyle(palette.ink)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func blockView(_ block: RenderedMarkdown.Block) -> some View {
        switch block {
        case let .heading(level, text):
            Text(text)
                .font(Self.headingFont(level))
                .padding(.top, level == 2 ? 8 : 0)
                .accessibilityAddTraits(.isHeader)
        case let .paragraph(text):
            Text(text)
        case let .list(ordered, start, items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        Text(ordered ? "\(start + index)." : "•").frame(width: 20, alignment: .leading)
                        Text(item)
                    }
                }
            }
        case let .code(text):
            Text(text)
                .font(.system(size: 12).monospaced())
                .lineSpacing(3)
                .padding(GardenSpacing.s)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(palette.fill, in: .garden(GardenRadius.button))
        case let .quote(text):
            Text(text)
                .foregroundStyle(palette.muted)
                .padding(.leading, GardenSpacing.s)
                .overlay(alignment: .leading) { Capsule().fill(palette.line).frame(width: 2) }
        case let .image(url, alt):
            ArticleImageView(url: url, alt: alt)
        case .rule:
            Rectangle().fill(palette.line).frame(height: 1)
        }
    }

    /// Semibold headings: 20, 17, 15, then 13.
    private static func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: GardenFont.title
        case 2: .system(size: 17, weight: .semibold)
        case 3: GardenFont.heading
        default: GardenFont.cardTitle
        }
    }
}

/// An article image at column width, aspect fit and never cropped. A missing file shows the alt text.
/// A click, Return or Space opens a loaded image in the large view of the lecture page (#238).
struct ArticleImageView: View {
    let url: URL?
    let alt: String
    @Environment(\.imageLoads) private var imageLoads
    @Environment(\.gardenPalette) private var palette
    @Environment(\.enlargeImage) private var enlargeImage
    @Environment(\.snapshotEnlargedImage) private var snapshotEnlargedImage
    @State private var loaded: NSImage?
    @State private var failed = false
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if let loaded {
                let enlarges = enlargeImage != nil
                Image(nsImage: loaded)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(.garden(GardenRadius.image))
                    .frame(maxHeight: 480)
                    .contentShape(.garden(GardenRadius.image))
                    .contentShape(.focusEffect, .garden(GardenRadius.image))
                    .focusable(enlarges)
                    .focused($focused)
                    .onTapGesture { enlarge() }
                    .onKeyPress(keys: [.return, .space]) { _ in enlarge() ? .handled : .ignored }
                    .pointerStyle(enlarges ? .link : nil)
                    .help(enlarges ? "Enlarge image" : "")
            } else {
                Rectangle()
                    .fill(palette.fill)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .overlay {
                        if failed {
                            VStack(spacing: CourseStyle.spacing) {
                                Image(systemName: "photo").font(.largeTitle)
                                Text(alt).multilineTextAlignment(.center)
                            }
                            .foregroundStyle(palette.muted)
                            .padding()
                        }
                    }
                    .clipShape(.garden(GardenRadius.image))
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(alt)
        .accessibilityAddTraits(.isImage)
        .accessibilityActions {
            if loaded != nil, enlargeImage != nil {
                Button("Enlarge image") { enlarge() }
            }
        }
        .task(id: url) {
            loaded = nil
            failed = false
            guard let url else { failed = true; return }
            imageLoads?.start()
            // NSImage keeps SVG as a vector, so it draws sharp at any size.
            let data = await Task.detached { try? Data(contentsOf: url) }.value
            loaded = data.flatMap(NSImage.init(data:))
            failed = loaded == nil
            // The snapshot harness opens the large view after the load (#238).
            if let snapshotEnlargedImage { enlarge(alt: snapshotEnlargedImage == .withAlt ? alt : "") }
            imageLoads?.finish(loaded: loaded != nil)
        }
    }

    /// Opens the loaded image in the large view. Returns false when the image did not load or no page shows the view.
    @discardableResult private func enlarge() -> Bool { enlarge(alt: alt) }

    @discardableResult private func enlarge(alt: String) -> Bool {
        guard let loaded, let enlargeImage else { return false }
        enlargeImage(EnlargedImage(image: loaded, alt: alt, restoreFocus: { focused = true }))
        return true
    }
}

/// An image in the large view of the lecture page (#238).
struct EnlargedImage {
    let image: NSImage
    let alt: String
    /// Moves the focus back to the image in the page when the large view closes.
    let restoreFocus: () -> Void

    /// The pixel size of a bitmap. Nil for a vector image (SVG, PDF), which has no pixel limit.
    var pixelSize: CGSize? {
        guard let bitmap = image.representations.first as? NSBitmapImageRep else { return nil }
        return CGSize(width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
    }
}

/// Opens an image in the large view. The lecture page sets it. Nil means no page shows the large view.
struct EnlargeImageAction {
    let open: (EnlargedImage) -> Void

    func callAsFunction(_ image: EnlargedImage) { open(image) }
}

/// The large view of an article image (#238): a 60% black scrim over the detail column, the image aspect fit with a 32 pt
/// inset, the alt text below it and a close button at the top right. Esc, a scrim click or the button closes it.
struct EnlargedImageOverlay: View {
    let image: EnlargedImage
    let close: () -> Void
    @Environment(\.gardenPalette) private var palette
    @Environment(\.displayScale) private var displayScale
    @FocusState private var closeFocused: Bool

    var body: some View {
        let limit = ImageEnlargement.maximumSize(pixelSize: image.pixelSize, displayScale: displayScale)
        ZStack(alignment: .topTrailing) {
            Color.black.opacity(0.6)
                .contentShape(.rect)
                .onTapGesture(perform: close)
                .accessibilityHidden(true)
            VStack(spacing: GardenSpacing.s) {
                // The ratio goes outside the size limit, so the frame is exactly the image and the alt text sits below it.
                Image(nsImage: image.image)
                    .resizable()
                    .frame(maxWidth: limit?.width ?? .infinity, maxHeight: limit?.height ?? .infinity)
                    .aspectRatio(ImageEnlargement.aspectRatio(pixelSize: image.pixelSize, pointSize: image.image.size),
                                 contentMode: .fit)
                    .clipShape(.garden(GardenRadius.image))
                    // A click on the image does not close the view.
                    .onTapGesture {}
                    .accessibilityLabel(image.alt)
                    .accessibilityAddTraits(.isImage)
                if !image.alt.isEmpty {
                    Text(image.alt)
                        .font(GardenFont.meta)
                        .foregroundStyle(.white.opacity(0.85))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityHidden(true)
                }
            }
            .padding(GardenSpacing.xl)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Button("Close", systemImage: "xmark", action: close)
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(palette.ink)
                .frame(width: 28, height: 28)
                .background(palette.card, in: .circle)
                .contentShape(.circle)
                .contentShape(.focusEffect, .circle)
                .keyboardShortcut(.cancelAction)
                .focused($closeFocused)
                .help("Close (Esc)")
                .padding(GardenSpacing.m)
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .onAppear { closeFocused = true }
        .onExitCommand(perform: close)
    }
}

private struct EnlargeImageKey: EnvironmentKey {
    static var defaultValue: EnlargeImageAction? { nil }
}

private struct SnapshotEnlargedImageKey: EnvironmentKey {
    static let defaultValue: SnapshotEnlargedImage? = nil
}

extension EnvironmentValues {
    /// Opens an article image in the large view of the lecture page (#238).
    var enlargeImage: EnlargeImageAction? {
        get { self[EnlargeImageKey.self] }
        set { self[EnlargeImageKey.self] = newValue }
    }

    /// The snapshot harness sets this, so the first article image opens in the large view after the load. The app sets none.
    var snapshotEnlargedImage: SnapshotEnlargedImage? {
        get { self[SnapshotEnlargedImageKey.self] }
        set { self[SnapshotEnlargedImageKey.self] = newValue }
    }
}
