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

/// The outline column: the course card, "Course Overview", each section with its lecture stops, then "Credits".
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
            if !library.selectedCredits.isEmpty {
                Label("Credits", systemImage: "person.2")
                    .font(GardenFont.body.weight(.heavy))
                    .foregroundStyle(palette.ink)
                    .tag(CourseDestination.credits)
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

/// The course landing page: the hero card with the resume box, "Your path", then one card for each manifest page field.
/// Two columns (560 pt and the rest) at 1040 pt or wider, else one column of 720 pt.
struct CourseLandingView: View {
    let course: Course
    let landing: CourseLanding?
    let root: URL
    let path: [CoursePathRow]
    /// The percent of complete learner lectures in the course.
    let percent: Int
    /// The last opened lecture. If it is set, "Resume" replaces "Start Course".
    let resumeLecture: Lecture?
    let resume: () -> Void
    let start: (() -> Void)?
    let openLecture: (CourseSection, Lecture) -> Void
    /// Opens the credits page. Nil hides "View credits" because the course has no credits.
    var openCredits: (() -> Void)? = nil
    @Environment(\.gardenPalette) private var palette

    static let twoColumnWidth: CGFloat = 1040

    private var lectureCount: Int { path.reduce(0) { $0 + $1.section.lectures.count } }

    var body: some View {
        ScrollView {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: GardenSpacing.l) {
                    hero.frame(width: 560)
                    VStack(alignment: .leading, spacing: GardenSpacing.m) {
                        pathCard
                        blocks
                        creditsLink
                    }
                }
                // The ideal width is fixed, so this layout fits only in a column of 1040 pt or wider.
                .frame(minWidth: Self.twoColumnWidth, idealWidth: Self.twoColumnWidth, maxWidth: .infinity, alignment: .topLeading)
                VStack(alignment: .leading, spacing: GardenSpacing.m) {
                    hero
                    pathCard
                    blocks
                    creditsLink
                }
                .frame(maxWidth: CourseStyle.textWidth, alignment: .leading)
            }
            .padding(GardenSpacing.l)
            .frame(maxWidth: .infinity)
        }
    }

    private var hero: some View {
        GardenCard(padding: 18) {
            VStack(alignment: .leading, spacing: 0) {
                // 750:422 at the card width. A narrow column scales the image down and never crops it.
                Color.clear
                    .aspectRatio(750 / 422, contentMode: .fit)
                    .overlay {
                        GeometryReader { geometry in
                            CourseImageView(image: course.image, root: root, width: geometry.size.width,
                                            height: geometry.size.height, cornerRadius: GardenRadius.image)
                        }
                    }
                VStack(alignment: .leading, spacing: 0) {
                    Text(course.title)
                        .gardenText(.display)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, GardenSpacing.m)
                        .accessibilityAddTraits(.isHeader)
                    if !course.subtitle.isEmpty {
                        Text(course.subtitle)
                            .font(GardenFont.body).lineSpacing(GardenFont.bodyLineSpacing)
                            .foregroundStyle(palette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 10)
                    }
                    HStack(spacing: GardenSpacing.xs) {
                        fact("\(path.count) \(path.count == 1 ? "section" : "sections")")
                        fact("\(lectureCount) \(lectureCount == 1 ? "lecture" : "lectures")")
                    }
                    .padding(.top, 16)
                }
                .padding(.horizontal, 6)
                resumeBox.padding(.top, 18)
            }
        }
    }

    private func fact(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .bold)).monospacedDigit()
            .foregroundStyle(palette.ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(palette.soft, in: Capsule())
    }

    /// "Resume · N% done" with the last opened lecture, or "Start here" with the first lecture.
    private var resumeBox: some View {
        let lecture = resumeLecture ?? course.learnerLectures.first?.lecture
        return HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(resumeLecture == nil ? "Start here" : "Resume · \(percent)% done").gardenText(.label).monospacedDigit()
                if let lecture {
                    Text(lecture.title)
                        .font(.system(size: 16, weight: .heavy))
                        .foregroundStyle(palette.ink)
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
        .padding(.vertical, 16)
        .padding(.horizontal, 18)
        .background(palette.soft, in: .garden(GardenRadius.innerBox))
    }

    @ViewBuilder private var pathCard: some View {
        if !path.isEmpty {
            GardenCard(padding: GardenSpacing.l) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Your path").gardenText(.heading).accessibilityAddTraits(.isHeader)
                        Spacer(minLength: GardenSpacing.xs)
                        Text("One stone per lecture").gardenText(.meta).accessibilityHidden(true)
                    }
                    .padding(.bottom, GardenSpacing.xxs)
                    ForEach(Array(path.enumerated()), id: \.element.section.id) { index, row in
                        if index > 0 {
                            DashedLine().stroke(palette.line, style: StrokeStyle(lineWidth: 2, dash: [6, 5])).frame(height: 2)
                        }
                        CoursePathSectionView(row: row) { openLecture(row.section, $0) }
                    }
                }
            }
        }
    }

    @ViewBuilder private var blocks: some View {
        if let landing {
            if !landing.learningOutcomes.isEmpty {
                block("What you'll learn") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: GardenSpacing.m, alignment: .topLeading), count: 2),
                              alignment: .leading, spacing: GardenSpacing.xs) {
                        ForEach(Array(landing.learningOutcomes.enumerated()), id: \.offset) { _, outcome in
                            HStack(alignment: .firstTextBaseline, spacing: GardenSpacing.xs) {
                                Image(systemName: "checkmark").font(.system(size: 13, weight: .heavy)).foregroundStyle(palette.accent)
                                Text(outcome).font(.system(size: 14, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
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
                .buttonStyle(.link)
                .font(GardenFont.body.weight(.semibold))
                .tint(palette.accent)
        }
    }

    private func block<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        GardenCard {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).gardenText(.label).accessibilityAddTraits(.isHeader)
                content()
                    .font(GardenFont.body).lineSpacing(GardenFont.bodyLineSpacing)
                    .foregroundStyle(palette.ink)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(palette.ink)
                    .accessibilityAddTraits(.isHeader)
                Text("People and sources that made this course.")
                    .font(.subheadline)
                    .foregroundStyle(palette.muted)
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

/// A horizontal line through the middle of its frame. Stroke it with a dash for the path dividers.
struct DashedLine: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        }
    }
}

/// One "Your path" row: the 48 pt number tile, the title, the objective, the stones and the percent.
/// The section with the next lecture lists its lectures in 2 columns. The next lecture has an ink fill.
struct CoursePathSectionView: View {
    let row: CoursePathRow
    let open: (Lecture) -> Void
    @Environment(\.gardenPalette) private var palette

    private var objective: String { row.section.objective.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: GardenSpacing.s) {
            HStack(spacing: 16) {
                numberTile
                VStack(alignment: .leading, spacing: 0) {
                    Text(row.section.title)
                        .font(.system(size: 17, weight: .heavy))
                        .foregroundStyle(palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    if !objective.isEmpty {
                        Text("Objective: \(objective)")
                            .gardenText(.meta)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 3)
                    }
                    if !row.stones.isEmpty { SteppingStones(states: row.stones).padding(.top, GardenSpacing.xs) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let percent = row.progress.percent {
                    (Text("\(percent)").font(.system(size: 22, weight: .heavy))
                        + Text("%").font(.system(size: 12, weight: .heavy)).foregroundStyle(palette.muted))
                        .monospacedDigit()
                        .foregroundStyle(palette.ink)
                        .accessibilityLabel("Section \(percent) percent complete")
                }
            }
            if row.nextLectureID != nil {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 2), spacing: 6) {
                    ForEach(Array(row.section.lectures.enumerated()), id: \.offset) { index, lecture in
                        lectureButton(lecture, stone: row.stones[index])
                    }
                }
                .padding(.leading, 64)
            }
        }
        .padding(.vertical, GardenSpacing.s)
    }

    private var numberTile: some View {
        let full = row.progress.percent == 100
        let text = palette.colorScheme == .dark ? palette.accent : palette.accent.mix(with: .black, by: 0.2, in: .device)
        return Text("\(row.number)")
            .font(.system(size: 20, weight: .heavy)).monospacedDigit()
            .foregroundStyle(full ? palette.onAccent : text)
            .frame(width: 48, height: 48)
            .background(full ? palette.accent : palette.soft, in: .garden(16))
            .accessibilityHidden(true)
    }

    private func lectureButton(_ lecture: Lecture, stone: SteppingStone) -> some View {
        let isNext = stone == .next
        let done = stone == .done
        return Button { open(lecture) } label: {
            HStack(spacing: 10) {
                Image(systemName: isNext ? "play.fill" : done ? "checkmark" : lecture.type.symbolName)
                    .font(.system(size: 12, weight: .heavy))
                    .foregroundStyle(isNext ? palette.card : done ? palette.accent : palette.muted)
                    .frame(width: 16)
                Text(lecture.title)
                    .font(.system(size: 13.5, weight: .bold))
                    .lineLimit(1)
                Spacer(minLength: GardenSpacing.xxs)
                Text(isNext ? "Next" : lecture.type.rawValue.capitalized)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isNext ? palette.card.opacity(0.7) : palette.muted)
            }
            .foregroundStyle(isNext ? palette.card : palette.ink)
            .padding(.vertical, GardenSpacing.xs)
            .padding(.horizontal, 12)
            .background(isNext ? palette.ink : palette.page, in: .garden(GardenRadius.row))
            .contentShape(.garden(GardenRadius.row))
        }
        .buttonStyle(.plain)
        .contentShape(.focusEffect, .garden(GardenRadius.row))
        .accessibilityLabel("\(lecture.title), \(lecture.type.rawValue)\(isNext ? ", Next" : done ? ", Completed" : "")")
    }
}

