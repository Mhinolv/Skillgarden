import Foundation
import Observation

public enum CourseDestination: Hashable, Sendable {
    case overview
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
    public let root: URL

    public init(root: URL = Skillgarden.defaultDataDirectory) {
        self.root = root
    }

    public var selectedCourse: Course? {
        courses.first { $0.id == selectedCourseID }
    }

    public var selectedLecture: Lecture? {
        guard case let .lecture(sectionID, lectureID) = destination else { return nil }
        return selectedCourse?.sections.first { $0.id == sectionID }?.lectures.first { $0.id == lectureID }
    }

    public func selectCourse(_ id: String?) {
        guard id != selectedCourseID else { return }
        selectedCourseID = courses.first { $0.id == id }?.id
        destination = selectedCourseID == nil ? nil : .overview
    }

    public func selectDestination(_ value: CourseDestination?) {
        guard let course = selectedCourse else { destination = nil; return }
        if case let .lecture(sectionID, lectureID) = value {
            guard course.sections.first(where: { $0.id == sectionID })?.lectures.contains(where: { $0.id == lectureID }) == true else {
                return
            }
        }
        destination = value
    }

    public func reload() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let root = root
        do {
            let loaded = try await Task.detached {
                try CourseStore(root: root).listCourses()
            }.value
            courses = loaded
            errorMessage = nil
            if selectedCourse == nil {
                selectedCourseID = nil
                destination = nil
            } else if case .lecture = destination, selectedLecture == nil {
                destination = .overview
            }
        } catch {
            courses = []
            selectedCourseID = nil
            destination = nil
            errorMessage = error.localizedDescription
        }
    }
}
