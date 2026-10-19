import Foundation

/// Screens that `scripts/snapshot.sh` renders for QA. Add new screens here with the same name rule.
/// Course screens other than the dark-theme screen also get a dark capture with no course theme: `<screen>-unthemed-dark.png`.
public enum SnapshotScreen: String, CaseIterable, Sendable {
    case libraryEmpty = "library-empty"
    /// The empty library in a data folder that is not the default. The "Library: <path>" line shows.
    case libraryEmptyCustomFolder = "library-empty-custom-folder"
    /// The Library home with no selected course: the fixture course in progress in the "Continue" strip, then the tiles.
    case library
    case section
    case lecture
    case lectureComplete = "lecture-complete"
    case article
    /// The fixture course, which has a light theme. The learner opened a lecture, so "Resume" shows.
    case courseLanding = "course-landing"
    /// The fixture course with `theme.appearance: dark` and a light accent. No lecture is opened, so "Start Course" shows.
    case courseLandingDarkTheme = "course-landing-dark-theme"
    /// The fixture course with five outcomes and "Details" open: all outcomes, requirements, audience and description.
    case courseLandingDetails = "course-landing-details"
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
    /// The video lecture in theater mode (#85): no sidebar, and the paused player fills the page column.
    /// The page scrolls to the end, so the "Theater" pill (on) and the 960 pt transcript show.
    case videoTheater = "video-theater"
    /// The spaced review sheet of the "plan" section, after the quiz section moved first.
    /// Two questions: one unanswered, one answered correctly.
    case sectionReview = "section-review"
    /// The credits page of the fixture course with a second credit. One row has a role and a URL, one row has neither.
    case courseCredits = "course-credits"
    /// The fixture assignment with its draft section and lecture published. No rubric row is checked.
    case assignment
    /// The same assignment with every rubric row checked, so the success line shows.
    case assignmentComplete = "assignment-complete"
    /// The article lecture with three downloads, scrolled to the end: a PDF with its first-page thumbnail,
    /// a CSV, and a text file that is missing from the store, so its row shows "File unavailable".
    case lectureDownloads = "lecture-downloads"
    /// The same lecture with the PDF preview sheet of the worksheet open. The real PDFKit view shows page 1.
    case pdfPreview = "pdf-preview"
    /// The transcript search of a course with a second video lecture. The query "course" finds cues in both lectures.
    case transcriptSearch = "transcript-search"
    /// The same search with the first result selected (#90). The row shows the quiet selection fill.
    case transcriptSearchSelected = "transcript-search-selected"
    /// The same course with a query that no cue contains.
    case transcriptSearchNoResults = "transcript-search-no-results"
    /// The article lecture scrolled to the end, so its three source cards show:
    /// a full time range with a URL, a start only with a URL, and no URL.
    case lectureSources = "lecture-sources"
    /// The video lecture after its end with Auto-play on (#99): the "Up next" overlay on the player shows "Starts in 5".
    case videoUpNext = "video-up-next"
    /// The same overlay in theater mode.
    case videoUpNextTheater = "video-up-next-theater"
    /// The sidebar lengths of video lectures (#103). The open section has a done video, an article and a selected video
    /// with a long title, so the title truncates and the length stays.
    case outlineDurations = "outline-durations"
    /// The Settings window (⌘,) with "Auto-play next lecture" on (#99). The harness draws it in place of the main window.
    /// The "Local AI" section shows a valid model (#122) and the Ready status (#123).
    case settings
    /// The same Settings window when the saved model file is missing (#122). The status is No model.
    case settingsModelMissing = "settings-model-missing"
    /// The same Settings window with "Use local AI" off (#123).
    case settingsAIOff = "settings-ai-off"
    /// The same Settings window when no port is free (#123): the Error status, its reason and `Try Again`.
    case settingsAIError = "settings-ai-error"
    /// The Q&A panel of the video lecture (#128), scrolled to the end: Ready with three saved turns,
    /// one complete, one cancelled and one failed.
    case qaThread = "qa-thread"
    /// The Q&A panel when the server is Ready and the lecture has no saved turns.
    case qaEmpty = "qa-empty"
    /// The Q&A panel with a saved turn and a draft answer with "Cancel".
    case qaDraft = "qa-draft"
    /// The Q&A panel with no model.
    case qaNoModel = "qa-no-model"
    /// The Q&A panel with "Use local AI" off.
    case qaOff = "qa-off"
    /// The Q&A panel while the local model starts.
    case qaStarting = "qa-starting"
    /// The Q&A panel while the local model stops.
    case qaStopping = "qa-stopping"
    /// The Q&A panel after the local model stopped: the reason and "Retry".
    case qaError = "qa-error"
    /// The Q&A panel of a video lecture with no captions.
    case qaNoCaptions = "qa-no-captions"
    /// The Q&A panel of the article lecture, between the meta row and the article card, with saved turns.
    case qaArticle = "qa-article"
    /// The Q&A panel of the video lecture in theater mode, with saved turns.
    case qaTheater = "qa-theater"
    /// The Q&A panel of the video lecture (#129): an answer with two valid video sources and one unknown source.
    case qaCitations = "qa-citations"
    /// The Q&A panel of the article lecture (#129): an answer with two article sources, the first excerpt open.
    case qaCitationExcerpt = "qa-citation-excerpt"
    /// The Q&A panel of the video lecture (#129): a turn of an earlier version of the lecture text with stale sources.
    case qaCitationsStale = "qa-citations-stale"

    static let settingsScreens: [SnapshotScreen] = [.settings, .settingsModelMissing, .settingsAIOff, .settingsAIError]

    /// True for the Settings screens. The harness draws the Settings form in place of the main window.
    public var isSettings: Bool { Self.settingsScreens.contains(self) }

    /// The local AI status that the harness injects into the Settings form (#123). It starts no runtime. Nil for the other screens.
    public var localAIStatus: LocalAIStatus? {
        switch self {
        case .settings: .ready(version: "b11669")
        case .settingsModelMissing: .noModel
        case .settingsAIOff: .off
        case .settingsAIError: .failed(.noFreePort)
        default: nil
        }
    }

    /// True when the harness opens the Q&A panel of the lecture (#128).
    public var showsQA: Bool { rawValue.hasPrefix("qa-") }

    /// The local AI status that the harness gives to the Q&A panel (#128). Nil for the other screens.
    public var qaStatus: LocalAIStatus? {
        switch self {
        case .qaNoModel: .noModel
        case .qaOff: .off
        case .qaStarting: .starting
        case .qaStopping: .stopping
        case .qaError: .failed(.serverStopped(exitCode: 9))
        default: showsQA ? .ready(version: "b11669") : nil
        }
    }

    /// The draft that the harness shows in the Q&A panel: the question, then the answer so far. Nil for no draft.
    public var qaDraft: (question: String, text: String)? {
        self == .qaDraft ? ("What does the outline show first?", "The outline shows the **sections** of the course, in order.") : nil
    }

    /// The model row state that the harness injects into the Settings form (#122). Nil for the other screens.
    public func modelState(home: URL) -> ModelSettings.State? {
        switch self {
        case .settings, .settingsAIOff, .settingsAIError:
            let url = home.appending(path: "Library/Application Support/Skillgarden/Models/qwen2.5-3b-instruct-q4_k_m.gguf")
            return .ready(LocalModel(url: url, sizeBytes: 2_104_932_768))
        case .settingsModelMissing: return .problem(.missing("qwen2.5-3b-instruct-q4_k_m.gguf"))
        default: return nil
        }
    }

    /// True when the harness opens the player of the video lecture before the capture.
    public var opensVideoPlayer: Bool {
        [.videoPlayer, .videoTranscript, .videoQuickCheck, .videoTheater, .videoUpNext, .videoUpNextTheater].contains(self)
    }

    /// True when the harness starts theater mode on the video lecture (#85).
    public var startsTheater: Bool { [.videoTheater, .videoUpNextTheater, .qaTheater].contains(self) }

    /// True when the harness shows the "Up next" overlay at 5 after the load. The countdown does not run (#99).
    public var showsUpNext: Bool { self == .videoUpNext || self == .videoUpNextTheater }

    /// The paused player opens at this time instead of the saved position. 3 s is in the second fixture cue (2–4 s).
    public var videoStartSeconds: Double? { self == .videoTranscript ? 3 : nil }

    /// True when the harness scrolls the lecture page, or the course landing with "Details" open, to the end.
    public var scrollsLectureToEnd: Bool {
        [.courseLandingDetails, .videoTranscript, .videoQuickCheck, .videoTheater, .lectureSources, .lectureDownloads, .pdfPreview]
            .contains(self) || (showsQA && self != .qaArticle && self != .qaCitationExcerpt)
    }

    /// True when the harness opens the first article excerpt of the last Q&A answer (#129).
    public var opensCitationExcerpt: Bool { self == .qaCitationExcerpt }

    /// True when the harness opens the quick-check card of the video lecture.
    public var showsQuickChecks: Bool { self == .videoQuickCheck }

    /// True when the harness fails if the capture has black video pixels in the title bar and the toolbar (#55).
    public var checksTitlebarForVideo: Bool { opensVideoPlayer }

    /// True when the harness fails if a toolbar material view covers the column colors (#101).
    /// The Settings screens draw no main-window toolbar, so the harness does not check it.
    public var checksToolbarMaterial: Bool { !isSettings }

    /// True when the harness opens "Details" on the course landing.
    public var showsLandingDetails: Bool { self == .courseLandingDetails }

    /// True when the harness draws the review sheet in the window. A real sheet is a separate window, so the capture misses it.
    public var showsReviewInline: Bool { self == .sectionReview }

    /// True when the harness draws the PDF preview sheet of the first PDF download in the window, like the review sheet.
    /// The harness fails if the sheet has no PDFKit view with a page.
    public var showsPDFPreviewInline: Bool { self == .pdfPreview }

    /// True when the harness selects the seeded course. The Library screens show the Library home, so they select none.
    public var selectsCourse: Bool { !([.library, .libraryEmpty, .libraryEmptyCustomFolder] + Self.settingsScreens).contains(self) }

    /// True when the harness also writes `<screen>-unthemed-dark.png`: the course screen with no course theme, in dark (#82).
    /// The `-dark` capture uses the Dark setting, which wins over the light fixture theme (#93). The dark-theme screen gets no unthemed capture.
    public var hasUnthemedCapture: Bool { selectsCourse && self != .courseLandingDarkTheme }

    /// True when the harness selects the first transcript search result (#90). The selection does not open the result.
    public var selectsFirstTranscriptHit: Bool { self == .transcriptSearchSelected }

    /// The fixed library path that the harness shows. The real temporary root changes on each run.
    public var customRootPath: String? { self == .libraryEmptyCustomFolder ? "/Users/agent/skillgarden-library" : nil }

    /// The text that the harness types into the transcript search field. Nil leaves the field empty.
    public var transcriptQuery: String? {
        switch self {
        case .transcriptSearch, .transcriptSearchSelected: "course"
        case .transcriptSearchNoResults: "zebra"
        default: nil
        }
    }
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
        /// True when the window uses no course theme, so the system color scheme and the system accent show.
        public let ignoresCourseTheme: Bool
    }

    /// One output per screen and appearance, in a fixed order: `<out-dir>/<screen>-<light|dark>.png`.
    /// Then `<out-dir>/<screen>-unthemed-dark.png` for each screen with `hasUnthemedCapture`.
    /// `screens` limits the outputs to these screens. The order stays the same.
    public static func outputs(outDirectory: URL, screens: Set<SnapshotScreen>? = nil) -> [Output] {
        SnapshotScreen.allCases.filter { screens?.contains($0) ?? true }.flatMap { screen in
            let themed = SnapshotAppearance.allCases.map { appearance in
                Output(screen: screen, appearance: appearance,
                       url: outDirectory.appending(path: "\(screen.rawValue)-\(appearance.rawValue).png"), ignoresCourseTheme: false)
            }
            guard screen.hasUnthemedCapture else { return themed }
            return themed + [Output(screen: screen, appearance: .dark,
                                    url: outDirectory.appending(path: "\(screen.rawValue)-unthemed-dark.png"), ignoresCourseTheme: true)]
        }
    }

    /// The accent of the dark-theme fixture copy. It has more than 3:1 contrast on the dark background.
    public static let darkThemeAccent = "#7FD3A0"

    /// Writes the store that a screen needs into `root` and returns the course to select, if any.
    public static func seedStore(for screen: SnapshotScreen, root: URL, fixture: URL) throws -> String? {
        switch screen {
        case .libraryEmpty, .libraryEmptyCustomFolder, .settings, .settingsModelMissing, .settingsAIOff, .settingsAIError:
            _ = try CourseStore(root: root)
            return nil
        case .library, .section, .lecture, .lectureComplete, .article, .courseLanding, .videoPlayer, .videoTranscript,
             .videoQuickCheck, .videoTheater, .lectureSources, .videoUpNext, .videoUpNextTheater, .qaThread, .qaEmpty, .qaDraft,
             .qaNoModel, .qaOff, .qaStarting, .qaStopping, .qaError, .qaArticle, .qaTheater, .qaCitations, .qaCitationExcerpt,
             .qaCitationsStale:
            // A real publish installs the media snapshot and image metadata, so the course and header images load.
            let id = try CoursePublisher.publish(courseFolder: fixture, root: root).id
            let store = try CourseStore(root: root)
            // Mixed completion: one of the two learner lectures is complete.
            if screen == .library || screen == .lectureComplete { try store.setCompleted(true, courseID: id, lectureID: "welcome") }
            if screen == .courseLanding { try store.saveLastOpenedLecture(courseID: id, lectureID: "read") }
            // A second course with no progress shows a "New" tile next to the fixture course tile.
            if screen == .library { _ = try publishCopy(of: fixture, root: root, replacing: libraryTileCourse) }
            return id
        case .courseLandingDarkTheme:
            return try publishCopy(of: fixture, root: root, replacing: [
                ("appearance: light", "appearance: dark"),
                ("accent_color: '#286644'", "accent_color: '\(darkThemeAccent)'"),
            ])
        case .courseLandingDetails:
            return try publishCopy(of: fixture, root: root, replacing: detailsCourse)
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
        case .lectureDownloads, .pdfPreview:
            let id = try publishCopy(of: fixture, root: root, replacing: downloadsCourse)
            // A store file that disappears after publish shows the unavailable row.
            if let snapshot = try CoursePublisher.assetDirectory(courseID: id, root: root) {
                try FileManager.default.removeItem(at: snapshot.appending(path: "content/checklist.txt"))
            }
            return id
        case .transcriptSearch, .transcriptSearchSelected, .transcriptSearchNoResults:
            return try publishCopy(of: fixture, root: root, replacing: searchCourse)
        case .qaNoCaptions:
            return try publishCopy(of: fixture, root: root, replacing: [("          captions:\n            path: content/welcome.vtt\n", "")])
        case .outlineDurations:
            let id = try publishCopy(of: fixture, root: root, replacing: outlineDurationsCourse)
            try CourseStore(root: root).setCompleted(true, courseID: id, lectureID: "welcome")
            return id
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

    /// The replacement for the `course-landing-details` course: five outcomes, so the page shows three
    /// and "Details" shows all five.
    static let detailsCourse = [
        ("  - Check your work\n", "  - Check your work\n  - Order the sections\n  - Write a lecture objective\n  - Publish the course\n"),
    ]

    /// The replacement for the `course-credits` course: a second credit with no role and no URL.
    static let creditsCourse = [
        ("    url: https://example.com/credits\n", "    url: https://example.com/credits\n  - name: Garden Photo Library\n"),
    ]

    /// The replacement for the `lecture-downloads` course: three downloads on the article lecture.
    static let downloadsCourse = [
        ("              alt: The two sections of the course plan\n", """
                      alt: The two sections of the course plan
                downloads:
                  - path: content/worksheet.pdf
                    title: Course plan worksheet
                    description: Fill in one row for each section of your course.
                  - path: content/sections.csv
                    title: Section list
                  - path: content/checklist.txt
                    title: Plan checklist

        """),
    ]

    /// The replacement for the transcript search course: a second video lecture after "read" with the welcome captions.
    /// The stable key line of the "practice" section is the anchor, so the lecture goes in at the end of "plan".
    static let searchCourse = [
        ("\n  - id: practice\n", """

              - id: recap
                title: Recap the plan
                type: video
                objective: Review the course plan
                state: published
                order: 2
                video:
                  path: content/welcome.mp4
                  duration_seconds: 4
                  captions:
                    path: content/welcome.vtt
          - id: practice

        """),
    ]

    /// The replacement for the `outline-durations` course: a second video lecture with a long title after "read".
    /// Publish checks `duration_seconds` against the file, so the lecture uses the 4 s welcome video.
    static let outlineDurationsCourse = [
        ("\n  - id: practice\n", """

              - id: recap
                title: Recap the plan and check each section before you publish the course
                type: video
                objective: Review the course plan
                state: published
                order: 2
                video:
                  path: content/welcome.mp4
                  duration_seconds: 4
          - id: practice

        """),
    ]

    /// The saved Q&A turns of the selected lecture for a screen (#128): the question, the answer and the outcome.
    public static func qaTurns(for screen: SnapshotScreen) -> [(question: String, answer: String, outcome: AnswerOutcome)] {
        switch screen {
        case .qaThread, .qaArticle, .qaTheater:
            [("What is the goal of this course?", "You plan a course step by step [t1].", .finished),
             ("Which tools do I need?", "You need", .canceled),
             ("How long is the course?", "", .httpError(status: 500))]
        case .qaDraft:
            [("What is the goal of this course?", "You plan a course step by step [t1].", .finished)]
        case .qaCitations:
            // Inline Markdown (#158): italic, a marker in bold and code.
            [("How does the course start?", "It starts with a *welcome* [t0]. Then you plan the course **step by step [t1]**. "
                + "The `guide` has more help [L9].", .finished)]
        case .qaCitationExcerpt:
            [("What do I do first?", "Write the goal of the course first [a4]. Keep each lecture short [a6].", .finished)]
        case .qaCitationsStale:
            [("How does the course start?", "It starts with a welcome [t0], then a plan [t1].", .finished)]
        default: []
        }
    }

    /// True when the harness saves the Q&A turns of the screen with an earlier revision of the lecture text (#129).
    public static func qaTurnsAreStale(for screen: SnapshotScreen) -> Bool { screen == .qaCitationsStale }

    /// Saves the Q&A turns of the screen for the selected lecture of `library`, after the harness selects it.
    @MainActor
    public static func seedQATurns(for screen: SnapshotScreen, library: LibraryModel) async throws {
        let turns = qaTurns(for: screen)
        guard !turns.isEmpty, let lectureID = library.selectedLecture?.id,
              case .ready(let context) = await library.lectureContext(forLecture: lectureID) else { return }
        // Other text gives another source revision, so the turns are of an earlier version of the lecture.
        let asked = qaTurnsAreStale(for: screen)
            ? LectureContext(courseTitle: context.courseTitle, lectureTitle: context.lectureTitle,
                             passages: context.passages.map { LecturePassage(id: $0.id, label: $0.label, text: $0.text + " Old.") })
            : context
        for turn in turns {
            let saved = try await library.startQATurn(question: turn.question, context: asked, lectureID: lectureID)
            library.finishQATurn(saved, outcome: turn.outcome, text: turn.answer)
        }
        await library.waitForWrites()
    }

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
    /// Library: the "Continue" strip image and one tile image per course. Course screens: the outline course image,
    /// then the question image or the assignment brief or the PDF thumbnail.
    public static func imageLoads(for screen: SnapshotScreen) -> Int {
        switch screen {
        case .libraryEmpty, .libraryEmptyCustomFolder, .settings, .settingsModelMissing, .settingsAIOff, .settingsAIError: 0
        case .library: 3
        case .quizQuestion, .quizWrongAnswer, .sectionReview, .assignment, .assignmentComplete, .lectureDownloads, .pdfPreview: 2
        default: 1
        }
    }

    /// The page to open after the course is selected.
    public static func destination(for screen: SnapshotScreen) -> CourseDestination? {
        switch screen {
        case .libraryEmpty, .libraryEmptyCustomFolder, .library, .settings, .settingsModelMissing, .settingsAIOff,
             .settingsAIError: nil
        case .section, .sectionReview: .section(sectionID: "plan")
        case .lecture, .lectureComplete, .videoPlayer, .videoTranscript, .videoQuickCheck, .videoTheater, .videoUpNext,
             .videoUpNextTheater, .qaThread, .qaEmpty, .qaDraft, .qaNoModel, .qaOff, .qaStarting, .qaStopping, .qaError, .qaNoCaptions,
             .qaTheater, .qaCitations, .qaCitationsStale:
            .lecture(sectionID: "plan", lectureID: "welcome")
        case .article, .lectureSources, .lectureDownloads, .pdfPreview, .qaArticle, .qaCitationExcerpt:
            .lecture(sectionID: "plan", lectureID: "read")
        case .courseLanding, .courseLandingDarkTheme, .courseLandingDetails, .transcriptSearch, .transcriptSearchSelected,
             .transcriptSearchNoResults: .overview
        case .courseCredits: .credits
        case .quizQuestion, .quizWrongAnswer, .quizResults: .lecture(sectionID: "practice", lectureID: "check")
        case .interactiveResult: .lecture(sectionID: "practice", lectureID: "order-steps")
        case .assignment, .assignmentComplete: .lecture(sectionID: "practice", lectureID: "apply")
        case .outlineDurations: .lecture(sectionID: "plan", lectureID: "recap")
        }
    }
}
