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
        "section-light.png", "section-dark.png", "lecture-light.png", "lecture-dark.png",
        "lecture-complete-light.png", "lecture-complete-dark.png", "article-light.png", "article-dark.png",
        "course-landing-light.png", "course-landing-dark.png",
        "course-landing-dark-theme-light.png", "course-landing-dark-theme-dark.png",
        "quiz-question-light.png", "quiz-question-dark.png", "quiz-wrong-answer-light.png", "quiz-wrong-answer-dark.png",
        "quiz-results-light.png", "quiz-results-dark.png", "interactive-result-light.png", "interactive-result-dark.png",
        "video-player-light.png", "video-player-dark.png", "section-review-light.png", "section-review-dark.png",
    ])
    #expect(SnapshotScreen.allCases.filter(\.showsReviewInline) == [.sectionReview])
    #expect(SnapshotScreen.allCases.filter(\.opensVideoPlayer) == [.videoPlayer])
    #expect(SnapshotScreen.allCases.filter { !$0.selectsCourse } == [.libraryEmpty, .libraryEmptyCustomFolder, .library])
    #expect(SnapshotScreen.allCases.filter { $0.customRootPath != nil } == [.libraryEmptyCustomFolder])
    #expect(outputs.allSatisfy { $0.url.deletingLastPathComponent().path == out.path })
    #expect(outputs == SnapshotPlan.outputs(outDirectory: out))
    #expect(Set(outputs.map(\.url)).count == SnapshotScreen.allCases.count * SnapshotAppearance.allCases.count)
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
        case .libraryEmpty, .libraryEmptyCustomFolder:
            #expect(courseID == nil)
            #expect(!screen.selectsCourse)
            #expect(SnapshotPlan.imageLoads(for: screen) == 0)
            #expect(library.courses.isEmpty)
        case .library:
            #expect(courseID == "sample-course")
            // The Library home: no selected course, the fixture course is the hero and a second course is new.
            #expect(!screen.selectsCourse)
            #expect(SnapshotPlan.imageLoads(for: screen) == 2)
            #expect(library.courses.map(\.id) == ["garden-tools", "sample-course"])
            #expect(library.heroCourse?.id == "sample-course")
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
            #expect(library.nudge?.kind == .recommended)
            #expect(library.nudge?.lecture.id == "read")
            #expect(!library.isSelectedLectureComplete)
            // The video lecture shows its poster and the "Free preview" capsule in the header and the outline row.
            #expect(library.selectedLecture?.type == .video)
            #expect(library.isFreePreview("welcome"))
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
        case .videoPlayer:
            #expect(courseID == "sample-course")
            library.selectCourse(courseID)
            library.selectDestination(SnapshotPlan.destination(for: screen))
            #expect(library.selectedLecture?.type == .video)
            let video = try #require(library.video(forLecture: "welcome"))
            #expect(FileManager.default.fileExists(atPath: video.url.path))
            #expect(video.captionsURL != nil)
        case .interactiveResult:
            #expect(courseID == "interactive-course")
            library.selectCourse(courseID)
            library.selectDestination(SnapshotPlan.destination(for: screen))
            #expect(library.selectedLecture?.type == .interactive)
            let module = try #require(library.selectedInteractive)
            #expect(module.entryExists())
            #expect(library.selectedInteractiveResult == InteractiveResult(score: 75, weakSkills: ["Order the steps of a course plan"]))
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
