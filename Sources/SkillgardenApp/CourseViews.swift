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
        case .interactive: "hand.tap"
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
            imageLoads?.start()
            // Read the file off the main actor. NSImage keeps SVG as a vector, so it draws sharp at any size.
            let data = await Task.detached { try? Data(contentsOf: url) }.value
            loaded = data.flatMap(NSImage.init(data:))
            imageLoads?.finish(loaded: loaded != nil)
        }
    }
}

/// Counts course image and article loads so the snapshot harness can capture after the loads end. The app sets none.
@MainActor
final class ImageLoadTracker {
    private(set) var started = 0
    private(set) var finished = 0
    private(set) var loaded = 0

    var pending: Int { started - finished }

    func start() { started += 1 }

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
                        LectureRow(lecture: lecture, completed: library.isComplete(lecture.id),
                                   freePreview: library.isFreePreview(lecture.id))
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

/// A lecture with its type, the "Free preview" capsule at the trailing edge and the complete mark.
struct LectureRow: View {
    let lecture: Lecture
    let completed: Bool
    var freePreview = false

    var body: some View {
        HStack(spacing: CourseStyle.spacing) {
            Image(systemName: lecture.type.symbolName)
                .foregroundStyle(.secondary)
            Text(lecture.title).font(.body).lineLimit(2)
            if completed || freePreview { Spacer(minLength: 0) }
            if freePreview { FreePreviewBadge(filled: true) }
            if completed {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(lecture.title), \(lecture.type.rawValue)\(freePreview ? ", Free preview" : "")\(completed ? ", Completed" : "")")
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
                .keyboardShortcut(.defaultAction)
                .accessibilityHint(lecture.title)
            Text(lecture.title).font(.callout).foregroundStyle(.secondary).accessibilityHidden(true)
        }
    }
}

/// The course landing page: image, title, meta line, "Start Course" or "Resume", then the manifest page fields.
struct CourseLandingView: View {
    let course: Course
    let landing: CourseLanding?
    let root: URL
    /// The last opened lecture. If it is set, "Resume" replaces "Start Course".
    let resumeLecture: Lecture?
    let resume: () -> Void
    let start: (() -> Void)?

    private static let blockSpacing: CGFloat = 24

    private var metaLine: String {
        let sections = course.learnerSections
        let lectures = sections.reduce(0) { $0 + $1.lectures.count }
        return "\(sections.count) \(sections.count == 1 ? "section" : "sections") · "
            + "\(lectures) \(lectures == 1 ? "lecture" : "lectures")"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Self.blockSpacing) {
                // 750:422 at most 750 pt wide. A narrow column scales the image down and never crops it.
                Color.clear
                    .aspectRatio(750 / 422, contentMode: .fit)
                    .frame(maxWidth: 750)
                    .overlay {
                        GeometryReader { geometry in
                            CourseImageView(image: course.image, root: root,
                                            width: geometry.size.width, height: geometry.size.height)
                        }
                    }
                    .frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: CourseStyle.spacing) {
                    Text(course.title).font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
                    if !course.subtitle.isEmpty {
                        Text(course.subtitle).font(.title3).foregroundStyle(.secondary)
                    }
                    Text(metaLine).font(.callout).foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
                if let resumeLecture {
                    ResumeButton(lecture: resumeLecture, resume: resume)
                } else {
                    Button("Start Course") { start?() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                        .disabled(start == nil)
                }
                if let landing {
                    blocks(landing)
                }
            }
            .frame(maxWidth: CourseStyle.textWidth, alignment: .leading)
            .padding(CourseStyle.detailPadding)
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder private func blocks(_ landing: CourseLanding) -> some View {
        if !landing.learningOutcomes.isEmpty {
            block("What you'll learn") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .topLeading), count: 2),
                          alignment: .leading, spacing: CourseStyle.spacing) {
                    ForEach(Array(landing.learningOutcomes.enumerated()), id: \.offset) { _, outcome in
                        Label {
                            Text(outcome).fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "checkmark").foregroundStyle(.tint)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        if !landing.requirements.isEmpty {
            block("Requirements") {
                VStack(alignment: .leading, spacing: CourseStyle.spacing) {
                    ForEach(Array(landing.requirements.enumerated()), id: \.offset) { _, requirement in
                        Text("• \(requirement)").fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        if !landing.targetAudience.isEmpty {
            block("Who this course is for") { Text(landing.targetAudience).fixedSize(horizontal: false, vertical: true) }
        }
        if !landing.description.isEmpty {
            block("Description") { Text(landing.description).fixedSize(horizontal: false, vertical: true) }
        }
    }

    private func block<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: CourseStyle.spacing) {
            Text(title).font(.title3.bold()).accessibilityAddTraits(.isHeader)
            content().font(.body)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
