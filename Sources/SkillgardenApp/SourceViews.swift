import SwiftUI
import SkillgardenCore

/// "Sources and further watching": an adaptive grid of source cards in manifest order. Hidden when there are no sources.
struct SourcesSection: View {
    let sources: [LectureSource]

    var body: some View {
        if !sources.isEmpty {
            VStack(alignment: .leading, spacing: GardenSpacing.xs) {
                Label("Sources and further watching", systemImage: "play.rectangle.on.rectangle")
                    .gardenText(.cardTitle)
                    .accessibilityAddTraits(.isHeader)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 12, alignment: .top)],
                          alignment: .leading, spacing: 12) {
                    ForEach(Array(sources.enumerated()), id: \.offset) { _, source in
                        SourceCard(source: source)
                    }
                }
                .padding(.top, GardenSpacing.xxs)
            }
        }
    }
}

/// One source card. If the source has a URL, the full card is a button that opens it in the browser.
struct SourceCard: View {
    let source: LectureSource
    @Environment(\.openURL) private var openURL

    var body: some View {
        if let url = source.url {
            Button { openURL(url) } label: { SourceCardContent(source: source) }
                .buttonStyle(SourceCardStyle(linked: true))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(source.accessibilityLabel)
                .accessibilityHint("Opens in your browser.")
                .accessibilityAddTraits(.isLink)
        } else {
            SourceCardBody(linked: false, isPressed: false) { SourceCardContent(source: source) }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(source.accessibilityLabel)
        }
    }
}

/// Title, channel and time range. "Open" shows only for a linked card.
private struct SourceCardContent: View {
    let source: LectureSource
    @Environment(\.gardenPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: GardenSpacing.xxs) {
            Text(source.title)
                .font(GardenFont.cardTitle)
                .foregroundStyle(palette.ink)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Label(source.channel, systemImage: "person.crop.square")
                .font(GardenFont.meta)
                .foregroundStyle(palette.muted)
                .lineLimit(1)
            HStack(alignment: .firstTextBaseline) {
                if let range = source.rangeText {
                    Label(range, systemImage: "clock")
                        .font(GardenFont.small.monospacedDigit())
                        .foregroundStyle(palette.muted)
                }
                Spacer(minLength: GardenSpacing.xs)
                if source.url != nil {
                    Label("Open", systemImage: "arrow.up.right.square")
                        .font(GardenFont.meta)
                        .foregroundStyle(palette.muted)
                }
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SourceCardStyle: ButtonStyle {
    let linked: Bool

    func makeBody(configuration: Configuration) -> some View {
        SourceCardBody(linked: linked, isPressed: configuration.isPressed) { configuration.label }
    }
}

/// Padding 12 pt, radius 8 pt, the card fill and a 1 pt line border. A linked card has the neutral fill and a hand pointer on hover.
private struct SourceCardBody<Content: View>: View {
    let linked: Bool
    let isPressed: Bool
    @ViewBuilder let content: Content
    @Environment(\.gardenPalette) private var palette
    @State private var hovers = false

    var body: some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background {
                RoundedRectangle(cornerRadius: 8).fill(palette.card)
                if linked, hovers { RoundedRectangle(cornerRadius: 8).fill(palette.fill) }
            }
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(palette.line, lineWidth: 1) }
            .opacity(isPressed ? 0.7 : 1)
            .contentShape(.rect(cornerRadius: 8))
            .contentShape(.focusEffect, .rect(cornerRadius: 8))
            .onHover { if linked { hovers = $0 } }
            .pointerStyle(linked ? .link : nil)
    }
}

struct SourceViews_Previews: PreviewProvider {
    static let sources = [
        LectureSource(title: "Plan a course on one page", channel: "Skillgarden Studio",
                      url: URL(string: "https://example.com/plan-a-course"), start: 250, end: 572),
        LectureSource(title: "Course outlines that work", channel: "Learning Lab",
                      url: URL(string: "https://example.com/course-outlines"), start: 3725),
        LectureSource(title: "The course plan checklist", channel: "Skillgarden Docs"),
    ]

    static var previews: some View {
        SourcesSection(sources: sources)
            .padding()
            .frame(width: 720)
    }
}
