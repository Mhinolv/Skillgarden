import Foundation

/// Screens that `scripts/snapshot.sh` renders for QA. Add new screens here with the same name rule.
public enum SnapshotScreen: String, CaseIterable, Sendable {
    case libraryEmpty = "library-empty"
    /// The empty library in a data folder that is not the default. The "Library: <path>" line shows.
    case libraryEmptyCustomFolder = "library-empty-custom-folder"
    /// The Library home with no selected course: the fixture course in progress as the hero, then a new course tile.
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
    /// The video lecture after the learner started it, so the real AVKit player view shows. Playback stays paused.
    case videoPlayer = "video-player"
    /// The video lecture scrolled to the end, so the Transcript panel and all its lines show. The second cue is active.
    case videoTranscript = "video-transcript"
    /// The video lecture with its quick-check card open and scrolled into view.
    /// Two checks: the first is unanswered, the second is answered wrong and shows its explanation.
    case videoQuickCheck = "video-quick-check"
    /// The spaced review sheet of the "plan" section, after the quiz section moved first.
    /// Two questions: one unanswered, one answered correctly.
    case sectionReview = "section-review"
    /// The credits page of the fixture course with a second credit. One row has a role and a URL, one row has neither.
    case courseCredits = "course-credits"
    /// The fixture assignment with its draft section and lecture published. No rubric row is checked.
    case assignment
    /// The same assignment with every rubric row checked, so the success line shows.
    case assignmentComplete = "assignment-complete"
    /// The article lecture scrolled to the end, so its three source cards show:
    /// a full time range with a URL, a start only with a URL, and no URL.
    case lectureSources = "lecture-sources"

    /// True when the harness opens the player of the video lecture before the capture.
    public var opensVideoPlayer: Bool { self == .videoPlayer || self == .videoTranscript || self == .videoQuickCheck }

    /// The paused player opens at this time instead of the saved position. 3 s is in the second fixture cue (2–4 s).
    public var videoStartSeconds: Double? { self == .videoTranscript ? 3 : nil }

    /// True when the harness scrolls the lecture page to the end.
    public var scrollsLectureToEnd: Bool { self == .videoTranscript || self == .videoQuickCheck || self == .lectureSources }

    /// True when the harness opens the quick-check card of the video lecture.
    public var showsQuickChecks: Bool { self == .videoQuickCheck }

    /// True when the harness fails if the capture has black video pixels in the title bar and the toolbar (#55).
    public var checksTitlebarForVideo: Bool { opensVideoPlayer }

    /// True when the harness draws the review sheet in the window. A real sheet is a separate window, so the capture misses it.
    public var showsReviewInline: Bool { self == .sectionReview }

    /// True when the harness selects the seeded course. The Library screens show the Library home, so they select none.
    public var selectsCourse: Bool { self != .library && self != .libraryEmpty && self != .libraryEmptyCustomFolder }

    /// The fixed library path that the harness shows. The real temporary root changes on each run.
    public var customRootPath: String? { self == .libraryEmptyCustomFolder ? "/Users/agent/skillgarden-library" : nil }
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
    /// `screens` limits the outputs to these screens. The order stays the same.
    public static func outputs(outDirectory: URL, screens: Set<SnapshotScreen>? = nil) -> [Output] {
        SnapshotScreen.allCases.filter { screens?.contains($0) ?? true }.flatMap { screen in
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
        case .libraryEmpty, .libraryEmptyCustomFolder:
            _ = try CourseStore(root: root)
            return nil
        case .library, .section, .lecture, .lectureComplete, .article, .courseLanding, .videoPlayer, .videoTranscript,
             .videoQuickCheck, .lectureSources:
            // A real publish installs the media snapshot and image metadata, so the course and header images load.
            let id = try CoursePublisher.publish(courseFolder: fixture, root: root).id
            let store = try CourseStore(root: root)
            // Mixed completion: one of the two learner lectures is complete.
            if screen == .library || screen == .lectureComplete { try store.setCompleted(true, courseID: id, lectureID: "welcome") }
            if screen == .courseLanding { try store.saveLastOpenedLecture(courseID: id, lectureID: "read") }
            // A second course with no progress shows a "New" tile next to the hero.
            if screen == .library { _ = try publishCopy(of: fixture, root: root, replacing: libraryTileCourse) }
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
        case .assignment, .assignmentComplete:
            // The fixture assignment is a draft lecture in a draft section. The copy publishes both.
            return try publishCopy(of: fixture, root: root, replacing: [
                ("objective: Apply the course plan\n    state: draft", "objective: Apply the course plan\n    state: published"),
                ("objective: Create a course plan\n        state: draft", "objective: Create a course plan\n        state: published"),
            ])
        case .sectionReview:
            return try publishCopy(of: fixture, root: root, replacing: reviewCourse)
        case .courseCredits:
            return try publishCopy(of: fixture, root: root, replacing: creditsCourse)
        }
    }

    /// The replacements for the `section-review` course: the quiz section is published and comes first.
    /// The third question is removed, so the review shows two questions.
    static let reviewCourse = [
        ("objective: Identify the course structure\n    state: published\n    order: 0",
         "objective: Identify the course structure\n    state: published\n    order: 2"),
        ("objective: Apply the course plan\n    state: draft", "objective: Apply the course plan\n    state: published"),
        ("""
                    - id: goal
                      prompt: What does a lecture objective tell the learner?
                      objective_tag: Check a lecture objective
                      choices:
                        - id: skill
                          text: The skill that the lecture teaches
                        - id: length
                          text: The length of the lecture
                      correct_choice_id: skill
                      explanation: An objective names the skill that the learner gets from the lecture.

        """, ""),
    ]

    /// The replacement for the `course-credits` course: a second credit with no role and no URL.
    static let creditsCourse = [
        ("    url: https://example.com/credits\n", "    url: https://example.com/credits\n  - name: Garden Photo Library\n"),
    ]

    /// The seed of the review question order in the snapshot harness.
    public static let reviewSeed: UInt64 = 17

    /// Review answers that the harness applies after the sheet opens: review question id, then choice id.
    public static func reviewAnswers(for screen: SnapshotScreen) -> [(questionID: String, choiceID: String)] {
        screen == .sectionReview ? [("check/order", "lowest")] : []
    }

    /// The replacements for the second course of the `library` screen: a new id, title and accent.
    static let libraryTileCourse = [
        ("\nid: sample-course\n", "\nid: garden-tools\n"),
        ("title: Local Course Basics", "title: Garden Tools for Agents"),
        ("accent_color: '#286644'", "accent_color: '#2F6FED'"),
    ]

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

    /// Quick-check answers that the harness applies after it opens the video lecture: check id, then choice id.
    public static func quickCheckAnswers(for screen: SnapshotScreen) -> [(checkID: Int, choiceID: String)] {
        screen == .videoQuickCheck ? [(1, "scores")] : []
    }

    /// The rubric rows that the harness checks after it opens the assignment lecture.
    public static func rubricChecks(for screen: SnapshotScreen) -> [String] {
        screen == .assignmentComplete ? ["goal", "sections", "order", "length"] : []
    }

    /// The image loads to wait for before the capture.
    /// Library: the hero and the tile images. Course screens: the outline course image, then the question image
    /// or the assignment brief.
    public static func imageLoads(for screen: SnapshotScreen) -> Int {
        switch screen {
        case .libraryEmpty, .libraryEmptyCustomFolder: 0
        case .library, .quizQuestion, .quizWrongAnswer, .sectionReview, .assignment, .assignmentComplete: 2
        default: 1
        }
    }

    /// The page to open after the course is selected. The fixture lecture has a `recommended_next` target.
    public static func destination(for screen: SnapshotScreen) -> CourseDestination? {
        switch screen {
        case .libraryEmpty, .libraryEmptyCustomFolder, .library: nil
        case .section, .sectionReview: .section(sectionID: "plan")
        case .lecture, .lectureComplete, .videoPlayer, .videoTranscript, .videoQuickCheck: .lecture(sectionID: "plan", lectureID: "welcome")
        case .article, .lectureSources: .lecture(sectionID: "plan", lectureID: "read")
        case .courseLanding, .courseLandingDarkTheme: .overview
        case .courseCredits: .credits
        case .quizQuestion, .quizWrongAnswer, .quizResults: .lecture(sectionID: "practice", lectureID: "check")
        case .interactiveResult: .lecture(sectionID: "practice", lectureID: "order-steps")
        case .assignment, .assignmentComplete: .lecture(sectionID: "practice", lectureID: "apply")
        }
    }
}
