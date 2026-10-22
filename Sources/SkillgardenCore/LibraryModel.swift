import Foundation
import Observation

public enum CourseDestination: Hashable, Sendable {
    case overview
    case section(sectionID: String)
    case lecture(sectionID: String, lectureID: String)
    /// The course credits page. It is valid only if the course has credits.
    case credits
    /// The course Notes page (#181): the notes of the learner on each lecture, in course order.
    case notes
}

/// The once-per-app-session recovery of pending Q&A turns (#208). Each window has its own `LibraryModel`, and all of them
/// use `shared`. So a new window does not interrupt the active request of another window. A new instance is a new app run.
public final class PendingTurnRecovery: @unchecked Sendable {
    public static let shared = PendingTurnRecovery()
    private let lock = NSLock()
    /// The data folders that this session recovered.
    private var recovered: Set<String> = []

    public init() {}

    /// Runs `recover` the first time a data folder loads in this session. A recover that throws runs again at the next call.
    /// The lock holds during `recover`, so a second window waits for the first recovery and then skips it.
    func recoverOnce(root: URL, _ recover: () throws -> Void) throws {
        let key = root.standardizedFileURL.resolvingSymlinksInPath().path
        try lock.withLock {
            guard !recovered.contains(key) else { return }
            try recover()
            recovered.insert(key)
        }
    }
}

/// Runs a blocking store call on a dispatch queue, not on the cooperative pool (#209). A busy store waits up to
/// 5 seconds for a lock, and that wait must not stop other tasks.
private let storeQueue = DispatchQueue(label: "Skillgarden.store", qos: .userInitiated, attributes: .concurrent)

func onStoreQueue<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        storeQueue.async { continuation.resume(with: Result(catching: body)) }
    }
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
    /// Source cards by course id, then lecture id, read from each installed manifest. Lectures without sources have none.
    public private(set) var sources: [String: [String: [LectureSource]]] = [:]
    /// Quiz attempts of this session by course id, then lecture id. They are not saved.
    private var quizAttempts: [String: [String: QuizAttempt]] = [:]
    /// Rubric checks of this session by course id, then lecture id. They are not saved.
    private var rubricChecklists: [String: [String: RubricChecklist]] = [:]
    /// Video quick-check answers of this session by course id, then lecture id. They are not saved.
    private var quickCheckSessions: [String: [String: QuickCheckSession]] = [:]
    /// Section ids whose review sheet opened, by course id.
    public private(set) var reviewedSections: [String: Set<String>] = [:]
    /// Learner notes by course id, then lecture id, in creation order (#181).
    public private(set) var notes: [String: [String: [LectureNote]]] = [:]
    /// Indexed transcript cues by course id (#18). Courses published before the index have none.
    public private(set) var transcriptCues: [String: [TranscriptCue]] = [:]
    /// The text of the transcript search field of the selected course.
    public var transcriptQuery = ""
    /// The results of the last search. Nil shows the outline.
    public private(set) var transcriptResults: TranscriptSearchResults?
    /// The cue that the video player of the selected lecture must seek to, paused. Nil when no seek waits.
    public private(set) var transcriptSeek: TranscriptSeek?
    @ObservationIgnored private var seekCount = 0
    /// The lecture whose video starts at once when its page opens (#99). `playNextLecture()` sets it. Each other open clears it.
    @ObservationIgnored private var autoPlayLectureID: String?
    /// The open spaced review sheet. Nil when no sheet shows.
    public private(set) var sectionReview: SectionReview?
    /// Picks the review questions. Tests and the snapshot harness pass a seeded generator.
    @ObservationIgnored private var reviewRandom: any RandomNumberGenerator
    /// Lecture contexts for local AI by course, lecture and source revision (#125).
    @ObservationIgnored private let lectureContexts = LectureContextCache()
    /// Marks the pending Q&A turns of the last app run as interrupted, once per data folder for all windows (#127, #208).
    @ObservationIgnored private let recovery: PendingTurnRecovery
    public let root: URL
    /// The store of the last reload. Progress writes use it off the main actor, one at a time.
    private var store: CourseStore?
    private var pendingWrite: Task<Bool, Never>?
    /// A bad data folder setting. Each reload shows it and does not open the store.
    private let rootError: String?

    public init(root: URL = Skillgarden.defaultDataDirectory, rootError: String? = nil,
                reviewRandom: any RandomNumberGenerator = SystemRandomNumberGenerator(),
                recovery: PendingTurnRecovery = .shared) {
        self.root = root
        self.rootError = rootError
        self.reviewRandom = reviewRandom
        self.recovery = recovery
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
        case .overview, .credits, .notes, nil: return nil
        }
        return selectedCourse?.learnerSections.first { $0.id == sectionID }
    }

    public var previousLecture: CourseDestination? {
        selectedLecture.flatMap { selectedCourse?.adjacentLecture(to: $0.id, offset: -1) }
    }

    public var nextLecture: CourseDestination? {
        selectedLecture.flatMap { selectedCourse?.adjacentLecture(to: $0.id, offset: 1) }
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

    public func goToPreviousLecture() { if let previousLecture { open(previousLecture) } }
    public func goToNextLecture() { if let nextLecture { open(nextLecture) } }

    /// The title of `nextLecture`. The "Up next" overlay shows it (#99).
    public var nextLectureTitle: String? {
        guard case let .lecture(_, lectureID)? = nextLecture else { return nil }
        return selectedCourse?.learnerLectures.first { $0.lecture.id == lectureID }?.lecture.title
    }

    /// Auto-play after a video ends (#99): opens `nextLecture`, the same target as Next and ⌥⌘→.
    /// If the next lecture is a video, its player starts at once. Returns false if no next lecture exists.
    @discardableResult
    public func playNextLecture() -> Bool {
        guard let nextLecture else { return false }
        open(nextLecture)
        if case let .lecture(_, lectureID) = nextLecture, selectedLecture?.type == .video { autoPlayLectureID = lectureID }
        return true
    }

    /// The video player of `lectureID` calls this after its load. True starts the player at once, one time only (#99).
    public func takeAutoPlay(lectureID: String) -> Bool {
        guard autoPlayLectureID == lectureID else { return false }
        autoPlayLectureID = nil
        return true
    }

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

    /// The one section that the outline shows open (#70): the section of the selection.
    /// On the overview, the credits or no selection, the section of the next lecture. If all lectures are done, the first section.
    public var outlineOpenSectionID: String? {
        if let selectedSection { return selectedSection.id }
        guard let course = selectedCourse else { return nil }
        if case let .lecture(sectionID, _)? = summary(of: course).nextDestination { return sectionID }
        return course.learnerSections.first?.id
    }

    /// The section header that the outline rings (#77): the section that the course card stone marks next.
    /// The selection does not change it. Nil with no course or if all sections are done.
    public var outlineNextSectionID: String? {
        guard let course = selectedCourse else { return nil }
        return SectionStone.nextSectionID(course: course, progress: progress[course.id] ?? [:])
    }

    // MARK: Library home

    /// The tile progress of any course in the library. It does not need a selected course.
    public func summary(of course: Course) -> CourseSummary {
        CourseSummary(course: course, progress: progress[course.id] ?? [:])
    }

    /// The course of the Library "Continue" strip: the first course in library order that is in progress.
    /// The store has no "last opened" time, so library order decides.
    public var continueCourse: Course? {
        courses.first { summary(of: $0).status == .inProgress }
    }

    /// The Library header meta line, for example "6 courses · 3 in progress".
    public var libraryMeta: String {
        LibraryGrid.meta(courses: courses.count, inProgress: courses.filter { summary(of: $0).status == .inProgress }.count)
    }

    /// Opens a course at its first incomplete lecture, or at the course landing if every lecture is done.
    public func openNextLecture(ofCourse courseID: String) {
        selectCourse(courseID)
        guard let course = selectedCourse, course.id == courseID else { return }
        selectDestination(summary(of: course).nextDestination ?? .overview)
    }

    /// Marks the selected lecture complete or incomplete. If the write fails, the state goes back.
    /// Incomplete by hand turns off the automatic complete of a video. Complete by hand turns it on again (#79).
    public func toggleSelectedLectureComplete() async {
        guard let courseID = selectedCourseID, let lectureID = selectedLecture?.id else { return }
        let completed = !isComplete(lectureID)
        let wasOff = progress[courseID]?[lectureID]?.autoCompleteOff ?? false
        progress[courseID, default: [:]][lectureID, default: LectureProgress()].completed = completed
        progress[courseID, default: [:]][lectureID, default: LectureProgress()].autoCompleteOff = !completed
        let saved = await enqueueWrite { try $0.setCompletedByHand(completed, courseID: courseID, lectureID: lectureID) }.value
        if !saved, progress[courseID]?[lectureID]?.completed == completed {
            progress[courseID]?[lectureID]?.completed = !completed
            progress[courseID]?[lectureID]?.autoCompleteOff = wasOff
        }
    }

    /// True if the video of `lectureID` completes the lecture at 90% or at the end (#79).
    /// False after the learner marks the lecture incomplete by hand.
    public func autoCompletes(_ lectureID: String) -> Bool {
        !(selectedCourseID.flatMap { progress[$0]?[lectureID]?.autoCompleteOff } ?? false)
    }

    /// The video player calls this when play passes 90% of the video or reaches the end (#79).
    /// Returns true if the lecture changes to complete. A lecture that is not the selected video does not change.
    @discardableResult
    public func autoCompleteVideo(lectureID: String) -> Bool {
        guard let courseID = selectedCourseID, let lecture = selectedLecture, lecture.id == lectureID, lecture.type == .video,
              !isComplete(lectureID), autoCompletes(lectureID) else { return false }
        progress[courseID, default: [:]][lectureID, default: LectureProgress()].completed = true
        enqueueWrite { try $0.setCompleted(true, courseID: courseID, lectureID: lectureID) }
        return true
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

    // MARK: Quick checks

    /// The quick checks of this session for the selected video. Nil if the video has no checks.
    /// A republish that changes the checks clears the answers.
    public var selectedQuickChecks: QuickCheckSession? {
        guard let courseID = selectedCourseID, let lecture = selectedLecture, lecture.type == .video,
              let checks = videos[courseID]?[lecture.id]?.quickChecks, !checks.isEmpty else { return nil }
        if let session = quickCheckSessions[courseID]?[lecture.id], session.checks == checks { return session }
        return QuickCheckSession(checks: checks)
    }

    /// Answers one quick check of the selected video. The first answer locks the check.
    public func answerQuickCheck(_ checkID: Int, choiceID: String) {
        updateQuickChecks { $0.answer(checkID: checkID, choiceID: choiceID) }
    }

    /// Unlocks one quick check of the selected video.
    public func retryQuickCheck(_ checkID: Int) {
        updateQuickChecks { $0.tryAgain(checkID: checkID) }
    }

    private func updateQuickChecks(_ body: (inout QuickCheckSession) -> Void) {
        guard var session = selectedQuickChecks, let courseID = selectedCourseID, let lectureID = selectedLecture?.id else { return }
        body(&session)
        quickCheckSessions[courseID, default: [:]][lectureID] = session
    }

    // MARK: Sources

    /// The source cards of the selected lecture in manifest order. Empty if the lecture has none.
    public var selectedSources: [LectureSource] {
        guard let courseID = selectedCourseID, let lectureID = selectedLecture?.id else { return [] }
        return sources[courseID]?[lectureID] ?? []
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

    // MARK: Transcript search

    /// Searches the transcripts of the selected course for `transcriptQuery`.
    /// A query shorter than `TranscriptSearch.minimumQueryLength` clears the results, so the outline shows.
    public func searchTranscripts() {
        let results = selectedCourse.flatMap {
            TranscriptSearch.search(transcriptQuery, course: $0, cues: transcriptCues[$0.id] ?? [])
        }
        if results != transcriptResults { transcriptResults = results }
    }

    /// Clears the query and the results, so the outline shows again.
    public func clearTranscriptSearch() {
        transcriptQuery = ""
        transcriptResults = nil
    }

    /// Opens the lecture of a result. The video player seeks to the cue start and stays paused.
    /// The results stay, so the learner can select another result.
    public func openTranscriptHit(_ hit: TranscriptHit) {
        guard let course = selectedCourse, Self.isValid(hit.destination, in: course, credits: selectedCredits) else { return }
        open(hit.destination)
        seekCount += 1
        transcriptSeek = TranscriptSeek(id: seekCount, lectureID: hit.lectureID, seconds: hit.start)
    }

    /// A video source chip of the Q&A panel (#129). The player of the open lecture seeks to the stored cue start
    /// and stays paused. The transcript does not open, so the Q&A panel stays in its slot.
    public func seekCitation(lectureID: String, seconds: Double) {
        guard let lecture = selectedLecture, lecture.id == lectureID, lecture.type == .video, seconds.isFinite, seconds >= 0
        else { return }
        seekCount += 1
        transcriptSeek = TranscriptSeek(id: seekCount, lectureID: lectureID, seconds: seconds, showsTranscript: false)
    }

    // MARK: Local AI

    /// The local AI context of a lecture in the selected course (#125). The cache reads the text off the main actor.
    /// A lecture that the learner cannot see is not available.
    public func lectureContext(forLecture lectureID: String,
                               budget: LectureContextBudget = .standard) async -> LectureContextOutcome {
        guard let course = selectedCourse else { return .notAvailable }
        return await lectureContexts.context(course: course, lectureID: lectureID, video: videos[course.id]?[lectureID],
                                             article: articles[course.id]?[lectureID], budget: budget)
    }

    /// The saved Q&A thread of a lecture in the selected course (#127). Nil for a lecture outside the published outline,
    /// so its history does not show. The current source revision comes from the lecture context.
    public func lectureConversation(forLecture lectureID: String,
                                    budget: LectureContextBudget = .standard) async throws -> LectureConversation? {
        guard let course = selectedCourse, LectureContextBuilder.learnerLecture(lectureID, in: course) != nil,
              let store else { return nil }
        let revision: String? = if case .ready(let context) = await lectureContext(forLecture: lectureID, budget: budget) {
            context.sourceRevision
        } else { nil }
        await waitForWrites()
        let courseID = course.id
        let turns = try await onStoreQueue { try store.qaTurns(courseID: courseID, lectureID: lectureID) }
        return LectureConversation(turns: turns, sourceRevision: revision)
    }

    /// Saves the question with a pending answer before the request starts (#127).
    /// `origin` is the provider and the model that answer it (#150).
    public func startQATurn(question: String, context: LectureContext, origin: AnswerOrigin,
                            lectureID: String) async throws -> QATurn {
        guard let courseID = selectedCourseID, let store else { throw CourseStoreError.databaseFailure }
        await waitForWrites()
        return try await onStoreQueue {
            try store.startQATurn(question: question, sourceRevision: context.sourceRevision, origin: origin, courseID: courseID,
                                  lectureID: lectureID)
        }
    }

    /// Saves the end of a request: the last `AnswerUpdate.ended` outcome and text (#127).
    /// The task gives false when the store refuses the save (#209). A turn that is not pending any more is not a failure.
    @discardableResult
    public func finishQATurn(_ turn: QATurn, outcome: AnswerOutcome, text: String) -> Task<Bool, Never> {
        enqueueWrite { try $0.finishQATurn(id: turn.id, status: QATurnStatus(outcome: outcome), answer: text) }
    }

    /// Clear History for one lecture of the selected course (#127). The caller cancels the active request first.
    public func clearQAHistory(forLecture lectureID: String) {
        guard let courseID = selectedCourseID else { return }
        enqueueWrite { try $0.clearQAHistory(courseID: courseID, lectureID: lectureID) }
    }

    /// Removes one Q&A turn (#170). The course id comes from the caller, so a late request removes the turn of its own course.
    /// The task gives false when the store refuses the delete (#209).
    @discardableResult
    public func removeQATurn(_ turn: QATurn, courseID: String, lectureID: String) -> Task<Bool, Never> {
        enqueueWrite { try $0.removeQATurn(id: turn.id, courseID: courseID, lectureID: lectureID) }
    }

    // MARK: Notes (#181)

    /// The notes of a lecture in the selected course, in panel order: video time, then creation order.
    public func notes(forLecture lectureID: String) -> [LectureNote] {
        LectureNote.panelOrder(selectedCourseID.flatMap { notes[$0]?[lectureID] } ?? [])
    }

    /// The Notes page of the selected course: one group for each learner lecture with notes, in course order.
    public var selectedNoteGroups: [LectureNoteGroup] {
        guard let course = selectedCourse else { return [] }
        return LectureNoteGroup.groups(course: course, notes: notes[course.id] ?? [:])
    }

    /// Saves a new note on a learner lecture of the selected course. Returns false when the save fails,
    /// so the composer keeps the text. `videoSeconds` is nil for a lecture that is not a video.
    @discardableResult
    public func addNote(_ text: String, videoSeconds: Double?, lectureID: String) async -> Bool {
        guard let course = selectedCourse, LectureContextBuilder.learnerLecture(lectureID, in: course) != nil,
              LectureNote.cleanText(text) != nil, let store else { return false }
        let courseID = course.id
        await waitForWrites()
        guard let note = try? await onStoreQueue({
            try store.addNote(text: text, videoSeconds: videoSeconds, courseID: courseID, lectureID: lectureID)
        }) else { return false }
        notes[courseID, default: [:]][lectureID, default: []].append(note)
        return true
    }

    /// Saves new text for a note of the selected course. Returns false when the save fails, so the field keeps the text.
    @discardableResult
    public func updateNote(_ note: LectureNote, text: String) async -> Bool {
        guard let courseID = selectedCourseID, let clean = LectureNote.cleanText(text) else { return false }
        guard await enqueueWrite({ try $0.updateNote(id: note.id, text: clean, courseID: courseID) }).value else { return false }
        if let index = notes[courseID]?[note.lectureID]?.firstIndex(where: { $0.id == note.id }) {
            notes[courseID]?[note.lectureID]?[index].text = clean
        }
        return true
    }

    /// Removes a note of the selected course. Returns false when the delete fails, so the note stays.
    @discardableResult
    public func deleteNote(_ note: LectureNote) async -> Bool {
        guard let courseID = selectedCourseID else { return false }
        guard await enqueueWrite({ try $0.deleteNote(id: note.id, courseID: courseID) }).value else { return false }
        notes[courseID]?[note.lectureID]?.removeAll { $0.id == note.id }
        if notes[courseID]?[note.lectureID]?.isEmpty == true { notes[courseID]?[note.lectureID] = nil }
        return true
    }

    /// A click on the time of a video note in the panel. The player of the open lecture seeks to the time and plays,
    /// like a transcript line. The Notes panel stays in its slot.
    public func seekNote(_ note: LectureNote) {
        guard let seconds = note.videoSeconds, let lecture = selectedLecture, lecture.id == note.lectureID,
              lecture.type == .video else { return }
        seekCount += 1
        transcriptSeek = TranscriptSeek(id: seekCount, lectureID: note.lectureID, seconds: seconds, showsTranscript: false, plays: true)
    }

    /// A row of the Notes page opens its lecture. A click on the time also seeks the video to the note and plays.
    public func openNote(_ note: LectureNote, seeks: Bool = false) {
        guard let course = selectedCourse,
              let target = course.learnerLectures.first(where: { $0.lecture.id == note.lectureID }) else { return }
        open(.lecture(sectionID: target.sectionID, lectureID: note.lectureID))
        if seeks { seekNote(note) }
    }

    /// Waits until all queued progress writes finish.
    func waitForWrites() async { _ = await pendingWrite?.value }

    private func open(_ value: CourseDestination) {
        destination = value
        transcriptSeek = nil
        autoPlayLectureID = nil
        switch value {
        case let .section(sectionID), let .lecture(sectionID, _): openReviewIfNeeded(sectionID: sectionID)
        case .overview, .credits, .notes: break
        }
        guard let courseID = selectedCourseID, case let .lecture(_, lectureID) = value,
              lastOpenedLectures[courseID] != lectureID else { return }
        lastOpenedLectures[courseID] = lectureID
        enqueueWrite { try $0.saveLastOpenedLecture(courseID: courseID, lectureID: lectureID) }
    }

    /// Runs store writes off the main actor and off the cooperative pool, in the order of the calls.
    @discardableResult
    private func enqueueWrite(_ body: @escaping @Sendable (CourseStore) throws -> Void) -> Task<Bool, Never> {
        let previous = pendingWrite
        let store = store
        let task = Task.detached {
            _ = await previous?.value
            guard let store else { return false }
            return (try? await onStoreQueue { try body(store) }) != nil
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
        transcriptSeek = nil
        autoPlayLectureID = nil
        clearTranscriptSearch()
    }

    public func selectDestination(_ value: CourseDestination?) {
        guard let course = selectedCourse else { destination = nil; return }
        guard Self.isValid(value, in: course, credits: selectedCredits) else { return }
        if let value { open(value) } else { destination = nil }
    }

    // MARK: Import

    /// True while an import checks or publishes a course folder (#111).
    public private(set) var isImporting = false
    /// The title of the course that an import publishes now. The progress sheet shows it. Nil when no publish runs.
    public private(set) var importingTitle: String?

    /// False while the library loads, while an import runs or when the data folder setting is bad.
    public var canImport: Bool { !isLoading && !isImporting && rootError == nil }

    /// Checks a course folder off the main actor. It writes nothing to the library.
    public func checkImport(folder: URL) async throws -> CourseImportCheck {
        isImporting = true
        defer { isImporting = false }
        let root = root
        return try await Task.detached { try CourseImport.check(folder: folder, root: root) }.value
    }

    /// Publishes a checked course folder off the main actor, then reloads the library.
    /// A published course then opens at its landing page. A draft course does not show, so nothing opens.
    public func importCourse(folder: URL, title: String) async throws -> PublishResult {
        isImporting = true
        importingTitle = title
        defer { isImporting = false; importingTitle = nil }
        let root = root
        let result = try await Task.detached { try CoursePublisher.publish(courseFolder: folder, root: root) }.value
        // Reload is disabled while an import runs, so this reload is not skipped.
        await reload()
        if result.state == .published {
            selectCourse(result.id)
            if selectedCourseID == result.id { selectDestination(.overview) }
        }
        return result
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
        let recovery = recovery
        do {
            let (store, loaded, installed, progress, lastOpened, quizResults, interactiveResults, reviewed, cues, notes) = try await Task.detached {
                let store = try CourseStore(root: root)
                // A turn that was pending when the app stopped can never finish (#127).
                // Later reloads and other windows keep active requests (#208).
                try recovery.recoverOnce(root: root) { try store.interruptPendingQATurns() }
                return (store, try store.listCourses(), try Self.installedData(store: store, root: root),
                        try store.allProgress(), try store.lastOpenedLectures(), try store.allQuizResults(),
                        try store.allInteractiveResults(), try store.allReviewedSections(), try store.allTranscriptCues(),
                        try store.allNotes())
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
            sources = installed.sources
            self.interactiveResults = interactiveResults
            reviewedSections = reviewed
            transcriptCues = cues
            self.notes = notes
            errorMessage = nil
            if let course = selectedCourse {
                if !Self.isValid(destination, in: course, credits: selectedCredits) { destination = .overview }
            } else {
                selectedCourseID = nil
                destination = nil
            }
            if sectionReview?.courseID != selectedCourseID { sectionReview = nil }
            if selectedCourseID == nil { clearTranscriptSearch() } else { searchTranscripts() }
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
            sources = [:]
            reviewedSections = [:]
            transcriptCues = [:]
            notes = [:]
            clearTranscriptSearch()
            transcriptSeek = nil
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
        case .overview, .notes, nil:
            return true
        }
    }

    /// Reads header images, course page fields, article files, video files, quizzes, interactive bundles
    /// assignments, downloads and source cards from each installed manifest.
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
                // Manifests saved before source support have no `sources` field.
                if let sources = lecture.sources, !sources.isEmpty {
                    data.sources[courseID, default: [:]][lecture.id] = sources.map(LectureSource.init(manifest:))
                }
            }
        }
        return data
    }
}

/// A request to the video player of `lectureID`: seek to `seconds` and stay paused (#18), or play (#181).
/// `id` changes on each request, so a second click on the same result seeks again.
public struct TranscriptSeek: Equatable, Sendable {
    public let id: Int
    public let lectureID: String
    public let seconds: Double
    /// True opens the transcript with the cue active. A Q&A source seek (#129) and a note seek (#181) keep their panel.
    public let showsTranscript: Bool
    /// True plays after the seek, like a click on a transcript line. A note time seek plays (#181). The others stay paused.
    public let plays: Bool

    init(id: Int, lectureID: String, seconds: Double, showsTranscript: Bool = true, plays: Bool = false) {
        self.id = id
        self.lectureID = lectureID
        self.seconds = seconds
        self.showsTranscript = showsTranscript
        self.plays = plays
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
    /// Source cards by course id, then lecture id.
    var sources: [String: [String: [LectureSource]]] = [:]
}
