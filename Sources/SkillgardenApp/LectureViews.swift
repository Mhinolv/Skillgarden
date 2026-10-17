import AppKit
import SwiftUI
import SkillgardenCore

/// The objective of a section or lecture. Hidden when the objective is empty.
struct ObjectiveCallout: View {
    let objective: String

    var body: some View {
        let text = objective.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            VStack(alignment: .leading, spacing: CourseStyle.spacing) {
                Label("Objective", systemImage: "target").font(.callout.bold())
                Text(text).font(.body)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.tint.opacity(0.08), in: .rect(cornerRadius: CourseStyle.cornerRadius))
            .accessibilityElement(children: .combine)
        }
    }
}

/// A 16:9 header image that fits on a fill and is never cropped. The file loads off the main actor.
struct SectionHeaderImageView: View {
    let image: SectionHeaderImage?
    @State private var loaded: NSImage?

    var body: some View {
        Rectangle()
            .fill(.quaternary)
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay {
                if let loaded {
                    Image(nsImage: loaded).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: "photo").font(.largeTitle).foregroundStyle(.secondary)
                }
            }
            .clipShape(.rect(cornerRadius: CourseStyle.cornerRadius))
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

struct SectionPageView: View {
    let section: CourseSection
    let number: Int
    let headerImage: SectionHeaderImage?
    let progress: SectionProgress
    let isComplete: (String) -> Bool
    let isFreePreview: (String) -> Bool
    let openLecture: (Lecture) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeaderImageView(image: headerImage)
                VStack(alignment: .leading, spacing: CourseStyle.spacing) {
                    Text(section.title).font(.title2).accessibilityAddTraits(.isHeader)
                    Text("Section \(number) · \(section.lectures.count) \(section.lectures.count == 1 ? "lecture" : "lectures")")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if progress.total > 0 {
                        ProgressView(value: progress.fraction) {
                            Text("\(progress.completed) of \(progress.total) lectures complete")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                ObjectiveCallout(objective: section.objective)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(section.lectures) { lecture in
                        Button { openLecture(lecture) } label: {
                            LectureRow(lecture: lecture, completed: isComplete(lecture.id), freePreview: isFreePreview(lecture.id))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, CourseStyle.spacing)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        if lecture.id != section.lectures.last?.id { Divider() }
                    }
                }
            }
            .frame(maxWidth: CourseStyle.textWidth, alignment: .leading)
            .padding(CourseStyle.detailPadding)
            .frame(maxWidth: .infinity)
        }
    }
}

/// Wraps every lecture type: meta line, title, objective, content, then the nudge card and Previous and Next.
struct LectureFrameView<Content: View>: View {
    let sectionTitle: String
    let number: Int
    let lecture: Lecture
    let nudge: LectureNudge?
    let completed: Bool
    let toggleComplete: () -> Void
    let previous: (() -> Void)?
    let next: (() -> Void)?
    let openNudge: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: CourseStyle.spacing) {
                    Text("\(sectionTitle) · Lecture \(number)").font(.subheadline).foregroundStyle(.secondary)
                    Text(lecture.title).font(.title2).accessibilityAddTraits(.isHeader)
                }
                ObjectiveCallout(objective: lecture.objective)
                content
                Divider()
                MarkCompleteButton(completed: completed, toggle: toggleComplete)
                if let nudge { NudgeCard(nudge: nudge, open: openNudge) }
                HStack {
                    Button("Previous", systemImage: "chevron.left") { previous?() }
                        .disabled(previous == nil)
                    Spacer()
                    Button { next?() } label: {
                        HStack { Text("Next"); Image(systemName: "chevron.right") }
                    }
                    .disabled(next == nil)
                }
                .buttonStyle(.bordered)
            }
            .frame(maxWidth: CourseStyle.textWidth, alignment: .leading)
            .padding(CourseStyle.detailPadding)
            .frame(maxWidth: .infinity)
        }
    }
}

/// The lecture body until the lecture types (#9–#12) add their own views.
struct LectureContentPlaceholder: View {
    let lecture: Lecture

    var body: some View {
        Label("\(lecture.type.rawValue.capitalized) lecture", systemImage: lecture.type.symbolName)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 120)
            .background(.quaternary, in: .rect(cornerRadius: CourseStyle.cornerRadius))
    }
}

/// A toggle for the complete state of a lecture. A second click is the undo.
struct MarkCompleteButton: View {
    let completed: Bool
    let toggle: () -> Void

    var body: some View {
        if completed {
            Button("Completed", systemImage: "checkmark.circle.fill", action: toggle)
                .buttonStyle(.borderedProminent)
                .help("Mark as Incomplete")
        } else {
            Button("Mark as Complete", systemImage: "checkmark.circle", action: toggle)
                .buttonStyle(.bordered)
        }
    }
}

struct NudgeCard: View {
    let nudge: LectureNudge
    let open: () -> Void

    private var label: String { nudge.kind == .recommended ? "Recommended next" : "Up next" }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Label(nudge.lecture.title, systemImage: nudge.lecture.type.symbolName).font(.headline)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(label): \(nudge.lecture.title)")
            Spacer()
            Button("Go to Lecture", action: open).buttonStyle(.borderedProminent)
        }
        .padding(12)
        .background(.quinary, in: .rect(cornerRadius: CourseStyle.cornerRadius))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(label): \(nudge.lecture.title)")
    }
}
