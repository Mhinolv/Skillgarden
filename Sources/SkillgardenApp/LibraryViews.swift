import SwiftUI
import SkillgardenCore

/// The Library home: the full window while no course is open. A bento grid with the hero and one tile per course.
struct LibraryHomeView: View {
    let library: LibraryModel
    @Environment(\.gardenPalette) private var palette
    @State private var width = LibraryBento.wideWidth

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
                                 message: "Publish a course with the skillgarden CLI.") { EmptyView() }
            } else {
                home
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.page.ignoresSafeArea())
        .onGeometryChange(for: Double.self) { $0.size.width } action: { width = $0 }
    }

    private var home: some View {
        let hero = library.heroCourse
        let tiles = library.courses.filter { $0.id != hero?.id }
        return ScrollView {
            VStack(alignment: .leading, spacing: GardenSpacing.m) {
                HStack(alignment: .firstTextBaseline, spacing: GardenSpacing.s) {
                    Text("Library").gardenText(.title).accessibilityAddTraits(.isHeader)
                    Text(library.libraryMeta).gardenText(.meta).monospacedDigit()
                }
                LibraryBentoLayout(columns: LibraryBento.columns(forWidth: width), spacing: GardenSpacing.m,
                                   hasHero: hero != nil) {
                    if let hero {
                        LibraryHeroCard(course: hero, summary: library.summary(of: hero), root: library.root,
                                        open: { library.selectCourse(hero.id) },
                                        resume: { library.openNextLecture(ofCourse: hero.id) })
                            .coursePalette(library.accent(ofCourse: hero.id))
                    }
                    ForEach(tiles) { course in
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

/// The 2×2 hero: the first course in progress, its next lecture, "Resume", the stones and "14 / 32".
/// A click opens the course landing. "Resume" opens the next lecture.
struct LibraryHeroCard: View {
    let course: Course
    let summary: CourseSummary
    let root: URL
    let open: () -> Void
    let resume: () -> Void
    @Environment(\.gardenPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LibraryCardImage(course: course, root: root)
            Text("Pick up where you left off")
                .font(.system(size: 13, weight: .heavy))
                .opacity(0.85)
                .padding(.top, GardenSpacing.m)
            Text(course.title)
                .font(.system(size: 38, weight: .heavy))
                .lineLimit(2)
                .padding(.top, 6)
                .accessibilityAddTraits(.isHeader)
            if let next = summary.nextLecture {
                Text(next.title).font(GardenFont.body).opacity(0.9).lineLimit(2).padding(.top, GardenSpacing.xs)
            }
            Spacer(minLength: 18)
            HStack(spacing: 18) {
                Button("Resume", systemImage: "play.fill", action: resume)
                    .buttonStyle(HeroResumeButtonStyle())
                    .accessibilityHint(summary.nextLecture?.title ?? "")
                SteppingStones(states: summary.stones, style: .onAccent)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("\(summary.completed) / \(summary.total)")
                    .font(.system(size: 15, weight: .heavy)).monospacedDigit()
                    .accessibilityHidden(true)
            }
        }
        .foregroundStyle(palette.onAccent)
        .padding(GardenSpacing.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(palette.accent, in: .garden(GardenRadius.hero))
        .contentShape(.garden(GardenRadius.hero))
        .onTapGesture(perform: open)
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Open Course", open)
    }
}

/// The white "Resume" pill on the hero, with a dark base below it.
private struct HeroResumeButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HeroResumeButton(configuration: configuration)
    }
}

private struct HeroResumeButton: View {
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

/// A 1×1 course tile: image, title, meta line, stones and status. A click or Return opens the course landing.
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
                    if let status = summary.statusText {
                        HStack(spacing: GardenSpacing.xs) {
                            SteppingStones(states: summary.stones)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(status)
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
        .accessibilityLabel("\(course.title), \(summary.meta)\(summary.statusText.map { ", \($0)" } ?? "")")
        .accessibilityAddTraits(.isButton)
    }
}

/// Places the hero over 2×2 cells at the top leading corner and the tiles in the cells of `LibraryBento.tileCells`.
/// Tiles in one row get the same height. Rows 0 and 1 grow if the hero needs more height.
struct LibraryBentoLayout: Layout {
    var columns: Int
    var spacing: CGFloat
    var hasHero: Bool

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

    /// One frame per subview, in subview order. The first subview is the hero if `hasHero` is true.
    private func frames(width: CGFloat, subviews: Subviews) -> [CGRect] {
        guard !subviews.isEmpty else { return [] }
        let columnWidth = max((width - spacing * CGFloat(columns - 1)) / CGFloat(columns), 0)
        let tileIndices = Array(subviews.indices.dropFirst(hasHero ? 1 : 0))
        let cells = LibraryBento.tileCells(count: tileIndices.count, columns: columns, hasHero: hasHero)
        var heights = Array(repeating: CGFloat(0), count: max((cells.map(\.row).max() ?? -1) + 1, hasHero ? 2 : 0))
        for (cell, index) in zip(cells, tileIndices) {
            let size = subviews[index].sizeThatFits(ProposedViewSize(width: columnWidth, height: nil))
            heights[cell.row] = max(heights[cell.row], size.height)
        }
        let heroWidth = columnWidth * 2 + spacing
        if hasHero {
            let needed = subviews[0].sizeThatFits(ProposedViewSize(width: heroWidth, height: nil)).height
            let extra = needed - (heights[0] + spacing + heights[1])
            // If row 1 has no tiles, it takes all the extra height, so the tiles in row 0 keep their own height.
            if extra > 0, heights[1] == 0 {
                heights[1] += extra
            } else if extra > 0 {
                heights[0] += extra / 2
                heights[1] += extra / 2
            }
        }
        var tops: [CGFloat] = []
        var y: CGFloat = 0
        for height in heights {
            tops.append(y)
            y += height + spacing
        }
        let x = { (column: Int) in CGFloat(column) * (columnWidth + spacing) }
        var frames: [CGRect] = []
        if hasHero { frames.append(CGRect(x: 0, y: 0, width: heroWidth, height: heights[0] + spacing + heights[1])) }
        for cell in cells {
            frames.append(CGRect(x: x(cell.column), y: tops[cell.row], width: columnWidth, height: heights[cell.row]))
        }
        return frames
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
        HStack(alignment: .top, spacing: GardenSpacing.m) {
            LibraryHeroCard(course: course, summary: summary, root: URL(fileURLWithPath: "/"), open: {}, resume: {})
                .frame(width: 560, height: 520)
            LibraryTile(course: course, summary: CourseSummary(course: course, progress: [:]),
                        root: URL(fileURLWithPath: "/"), open: {})
                .frame(width: 270)
        }
        .padding(GardenSpacing.xl)
        .gardenTheme(nil)
    }
}
