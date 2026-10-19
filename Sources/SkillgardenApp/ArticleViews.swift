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
struct ArticleLectureView: View {
    let article: LectureArticle?
    /// The Q&A pill and panel (#128). Nil shows no pill.
    var qaPanel: LectureQAPanel? = nil
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
                    }
                    if let qaPanel, qaPanel.isShown { qaPanel.panel() }
                    GardenCard(padding: GardenSpacing.l) { MarkdownBlocksView(markdown: content) }
                }
            } else if unavailable {
                ContentUnavailableView("Article unavailable", systemImage: "exclamationmark.triangle")
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .focusedSceneValue(\.showsQA, content == nil ? nil : qaPanel?.isOn)
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
struct ArticleImageView: View {
    let url: URL?
    let alt: String
    @Environment(\.imageLoads) private var imageLoads
    @Environment(\.gardenPalette) private var palette
    @State private var loaded: NSImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let loaded {
                Image(nsImage: loaded)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(.garden(GardenRadius.image))
                    .frame(maxHeight: 480)
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
        .task(id: url) {
            loaded = nil
            failed = false
            guard let url else { failed = true; return }
            imageLoads?.start()
            // NSImage keeps SVG as a vector, so it draws sharp at any size.
            let data = await Task.detached { try? Data(contentsOf: url) }.value
            loaded = data.flatMap(NSImage.init(data:))
            failed = loaded == nil
            imageLoads?.finish(loaded: loaded != nil)
        }
    }
}
