import AppKit
import SwiftUI
import SkillgardenCore

/// The objective of a section or lecture: one light tinted line with "Objective" in the accent. Hidden when the objective is empty.
struct ObjectiveCallout: View {
    let objective: String
    @Environment(\.gardenPalette) private var palette

    var body: some View {
        let text = objective.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Objective")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(palette.accentInk)
                    .fixedSize()
                Text(text)
                    .font(.system(size: 12.5))
                    .foregroundStyle(palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, GardenSpacing.xs)
            .padding(.horizontal, GardenSpacing.s)
            .background(palette.tint, in: .garden(GardenRadius.button))
            .accessibilityElement(children: .combine)
        }
    }
}

/// A 16:9 header image that fits on a fill and is never cropped. The file loads off the main actor.
struct SectionHeaderImageView: View {
    let image: SectionHeaderImage?
    @Environment(\.gardenPalette) private var palette
    @State private var loaded: NSImage?

    var body: some View {
        Rectangle()
            .fill(palette.fill)
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay {
                if let loaded {
                    Image(nsImage: loaded).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: "photo").font(.largeTitle).foregroundStyle(palette.muted)
                }
            }
            .clipShape(.garden(GardenRadius.image))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(image?.alt ?? "")
            .accessibilityAddTraits(.isImage)
            .accessibilityHidden(image == nil)
            .task(id: image?.url) {
                loaded = nil
                guard let url = image?.url else { return }
                let data = await Task.detached { try? Data(contentsOf: url) }.value
                loaded = data.flatMap(NSImage.init(data:))
            }
    }
}

/// The section page: the image, title, stones and count, then the objective and the lecture stops in a bordered card.
struct SectionPageView: View {
    let section: CourseSection
    let number: Int
    let headerImage: SectionHeaderImage?
    let progress: SectionProgress
    let stones: [SteppingStone]
    let isComplete: (String) -> Bool
    let openLecture: (Lecture) -> Void
    @Environment(\.gardenPalette) private var palette

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: GardenSpacing.m) {
                VStack(alignment: .leading, spacing: 0) {
                    SectionHeaderImageView(image: headerImage)
                        .overlay { RoundedRectangle.garden(GardenRadius.image).strokeBorder(palette.line, lineWidth: 1) }
                    Text("Section \(number) · \(section.lectures.count) \(section.lectures.count == 1 ? "lecture" : "lectures")")
                        .gardenText(.label).monospacedDigit()
                        .padding(.top, GardenSpacing.m)
                    Text(section.title)
                        .gardenText(.title)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                        .accessibilityAddTraits(.isHeader)
                    if progress.total > 0 {
                        HStack(spacing: GardenSpacing.xs) {
                            SteppingStones(states: stones)
                            Text("\(progress.completed) of \(progress.total) lectures complete")
                                .gardenText(.label).monospacedDigit()
                                .fixedSize()
                                .accessibilityHidden(true)
                        }
                        .padding(.top, GardenSpacing.xs)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                ObjectiveCallout(objective: section.objective)
                if !section.lectures.isEmpty {
                    GardenCard {
                        VStack(alignment: .leading, spacing: GardenSpacing.xs) {
                            ForEach(Array(section.lectures.enumerated()), id: \.element.id) { index, lecture in
                                Button { openLecture(lecture) } label: {
                                    LectureStopRow(lecture: lecture, stop: stop(index, lecture),
                                                   isFirst: index == 0, isLast: index == section.lectures.count - 1)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .contentShape(.rect)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: CourseStyle.textWidth, alignment: .leading)
            .padding(GardenSpacing.l)
            .frame(maxWidth: .infinity)
        }
    }

    /// Done lectures show a check. The first incomplete lecture is the current stop.
    private func stop(_ index: Int, _ lecture: Lecture) -> LectureStopRow.Stop {
        if isComplete(lecture.id) { return .done }
        return stones.indices.contains(index) && stones[index] == .next ? .current : .todo
    }
}

/// Wraps every lecture type: label, title, section stones, objective, content, downloads, the source cards,
/// then Mark as Complete (not for a video), the nudge and Previous and Next.
struct LectureFrameView<Content: View>: View {
    let sectionTitle: String
    let number: Int
    let lecture: Lecture
    /// The stones of the section of the lecture.
    let stones: [SteppingStone]
    let nudge: LectureNudge?
    let completed: Bool
    let toggleComplete: () -> Void
    let previous: (() -> Void)?
    let next: (() -> Void)?
    let openNudge: () -> Void
    /// Interactive modules use a wider column (960 pt).
    var maxWidth: CGFloat = CourseStyle.textWidth
    /// The downloads of the lecture. The block hides when the list is empty.
    var downloads: [LectureDownload] = []
    /// "Sources and further watching" cards. The block is hidden when it is empty.
    var sources: [LectureSource] = []
    /// False makes "Mark as Complete" a bordered button, because the page has its own primary action (a quiz).
    var completeIsPrimary = true
    /// False hides the complete row below the sources, because the content has its own complete control (a video).
    var showsCompleteRow = true
    @ViewBuilder let content: Content
    @State private var visibleTop: CGFloat?

    var body: some View {
        ScrollViewReader { proxy in
            page.environment(\.lectureScrollProxy, proxy)
        }
    }

    private var page: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: GardenSpacing.m) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(sectionTitle) · Lecture \(number)").gardenText(.label).monospacedDigit()
                    Text(lecture.title)
                        .gardenText(.title)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    if !stones.isEmpty { SteppingStones(states: stones).padding(.top, 6) }
                }
                ObjectiveCallout(objective: lecture.objective)
                content
                DownloadsBlock(downloads: downloads)
                SourcesSection(sources: sources)
                if showsCompleteRow {
                    HStack {
                        Spacer()
                        MarkCompleteButton(completed: completed, isPrimary: completeIsPrimary, toggle: toggleComplete)
                    }
                }
                if let nudge { NudgeCard(nudge: nudge, open: openNudge) }
                HStack {
                    Button("Previous", systemImage: "chevron.left") { previous?() }
                        .disabled(previous == nil)
                    Spacer()
                    Button { next?() } label: {
                        HStack(spacing: 6) { Text("Next"); Image(systemName: "chevron.right") }
                    }
                    .disabled(next == nil)
                }
                .buttonStyle(.garden(.bordered))
            }
            .frame(maxWidth: maxWidth, alignment: .leading)
            .padding(GardenSpacing.l)
            .frame(maxWidth: .infinity)
            .environment(\.pageVisibleTop, visibleTop)
        }
        // The proxy frame leaves out the safe area, so its top is the bottom edge of the toolbar.
        // It changes with the window layout, not on a scroll.
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { visibleTop = $0 }
    }
}

/// The lecture body until the lecture types (#9–#12) add their own views.
struct LectureContentPlaceholder: View {
    let lecture: Lecture
    @Environment(\.gardenPalette) private var palette

    var body: some View {
        Label("\(lecture.type.rawValue.capitalized) lecture", systemImage: lecture.type.symbolName)
            .font(GardenFont.cardTitle)
            .foregroundStyle(palette.muted)
            .frame(maxWidth: .infinity)
            .aspectRatio(16 / 9, contentMode: .fit)
            .background(palette.fill, in: .garden(GardenRadius.card))
    }
}

/// A toggle for the complete state of a lecture. "Mark as Complete" is the primary action of the page.
/// "Completed" is a bordered button. A second click is the undo.
struct MarkCompleteButton: View {
    let completed: Bool
    /// False makes "Mark as Complete" bordered, for a page with another primary action.
    var isPrimary = true
    /// The tooltip of "Mark as Complete". Nil shows none.
    var help: String? = nil
    let toggle: () -> Void

    var body: some View {
        if completed {
            Button("Completed", systemImage: "checkmark.circle.fill", action: toggle)
                .buttonStyle(.garden(.bordered))
                .help("Mark as Incomplete")
        } else {
            Button("Mark as Complete", systemImage: "checkmark.circle", action: toggle)
                .buttonStyle(.garden(isPrimary ? .primary : .bordered))
                .help(help ?? "")
        }
    }
}

/// "Up next" or "Recommended next": a 44 pt bordered row with the lecture type, the title and a plain "Go to Lecture".
struct NudgeCard: View {
    let nudge: LectureNudge
    let open: () -> Void
    @Environment(\.gardenPalette) private var palette

    private var label: String { nudge.kind == .recommended ? "Recommended next" : "Up next" }

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                Text(label)
                    .font(GardenFont.label)
                    .foregroundStyle(palette.muted)
                    .fixedSize()
                Image(systemName: nudge.lecture.type.symbolName)
                    .font(.system(size: 12))
                    .foregroundStyle(palette.muted)
                Text(nudge.lecture.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(palette.ink)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(label): \(nudge.lecture.title)")
            Button(action: open) {
                HStack(spacing: 6) { Text("Go to Lecture"); Image(systemName: "chevron.right").imageScale(.small) }
            }
            .buttonStyle(.garden(.plain))
        }
        .frame(minHeight: 44)
        .padding(.leading, GardenSpacing.s)
        .padding(.trailing, 6)
        .background(palette.card, in: .garden(GardenRadius.card))
        .overlay { RoundedRectangle.garden(GardenRadius.card).strokeBorder(palette.line, lineWidth: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(label): \(nudge.lecture.title)")
    }
}
