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
    /// Course page fields and theme by course id. Courses without an installed snapshot have none.
    public private(set) var landings: [String: CourseLanding] = [:]
    public let root: URL

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

    public var selectedLanding: CourseLanding? {
        selectedCourseID.flatMap { landings[$0] }
    }

    public func headerImage(forSection sectionID: String) -> SectionHeaderImage? {
        selectedCourseID.flatMap { headerImages[$0]?[sectionID] }
    }

    public func goToPreviousLecture() { if let previousLecture { destination = previousLecture } }
    public func goToNextLecture() { if let nextLecture { destination = nextLecture } }
    public func goToNudge() { if let nudge { destination = nudge.destination } }

    public func selectCourse(_ id: String?) {
        guard id != selectedCourseID else { return }
        selectedCourseID = courses.first { $0.id == id }?.id
        destination = selectedCourseID == nil ? nil : .overview
    }

    public func selectDestination(_ value: CourseDestination?) {
        guard let course = selectedCourse else { destination = nil; return }
        guard Self.isValid(value, in: course) else { return }
        destination = value
    }

    public func reload() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let root = root
        do {
            let (loaded, installed) = try await Task.detached {
                let store = try CourseStore(root: root)
                return (try store.listCourses(), try Self.installedData(store: store, root: root))
            }.value
            courses = loaded
            headerImages = installed.headerImages
            landings = installed.landings
            errorMessage = nil
            if let course = selectedCourse {
                if !Self.isValid(destination, in: course) { destination = .overview }
            } else {
                selectedCourseID = nil
                destination = nil
            }
        } catch {
            courses = []
            headerImages = [:]
            landings = [:]
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

    /// Reads header images and course page fields from each installed manifest.
    /// A header image path outside the snapshot folder is ignored.
    nonisolated private static func installedData(store: CourseStore, root: URL) throws
        -> (headerImages: [String: [String: SectionHeaderImage]], landings: [String: CourseLanding]) {
        var images: [String: [String: SectionHeaderImage]] = [:]
        var landings: [String: CourseLanding] = [:]
        for (courseID, publication) in try store.publications() {
            guard let manifest = try? JSONDecoder().decode(CourseManifest.self, from: publication.manifest) else { continue }
            landings[courseID] = CourseLanding(manifest: manifest)
            let folder = root.appending(path: publication.directory).standardizedFileURL
            for section in manifest.sections {
                let url = folder.appending(path: section.headerImage.path).standardizedFileURL
                guard url.path.hasPrefix(folder.path + "/") else { continue }
                images[courseID, default: [:]][section.id] = SectionHeaderImage(url: url, alt: section.headerImage.alt)
            }
        }
        return (images, landings)
    }
}
