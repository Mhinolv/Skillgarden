import Foundation
import Testing
@testable import SkillgardenCore

private let fixture = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "Tests/Fixtures/sample-course")

private func temporaryFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appending(path: "CourseLandingTests-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

@Test(arguments: ["", "286644", "#28664", "#2866444", "#286G44", "#FFF", "##28664", " #286644", "#286644 ", "#２８６６４４"])
func themeColorRejectsAnyFormOtherThanSixHexDigits(_ value: String) {
    #expect(ThemeColor(hex: value) == nil)
}

@Test func themeColorReadsUpperAndLowerCaseHex() throws {
    let color = try #require(ThemeColor(hex: "#ff8000"))
    #expect(color == ThemeColor(red: 1, green: 128.0 / 255, blue: 0))
    #expect(ThemeColor(hex: "#FF8000") == color)
}

@Test func contrastRatioMatchesWCAG() throws {
    let black = try #require(ThemeColor(hex: "#000000"))
    let white = try #require(ThemeColor(hex: "#FFFFFF"))
    #expect(abs(black.contrastRatio(with: white) - 21) < 0.001)
    #expect(white.contrastRatio(with: black) == black.contrastRatio(with: white))
    #expect(white.contrastRatio(with: white) == 1)
    // #767676 on white is the WCAG reference value of about 4.54:1.
    #expect(abs(try #require(ThemeColor(hex: "#767676")).contrastRatio(with: white) - 4.54) < 0.01)
}

@Test func themeKeepsAnAccentWithEnoughContrast() {
    let light = CourseTheme(accentColor: "#286644", appearance: .light)
    #expect(light.appearance == .light)
    #expect(light.accent == ThemeColor(hex: "#286644"))
    let dark = CourseTheme(accentColor: "#7FD3A0", appearance: .dark)
    #expect(dark.appearance == .dark)
    #expect(dark.accent == ThemeColor(hex: "#7FD3A0"))
}

@Test func themeUsesTheSystemAccentForLowContrastOrInvalidColors() {
    // Each accent has less than 3:1 contrast on its background.
    #expect(CourseTheme(accentColor: "#FFFFFF", appearance: .light).accent == nil)
    #expect(CourseTheme(accentColor: "#FFFF00", appearance: .light).accent == nil)
    #expect(CourseTheme(accentColor: "#000000", appearance: .dark).accent == nil)
    #expect(CourseTheme(accentColor: "#286644", appearance: .dark).accent == nil)
    #expect(CourseTheme(accentColor: "#7FD3A0", appearance: .light).accent == nil)
    // Invalid forms keep the appearance and use the system accent.
    let invalid = CourseTheme(accentColor: "green", appearance: .dark)
    #expect(invalid.accent == nil)
    #expect(invalid.appearance == .dark)
}

@Test func themeContrastLimitIsInclusive() throws {
    // Find the darkest gray that passes on the light background. The gray one step lighter fails.
    let background = CourseAppearance.light.background
    let passing = try #require((0...255).reversed().first { value in
        ThemeColor(red: Double(value) / 255, green: Double(value) / 255, blue: Double(value) / 255)
            .contrastRatio(with: background) >= 3
    })
    let hex = { (value: Int) in "#" + String(repeating: String(format: "%02X", value), count: 3) }
    #expect(CourseTheme(accentColor: hex(passing), appearance: .light).accent != nil)
    #expect(CourseTheme(accentColor: hex(passing + 1), appearance: .light).accent == nil)
}

@Test func themeChecksContrastOnTheGardenPageBase() {
    #expect(CourseAppearance.light.background == ThemeColor(hex: "#FBFAF7"))
    #expect(CourseAppearance.dark.background == ThemeColor(hex: "#0F0D16"))
    // Each gray failed on the old macOS window gray (#ECECEC, #323232) and passes on the Garden page base.
    #expect(CourseTheme(accentColor: "#8A8A8A", appearance: .light).accent == ThemeColor(hex: "#8A8A8A"))
    #expect(CourseTheme(accentColor: "#6E6E6E", appearance: .dark).accent == ThemeColor(hex: "#6E6E6E"))
    // A color with less than 3:1 contrast on the page base still falls back to the system accent.
    #expect(CourseTheme(accentColor: "#FBFAF7", appearance: .light).accent == nil)
    #expect(CourseTheme(accentColor: "#2A2638", appearance: .dark).accent == nil)
}

@Test func onAccentIsWhiteForDarkFillsAndInkForLightFills() throws {
    #expect(ThemeColor.ink == ThemeColor(hex: "#211F1A"))
    for hex in ["#000000", "#286644", "#7B5CFA", "#3B7A57", "#C2412C"] {
        #expect(try #require(ThemeColor(hex: hex)).onAccent == .white, "\(hex)")
    }
    for hex in ["#FFFFFF", "#FFFF00", "#7FD3A0", "#AAAAAA"] {
        #expect(try #require(ThemeColor(hex: hex)).onAccent == .ink, "\(hex)")
    }
}

@Test func onAccentLimitIsInclusive() throws {
    // Find the lightest gray that has 3:1 contrast with white. The gray one step lighter gets ink.
    let gray = { (value: Int) in ThemeColor(red: Double(value) / 255, green: Double(value) / 255, blue: Double(value) / 255) }
    let passing = try #require((0...255).reversed().first { gray($0).contrastRatio(with: .white) >= 3 })
    #expect(gray(passing).onAccent == .white)
    #expect(gray(passing + 1).onAccent == .ink)
}

@MainActor @Test func publishedSampleShowsEveryLandingField() async throws {
    let root = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let id = try CoursePublisher.publish(courseFolder: fixture, root: root).id
    let library = LibraryModel(root: root)
    await library.reload()
    #expect(library.selectedLanding == nil)
    library.selectCourse(id)
    #expect(library.destination == .overview)
    let course = try #require(library.selectedCourse)
    #expect(course.title == "Local Course Basics")
    #expect(course.subtitle == "A course for the Skillgarden sample")
    #expect(course.image?.alt == "A green garden with two plants")
    let landing = try #require(library.selectedLanding)
    #expect(landing.description == "Learn how to plan and complete a local course.")
    #expect(landing.learningOutcomes == ["Plan a course", "Check your work"])
    #expect(landing.requirements == ["A Mac"])
    #expect(landing.targetAudience == "New learners")
    #expect(landing.theme == CourseTheme(accentColor: "#286644", appearance: .light))
    #expect(landing.theme.accent != nil)
    // "Start Course" opens the first learner lecture.
    #expect(course.firstLecture == .lecture(sectionID: "plan", lectureID: "welcome"))
}

@Test func landingTrimsFieldsAndDropsEmptyListItems() throws {
    let data = try Data(contentsOf: fixture.appending(path: "equivalent.json"))
    var manifest = try JSONDecoder().decode(CourseManifest.self, from: data)
    manifest.description = "  \n"
    manifest.learningOutcomes = ["  Plan  ", "", " "]
    manifest.requirements = []
    manifest.targetAudience = " Everyone "
    manifest.theme.appearance = .dark
    let landing = CourseLanding(manifest: manifest)
    #expect(landing.description.isEmpty)
    #expect(landing.learningOutcomes == ["Plan"])
    #expect(landing.requirements.isEmpty)
    #expect(landing.targetAudience == "Everyone")
    #expect(landing.theme.appearance == .dark)
}

@Test func courseWithoutLearnerLecturesHasNoFirstLecture() {
    let draft = Lecture(id: "a", title: "A", type: .video, order: 0, state: .draft)
    let course = Course(id: "c", title: "C", state: .published, sections: [
        CourseSection(id: "empty", title: "Empty", order: 0, state: .published),
        CourseSection(id: "drafts", title: "Drafts", order: 1, state: .published, lectures: [draft]),
    ])
    #expect(course.firstLecture == nil)
    var later = course
    later.sections.append(CourseSection(id: "s", title: "S", order: 2, state: .published, lectures: [
        Lecture(id: "b", title: "B", type: .article, order: 0, state: .published),
    ]))
    #expect(later.firstLecture == .lecture(sectionID: "s", lectureID: "b"))
}

// MARK: Landing summary and "Details" (#66)

private func landing(outcomes: [String], requirements: [String] = [], audience: String = "",
                     description: String = "") throws -> CourseLanding {
    let data = try Data(contentsOf: fixture.appending(path: "equivalent.json"))
    var manifest = try JSONDecoder().decode(CourseManifest.self, from: data)
    manifest.learningOutcomes = outcomes
    manifest.requirements = requirements
    manifest.targetAudience = audience
    manifest.description = description
    return CourseLanding(manifest: manifest)
}

@Test(arguments: [0, 1, 3, 4, 10])
func landingShowsAtMostThreeOutcomesAndDetailsListsAllOnlyWhenMore(count: Int) throws {
    let outcomes = (0..<count).map { "Outcome \($0 + 1)" }
    let page = try landing(outcomes: outcomes)
    #expect(CourseLanding.summaryOutcomeLimit == 3)
    #expect(page.summaryOutcomes == Array(outcomes.prefix(3)))
    #expect(page.detailOutcomes == (count > 3 ? outcomes : []))
    // With no other field, "Details" has content only if it lists more outcomes than the page.
    #expect(page.hasDetails == (count > 3))
}

@Test func landingDetailsShowForEachOtherField() throws {
    #expect(try landing(outcomes: ["A"], requirements: ["A Mac"]).hasDetails)
    #expect(try landing(outcomes: [], audience: "New learners").hasDetails)
    #expect(try landing(outcomes: [], description: "Learn it.").hasDetails)
    // Blank fields are trimmed away, so "Details" stays hidden.
    #expect(try !landing(outcomes: [" "], requirements: ["  "], audience: " \n", description: "\t").hasDetails)
}

