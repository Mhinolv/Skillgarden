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
                                 message: "Publish a course with the skillgarden CLI.") {
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
            VStack(alignment: .leading, spacing: GardenSpacing.m) {
                HStack(alignment: .firstTextBaseline, spacing: GardenSpacing.s) {
                    Text("Library").gardenText(.title).accessibilityAddTraits(.isHeader)
                    Text(library.libraryMeta).gardenText(.meta).monospacedDigit()
                }
                if let course = library.continueCourse {
                    LibraryContinueStrip(course: course, summary: library.summary(of: course), root: library.root,
                                         open: { library.selectCourse(course.id) },
                                         resume: { library.openNextLecture(ofCourse: course.id) })
                        .coursePalette(library.accent(ofCourse: course.id))
                }
                LibraryGridLayout(columns: LibraryGrid.columns(forWidth: width), spacing: GardenSpacing.m) {
                    ForEach(library.courses) { course in
                        LibraryTile(course: course, summary: library.summary(of: course), root: library.root) {
                            library.selectCourse(course.id)
                        }
                        .coursePalette(library.accent(ofCourse: course.id))
                    }
                }
            }
            .padding(GardenSpacing.xl)
        }
    }
}

extension View {
    /// Gives a Library card the Garden colors of its own course accent.
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

/// The empty and error states: a centered card with a 40 pt symbol, the title, the message and the actions.
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
                    .font(.system(size: 40, weight: .heavy))
                    .foregroundStyle(palette.accent)
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

/// The course image at 750:422 for the full width of a Library card.
private struct LibraryCardImage: View {
    let course: Course
    let root: URL

    var body: some View {
        Color.clear
            .aspectRatio(750 / 422, contentMode: .fit)
            .overlay {
                GeometryReader { geometry in
                    CourseImageView(image: course.image, root: root, width: geometry.size.width,
                                    height: geometry.size.height, cornerRadius: GardenRadius.image)
                }
            }
    }
}

/// The one-row "Continue" strip: the first course in progress, a 128 × 72 image, the title, the next lecture,
/// the section stones, "14 of 32 done" and "Resume". A click opens the course landing. "Resume" opens the next lecture.
struct LibraryContinueStrip: View {
    let course: Course
    let summary: CourseSummary
    let root: URL
    let open: () -> Void
    let resume: () -> Void
    @Environment(\.gardenPalette) private var palette

    var body: some View {
        HStack(spacing: GardenSpacing.m) {
            CourseImageView(image: course.image, root: root, width: 128, height: 72, cornerRadius: GardenRadius.row)
                // The ring keeps the image apart from the accent fill when the image has a similar color.
                .overlay { RoundedRectangle.garden(GardenRadius.row).strokeBorder(.white.opacity(0.7), lineWidth: 2) }
            VStack(alignment: .leading, spacing: 2) {
                Text("Continue")
                    .font(.system(size: 13, weight: .heavy))
                    .opacity(0.85)
                Text(course.title)
                    .font(GardenFont.cardTitle)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                if let next = summary.nextLecture {
                    Text(next.title).font(GardenFont.body).opacity(0.9).lineLimit(1)
                }
                HStack(spacing: GardenSpacing.xs) {
                    SectionStones(stones: summary.stones, style: .onAccent)
                    Text(summary.countText ?? "")
                        .font(.system(size: 13, weight: .heavy)).monospacedDigit()
                        .fixedSize()
                        .accessibilityHidden(true)
                }
                .padding(.top, GardenSpacing.xxs)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Resume", systemImage: "play.fill", action: resume)
                .buttonStyle(ResumePillStyle())
                .fixedSize()
                .accessibilityHint(summary.nextLecture?.title ?? "")
        }
        .foregroundStyle(palette.onAccent)
        .padding(GardenSpacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.accent, in: .garden(GardenRadius.card))
        .contentShape(.garden(GardenRadius.card))
        .onTapGesture(perform: open)
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Open Course", open)
    }
}

/// The white "Resume" pill on the "Continue" strip, with a dark base below it.
private struct ResumePillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ResumePill(configuration: configuration)
    }
}

private struct ResumePill: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.gardenPalette) private var palette

    var body: some View {
        configuration.label
            .font(.system(size: 15.5, weight: .heavy))
            .lineLimit(1)
            .padding(.horizontal, 24)
            .frame(height: 46)
            .foregroundStyle(palette.accentBase)
            .background(.white, in: Capsule())
            .offset(y: configuration.isPressed ? 3 : 0)
            .background { Capsule().fill(.black.opacity(0.2)).offset(y: 4) }
            .padding(.bottom, 4)
            .contentShape(Capsule())
            .contentShape(.focusEffect, Capsule())
    }
}

/// A 1×1 course tile: image, title, meta line, section stones and "2 of 22 done". A click or Return opens the course landing.
struct LibraryTile: View {
    let course: Course
    let summary: CourseSummary
    let root: URL
    let open: () -> Void
    @Environment(\.gardenPalette) private var palette

    private var fill: Color {
        palette.colorScheme == .dark ? palette.soft : Color.white.mix(with: palette.accent, by: 0.14, in: .device)
    }

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 0) {
                LibraryCardImage(course: course, root: root)
                VStack(alignment: .leading, spacing: 0) {
                    Text(course.title).gardenText(.cardTitle).lineLimit(2).padding(.top, GardenSpacing.s)
                    Text(summary.meta).gardenText(.meta).lineLimit(1).padding(.top, GardenSpacing.xxs)
                    if let count = summary.countText {
                        HStack(spacing: GardenSpacing.xs) {
                            SectionStones(stones: summary.stones)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(count)
                                .font(GardenFont.meta.weight(.heavy)).monospacedDigit()
                                .foregroundStyle(palette.colorScheme == .dark
                                                 ? palette.accent : palette.accent.mix(with: .black, by: 0.25, in: .device))
                        }
                        .padding(.top, 10)
                    }
                }
                .padding(.horizontal, GardenSpacing.xxs)
            }
            .padding([.horizontal, .top], GardenSpacing.s)
            .padding(.bottom, 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(fill, in: .garden(GardenRadius.card))
            .contentShape(.garden(GardenRadius.card))
        }
        .buttonStyle(.plain)
        .contentShape(.focusEffect, .garden(GardenRadius.card))
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
        VStack(alignment: .leading, spacing: GardenSpacing.m) {
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
