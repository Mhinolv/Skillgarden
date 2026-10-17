import AppKit
import SwiftUI
import SkillgardenCore

/// The objective of a section or lecture on an accent fill. Hidden when the objective is empty.
struct ObjectiveCallout: View {
    let objective: String
    @Environment(\.gardenPalette) private var palette

    var body: some View {
        let text = objective.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            HStack(spacing: GardenSpacing.s) {
                Image(systemName: "target")
                    .font(.system(size: 20, weight: .heavy))
                    .frame(width: 40, height: 40)
                    .background(.white.opacity(0.2), in: .garden(GardenRadius.row))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Objective").font(.system(size: 12, weight: .heavy)).opacity(0.85)
                    Text(text).font(.system(size: 16, weight: .bold)).fixedSize(horizontal: false, vertical: true)
                }
            }
            .foregroundStyle(palette.onAccent)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, GardenSpacing.s)
            .padding(.horizontal, 18)
            .background(palette.accent, in: .garden(GardenRadius.innerBox))
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
            .fill(palette.soft)
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

/// The section page: the header card with the image, title, stones and count, then the objective and the lecture stops.
struct SectionPageView: View {
    let section: CourseSection
    let number: Int
    let headerImage: SectionHeaderImage?
    let progress: SectionProgress
    let stones: [SteppingStone]
    let isComplete: (String) -> Bool
    let isFreePreview: (String) -> Bool
    let openLecture: (Lecture) -> Void
    @Environment(\.gardenPalette) private var palette

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: GardenSpacing.m) {
                GardenCard(padding: 18) {
                    VStack(alignment: .leading, spacing: 0) {
                        SectionHeaderImageView(image: headerImage)
                        VStack(alignment: .leading, spacing: 0) {
                            Text("Section \(number) · \(section.lectures.count) \(section.lectures.count == 1 ? "lecture" : "lectures")")
                                .gardenText(.label).monospacedDigit()
                            Text(section.title)
                                .gardenText(.heading)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.top, GardenSpacing.xxs)
                                .accessibilityAddTraits(.isHeader)
                            if progress.total > 0 {
                                SteppingStones(states: stones).padding(.top, GardenSpacing.s)
                                Text("\(progress.completed) of \(progress.total) lectures complete")
                                    .gardenText(.meta).monospacedDigit()
                                    .padding(.top, GardenSpacing.xs)
                                    .accessibilityHidden(true)
                            }
                        }
                        .padding(.horizontal, 6)
                        .padding(.top, 18)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                ObjectiveCallout(objective: section.objective)
                if !section.lectures.isEmpty {
                    GardenCard {
                        VStack(alignment: .leading, spacing: GardenSpacing.xs) {
                            ForEach(Array(section.lectures.enumerated()), id: \.element.id) { index, lecture in
                                Button { openLecture(lecture) } label: {
                                    LectureStopRow(lecture: lecture, stop: stop(index, lecture),
                                                   isFirst: index == 0, isLast: index == section.lectures.count - 1,
                                                   freePreview: isFreePreview(lecture.id))
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

/// Wraps every lecture type: label, title, section stones, objective, content, the source cards,
/// then Mark as Complete, the nudge and Previous and Next.
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
    /// "Sources and further watching" cards. The block is hidden when it is empty.
    var sources: [LectureSource] = []
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: GardenSpacing.m) {
                VStack(alignment: .leading, spacing: GardenSpacing.xs) {
                    Text("\(sectionTitle) · Lecture \(number)").gardenText(.label).monospacedDigit()
                    Text(lecture.title)
                        .gardenText(.heading)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    if !stones.isEmpty { SteppingStones(states: stones).padding(.top, GardenSpacing.xxs) }
                }
                ObjectiveCallout(objective: lecture.objective)
                content
                SourcesSection(sources: sources)
                MarkCompleteButton(completed: completed, toggle: toggleComplete)
                    .padding(.top, GardenSpacing.xs)
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
                .buttonStyle(.garden(.soft))
            }
            .frame(maxWidth: maxWidth, alignment: .leading)
            .padding(GardenSpacing.l)
            .frame(maxWidth: .infinity)
        }
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
            .background(palette.soft, in: .garden(24))
    }
}

/// A toggle for the complete state of a lecture: a soft pill, or the primary "Completed" pill. A second click is the undo.
struct MarkCompleteButton: View {
    let completed: Bool
    let toggle: () -> Void

    var body: some View {
        if completed {
            Button("Completed", systemImage: "checkmark.circle.fill", action: toggle)
                .buttonStyle(.garden())
                .help("Mark as Incomplete")
        } else {
            Button("Mark as Complete", systemImage: "checkmark.circle", action: toggle)
                .buttonStyle(.garden(.soft))
        }
    }
}

/// "Up next" or "Recommended next": an ink capsule with the lecture title and "Go to Lecture".
struct NudgeCard: View {
    let nudge: LectureNudge
    let open: () -> Void
    @Environment(\.gardenPalette) private var palette

    private var label: String { nudge.kind == .recommended ? "Recommended next" : "Up next" }

    var body: some View {
        HStack(spacing: GardenSpacing.s) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.system(size: 12, weight: .heavy)).opacity(0.6)
                Label(nudge.lecture.title, systemImage: nudge.lecture.type.symbolName)
                    .font(.system(size: 15, weight: .heavy))
                    .lineLimit(2)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(label): \(nudge.lecture.title)")
            Spacer(minLength: GardenSpacing.xs)
            Button("Go to Lecture", action: open).buttonStyle(.garden(.primary, .small))
        }
        .foregroundStyle(palette.card)
        .padding(.vertical, 12)
        .padding(.leading, GardenSpacing.m)
        .padding(.trailing, 12)
        .background(palette.ink, in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(label): \(nudge.lecture.title)")
    }
}
