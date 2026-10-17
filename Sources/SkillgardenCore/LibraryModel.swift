import Foundation
import Observation

public enum CourseDestination: Hashable, Sendable {
    case overview
    case section(sectionID: String)
    case lecture(sectionID: String, lectureID: String)
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
    /// Learner progress by course id, then lecture id.
    public private(set) var progress: [String: [String: LectureProgress]] = [:]
    /// The last opened lecture id by course id. The lecture can be absent from the current outline.
    public private(set) var lastOpenedLectures: [String: String] = [:]
    public let root: URL
    /// The store of the last reload. Progress writes use it off the main actor, one at a time.
    private var store: CourseStore?
    private var pendingWrite: Task<Bool, Never>?

    public init(root: URL = Skillgarden.defaultDataDirectory) {
        self.root = root
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
        case .overview, nil: return nil
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

    public func headerImage(forSection sectionID: String) -> SectionHeaderImage? {
        selectedCourseID.flatMap { headerImages[$0]?[sectionID] }
    }

    /// The article file of a lecture in the selected course, or nil if the snapshot has none.
    public func article(forLecture lectureID: String) -> LectureArticle? {
        selectedCourseID.flatMap { articles[$0]?[lectureID] }
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

    /// Waits until all queued progress writes finish.
    func waitForWrites() async { _ = await pendingWrite?.value }

    private func open(_ value: CourseDestination) {
        destination = value
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

    public func selectCourse(_ id: String?) {
        guard id != selectedCourseID else { return }
        selectedCourseID = courses.first { $0.id == id }?.id
        destination = selectedCourseID == nil ? nil : .overview
    }

    public func selectDestination(_ value: CourseDestination?) {
        guard let course = selectedCourse else { destination = nil; return }
        guard Self.isValid(value, in: course) else { return }
        if let value { open(value) } else { destination = nil }
    }

    public func reload() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let root = root
        // Queued writes finish first, so the reload reads them.
        await waitForWrites()
        do {
            let (store, loaded, media, progress, lastOpened) = try await Task.detached {
                let store = try CourseStore(root: root)
                return (store, try store.listCourses(), try Self.snapshotMedia(store: store, root: root),
                        try store.allProgress(), try store.lastOpenedLectures())
            }.value
            self.store = store
            courses = loaded
            headerImages = media.headerImages
            articles = media.articles
            self.progress = progress
            lastOpenedLectures = lastOpened
            errorMessage = nil
            if let course = selectedCourse {
                if !Self.isValid(destination, in: course) { destination = .overview }
            } else {
                selectedCourseID = nil
                destination = nil
            }
        } catch {
            store = nil
            courses = []
            headerImages = [:]
            articles = [:]
            progress = [:]
            lastOpenedLectures = [:]
            selectedCourseID = nil
            destination = nil
            errorMessage = error.localizedDescription
        }
    }

    private static func isValid(_ value: CourseDestination?, in course: Course) -> Bool {
        let sections = course.learnerSections
        switch value {
        case let .section(sectionID):
            return sections.contains { $0.id == sectionID }
        case let .lecture(sectionID, lectureID):
            return sections.first { $0.id == sectionID }?.lectures.contains { $0.id == lectureID } == true
        case .overview, nil:
            return true
        }
    }

    /// Reads header images and article files from each installed manifest. A path outside the snapshot folder is ignored.
    nonisolated private static func snapshotMedia(store: CourseStore, root: URL) throws
        -> (headerImages: [String: [String: SectionHeaderImage]], articles: [String: [String: LectureArticle]]) {
        var images: [String: [String: SectionHeaderImage]] = [:]
        var articles: [String: [String: LectureArticle]] = [:]
        for (courseID, publication) in try store.publications() {
            guard let manifest = try? JSONDecoder().decode(CourseManifest.self, from: publication.manifest) else { continue }
            let folder = root.appending(path: publication.directory).standardizedFileURL
            for section in manifest.sections {
                let url = folder.appending(path: section.headerImage.path).standardizedFileURL
                if url.path.hasPrefix(folder.path + "/") {
                    images[courseID, default: [:]][section.id] = SectionHeaderImage(url: url, alt: section.headerImage.alt)
                }
                // Manifests saved before article support have no `article` field.
                for lecture in section.lectures {
                    guard let article = lecture.article, let path = LectureArticle.normalize(article.path) else { continue }
                    articles[courseID, default: [:]][lecture.id] = LectureArticle(folder: folder, path: path, images: article.images ?? [])
                }
            }
        }
        return (images, articles)
    }
}
