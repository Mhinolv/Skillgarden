import SwiftUI
import SkillgardenCore

/// Shared values for the course pages and lecture views.
enum CourseStyle {
    static let spacing: CGFloat = 8
    static let detailPadding: CGFloat = 24
    static let textWidth: CGFloat = 720
    static let cornerRadius: CGFloat = 8
}

extension LectureType {
    var symbolName: String {
        switch self {
        case .video: "play.rectangle"
        case .article: "doc.text"
        case .quiz: "checklist"
        case .assignment: "pencil.and.list.clipboard"
        }
    }
}

/// Draws a published image at a fixed size without crop. Raster images use the smallest derivative that covers the size.
struct CourseImageView: View {
    let image: CourseImage?
    let root: URL
    let width: CGFloat
    let height: CGFloat
    @Environment(\.displayScale) private var displayScale
    @Environment(\.imageLoads) private var imageLoads
    @State private var loaded: NSImage?

    private var url: URL? {
        image.map { root.appending(path: $0.path(forPixelWidth: width * displayScale, height: height * displayScale)) }
    }

    var body: some View {
        Group {
            if let loaded {
                Image(nsImage: loaded).resizable().aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "photo").foregroundStyle(.secondary)
            }
        }
        .frame(width: width, height: height)
        .background(.quaternary, in: .rect(cornerRadius: CourseStyle.cornerRadius))
        .clipShape(.rect(cornerRadius: CourseStyle.cornerRadius))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(image?.alt ?? "")
        .task(id: url) {
            guard let url else { loaded = nil; return }
            // Read the file off the main actor. NSImage keeps SVG as a vector, so it draws sharp at any size.
            let data = await Task.detached { try? Data(contentsOf: url) }.value
            loaded = data.flatMap(NSImage.init(data:))
            imageLoads?.finish(loaded: loaded != nil)
        }
    }
}

/// Counts finished course image loads so the snapshot harness can capture after the load ends. The app sets none.
@MainActor
final class ImageLoadTracker {
    private(set) var finished = 0
    private(set) var loaded = 0

    func finish(loaded success: Bool) {
        finished += 1
        if success { loaded += 1 }
    }
}

private struct ImageLoadsKey: EnvironmentKey {
    static let defaultValue: ImageLoadTracker? = nil
}

extension EnvironmentValues {
    var imageLoads: ImageLoadTracker? {
        get { self[ImageLoadsKey.self] }
        set { self[ImageLoadsKey.self] = newValue }
    }
}

struct LibraryRow: View {
    let course: Course
    let root: URL

    var body: some View {
        HStack(spacing: CourseStyle.spacing) {
            CourseImageView(image: course.image, root: root, width: 64, height: 36)
            VStack(alignment: .leading, spacing: CourseStyle.spacing) {
                Text(course.title).font(.headline).lineLimit(1)
                Text(course.subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct CourseOutlineView: View {
    let course: Course
    let library: LibraryModel
    @Binding var selection: CourseDestination?

    private var sections: [CourseSection] { course.learnerSections }

    var body: some View {
        List(selection: $selection) {
            Label("Course Overview", systemImage: "info.circle")
                .tag(CourseDestination.overview)
            ForEach(sections) { section in
                Section {
                    // The section header is a row, so a click selects it and opens the section page.
                    SectionHeaderRow(section: section, progress: library.sectionProgress(section))
                        .tag(CourseDestination.section(sectionID: section.id))
                    ForEach(section.lectures) { lecture in
                        LectureRow(lecture: lecture, completed: library.isComplete(lecture.id))
                            .tag(CourseDestination.lecture(sectionID: section.id, lectureID: lecture.id))
                    }
                }
            }
            if sections.allSatisfy({ $0.lectures.isEmpty }) {
                ContentUnavailableView("No lectures yet", systemImage: "list.bullet")
            }
        }
    }
}

/// The section title with the percent of complete lectures. The percent is hidden if the section has no lectures.
struct SectionHeaderRow: View {
    let section: CourseSection
    let progress: SectionProgress

    var body: some View {
        HStack(spacing: CourseStyle.spacing) {
            Text(section.title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            if let percent = progress.percent {
                Text("\(percent)%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Section \(percent) percent complete")
            }
        }
    }
}

struct LectureRow: View {
    let lecture: Lecture
    let completed: Bool

    var body: some View {
        HStack(spacing: CourseStyle.spacing) {
            Image(systemName: lecture.type.symbolName)
                .foregroundStyle(.secondary)
            Text(lecture.title).font(.body).lineLimit(2)
            if completed {
                Spacer(minLength: 0)
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(lecture.title), \(lecture.type.rawValue)\(completed ? ", Completed" : "")")
    }
}

/// The landing button after the learner opened a lecture. The lecture title shows below it.
struct ResumeButton: View {
    let lecture: Lecture
    let resume: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button("Resume", systemImage: "play.fill", action: resume)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityHint(lecture.title)
            Text(lecture.title).font(.callout).foregroundStyle(.secondary).accessibilityHidden(true)
        }
    }
}

struct CourseDetailPlaceholder<Actions: View>: View {
    let title: String
    let symbol: String
    let titleFont: Font
    @ViewBuilder var actions: Actions

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CourseStyle.spacing) {
                Image(systemName: symbol).foregroundStyle(.secondary).accessibilityHidden(true)
                Text(title).font(titleFont).accessibilityAddTraits(.isHeader)
                actions
            }
            .frame(maxWidth: CourseStyle.textWidth, alignment: .leading)
            .padding(CourseStyle.detailPadding)
            .frame(maxWidth: .infinity)
        }
    }
}

extension CourseDetailPlaceholder where Actions == EmptyView {
    init(title: String, symbol: String, titleFont: Font) {
        self.init(title: title, symbol: symbol, titleFont: titleFont) { EmptyView() }
    }
}
