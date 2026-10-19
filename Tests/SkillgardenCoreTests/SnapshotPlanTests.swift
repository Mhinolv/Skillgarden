import Foundation
import Testing
@testable import SkillgardenCore

private let repo = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let fixture = repo.appending(path: "Tests/Fixtures/sample-course")

private func temporaryFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appending(path: "SnapshotTests-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

@Test func snapshotOutputsAreDeterministicForAnOutDirectory() {
    let out = URL(fileURLWithPath: "/tmp/snapshots")
    let outputs = SnapshotPlan.outputs(outDirectory: out)
    #expect(outputs.map(\.url.lastPathComponent) == [
        "library-empty-light.png", "library-empty-dark.png",
        "library-empty-custom-folder-light.png", "library-empty-custom-folder-dark.png", "library-light.png", "library-dark.png",
        "section-light.png", "section-dark.png", "section-unthemed-dark.png",
        "lecture-light.png", "lecture-dark.png", "lecture-unthemed-dark.png",
        "lecture-complete-light.png", "lecture-complete-dark.png", "lecture-complete-unthemed-dark.png",
        "article-light.png", "article-dark.png", "article-unthemed-dark.png",
        "course-landing-light.png", "course-landing-dark.png", "course-landing-unthemed-dark.png",
        "course-landing-dark-theme-light.png", "course-landing-dark-theme-dark.png",
        "course-landing-details-light.png", "course-landing-details-dark.png", "course-landing-details-unthemed-dark.png",
        "quiz-question-light.png", "quiz-question-dark.png", "quiz-question-unthemed-dark.png",
        "quiz-wrong-answer-light.png", "quiz-wrong-answer-dark.png", "quiz-wrong-answer-unthemed-dark.png",
        "quiz-results-light.png", "quiz-results-dark.png", "quiz-results-unthemed-dark.png",
        "interactive-result-light.png", "interactive-result-dark.png", "interactive-result-unthemed-dark.png",
        "video-player-light.png", "video-player-dark.png", "video-player-unthemed-dark.png",
        "video-transcript-light.png", "video-transcript-dark.png", "video-transcript-unthemed-dark.png",
        "video-quick-check-light.png", "video-quick-check-dark.png", "video-quick-check-unthemed-dark.png",
        "video-theater-light.png", "video-theater-dark.png", "video-theater-unthemed-dark.png",
        "section-review-light.png", "section-review-dark.png", "section-review-unthemed-dark.png",
        "course-credits-light.png", "course-credits-dark.png", "course-credits-unthemed-dark.png",
        "assignment-light.png", "assignment-dark.png", "assignment-unthemed-dark.png",
        "assignment-complete-light.png", "assignment-complete-dark.png", "assignment-complete-unthemed-dark.png",
        "lecture-downloads-light.png", "lecture-downloads-dark.png", "lecture-downloads-unthemed-dark.png",
        "pdf-preview-light.png", "pdf-preview-dark.png", "pdf-preview-unthemed-dark.png",
        "transcript-search-light.png", "transcript-search-dark.png", "transcript-search-unthemed-dark.png",
        "transcript-search-selected-light.png", "transcript-search-selected-dark.png",
        "transcript-search-selected-unthemed-dark.png",
        "transcript-search-no-results-light.png", "transcript-search-no-results-dark.png",
        "transcript-search-no-results-unthemed-dark.png",
        "lecture-sources-light.png", "lecture-sources-dark.png", "lecture-sources-unthemed-dark.png",
        "video-up-next-light.png", "video-up-next-dark.png", "video-up-next-unthemed-dark.png",
        "video-up-next-theater-light.png", "video-up-next-theater-dark.png", "video-up-next-theater-unthemed-dark.png",
        "outline-durations-light.png", "outline-durations-dark.png", "outline-durations-unthemed-dark.png",
        "settings-light.png", "settings-dark.png",
        "settings-model-missing-light.png", "settings-model-missing-dark.png",
        "settings-ai-off-light.png", "settings-ai-off-dark.png",
        "settings-ai-error-light.png", "settings-ai-error-dark.png",
        "qa-thread-light.png", "qa-thread-dark.png", "qa-thread-unthemed-dark.png",
        "qa-empty-light.png", "qa-empty-dark.png", "qa-empty-unthemed-dark.png",
        "qa-draft-light.png", "qa-draft-dark.png", "qa-draft-unthemed-dark.png",
        "qa-no-model-light.png", "qa-no-model-dark.png", "qa-no-model-unthemed-dark.png",
        "qa-off-light.png", "qa-off-dark.png", "qa-off-unthemed-dark.png",
        "qa-starting-light.png", "qa-starting-dark.png", "qa-starting-unthemed-dark.png",
        "qa-stopping-light.png", "qa-stopping-dark.png", "qa-stopping-unthemed-dark.png",
        "qa-error-light.png", "qa-error-dark.png", "qa-error-unthemed-dark.png",
        "qa-no-captions-light.png", "qa-no-captions-dark.png", "qa-no-captions-unthemed-dark.png",
        "qa-article-light.png", "qa-article-dark.png", "qa-article-unthemed-dark.png",
        "qa-theater-light.png", "qa-theater-dark.png", "qa-theater-unthemed-dark.png",
    ])
    // #82: every course screen except the dark-theme screen gets one dark capture with no course theme.
    #expect(SnapshotScreen.allCases.filter { $0.selectsCourse && !$0.hasUnthemedCapture } == [.courseLandingDarkTheme])
    let unthemed = outputs.filter(\.ignoresCourseTheme)
    #expect(unthemed.count == 38)
    #expect(unthemed.allSatisfy { $0.appearance == .dark && $0.screen.hasUnthemedCapture })
    #expect(unthemed.allSatisfy { $0.url.lastPathComponent == "\($0.screen.rawValue)-unthemed-dark.png" })
    #expect(outputs.filter { !$0.ignoresCourseTheme }.map(\.url.lastPathComponent) == SnapshotScreen.allCases.flatMap { screen in
        SnapshotAppearance.allCases.map { "\(screen.rawValue)-\($0.rawValue).png" }
    })
    #expect(SnapshotScreen.allCases.filter { $0.transcriptQuery != nil }
        == [.transcriptSearch, .transcriptSearchSelected, .transcriptSearchNoResults])
    #expect(SnapshotScreen.allCases.filter(\.selectsFirstTranscriptHit) == [.transcriptSearchSelected])
    #expect(SnapshotScreen.allCases.filter(\.showsReviewInline) == [.sectionReview])
    #expect(SnapshotScreen.allCases.filter(\.showsPDFPreviewInline) == [.pdfPreview])
    #expect(SnapshotScreen.allCases.filter(\.showsLandingDetails) == [.courseLandingDetails])
    #expect(SnapshotScreen.allCases.filter(\.opensVideoPlayer) == [.videoPlayer, .videoTranscript, .videoQuickCheck, .videoTheater,
                                                                   .videoUpNext, .videoUpNextTheater])
    #expect(SnapshotScreen.allCases.filter(\.showsUpNext) == [.videoUpNext, .videoUpNextTheater])
    #expect(SnapshotScreen.allCases.filter { $0.videoStartSeconds != nil } == [.videoTranscript])
    #expect(SnapshotScreen.allCases.filter(\.scrollsLectureToEnd) == [
        .courseLandingDetails, .videoTranscript, .videoQuickCheck, .videoTheater, .lectureDownloads, .pdfPreview, .lectureSources,
        .qaThread, .qaEmpty, .qaDraft, .qaNoModel, .qaOff, .qaStarting, .qaStopping, .qaError, .qaNoCaptions, .qaTheater,
    ])
    // #128: the Q&A screens open the panel with an injected status. Only the draft screen shows a draft.
    #expect(SnapshotScreen.allCases.filter(\.showsQA) == [.qaThread, .qaEmpty, .qaDraft, .qaNoModel, .qaOff, .qaStarting,
                                                          .qaStopping, .qaError, .qaNoCaptions, .qaArticle, .qaTheater])
    #expect(SnapshotScreen.allCases.filter { $0.qaStatus != nil } == SnapshotScreen.allCases.filter(\.showsQA))
    #expect(SnapshotScreen.allCases.compactMap(\.qaStatus).map { LectureQAState(status: $0, content: .ready) }
        == [.ready, .ready, .ready, .noModel, .off, .starting, .stopping, .error(reason: "The server stopped. Exit code 9."),
            .ready, .ready, .ready])
    #expect(SnapshotScreen.allCases.filter { $0.qaDraft != nil } == [.qaDraft])
    #expect(SnapshotScreen.allCases.filter(\.startsTheater) == [.videoTheater, .videoUpNextTheater, .qaTheater])
    #expect(SnapshotScreen.allCases.filter(\.showsQuickChecks) == [.videoQuickCheck])
    #expect(SnapshotScreen.allCases.filter(\.checksTitlebarForVideo) == [.videoPlayer, .videoTranscript, .videoQuickCheck, .videoTheater,
                                                                         .videoUpNext, .videoUpNextTheater])
    #expect(SnapshotPlan.outputs(outDirectory: out, screens: [.videoTranscript, .library]).map(\.url.lastPathComponent) == [
        "library-light.png", "library-dark.png",
        "video-transcript-light.png", "video-transcript-dark.png", "video-transcript-unthemed-dark.png",
    ])
    #expect(SnapshotPlan.outputs(outDirectory: out, screens: []).isEmpty)
    #expect(SnapshotPlan.outputs(outDirectory: out, screens: nil) == outputs)
    #expect(SnapshotScreen.allCases.filter { !$0.selectsCourse } == [.libraryEmpty, .libraryEmptyCustomFolder, .library, .settings,
                                                                    .settingsModelMissing, .settingsAIOff, .settingsAIError])
    #expect(SnapshotScreen.allCases.filter { $0.customRootPath != nil } == [.libraryEmptyCustomFolder])
    #expect(outputs.allSatisfy { $0.url.deletingLastPathComponent().path == out.path })
    #expect(outputs == SnapshotPlan.outputs(outDirectory: out))
    #expect(Set(outputs.map(\.url)).count == SnapshotScreen.allCases.count * SnapshotAppearance.allCases.count + unthemed.count)
    #expect(SnapshotPlan.width == 1280 && SnapshotPlan.height == 800 && SnapshotPlan.scale == 2)
}

@MainActor @Test func snapshotSeedsEachScreenFromTheFixture() async throws {
    for screen in SnapshotScreen.allCases {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let courseID = try SnapshotPlan.seedStore(for: screen, root: root, fixture: fixture)
        let library = LibraryModel(root: root)
        await library.reload()
        #expect(library.errorMessage == nil)
        switch screen {
        case .libraryEmpty, .libraryEmptyCustomFolder, .settings, .settingsModelMissing, .settingsAIOff, .settingsAIError:
            #expect(courseID == nil)
            #expect(!screen.selectsCourse)
            #expect(SnapshotPlan.imageLoads(for: screen) == 0)
            #expect(library.courses.isEmpty)
        case .library:
            #expect(courseID == "sample-course")
            // The Library home: no selected course, the fixture course is in the "Continue" strip and a second course is new.
            // Three images: the strip and one tile per course.
            #expect(!screen.selectsCourse)
            #expect(SnapshotPlan.imageLoads(for: screen) == 3)
            #expect(library.courses.map(\.id) == ["garden-tools", "sample-course"])
            #expect(library.continueCourse?.id == "sample-course")
            #expect(library.courses.map { library.summary(of: $0).status } == [.new, .inProgress])
            #expect(library.accent(ofCourse: "garden-tools") == ThemeColor(hex: "#2F6FED"))
            #expect(library.libraryMeta == "2 courses · 1 in progress")
            library.selectCourse(courseID)
            library.selectDestination(nil)
            #expect(library.selectedCourse?.title == "Local Course Basics")
            #expect(library.selectedCourse?.sections.map(\.id) == ["plan"])
            #expect(library.selectedCourse?.sections.first?.lectures.map(\.id) == ["welcome", "read"])
            #expect(library.destination == nil)
            let section = try #require(library.selectedCourse?.learnerSections.first)
            #expect(library.sectionProgress(section).percent == 50)
        case .section:
            #expect(courseID == "sample-course")
            library.selectCourse(courseID)
            library.selectDestination(SnapshotPlan.destination(for: screen))
            #expect(library.destination == .section(sectionID: "plan"))
            #expect(library.selectedSection?.objective == "Identify the course structure")
            #expect(library.headerImage(forSection: "plan")?.alt == "Two course sections")
        case .lecture:
            #expect(courseID == "sample-course")
            library.selectCourse(courseID)
            library.selectDestination(SnapshotPlan.destination(for: screen))
            #expect(library.selectedLecture?.id == "welcome")
            #expect(library.nextLecture == .lecture(sectionID: "plan", lectureID: "read"))
            #expect(!library.isSelectedLectureComplete)
            // The video lecture shows its poster.
            #expect(library.selectedLecture?.type == .video)
            #expect(library.video(forLecture: "welcome")?.posterAlt == "The first frame of the welcome video")
        case .lectureComplete:
            library.selectCourse(courseID)
            library.selectDestination(SnapshotPlan.destination(for: screen))
            #expect(library.selectedLecture?.id == "welcome")
            #expect(library.isSelectedLectureComplete)
        case .article:
            library.selectCourse(courseID)
            library.selectDestination(SnapshotPlan.destination(for: screen))
            #expect(library.selectedLecture?.type == .article)
            #expect(library.article(forLecture: "read")?.path == "content/plan.md")
        case .lectureSources:
            #expect(courseID == "sample-course")
            library.selectCourse(courseID)
            library.selectDestination(SnapshotPlan.destination(for: screen))
            #expect(library.selectedLecture?.id == "read")
            // Three cards: a full range with a URL, a start only with a URL, and no URL.
            let sources = library.selectedSources
            #expect(sources.map(\.rangeText) == ["4:10 – 9:32", "From 1:02:05", nil])
            #expect(sources.map { $0.url != nil } == [true, true, false])
        case .courseLanding, .courseLandingDarkTheme:
            #expect(courseID == "sample-course")
            library.selectCourse(courseID)
            library.selectDestination(SnapshotPlan.destination(for: screen))
            #expect(library.destination == .overview)
            #expect(library.selectedLanding?.learningOutcomes == ["Plan a course", "Check your work"])
            let theme = try #require(library.selectedLanding?.theme)
            if screen == .courseLanding {
                #expect(theme.appearance == .light)
                #expect(theme.accent == ThemeColor(hex: "#286644"))
                #expect(library.resumeLecture?.title == "Read the plan")
            } else {
                #expect(theme.appearance == .dark)
                #expect(theme.accent == ThemeColor(hex: SnapshotPlan.darkThemeAccent))
                #expect(library.resumeLecture == nil)
            }
        case .courseLandingDetails:
            #expect(courseID == "sample-course")
            library.selectCourse(courseID)
            library.selectDestination(SnapshotPlan.destination(for: screen))
            #expect(library.destination == .overview)
            let landing = try #require(library.selectedLanding)
            #expect(landing.summaryOutcomes == ["Plan a course", "Check your work", "Order the sections"])
            #expect(landing.detailOutcomes.count == 5)
            #expect(landing.requirements == ["A Mac"])
            #expect(landing.hasDetails)
        case .quizQuestion, .quizWrongAnswer, .quizResults:
            #expect(courseID == "sample-course")
            library.selectCourse(courseID)
            library.selectDestination(SnapshotPlan.destination(for: screen))
            #expect(library.selectedLecture?.id == "check")
            for action in SnapshotPlan.quizActions(for: screen) { library.performQuizAction(action) }
            let attempt = try #require(library.selectedQuizAttempt)
            switch screen {
            case .quizQuestion:
                // The sample quiz renders an image question from the fixture.
                let image = try #require(attempt.question?.image)
                #expect(image.alt == "Two course sections")
                #expect(FileManager.default.fileExists(atPath: image.url.path))
                #expect(attempt.selection == nil)
                #expect(SnapshotPlan.imageLoads(for: screen) == 2)
            case .quizWrongAnswer:
                #expect(attempt.question?.id == "outline")
                #expect(attempt.isAnswerCorrect == false)
            default:
                #expect(attempt.showsResults)
                #expect(attempt.result.weakSkills == ["Read a course outline", "Order course sections"])
                await library.waitForWrites()
            }
        case .videoPlayer, .videoTheater, .videoUpNext, .videoUpNextTheater:
            #expect(courseID == "sample-course")
            library.selectCourse(courseID)
            library.selectDestination(SnapshotPlan.destination(for: screen))
            #expect(library.selectedLecture?.type == .video)
            // The "Up next" overlay names the article after the welcome video (#99).
            #expect(library.nextLectureTitle == "Read the plan")
            let video = try #require(library.video(forLecture: "welcome"))
            #expect(FileManager.default.fileExists(atPath: video.url.path))
            #expect(video.captionsURL != nil)
        case .videoTranscript:
            #expect(courseID == "sample-course")
            library.selectCourse(courseID)
            library.selectDestination(SnapshotPlan.destination(for: screen))
            let video = try #require(library.video(forLecture: "welcome"))
            // The start time makes the second of the two fixture lines active.
            let transcript = Transcript(captions: try #require(try video.loadCaptions()))
            #expect(transcript.lines.count == 2)
            let start = try #require(screen.videoStartSeconds)
            #expect(transcript.activeLine(at: start) == 1)
            #expect(SnapshotPlan.imageLoads(for: screen) == 1)
        case .videoQuickCheck:
            #expect(courseID == "sample-course")
            library.selectCourse(courseID)
            library.selectDestination(SnapshotPlan.destination(for: screen))
            for item in SnapshotPlan.quickCheckAnswers(for: screen) { library.answerQuickCheck(item.checkID, choiceID: item.choiceID) }
            let session = try #require(library.selectedQuickChecks)
            #expect(session.checks.count == 2)
            #expect(session.isCorrect(0) == nil)
            #expect(session.isCorrect(1) == false)
            #expect(session.checks[1].explanation != nil)
        case .interactiveResult:
            #expect(courseID == "interactive-course")
            library.selectCourse(courseID)
            library.selectDestination(SnapshotPlan.destination(for: screen))
            #expect(library.selectedLecture?.type == .interactive)
            let module = try #require(library.selectedInteractive)
            #expect(module.entryExists())
            #expect(library.selectedInteractiveResult == InteractiveResult(score: 75, weakSkills: ["Order the steps of a course plan"]))
        case .assignment, .assignmentComplete:
            #expect(courseID == "sample-course")
            library.selectCourse(courseID)
            library.selectDestination(SnapshotPlan.destination(for: screen))
            #expect(library.selectedLecture?.type == .assignment)
            let brief = try #require(library.selectedAssignment?.brief)
            #expect(FileManager.default.fileExists(atPath: brief.url.path))
            #expect(SnapshotPlan.imageLoads(for: screen) == 2)
            for id in SnapshotPlan.rubricChecks(for: screen) { library.toggleRubricCriterion(id) }
            let checklist = try #require(library.selectedRubricChecklist)
            #expect(checklist.rubric.count == 4)
            if screen == .assignment {
                #expect(checklist.summary == "0 of 4 criteria met")
            } else {
                #expect(checklist.allMet)
            }
        case .sectionReview:
            #expect(courseID == "sample-course")
            #expect(SnapshotPlan.imageLoads(for: screen) == 2)
            library.selectCourse(courseID)
            library.selectDestination(SnapshotPlan.destination(for: screen))
            for item in SnapshotPlan.reviewAnswers(for: screen) { library.answerReview(questionID: item.questionID, choiceID: item.choiceID) }
            // Two questions: the image question is unanswered, the other one is answered correctly.
            let review = try #require(library.sectionReview)
            #expect(Set(review.questions.map(\.id)) == ["check/outline", "check/order"])
            #expect(review.isCorrect("check/order") == true)
            #expect(review.isCorrect("check/outline") == nil)
            #expect(review.questions.first { $0.id == "check/outline" }?.question.image != nil)
        case .courseCredits:
            #expect(courseID == "sample-course")
            #expect(SnapshotPlan.imageLoads(for: screen) == 1)
            library.selectCourse(courseID)
            library.selectDestination(SnapshotPlan.destination(for: screen))
            #expect(library.destination == .credits)
            // One row with a role and a URL, one row with neither.
            #expect(library.selectedCredits.map(\.name) == ["Skillgarden Team", "Garden Photo Library"])
            #expect(library.selectedCredits.map { $0.role != nil } == [true, false])
            #expect(library.selectedCredits.map { $0.url != nil } == [true, false])
        case .lectureDownloads, .pdfPreview:
            #expect(courseID == "sample-course")
            #expect(SnapshotPlan.imageLoads(for: screen) == 2)
            library.selectCourse(courseID)
            library.selectDestination(SnapshotPlan.destination(for: screen))
            #expect(library.selectedLecture?.type == .article)
            // A PDF with a first page, a CSV, and a text file that the seed removed from the store.
            let downloads = library.downloads(forLecture: "read")
            #expect(downloads.map(\.title) == ["Course plan worksheet", "Section list", "Plan checklist"])
            #expect(downloads.map(\.kind) == [.pdf, .csv, .other("txt")])
            #expect(downloads.map(\.isAvailable) == [true, true, false])
            #expect(PDFPreview.firstPage(of: downloads[0].url, width: 64, height: 83) != nil)
            // The preview sheet opens the first available PDF: the worksheet, with a page count.
            #expect(downloads.first { $0.kind == .pdf && $0.isAvailable }?.title == "Course plan worksheet")
            #expect(PDFPreview.pageCount(of: downloads[0].url).map { $0 > 0 } == true)
            #expect(library.downloads(forLecture: "welcome").isEmpty)
            // The source cards of the fixture lecture stay next to the downloads.
            #expect(library.selectedSources.count == 3)
        case .transcriptSearch, .transcriptSearchSelected, .transcriptSearchNoResults:
            #expect(courseID == "sample-course")
            // The results replace the outline, so only the course page image loads.
            #expect(SnapshotPlan.imageLoads(for: screen) == 1)
            library.selectCourse(courseID)
            library.selectDestination(SnapshotPlan.destination(for: screen))
            library.transcriptQuery = try #require(screen.transcriptQuery)
            library.searchTranscripts()
            let results = try #require(library.transcriptResults)
            #expect(results.hasTranscripts)
            if screen != .transcriptSearchNoResults {
                #expect(results.groups.map(\.lectureID) == ["welcome", "recap"])
                #expect(results.summary == "4 results in 2 lectures")
            } else {
                #expect(results.groups.isEmpty)
            }
        case .qaThread, .qaEmpty, .qaDraft, .qaNoModel, .qaOff, .qaStarting, .qaStopping, .qaError, .qaNoCaptions, .qaArticle,
             .qaTheater:
            #expect(courseID == "sample-course")
            #expect(SnapshotPlan.imageLoads(for: screen) == 1)
            library.selectCourse(courseID)
            library.selectDestination(SnapshotPlan.destination(for: screen))
            #expect(library.selectedLecture?.type == (screen == .qaArticle ? .article : .video))
            let lectureID = try #require(library.selectedLecture?.id)
            let context = await library.lectureContext(forLecture: lectureID)
            if screen == .qaNoCaptions {
                #expect(library.video(forLecture: lectureID)?.captionsURL == nil)
                #expect(context == .noText)
            } else {
                guard case .ready = context else { Issue.record("\(screen) has no lecture text"); break }
            }
            try await SnapshotPlan.seedQATurns(for: screen, library: library)
            let turns = try #require(try await library.lectureConversation(forLecture: lectureID)).currentTurns
            #expect(turns.map(\.question) == SnapshotPlan.qaTurns(for: screen).map(\.question))
            switch screen {
            case .qaThread, .qaArticle, .qaTheater:
                #expect(turns.map(\.status) == [.complete, .cancelled, .failed(reason: "Local AI returned an error (500). Try again.")])
                #expect(turns.map(\.answer) == ["You plan a course step by step [t1].", "You need", ""])
            case .qaDraft:
                #expect(turns.map(\.status) == [.complete])
            default:
                #expect(turns.isEmpty)
            }
        case .outlineDurations:
            #expect(courseID == "sample-course")
            library.selectCourse(courseID)
            library.selectDestination(SnapshotPlan.destination(for: screen))
            #expect(library.selectedLecture?.id == "recap")
            #expect(library.isComplete("welcome"))
            // The open section: a done video, an article and the selected video with a long title.
            let lectures = try #require(library.selectedCourse?.learnerSections.first?.lectures)
            #expect(lectures.map(\.id) == ["welcome", "read", "recap"])
            #expect(lectures.map { LectureVideo.outlineDurationLabel(type: $0.type, video: library.video(forLecture: $0.id)) }
                == ["0:04", nil, "0:04"])
            #expect(lectures[2].title.count > 60)
        }
        if screen != .sectionReview {
            // Other screens open the first section or a section without earlier quizzes, so no review sheet shows.
            #expect(library.sectionReview == nil)
        }
    }
}

@Test func snapshotLibrarySeedPublishesTheCourseImage() throws {
    let root = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let courseID = try #require(try SnapshotPlan.seedStore(for: .library, root: root, fixture: fixture))
    let course = try #require(try CourseStore(root: root).loadCourse(id: courseID, includeDrafts: false))
    let image = try #require(course.image)
    #expect(image.alt == "A green garden with two plants")
    #expect(image.mimeType == "image/svg+xml")
    #expect(FileManager.default.fileExists(atPath: root.appending(path: image.path(forPixelWidth: 128, height: 72)).path))
}

/// #42: SwiftUI `VideoPlayer` crashes on macOS 15 when the app is built with the macOS 26 SDK.
@Test func noSourceUsesSwiftUIVideoPlayer() throws {
    let sources = repo.appending(path: "Sources")
    let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    #expect(!files.isEmpty)
    let users = try files.filter { try String(contentsOf: $0, encoding: .utf8).contains("VideoPlayer(") }
    #expect(users.map(\.lastPathComponent) == [])
}

@Test func snapshotScriptExitsNonZeroWhenTheBuildFails() throws {
    let root = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let scripts = root.appending(path: "scripts")
    try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: repo.appending(path: "scripts/snapshot.sh"), to: scripts.appending(path: "snapshot.sh"))
    let stub = scripts.appending(path: "build.sh")
    try "#!/bin/sh\necho 'error: stub build failure'\nexit 1\n".write(to: stub, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = [scripts.appending(path: "snapshot.sh").path, root.appending(path: "out").path]
    let stdout = Pipe(), stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    process.waitUntilExit()
    let errorText = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    #expect(process.terminationStatus != 0)
    #expect(errorText.contains("error: stub build failure"))
    #expect(errorText.contains("snapshot: the app build failed"))
    #expect(stdout.fileHandleForReading.readDataToEndOfFile().isEmpty)
    #expect(!FileManager.default.fileExists(atPath: root.appending(path: "out").path))
}
