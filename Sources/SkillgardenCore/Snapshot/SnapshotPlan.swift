import Foundation

/// Screens that `scripts/snapshot.sh` renders for QA. Add new screens here with the same name rule.
public enum SnapshotScreen: String, CaseIterable, Sendable {
    case libraryEmpty = "library-empty"
    case library
    case section
    case lecture
    case lectureComplete = "lecture-complete"
    case article
    /// The fixture course, which has a light theme. The learner opened a lecture, so "Resume" shows.
    case courseLanding = "course-landing"
    /// The fixture course with `theme.appearance: dark` and a light accent. No lecture is opened, so "Start Course" shows.
    case courseLandingDarkTheme = "course-landing-dark-theme"
    /// The fixture quiz with its draft section published. The first question has an image and no selection.
    case quizQuestion = "quiz-question"
    /// The same question after the learner submitted a wrong choice.
    case quizWrongAnswer = "quiz-wrong-answer"
    /// The results screen with two weak skills.
    case quizResults = "quiz-results"
    /// The interactive fixture course (`Tests/Fixtures/interactive-course`) with a saved weak score of 75.
    case interactiveResult = "interactive-result"
}

public enum SnapshotAppearance: String, CaseIterable, Sendable {
    case light, dark
}

/// Fixed render settings and deterministic output paths for the offscreen snapshot harness.
public enum SnapshotPlan {
    public static let width = 1280
    public static let height = 800
    public static let scale = 2
    public static let localeIdentifier = "en_US"
    public static let timeZoneIdentifier = "UTC"

    public struct Output: Equatable, Sendable {
        public let screen: SnapshotScreen
        public let appearance: SnapshotAppearance
        public let url: URL
    }

    /// One output per screen and appearance, in a fixed order: `<out-dir>/<screen>-<light|dark>.png`.
    public static func outputs(outDirectory: URL) -> [Output] {
        SnapshotScreen.allCases.flatMap { screen in
            SnapshotAppearance.allCases.map { appearance in
                Output(screen: screen, appearance: appearance,
                       url: outDirectory.appending(path: "\(screen.rawValue)-\(appearance.rawValue).png"))
            }
        }
    }

    /// The accent of the dark-theme fixture copy. It has more than 3:1 contrast on the dark background.
    public static let darkThemeAccent = "#7FD3A0"

    /// Writes the store that a screen needs into `root` and returns the course to select, if any.
    public static func seedStore(for screen: SnapshotScreen, root: URL, fixture: URL) throws -> String? {
        switch screen {
        case .libraryEmpty:
            _ = try CourseStore(root: root)
            return nil
        case .library, .section, .lecture, .lectureComplete, .article, .courseLanding:
            // A real publish installs the media snapshot and image metadata, so the course and header images load.
            let id = try CoursePublisher.publish(courseFolder: fixture, root: root).id
            let store = try CourseStore(root: root)
            // Mixed completion: one of the two learner lectures is complete.
            if screen == .library || screen == .lectureComplete { try store.setCompleted(true, courseID: id, lectureID: "welcome") }
            if screen == .courseLanding { try store.saveLastOpenedLecture(courseID: id, lectureID: "read") }
            return id
        case .courseLandingDarkTheme:
            return try publishCopy(of: fixture, root: root, replacing: [
                ("appearance: light", "appearance: dark"),
                ("accent_color: '#286644'", "accent_color: '\(darkThemeAccent)'"),
            ])
        case .interactiveResult:
            // The interactive fixture is next to the sample fixture.
            let folder = fixture.deletingLastPathComponent().appending(path: "interactive-course")
            let id = try CoursePublisher.publish(courseFolder: folder, root: root).id
            try CourseStore(root: root).saveInteractiveResult(
                InteractiveResult(score: 75, objective: "Order the steps of a course plan"), courseID: id, lectureID: "order-steps")
            return id
        case .quizQuestion, .quizWrongAnswer, .quizResults:
            // The fixture quiz is in a draft section. The copy publishes that section so the learner sees the quiz.
            return try publishCopy(of: fixture, root: root, replacing: [
                ("objective: Apply the course plan\n    state: draft", "objective: Apply the course plan\n    state: published"),
            ])
        }
    }

    /// Publishes a temporary copy of the fixture with text replacements in `skillgarden.yaml`.
    private static func publishCopy(of fixture: URL, root: URL, replacing replacements: [(String, String)]) throws -> String {
        let copy = FileManager.default.temporaryDirectory.appending(path: "SkillgardenFixtureCopy-\(UUID())")
        defer { try? FileManager.default.removeItem(at: copy) }
        try FileManager.default.copyItem(at: fixture, to: copy)
        let manifest = copy.appending(path: "skillgarden.yaml")
        var text = try String(contentsOf: manifest, encoding: .utf8)
        for (old, new) in replacements { text = text.replacingOccurrences(of: old, with: new) }
        try text.write(to: manifest, atomically: true, encoding: .utf8)
        return try CoursePublisher.publish(courseFolder: copy, root: root).id
    }

    /// Quiz actions that the harness applies after it opens the quiz lecture.
    /// Results: the learner answers the first two questions wrong, so two skills are weak.
    public static func quizActions(for screen: SnapshotScreen) -> [QuizAction] {
        switch screen {
        case .quizWrongAnswer: [.select(choiceID: "lectures"), .submit]
        case .quizResults:
            [.select(choiceID: "lectures"), .submit, .next, .select(choiceID: "newest"), .submit, .next,
             .select(choiceID: "skill"), .submit, .next]
        default: []
        }
    }

    /// The image loads to wait for before the capture: the Library row image, then the question image.
    public static func imageLoads(for screen: SnapshotScreen) -> Int {
        screen == .quizQuestion || screen == .quizWrongAnswer ? 2 : 1
    }

    /// The page to open after the course is selected. The fixture lecture has a `recommended_next` target.
    public static func destination(for screen: SnapshotScreen) -> CourseDestination? {
        switch screen {
        case .libraryEmpty, .library: nil
        case .section: .section(sectionID: "plan")
        case .lecture, .lectureComplete: .lecture(sectionID: "plan", lectureID: "welcome")
        case .article: .lecture(sectionID: "plan", lectureID: "read")
        case .courseLanding, .courseLandingDarkTheme: .overview
        case .quizQuestion, .quizWrongAnswer, .quizResults: .lecture(sectionID: "practice", lectureID: "check")
        case .interactiveResult: .lecture(sectionID: "practice", lectureID: "order-steps")
        }
    }
}
