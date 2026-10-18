import AppKit
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

/// The outline column: the course card, "Course Overview", one row for each section, then "Credits".
/// Only the open section shows its lectures (#70). The selection decides the open section, so the arrow keys
/// onto a closed section header open it. It keeps `List(selection:)`, so the arrow keys move the selection.
struct CourseOutlineView: View {
    let course: Course
    let library: LibraryModel
    @Binding var selection: CourseDestination?
    @Environment(\.gardenPalette) private var palette

    /// The height of one outline row, from the Quiet Garden mockup.
    nonisolated static let rowHeight: CGFloat = 26

    private var sections: [CourseSection] { course.learnerSections }

    var body: some View {
        let openSectionID = library.outlineOpenSectionID
        let nextSectionID = library.outlineNextSectionID
        List(selection: $selection) {
            OutlineCourseCard(course: course, root: library.root, summary: library.summary(of: course))
                .listRowSeparator(.hidden)
                .background(SystemSelectionHighlightOff())
            OutlineLinkRow(title: "Course Overview", systemImage: "info.circle", isSelected: selection == .overview)
                .outlineSelection(selection == .overview)
                .tag(CourseDestination.overview)
            ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                let isOpen = section.id == openSectionID
                let destination = CourseDestination.section(sectionID: section.id)
                // The section header is a row, so a click selects it, opens the section page and opens the section.
                SectionHeaderRow(section: section, number: index + 1, progress: library.sectionProgress(section), isOpen: isOpen,
                                 isNext: section.id == nextSectionID, isSelected: selection == destination)
                    .outlineSelection(selection == destination)
                    .tag(destination)
                if isOpen {
                    ForEach(section.lectures, id: \.id) { lecture in
                        let destination = CourseDestination.lecture(sectionID: section.id, lectureID: lecture.id)
                        OutlineLectureRow(lecture: lecture, video: library.video(forLecture: lecture.id),
                                          isDone: library.isComplete(lecture.id), isCurrent: library.selectedLecture?.id == lecture.id)
                            .outlineSelection(selection == destination)
                            .tag(destination)
                    }
                }
            }
            if sections.allSatisfy({ $0.lectures.isEmpty }) {
                ContentUnavailableView("No lectures yet", systemImage: "list.bullet")
            }
            if !library.selectedCredits.isEmpty {
                OutlineLinkRow(title: "Credits", systemImage: "person.2", isSelected: selection == .credits)
                    .outlineSelection(selection == .credits)
                    .tag(CourseDestination.credits)
            }
        }
        // The medium sidebar row size keeps rows at least 28 pt apart. The small size lets the 26 pt rows set the pitch (#77).
        .environment(\.sidebarRowSize, .small)
        .environment(\.defaultMinListRowHeight, Self.rowHeight)
    }
}

extension View {
    /// A one-line outline row with no list insets.
    func outlineRow() -> some View {
        frame(height: CourseOutlineView.rowHeight)
            .listRowInsets(EdgeInsets())
    }

    /// The quiet selection fill of an outline row (#89) or a transcript search result (#90): `palette.selection` in the row shape, in place of the system blue.
    func outlineSelection(_ isSelected: Bool) -> some View {
        modifier(OutlineSelection(isSelected: isSelected))
    }
}

private struct OutlineSelection: ViewModifier {
    let isSelected: Bool
    @Environment(\.gardenPalette) private var palette

    func body(content: Content) -> some View {
        content.listRowBackground(
            RoundedRectangle.garden(GardenRadius.row)
                .fill(isSelected ? palette.selection : .clear)
                .padding(.horizontal, 10)
        )
    }
}

/// Turns off the AppKit selection highlight of the enclosing outline or search results table (#89, #90). The selection and the arrow keys stay.
/// `OutlineSelection` draws the quiet fill in its place.
struct SystemSelectionHighlightOff: NSViewRepresentable {
    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            var view = superview
            while let current = view, !(current is NSTableView) { view = current.superview }
            if let table = view as? NSTableView, table.selectionHighlightStyle != .none {
                table.selectionHighlightStyle = .none
            }
        }
    }

    func makeNSView(context: Context) -> Probe { Probe() }

    func updateNSView(_ view: Probe, context: Context) {}
}

/// "Course Overview" or "Credits": an icon and the title. The selected row has the `accentInk` icon.
struct OutlineLinkRow: View {
    let title: String
    let systemImage: String
    let isSelected: Bool
    @Environment(\.gardenPalette) private var palette

    var body: some View {
        Label {
            Text(title).foregroundStyle(palette.ink)
        } icon: {
            Image(systemName: systemImage).foregroundStyle(isSelected ? palette.accentInk : palette.ink)
        }
        .font(.system(size: 12.5))
        .outlineRow()
    }
}

/// The top card of the outline: the course image, the title, one stone per section and "N of M done".
struct OutlineCourseCard: View {
    let course: Course
    let root: URL
    let summary: CourseSummary
    @Environment(\.gardenPalette) private var palette

    var body: some View {
        GardenCard(padding: GardenSpacing.xs) {
            HStack(spacing: 10) {
                CourseImageView(image: course.image, root: root, width: 64, height: 36, cornerRadius: 4)
                VStack(alignment: .leading, spacing: 5) {
                    Text(course.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(palette.ink).lineLimit(2)
                    if let countText = summary.countText {
                        HStack(spacing: 6) {
                            SectionStones(stones: summary.stones)
                            Text(countText)
                                .font(GardenFont.small).foregroundStyle(palette.muted).monospacedDigit()
                                .accessibilityHidden(true)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
    }
}

/// One 26 pt row: the open or closed chevron, the muted section number, the title on one line and the percent of
/// complete lectures. The percent is hidden if the section has no lectures. The tooltip shows the full title.
/// On the section of the next lecture, an accent ring wraps the number, like the `.next` stone of `SectionStones` (#77).
struct SectionHeaderRow: View {
    let section: CourseSection
    let number: Int
    let progress: SectionProgress
    let isOpen: Bool
    var isNext = false
    var isSelected = false
    @Environment(\.gardenPalette) private var palette

    var body: some View {
        HStack(spacing: GardenSpacing.xs) {
            Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(isSelected ? palette.accentInk : palette.muted)
                .frame(width: 10)
                .accessibilityHidden(true)
            Text("\(number)")
                .font(GardenFont.small).monospacedDigit()
                .foregroundStyle(isNext ? palette.accentInk : palette.muted)
                .frame(width: 18, height: 18)
                .overlay {
                    if isNext { Circle().strokeBorder(palette.accent, lineWidth: 1.5) }
                }
                .accessibilityHidden(true)
            Text(section.title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(palette.ink)
                .lineLimit(1)
                .truncationMode(.tail)
                .accessibilityLabel(isNext ? "\(section.title), next" : section.title)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            if let percent = progress.percent {
                Text("\(percent)%")
                    .font(GardenFont.small.monospacedDigit())
                    .foregroundStyle(palette.muted)
                    .accessibilityLabel("Section \(percent) percent complete")
            }
        }
        .outlineRow()
        .help(section.title)
        .accessibilityValue(isOpen ? "Expanded" : "Collapsed")
    }
}

/// A lecture row of the open section: a checkmark or the lecture type icon, the title on one line and,
/// for a video, the muted length (#103). The title truncates first. The tooltip shows the full title.
struct OutlineLectureRow: View {
    let lecture: Lecture
    /// The resolved video of a video lecture. Nil for other types or if the snapshot has no video.
    let video: LectureVideo?
    let isDone: Bool
    let isCurrent: Bool
    @Environment(\.gardenPalette) private var palette
    @Environment(\.locale) private var locale

    var body: some View {
        HStack(spacing: GardenSpacing.xs) {
            Image(systemName: isDone ? "checkmark.circle.fill" : lecture.type.symbolName)
                .font(.system(size: 11))
                .foregroundStyle(isDone ? palette.accent : isCurrent ? palette.accentInk : palette.faint)
                .frame(width: 16)
            Text(lecture.title)
                .font(.system(size: 12.5, weight: isCurrent ? .medium : .regular))
                .foregroundStyle(isDone ? palette.muted : palette.ink)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: GardenSpacing.xs)
            // The length lines up with the section percent, in the same style.
            if let duration = LectureVideo.outlineDurationLabel(type: lecture.type, video: video) {
                Text(duration)
                    .font(GardenFont.small.monospacedDigit())
                    .foregroundStyle(palette.muted)
                    .fixedSize()
                    .layoutPriority(1)
            }
        }
        // The lecture icon lines up under the section title, like the mockup.
        .padding(.leading, 26)
        .outlineRow()
        .help(lecture.title)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(LectureVideo.outlineAccessibilityLabel(lecture: lecture, video: video, isDone: isDone, locale: locale))
    }
}

/// A lecture stop on the section page: a 20 pt circle on a 1 pt connector and the title.
struct LectureStopRow: View {
    enum Stop { case done, current, todo }

    let lecture: Lecture
    let stop: Stop
    let isFirst: Bool
    let isLast: Bool
    @Environment(\.gardenPalette) private var palette

    private static let circle: CGFloat = 20

    var body: some View {
        HStack(spacing: GardenSpacing.xs) {
            marker
            Text(lecture.title)
                .font(.system(size: 12.5, weight: stop == .current ? .medium : .regular))
                .foregroundStyle(stop == .done ? palette.muted : palette.ink)
                .lineLimit(2)
        }
        .background(alignment: .leading) { connectors }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(lecture.title), \(lecture.type.rawValue)\(stop == .done ? ", Completed" : "")")
    }

    private var marker: some View {
        ZStack {
            Circle().fill(stop == .done ? palette.accent : palette.card)
            if stop == .current { Circle().strokeBorder(palette.accent, lineWidth: 1.5) }
            Image(systemName: stop == .done ? "checkmark" : lecture.type.symbolName)
                .font(.system(size: 9, weight: stop == .done ? .bold : .regular))
                .foregroundStyle(stop == .done ? palette.onAccent : stop == .current ? palette.accentInk : palette.faint)
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
            .fill(hidden ? .clear : palette.line)
            .frame(width: 1)
    }
}

/// The course landing page in one 600 pt column: the image, title and counts, the bordered resume box, the first outcomes,
/// then "Details" between two hairlines. With "Details" closed, the page fits the 900 × 600 minimum window without a scroll.
struct CourseLandingView: View {
    let course: Course
    let landing: CourseLanding?
    let root: URL
    /// The percent of complete learner lectures in the course.
    let percent: Int
    /// The last opened lecture. If it is set, "Resume" replaces "Start Course".
    let resumeLecture: Lecture?
    let resume: () -> Void
    let start: (() -> Void)?
    /// Opens the credits page. Nil hides "View credits" because the course has no credits.
    var openCredits: (() -> Void)? = nil
    @Environment(\.gardenPalette) private var palette
    @Environment(\.snapshotShowsLandingDetails) private var snapshotShowsDetails
    @State private var showsDetails = false

    static let columnWidth: CGFloat = 600

    private var sections: [CourseSection] { course.learnerSections }
    private var lectureCount: Int { sections.reduce(0) { $0 + $1.lectures.count } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                hero
                resumeBox.padding(.top, 20)
                summaryOutcomes
                if landing?.hasDetails == true || openCredits != nil {
                    HStack(alignment: .center) {
                        if landing?.hasDetails == true { detailsToggle }
                        Spacer(minLength: GardenSpacing.xs)
                        creditsLink
                    }
                    .frame(minHeight: 36)
                    .overlay(alignment: .top) { palette.line.frame(height: 1) }
                    .overlay(alignment: .bottom) { palette.line.frame(height: 1) }
                    .padding(.top, 18)
                    if showsDetails, let landing { details(landing).padding(.top, GardenSpacing.m) }
                }
            }
            .frame(maxWidth: Self.columnWidth, alignment: .leading)
            .padding(.vertical, 28)
            .padding(.horizontal, GardenSpacing.l)
            .frame(maxWidth: .infinity)
        }
        .onAppear { if snapshotShowsDetails { showsDetails = true } }
    }

    /// The 240 × 135 course image left of the title, the subtitle and the counts.
    private var hero: some View {
        HStack(alignment: .top, spacing: GardenSpacing.m) {
            CourseImageView(image: course.image, root: root, width: 240, height: 135, cornerRadius: GardenRadius.image)
                .overlay { RoundedRectangle.garden(GardenRadius.image).strokeBorder(palette.line, lineWidth: 1) }
            VStack(alignment: .leading, spacing: 0) {
                Text(course.title)
                    .gardenText(.display)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                if !course.subtitle.isEmpty {
                    Text(course.subtitle)
                        .font(.system(size: 14))
                        .foregroundStyle(palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, GardenSpacing.xxs)
                }
                Text(counts)
                    .gardenText(.meta).monospacedDigit()
                    .padding(.top, 6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// "3 sections · 22 lectures".
    private var counts: String {
        "\(sections.count) \(sections.count == 1 ? "section" : "sections") · \(lectureCount) \(lectureCount == 1 ? "lecture" : "lectures")"
    }

    /// "Resume · N% done" with the last opened lecture, or "Start here" with the first lecture, in a bordered box.
    private var resumeBox: some View {
        let lecture = resumeLecture ?? course.learnerLectures.first?.lecture
        return HStack(spacing: GardenSpacing.m) {
            VStack(alignment: .leading, spacing: 1) {
                Text(resumeLecture == nil ? "Start here" : "Resume · \(percent)% done").gardenText(.label).monospacedDigit()
                if let lecture {
                    Text(lecture.title)
                        .gardenText(.cardTitle)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            if let resumeLecture {
                Button("Resume", systemImage: "play.fill", action: resume)
                    .buttonStyle(.garden())
                    .keyboardShortcut(.defaultAction)
                    .accessibilityHint(resumeLecture.title)
            } else {
                Button("Start Course") { start?() }
                    .buttonStyle(.garden())
                    .keyboardShortcut(.defaultAction)
                    .disabled(start == nil)
            }
        }
        .padding(.vertical, GardenSpacing.s)
        .padding(.horizontal, 14)
        .background(palette.card, in: .garden(GardenRadius.card))
        .overlay { RoundedRectangle.garden(GardenRadius.card).strokeBorder(palette.line, lineWidth: 1) }
    }

    @ViewBuilder private var summaryOutcomes: some View {
        if let outcomes = landing?.summaryOutcomes, !outcomes.isEmpty {
            block("What you'll learn") { outcomeList(outcomes) }
                .padding(.top, GardenSpacing.l)
        }
    }

    private func outcomeList(_ outcomes: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(outcomes.enumerated()), id: \.offset) { _, outcome in
                HStack(alignment: .firstTextBaseline, spacing: GardenSpacing.xs) {
                    Image(systemName: "checkmark").font(.system(size: 11)).foregroundStyle(palette.muted)
                    Text(outcome).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// The "Details" disclosure button. It is closed by default.
    private var detailsToggle: some View {
        Button { showsDetails.toggle() } label: {
            HStack(spacing: GardenSpacing.xs) {
                Image(systemName: showsDetails ? "chevron.down" : "chevron.right")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.muted)
                    .frame(width: 14)
                Text("Details").font(GardenFont.cardTitle).foregroundStyle(palette.ink)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityValue(showsDetails ? "Expanded" : "Collapsed")
        .accessibilityHint(showsDetails ? "Hides the course details" : "Shows the course details")
    }

    /// All outcomes (if there are more than the page shows), the requirements, the audience and the description.
    private func details(_ landing: CourseLanding) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            if !landing.detailOutcomes.isEmpty {
                block("All outcomes") { outcomeList(landing.detailOutcomes) }
            }
            if !landing.requirements.isEmpty {
                block("Requirements") {
                    VStack(alignment: .leading, spacing: GardenSpacing.xxs) {
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
    }

    @ViewBuilder private var creditsLink: some View {
        if let openCredits {
            Button("View credits", action: openCredits)
                .buttonStyle(.garden(.plain))
        }
    }

    /// A 13 pt semibold heading, then the content in body text. No card.
    private func block<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).gardenText(.cardTitle).accessibilityAddTraits(.isHeader)
            content()
                .font(GardenFont.body).lineSpacing(GardenFont.bodyLineSpacing)
                .foregroundStyle(palette.ink)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SnapshotShowsLandingDetailsKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// The snapshot harness sets this, so the course landing opens with "Details" open. The app sets none.
    var snapshotShowsLandingDetails: Bool {
        get { self[SnapshotShowsLandingDetailsKey.self] }
        set { self[SnapshotShowsLandingDetailsKey.self] = newValue }
    }
}

/// The course credits page: one row for each credit in manifest order, with a divider between rows.
struct CourseCreditsView: View {
    let credits: [CourseCredit]
    @Environment(\.gardenPalette) private var palette

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Credits")
                    .gardenText(.title)
                    .accessibilityAddTraits(.isHeader)
                Text("People and sources that made this course.")
                    .gardenText(.meta)
                    .padding(.top, GardenSpacing.xxs)
                    .padding(.bottom, GardenSpacing.s)
                ForEach(Array(credits.enumerated()), id: \.offset) { index, credit in
                    if index > 0 { Divider() }
                    CreditRow(credit: credit)
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: CourseStyle.textWidth, alignment: .leading)
            .padding(CourseStyle.detailPadding)
            .frame(maxWidth: .infinity)
        }
    }
}

/// One credit: the name, the optional role under it and the optional trailing "Open Link".
struct CreditRow: View {
    let credit: CourseCredit
    @Environment(\.gardenPalette) private var palette

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: GardenSpacing.s) {
            VStack(alignment: .leading, spacing: 2) {
                Text(credit.name)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(palette.ink)
                if let role = credit.role {
                    Text(role)
                        .font(.subheadline)
                        .foregroundStyle(palette.muted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(credit.role.map { "\(credit.name), \($0)" } ?? credit.name)
            if let url = credit.url {
                // `Link` opens the URL with `openURL`, so a web link opens in the default browser.
                Link(destination: url) {
                    Label("Open Link", systemImage: "arrow.up.right.square")
                }
                .foregroundStyle(palette.accent)
                .accessibilityLabel("Open link for \(credit.name)")
            }
        }
        .padding(.vertical, 10)
    }
}
