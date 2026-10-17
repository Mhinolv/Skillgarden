import Foundation
import Observation

public enum CourseDestination: Hashable, Sendable {
    case overview
    case section(sectionID: String)
    case lecture(sectionID: String, lectureID: String)
    /// The course credits page. It is valid only if the course has credits.
    case credits
}

/// Owns the learner's library and selection. Store reads run outside the main actor.
@MainActor @Observable
public final class LibraryModel {
    public private(set) var courses: [Course] = []
    public private(set) var isLoading = false
    public private(set) var errorMessage: String?
    public private(set) var selectedCourseID: String?
    public private(set) var destination: CourseDestination? = nil
    /// Section header images by course id, then section id. Courses without an installed snapshot have none.
    public private(set) var headerImages: [String: [String: SectionHeaderImage]] = [:]
    /// Article files by course id, then lecture id. Courses without an installed snapshot have none.
    public private(set) var articles: [String: [String: LectureArticle]] = [:]
    /// Video files by course id, then lecture id. Courses without an installed snapshot have none.
    public private(set) var videos: [String: [String: LectureVideo]] = [:]
    /// Course page fields and theme by course id. Courses without an installed snapshot have none.
    public private(set) var landings: [String: CourseLanding] = [:]
    /// Learner progress by course id, then lecture id.
    public private(set) var progress: [String: [String: LectureProgress]] = [:]
    /// The last opened lecture id by course id. The lecture can be absent from the current outline.
    public private(set) var lastOpenedLectures: [String: String] = [:]
    /// Quiz content by course id, then lecture id, read from each installed manifest.
    public private(set) var quizzes: [String: [String: Quiz]] = [:]
    /// The latest saved quiz result by course id, then lecture id.
    public private(set) var quizResults: [String: [String: QuizResult]] = [:]
    /// Interactive bundles by course id, then lecture id, read from each installed manifest.
    public private(set) var interactives: [String: [String: InteractiveModule]] = [:]
    /// The latest saved interactive score by course id, then lecture id.
    public private(set) var interactiveResults: [String: [String: InteractiveResult]] = [:]
    /// Assignment briefs and rubrics by course id, then lecture id, read from each installed manifest.
    public private(set) var assignments: [String: [String: LectureAssignment]] = [:]
    /// Lecture downloads by course id, then lecture id, read from each installed manifest. Lectures without downloads have none.
    public private(set) var downloads: [String: [String: [LectureDownload]]] = [:]
    /// Quiz attempts of this session by course id, then lecture id. They are not saved.
    private var quizAttempts: [String: [String: QuizAttempt]] = [:]
    /// Rubric checks of this session by course id, then lecture id. They are not saved.
    private var rubricChecklists: [String: [String: RubricChecklist]] = [:]
    /// Section ids whose review sheet opened, by course id.
    public private(set) var reviewedSections: [String: Set<String>] = [:]
    /// The open spaced review sheet. Nil when no sheet shows.
    public private(set) var sectionReview: SectionReview?
    /// Picks the review questions. Tests and the snapshot harness pass a seeded generator.
    @ObservationIgnored private var reviewRandom: any RandomNumberGenerator
    public let root: URL
    /// The store of the last reload. Progress writes use it off the main actor, one at a time.
    private var store: CourseStore?
    private var pendingWrite: Task<Bool, Never>?
    /// A bad data folder setting. Each reload shows it and does not open the store.
    private let rootError: String?

    public init(root: URL = Skillgarden.defaultDataDirectory, rootError: String? = nil,
                reviewRandom: any RandomNumberGenerator = SystemRandomNumberGenerator()) {
        self.root = root
        self.rootError = rootError
        self.reviewRandom = reviewRandom
    }

    public var selectedCourse: Course? {
        courses.first { $0.id == selectedCourseID }
    }

    public var selectedLecture: Lecture? {
        guard case let .lecture(sectionID, lectureID) = destination else { return nil }
        return selectedCourse?.learnerSections.first { $0.id == sectionID }?.lectures.first { $0.id == lectureID }
    }

    /// The section of the section page or of the selected lecture.
    public var selectedSection: CourseSection? {
        let sectionID: String
        switch destination {
        case let .section(id), let .lecture(id, _): sectionID = id
        case .overview, .credits, nil: return nil
        }
        return selectedCourse?.learnerSections.first { $0.id == sectionID }
    }

    public var previousLecture: CourseDestination? {
        selectedLecture.flatMap { selectedCourse?.adjacentLecture(to: $0.id, offset: -1) }
    }

    public var nextLecture: CourseDestination? {
        selectedLecture.flatMap { selectedCourse?.adjacentLecture(to: $0.id, offset: 1) }
    }

    public var nudge: LectureNudge? {
        selectedLecture.flatMap { selectedCourse?.nudge(for: $0.id) }
    }

    public var selectedLanding: CourseLanding? {
        selectedCourseID.flatMap { landings[$0] }
    }

    /// The credits of the selected course in manifest order. Empty if the course has none, so the entry points hide.
    public var selectedCredits: [CourseCredit] {
        selectedLanding?.credits ?? []
    }

    public func headerImage(forSection sectionID: String) -> SectionHeaderImage? {
        selectedCourseID.flatMap { headerImages[$0]?[sectionID] }
    }

    /// The article file of a lecture in the selected course, or nil if the snapshot has none.
    public func article(forLecture lectureID: String) -> LectureArticle? {
        selectedCourseID.flatMap { articles[$0]?[lectureID] }
    }

    /// The video of a lecture in the selected course, or nil if the snapshot has none.
    public func video(forLecture lectureID: String) -> LectureVideo? {
        selectedCourseID.flatMap { videos[$0]?[lectureID] }
    }

    /// The downloads of a lecture in the selected course in manifest order. Empty if the lecture has none.
    public func downloads(forLecture lectureID: String) -> [LectureDownload] {
        selectedCourseID.flatMap { downloads[$0]?[lectureID] } ?? []
    }

    /// True if the lecture is a video lecture with `free_preview: true`.
    public func isFreePreview(_ lectureID: String) -> Bool {
        video(forLecture: lectureID)?.isFreePreview ?? false
    }

    public func goToPreviousLecture() { if let previousLecture { open(previousLecture) } }
    public func goToNextLecture() { if let nextLecture { open(nextLecture) } }
    public func goToNudge() { if let nudge { open(nudge.destination) } }

    // MARK: Progress

    public func isComplete(_ lectureID: String) -> Bool {
        selectedCourseID.flatMap { progress[$0]?[lectureID]?.completed } ?? false
    }

    public var isSelectedLectureComplete: Bool {
        selectedLecture.map { isComplete($0.id) } ?? false
    }

    public func sectionProgress(_ section: CourseSection) -> SectionProgress {
        SectionProgress(section: section, progress: selectedCourseID.flatMap { progress[$0] } ?? [:])
    }

    /// The stepping stones of the learner lectures in the selected course. Pass a section to get only its lectures.
    public func steppingStones(in section: CourseSection? = nil) -> [SteppingStone] {
        let lectures = section?.lectures ?? selectedCourse?.learnerLectures.map(\.lecture) ?? []
        return SteppingStone.states(lectureIDs: lectures.map(\.id)) { isComplete($0) }
    }

    /// The "Your path" rows of the selected course.
    public var coursePath: [CoursePathRow] {
        guard let course = selectedCourse else { return [] }
        return CoursePathRow.rows(course: course, progress: progress[course.id] ?? [:])
    }

    // MARK: Library home

    /// The tile progress of any course in the library. It does not need a selected course.
    public func summary(of course: Course) -> CourseSummary {
        CourseSummary(course: course, progress: progress[course.id] ?? [:])
    }

    /// The hero of the Library: the first course in library order that is in progress.
    /// The store has no "last opened" time, so library order decides.
    public var heroCourse: Course? {
        courses.first { summary(of: $0).status == .inProgress }
    }

    /// The Library header meta line, for example "6 courses · 3 in progress".
    public var libraryMeta: String {
        LibraryBento.meta(courses: courses.count, inProgress: courses.filter { summary(of: $0).status == .inProgress }.count)
    }

    /// The accent of a course theme, or nil for the system accent.
    public func accent(ofCourse courseID: String) -> ThemeColor? {
        landings[courseID]?.theme.accent
    }

    /// Opens a course at its first incomplete lecture, or at the course landing if every lecture is done.
    public func openNextLecture(ofCourse courseID: String) {
        selectCourse(courseID)
        guard let course = selectedCourse, course.id == courseID else { return }
        selectDestination(summary(of: course).nextDestination ?? .overview)
    }

    /// Marks the selected lecture complete or incomplete. If the write fails, the state goes back.
    public func toggleSelectedLectureComplete() async {
        guard let courseID = selectedCourseID, let lectureID = selectedLecture?.id else { return }
        let completed = !isComplete(lectureID)
        progress[courseID, default: [:]][lectureID, default: LectureProgress()].completed = completed
        let saved = await enqueueWrite { try $0.setCompleted(completed, courseID: courseID, lectureID: lectureID) }.value
        if !saved, progress[courseID]?[lectureID]?.completed == completed {
            progress[courseID]?[lectureID]?.completed = !completed
        }
    }

    /// The time to seek to when the video of a lecture in the selected course opens.
    public func startSeconds(forLecture lectureID: String, duration: Double?) -> Double {
        let saved = selectedCourseID.flatMap { progress[$0]?[lectureID]?.resumeSeconds } ?? 0
        return PlaybackResume.startSeconds(saved: saved, duration: duration)
    }

    /// The video player calls this every `PlaybackResume.saveInterval` seconds, on pause and when the learner leaves.
    public func saveResumePosition(_ seconds: Double, lectureID: String) {
        guard let courseID = selectedCourseID, seconds.isFinite,
              progress[courseID]?[lectureID]?.resumeSeconds != seconds else { return }
        progress[courseID, default: [:]][lectureID, default: LectureProgress()].resumeSeconds = seconds
        enqueueWrite { try $0.saveResumePosition(seconds, courseID: courseID, lectureID: lectureID) }
    }

    /// The last opened lecture of the selected course, if the learner can still see it.
    public var resumeDestination: CourseDestination? {
        guard let course = selectedCourse, let lectureID = lastOpenedLectures[course.id],
              let target = course.learnerLectures.first(where: { $0.lecture.id == lectureID }) else { return nil }
        return .lecture(sectionID: target.sectionID, lectureID: lectureID)
    }

    public var resumeLecture: Lecture? {
        guard case let .lecture(_, lectureID) = resumeDestination else { return nil }
        return selectedCourse?.learnerLectures.first { $0.lecture.id == lectureID }?.lecture
    }

    public func resume() { if let resumeDestination { open(resumeDestination) } }

    // MARK: Quiz

    /// The quiz of the selected lecture. Nil if the lecture is not a quiz or its course has no installed manifest.
    public var selectedQuiz: Quiz? {
        guard let courseID = selectedCourseID, let lecture = selectedLecture, lecture.type == .quiz else { return nil }
        return quizzes[courseID]?[lecture.id]
    }

    /// The attempt of this session for the selected quiz. A republish that changes the quiz starts a new attempt.
    public var selectedQuizAttempt: QuizAttempt? {
        guard let quiz = selectedQuiz, let courseID = selectedCourseID, let lectureID = selectedLecture?.id else { return nil }
        if let attempt = quizAttempts[courseID]?[lectureID], attempt.quiz == quiz { return attempt }
        return QuizAttempt(quiz: quiz)
    }

    /// Applies a learner action to the selected quiz. When the results screen opens, the result is saved.
    public func performQuizAction(_ action: QuizAction) {
        guard var attempt = selectedQuizAttempt, let courseID = selectedCourseID, let lectureID = selectedLecture?.id else { return }
        let wasShowingResults = attempt.showsResults
        attempt.perform(action)
        quizAttempts[courseID, default: [:]][lectureID] = attempt
        guard attempt.showsResults, !wasShowingResults else { return }
        let result = attempt.result
        quizResults[courseID, default: [:]][lectureID] = result
        enqueueWrite { try $0.saveQuizResult(result, courseID: courseID, lectureID: lectureID) }
    }

    // MARK: Assignment

    /// The assignment of the selected lecture. Nil if the lecture is not an assignment or its course has no installed manifest.
    public var selectedAssignment: LectureAssignment? {
        guard let courseID = selectedCourseID, let lecture = selectedLecture, lecture.type == .assignment else { return nil }
        return assignments[courseID]?[lecture.id]
    }

    /// The checks of this session for the selected assignment. All rows start unchecked.
    /// A republish keeps the checks of rows whose id is still in the rubric.
    public var selectedRubricChecklist: RubricChecklist? {
        guard let assignment = selectedAssignment, let courseID = selectedCourseID,
              let lectureID = selectedLecture?.id else { return nil }
        let checked = rubricChecklists[courseID]?[lectureID]?.checked ?? []
        return RubricChecklist(rubric: assignment.rubric, checked: checked)
    }

    /// Toggles one rubric row of the selected assignment.
    public func toggleRubricCriterion(_ id: String) {
        updateRubricChecklist { $0.toggle(id) }
    }

    /// Clears all rubric checks of the selected assignment.
    public func resetRubric() {
        updateRubricChecklist { $0.reset() }
    }

    private func updateRubricChecklist(_ body: (inout RubricChecklist) -> Void) {
        guard var checklist = selectedRubricChecklist, let courseID = selectedCourseID,
              let lectureID = selectedLecture?.id else { return }
        body(&checklist)
        rubricChecklists[courseID, default: [:]][lectureID] = checklist
    }

    // MARK: Spaced review

    /// Opens the review sheet on the first visit to a section that has two or more questions from earlier quizzes.
    /// The section counts as reviewed when the sheet opens, so a skip also stops a repeat.
    private func openReviewIfNeeded(sectionID: String) {
        guard let course = selectedCourse, reviewedSections[course.id]?.contains(sectionID) != true,
              let section = course.learnerSections.first(where: { $0.id == sectionID }) else { return }
        let candidates = SpacedReview.candidates(course: course, sectionID: sectionID, quizzes: quizzes[course.id] ?? [:])
        let questions = SpacedReview.select(from: candidates, using: &reviewRandom)
        guard !questions.isEmpty else { return }
        let courseID = course.id
        reviewedSections[courseID, default: []].insert(sectionID)
        sectionReview = SectionReview(courseID: courseID, sectionID: sectionID, sectionTitle: section.title, questions: questions)
        enqueueWrite { try $0.saveSectionReviewed(courseID: courseID, sectionID: sectionID) }
    }

    /// One click answers a review question. The answer is not saved.
    public func answerReview(questionID: String, choiceID: String) {
        sectionReview?.answer(questionID: questionID, choiceID: choiceID)
    }

    /// "Skip Review" and "Continue to Section" both close the sheet. The section stays open.
    public func closeReview() {
        sectionReview = nil
    }

    // MARK: Interactive

    /// The bundle of the selected lecture. Nil if the lecture is not interactive or its course has no installed manifest.
    public var selectedInteractive: InteractiveModule? {
        guard let courseID = selectedCourseID, let lecture = selectedLecture, lecture.type == .interactive else { return nil }
        return interactives[courseID]?[lecture.id]
    }

    /// The latest saved score of the selected interactive lecture.
    public var selectedInteractiveResult: InteractiveResult? {
        guard let courseID = selectedCourseID, let lecture = selectedLecture, lecture.type == .interactive else { return nil }
        return interactiveResults[courseID]?[lecture.id]
    }

    /// Applies a bridge message from the module of `lectureID`. Messages from a lecture that is not selected do nothing.
    /// `complete()` marks the lecture complete. A score replaces the saved score of the lecture.
    public func receiveInteractiveMessage(_ message: InteractiveBridgeMessage, lectureID: String) {
        guard let courseID = selectedCourseID, let lecture = selectedLecture, lecture.id == lectureID,
              lecture.type == .interactive else { return }
        switch message {
        case .complete:
            guard !isComplete(lectureID) else { return }
            progress[courseID, default: [:]][lectureID, default: LectureProgress()].completed = true
            enqueueWrite { try $0.setCompleted(true, courseID: courseID, lectureID: lectureID) }
        case let .score(score):
            let result = InteractiveResult(score: score, objective: lecture.objective)
            interactiveResults[courseID, default: [:]][lectureID] = result
            enqueueWrite { try $0.saveInteractiveResult(result, courseID: courseID, lectureID: lectureID) }
        }
    }

    /// Waits until all queued progress writes finish.
    func waitForWrites() async { _ = await pendingWrite?.value }

    private func open(_ value: CourseDestination) {
        destination = value
        switch value {
        case let .section(sectionID), let .lecture(sectionID, _): openReviewIfNeeded(sectionID: sectionID)
        case .overview, .credits: break
        }
        guard let courseID = selectedCourseID, case let .lecture(_, lectureID) = value,
              lastOpenedLectures[courseID] != lectureID else { return }
        lastOpenedLectures[courseID] = lectureID
        enqueueWrite { try $0.saveLastOpenedLecture(courseID: courseID, lectureID: lectureID) }
    }

    /// Runs store writes off the main actor in the order of the calls.
    @discardableResult
    private func enqueueWrite(_ body: @escaping @Sendable (CourseStore) throws -> Void) -> Task<Bool, Never> {
        let previous = pendingWrite
        let store = store
        let task = Task.detached {
            _ = await previous?.value
            guard let store else { return false }
            do { try body(store); return true } catch { return false }
        }
        pendingWrite = task
        return task
    }

    /// Nil goes back to the Library home.
    public func selectCourse(_ id: String?) {
        guard id != selectedCourseID else { return }
        selectedCourseID = courses.first { $0.id == id }?.id
        destination = selectedCourseID == nil ? nil : .overview
        sectionReview = nil
    }

    public func selectDestination(_ value: CourseDestination?) {
        guard let course = selectedCourse else { destination = nil; return }
        guard Self.isValid(value, in: course, credits: selectedCredits) else { return }
        if let value { open(value) } else { destination = nil }
    }

    public func reload() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        if let rootError {
            errorMessage = rootError
            return
        }
        let root = root
        // Queued writes finish first, so the reload reads them.
        await waitForWrites()
        do {
            let (store, loaded, installed, progress, lastOpened, quizResults, interactiveResults, reviewed) = try await Task.detached {
                let store = try CourseStore(root: root)
                return (store, try store.listCourses(), try Self.installedData(store: store, root: root),
                        try store.allProgress(), try store.lastOpenedLectures(), try store.allQuizResults(),
                        try store.allInteractiveResults(), try store.allReviewedSections())
            }.value
            self.store = store
            courses = loaded
            headerImages = installed.headerImages
            landings = installed.landings
            articles = installed.articles
            videos = installed.videos
            self.progress = progress
            lastOpenedLectures = lastOpened
            quizzes = installed.quizzes
            self.quizResults = quizResults
            interactives = installed.interactives
            assignments = installed.assignments
            downloads = installed.downloads
            self.interactiveResults = interactiveResults
            reviewedSections = reviewed
            errorMessage = nil
            if let course = selectedCourse {
                if !Self.isValid(destination, in: course, credits: selectedCredits) { destination = .overview }
            } else {
                selectedCourseID = nil
                destination = nil
            }
            if sectionReview?.courseID != selectedCourseID { sectionReview = nil }
        } catch {
            store = nil
            courses = []
            headerImages = [:]
            landings = [:]
            articles = [:]
            videos = [:]
            progress = [:]
            lastOpenedLectures = [:]
            quizzes = [:]
            quizResults = [:]
            interactives = [:]
            interactiveResults = [:]
            assignments = [:]
            downloads = [:]
            reviewedSections = [:]
            sectionReview = nil
            selectedCourseID = nil
            destination = nil
            errorMessage = error.localizedDescription
        }
    }

    private static func isValid(_ value: CourseDestination?, in course: Course, credits: [CourseCredit]) -> Bool {
        let sections = course.learnerSections
        switch value {
        case let .section(sectionID):
            return sections.contains { $0.id == sectionID }
        case let .lecture(sectionID, lectureID):
            return sections.first { $0.id == sectionID }?.lectures.contains { $0.id == lectureID } == true
        case .credits:
            return !credits.isEmpty
        case .overview, nil:
            return true
        }
    }

    /// Reads header images, course page fields, article files, video files, quizzes, interactive bundles
    /// assignments and downloads from each installed manifest.
    /// A path outside the snapshot folder is ignored.
    nonisolated private static func installedData(store: CourseStore, root: URL) throws -> InstalledCourseData {
        var data = InstalledCourseData()
        for (courseID, publication) in try store.publications() {
            guard let manifest = try? JSONDecoder().decode(CourseManifest.self, from: publication.manifest) else { continue }
            let folder = root.appending(path: publication.directory).standardizedFileURL
            data.landings[courseID] = CourseLanding(manifest: manifest, folder: folder)
            for section in manifest.sections {
                let url = folder.appending(path: section.headerImage.path).standardizedFileURL
                if url.path.hasPrefix(folder.path + "/") {
                    data.headerImages[courseID, default: [:]][section.id] = SectionHeaderImage(url: url, alt: section.headerImage.alt)
                }
                // Manifests saved before article support have no `article` field.
                for lecture in section.lectures {
                    guard let article = lecture.article, let path = LectureArticle.normalize(article.path) else { continue }
                    data.articles[courseID, default: [:]][lecture.id] = LectureArticle(folder: folder, path: path, images: article.images ?? [])
                }
                // Manifests saved before video support have no `video` field.
                for lecture in section.lectures {
                    guard let video = lecture.video.flatMap({ LectureVideo(folder: folder, video: $0) }) else { continue }
                    data.videos[courseID, default: [:]][lecture.id] = video
                }
            }
            for lecture in manifest.sections.flatMap(\.lectures) {
                if let quiz = lecture.quiz { data.quizzes[courseID, default: [:]][lecture.id] = Quiz(manifest: quiz, folder: folder) }
                if let module = lecture.interactive.flatMap({ InteractiveModule(snapshot: folder, bundlePath: $0.bundlePath) }) {
                    data.interactives[courseID, default: [:]][lecture.id] = module
                }
                // Manifests saved before assignment support have no `assignment` field.
                if let assignment = lecture.assignment {
                    data.assignments[courseID, default: [:]][lecture.id] = LectureAssignment(manifest: assignment, folder: folder)
                }
                // Manifests saved before download support have no `downloads` field.
                let files = LectureDownload.list(lecture.downloads, folder: folder)
                if !files.isEmpty { data.downloads[courseID, default: [:]][lecture.id] = files }
            }
        }
        return data
    }
}

/// The data that `LibraryModel` reads from the installed publication folders. Add new fields here.
struct InstalledCourseData: Sendable {
    /// Section header images by course id, then section id.
    var headerImages: [String: [String: SectionHeaderImage]] = [:]
    /// Course page fields and theme by course id.
    var landings: [String: CourseLanding] = [:]
    /// Article files by course id, then lecture id.
    var articles: [String: [String: LectureArticle]] = [:]
    /// Video files by course id, then lecture id.
    var videos: [String: [String: LectureVideo]] = [:]
    /// Quizzes by course id, then lecture id.
    var quizzes: [String: [String: Quiz]] = [:]
    /// Interactive bundles by course id, then lecture id.
    var interactives: [String: [String: InteractiveModule]] = [:]
    /// Assignment briefs and rubrics by course id, then lecture id.
    var assignments: [String: [String: LectureAssignment]] = [:]
    /// Lecture downloads by course id, then lecture id.
    var downloads: [String: [String: [LectureDownload]]] = [:]
}
