import SwiftUI
import SkillgardenCore

/// The Library home: the full window while no course is open. The "Continue" strip, then one tile per course in a grid.
struct LibraryHomeView: View {
    let library: LibraryModel
    /// The library folder to show under "No courses yet". It is nil for the default folder.
    var customRootPath: String? = nil
    @Environment(\.gardenPalette) private var palette
    @State private var width = LibraryGrid.wideWidth

    var body: some View {
        Group {
            if let error = library.errorMessage {
                LibraryStateCard(symbol: "exclamationmark.triangle", title: "Can't open the library", message: error) {
                    Button("Try Again") { Task { await library.reload() } }
                        .buttonStyle(.garden())
                        .disabled(library.isLoading)
                }
            } else if library.isLoading && library.courses.isEmpty {
                ProgressView("Load Library")
            } else if library.courses.isEmpty {
                LibraryStateCard(symbol: "books.vertical", title: "No courses yet",
                                 message: "Publish a course with the skillgarden CLI, or import a course folder.") {
                    Button("Import Course…") { CourseImporter.start(library) }
                        .buttonStyle(.garden())
                        .disabled(!library.canImport)
                    if let customRootPath {
                        Text("Library: \(customRootPath)")
                            .gardenText(.meta)
                            .multilineTextAlignment(.center)
                            .textSelection(.enabled)
                    }
                }
            } else {
                home
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.page.ignoresSafeArea())
        .onGeometryChange(for: Double.self) { $0.size.width } action: { width = $0 }
    }

    private var home: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("Library").gardenText(.title).accessibilityAddTraits(.isHeader)
                    Text(library.libraryMeta).gardenText(.meta).monospacedDigit()
                }
                if let course = library.continueCourse {
                    LibraryContinueStrip(course: course, summary: library.summary(of: course), root: library.root,
                                         accent: library.accent(ofCourse: course.id),
                                         open: { library.selectCourse(course.id) },
                                         resume: { library.openNextLecture(ofCourse: course.id) })
                        .padding(.top, GardenSpacing.m)
                }
                LibraryGridLayout(columns: LibraryGrid.columns(forWidth: width), spacing: GardenSpacing.l) {
                    ForEach(library.courses) { course in
                        LibraryTile(course: course, summary: library.summary(of: course), root: library.root,
                                    accent: library.accent(ofCourse: course.id)) {
                            library.selectCourse(course.id)
                        }
                    }
                }
                .padding(.top, GardenSpacing.xl)
            }
            .padding(.vertical, 28)
            .padding(.horizontal, GardenSpacing.xl)
        }
    }
}

extension View {
    /// Gives the progress stones of a Library card the accent of their own course. The rest of the Library uses the system accent.
    fileprivate func coursePalette(_ accent: ThemeColor?) -> some View {
        modifier(CoursePalette(accent: accent))
    }
}

private struct CoursePalette: ViewModifier {
    let accent: ThemeColor?
    @Environment(\.gardenPalette) private var palette

    func body(content: Content) -> some View {
        let own = GardenPalette(accent: accent, colorScheme: palette.colorScheme)
        content.environment(\.gardenPalette, own).tint(own.accent)
    }
}

/// The empty and error states: a centered card with a 28 pt muted symbol, the title, the message and the actions.
private struct LibraryStateCard<Actions: View>: View {
    let symbol: String
    let title: String
    let message: String
    @ViewBuilder let actions: Actions
    @Environment(\.gardenPalette) private var palette

    var body: some View {
        GardenCard(padding: GardenSpacing.l) {
            VStack(spacing: GardenSpacing.s) {
                Image(systemName: symbol)
                    .font(.system(size: 28, weight: .regular))
                    .foregroundStyle(palette.muted)
                    .accessibilityHidden(true)
                Text(title).gardenText(.heading).accessibilityAddTraits(.isHeader)
                Text(message).gardenText(.body).multilineTextAlignment(.center)
                actions
            }
            .frame(maxWidth: 420)
        }
        .padding(GardenSpacing.xl)
    }
}

/// The course image at 750:422 for the full width of a Library tile, with a hairline.
private struct LibraryCardImage: View {
    let course: Course
    let root: URL
    @Environment(\.gardenPalette) private var palette

    var body: some View {
        Color.clear
            .aspectRatio(750 / 422, contentMode: .fit)
            .overlay {
                GeometryReader { geometry in
                    CourseImageView(image: course.image, root: root, width: geometry.size.width,
                                    height: geometry.size.height, cornerRadius: GardenRadius.image)
                }
            }
            .overlay { RoundedRectangle.garden(GardenRadius.image).strokeBorder(palette.line, lineWidth: 1) }
    }
}

/// The one-row "Continue" strip with a hairline: the first course in progress, an 80 × 45 image, "Continue", the title,
/// the next lecture, the section stones, "14 of 32 done" and "Resume". A click opens the course landing.
/// "Resume" opens the next lecture. It is the one accent button of the Library.
struct LibraryContinueStrip: View {
    let course: Course
    let summary: CourseSummary
    let root: URL
    /// The course accent for the stones. Nil uses the system accent.
    var accent: ThemeColor? = nil
    let open: () -> Void
    let resume: () -> Void
    @Environment(\.gardenPalette) private var palette

    var body: some View {
        HStack(spacing: 14) {
            CourseImageView(image: course.image, root: root, width: 80, height: 45, cornerRadius: 4)
            VStack(alignment: .leading, spacing: 1) {
                Text("Continue").gardenText(.label)
                Text(course.title)
                    .gardenText(.cardTitle)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                if let next = summary.nextLecture {
                    Text("Next: \(next.title)").gardenText(.meta).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: GardenSpacing.xs) {
                SectionStones(stones: summary.stones).coursePalette(accent)
                Text(summary.countText ?? "")
                    .font(GardenFont.label).monospacedDigit()
                    .foregroundStyle(palette.muted)
                    .fixedSize()
                    .accessibilityHidden(true)
            }
            .fixedSize()
            Button("Resume", systemImage: "play.fill", action: resume)
                .buttonStyle(.garden())
                .fixedSize()
                .accessibilityHint(summary.nextLecture?.title ?? "")
        }
        .padding(.vertical, 10)
        .padding(.leading, 10)
        .padding(.trailing, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.card, in: .garden(GardenRadius.card))
        .overlay { RoundedRectangle.garden(GardenRadius.card).strokeBorder(palette.line, lineWidth: 1) }
        .contentShape(.garden(GardenRadius.card))
        .onTapGesture(perform: open)
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Open Course", open)
    }
}

/// A 1×1 course tile with no fill: image, title, meta line, section stones and "2 of 22 done".
/// A click or Return opens the course landing.
struct LibraryTile: View {
    let course: Course
    let summary: CourseSummary
    let root: URL
    /// The course accent for the stones. Nil uses the system accent.
    var accent: ThemeColor? = nil
    let open: () -> Void
    @Environment(\.gardenPalette) private var palette

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 0) {
                LibraryCardImage(course: course, root: root)
                Text(course.title)
                    .gardenText(.cardTitle)
                    .lineLimit(2, reservesSpace: true)
                    .padding(.top, 10)
                Text(summary.meta).gardenText(.meta).lineLimit(1).padding(.top, 2)
                if let count = summary.countText {
                    HStack(spacing: GardenSpacing.xs) {
                        SectionStones(stones: summary.stones).coursePalette(accent)
                        Text(count)
                            .font(GardenFont.label).monospacedDigit()
                            .foregroundStyle(palette.muted)
                            .fixedSize()
                    }
                    .padding(.top, GardenSpacing.xs)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .contentShape(.focusEffect, .garden(GardenRadius.image))
        .onKeyPress(.return) { open(); return .handled }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(course.title), \(summary.meta)\(summary.countText.map { ", \($0)" } ?? "")")
        .accessibilityAddTraits(.isButton)
    }
}

/// Places the tiles in the cells of `LibraryGrid.tileCells`. Every tile gets the column width and the height
/// of the tallest tile, so all tiles have the same size.
struct LibraryGridLayout: Layout {
    var columns: Int
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 1100
        let frames = frames(width: width, subviews: subviews)
        return CGSize(width: width, height: frames.map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (index, frame) in frames(width: bounds.width, subviews: subviews).enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                                  proposal: ProposedViewSize(frame.size))
        }
    }

    /// One frame per subview, in subview order.
    private func frames(width: CGFloat, subviews: Subviews) -> [CGRect] {
        guard !subviews.isEmpty else { return [] }
        let columnWidth = max((width - spacing * CGFloat(columns - 1)) / CGFloat(columns), 0)
        let height = subviews.map { $0.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height }.max() ?? 0
        return LibraryGrid.tileCells(count: subviews.count, columns: columns).map { cell in
            CGRect(x: CGFloat(cell.column) * (columnWidth + spacing), y: CGFloat(cell.row) * (height + spacing),
                   width: columnWidth, height: height)
        }
    }
}

struct LibraryViews_Previews: PreviewProvider {
    static let course = Course(id: "c", title: "Local Course Basics", state: .published, sections: [
        CourseSection(id: "s", title: "Plan", order: 0, state: .published, lectures: [
            Lecture(id: "a", title: "Welcome", type: .video, order: 0, state: .published),
            Lecture(id: "b", title: "Read the plan", type: .article, order: 1, state: .published),
        ]),
    ])

    static var previews: some View {
        let summary = CourseSummary(course: course, progress: ["a": LectureProgress(completed: true)])
        VStack(alignment: .leading, spacing: GardenSpacing.l) {
            LibraryContinueStrip(course: course, summary: summary, root: URL(fileURLWithPath: "/"), open: {}, resume: {})
                .frame(width: 900)
            LibraryTile(course: course, summary: CourseSummary(course: course, progress: [:]),
                        root: URL(fileURLWithPath: "/"), open: {})
                .frame(width: 270)
        }
        .padding(GardenSpacing.xl)
        .gardenTheme(nil)
    }
}
