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
    var cornerRadius: CGFloat = CourseStyle.cornerRadius
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
        .background(.quaternary, in: .rect(cornerRadius: cornerRadius, style: .continuous))
        .clipShape(.rect(cornerRadius: cornerRadius, style: .continuous))
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

/// The outline column: the course card, "Course Overview", then each section with its lecture stops.
/// It keeps `List(selection:)`, so the arrow keys move the selection.
struct CourseOutlineView: View {
    let course: Course
    let library: LibraryModel
    @Binding var selection: CourseDestination?
    @Environment(\.gardenPalette) private var palette

    private var sections: [CourseSection] { course.learnerSections }

    var body: some View {
        let stones = library.steppingStones()
        // A lecture id can repeat in two sections. The first stone wins.
        let states = Dictionary(zip(course.learnerLectures.map(\.lecture.id), stones)) { first, _ in first }
        List(selection: $selection) {
            OutlineCourseCard(course: course, root: library.root, stones: stones)
                .listRowSeparator(.hidden)
            Label("Course Overview", systemImage: "info.circle")
                .font(GardenFont.body.weight(.heavy))
                .foregroundStyle(palette.ink)
                .tag(CourseDestination.overview)
            ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                Section {
                    // The section header is a row, so a click selects it and opens the section page.
                    SectionHeaderRow(section: section, number: index + 1, progress: library.sectionProgress(section))
                        .tag(CourseDestination.section(sectionID: section.id))
                    ForEach(Array(section.lectures.enumerated()), id: \.element.id) { position, lecture in
                        LectureStopRow(lecture: lecture, stop: stop(lecture, states: states),
                                       isFirst: position == 0, isLast: position == section.lectures.count - 1,
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

    private func stop(_ lecture: Lecture, states: [String: SteppingStone]) -> LectureStopRow.Stop {
        if states[lecture.id] == .done { return .done }
        return library.selectedLecture?.id == lecture.id ? .current : .todo
    }
}

/// The top card of the outline: course image and title, the course stones and "N of M done".
struct OutlineCourseCard: View {
    let course: Course
    let root: URL
    let stones: [SteppingStone]

    var body: some View {
        GardenCard(padding: GardenSpacing.s) {
            VStack(alignment: .leading, spacing: GardenSpacing.s) {
                HStack(spacing: GardenSpacing.s) {
                    CourseImageView(image: course.image, root: root, width: 64, height: 36)
                    Text(course.title).gardenText(.cardTitle).lineLimit(2)
                }
                if !stones.isEmpty {
                    SteppingStones(states: stones)
                    Text("\(stones.filter { $0 == .done }.count) of \(stones.count) done")
                        .gardenText(.meta).monospacedDigit()
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, GardenSpacing.xs)
    }
}

/// The section number tile, the title and the percent of complete lectures. The percent is hidden if the section has no lectures.
struct SectionHeaderRow: View {
    let section: CourseSection
    let number: Int
    let progress: SectionProgress
    @Environment(\.gardenPalette) private var palette

    var body: some View {
        HStack(spacing: GardenSpacing.xs) {
            Text("\(number)")
                .font(.system(size: 13, weight: .heavy)).monospacedDigit()
                .foregroundStyle(palette.onAccent)
                .frame(width: 28, height: 28)
                .background(palette.accent, in: .garden(8))
                .accessibilityHidden(true)
            Text(section.title)
                .font(.system(size: 15, weight: .heavy))
                .foregroundStyle(palette.ink)
                .lineLimit(2)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            if let percent = progress.percent {
                Text("\(percent)%")
                    .font(GardenFont.meta.monospacedDigit())
                    .foregroundStyle(palette.muted)
                    .accessibilityLabel("Section \(percent) percent complete")
            }
        }
        .padding(.top, GardenSpacing.xs)
    }
}

/// A lecture stop in the outline: a 26 pt circle on a 2 pt connector, the title and the "Free preview" capsule.
struct LectureStopRow: View {
    enum Stop { case done, current, todo }

    let lecture: Lecture
    let stop: Stop
    let isFirst: Bool
    let isLast: Bool
    var freePreview = false
    @Environment(\.gardenPalette) private var palette

    private static let circle: CGFloat = 26

    var body: some View {
        HStack(spacing: GardenSpacing.xs) {
            marker
            Text(lecture.title)
                .font(.system(size: 13, weight: stop == .current ? .heavy : .semibold))
                .foregroundStyle(stop == .todo ? palette.muted : palette.ink)
                .lineLimit(2)
            if freePreview {
                Spacer(minLength: 0)
                FreePreviewBadge(filled: true)
            }
        }
        .background(alignment: .leading) { connectors }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(lecture.title), \(lecture.type.rawValue)\(freePreview ? ", Free preview" : "")\(stop == .done ? ", Completed" : "")")
    }

    private var marker: some View {
        ZStack {
            Circle().fill(stop == .done ? palette.accent : stop == .current ? palette.card : palette.soft)
            if stop == .current { Circle().strokeBorder(palette.accent, lineWidth: 3) }
            Image(systemName: stop == .done ? "checkmark" : lecture.type.symbolName)
                .font(.system(size: 11, weight: .heavy))
                .foregroundStyle(stop == .done ? palette.onAccent : stop == .current ? palette.accent : palette.muted)
        }
        .frame(width: Self.circle, height: Self.circle)
    }

    /// The connector runs from the row edges to the circle and into the row gaps, so a section reads as one path.
    private var connectors: some View {
        VStack(spacing: Self.circle) {
            connector(hidden: isFirst)
            connector(hidden: isLast)
        }
        .padding(.vertical, -GardenSpacing.xxs)
        .frame(width: Self.circle)
    }

    private func connector(hidden: Bool) -> some View {
        Rectangle()
            .fill(hidden ? .clear : stop == .done ? palette.accent : palette.line)
            .frame(width: 2)
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
