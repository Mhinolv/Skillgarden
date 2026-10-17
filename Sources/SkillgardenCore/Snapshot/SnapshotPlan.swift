import Foundation

/// Screens that `scripts/snapshot.sh` renders for QA. Add new screens here with the same name rule.
public enum SnapshotScreen: String, CaseIterable, Sendable {
    case libraryEmpty = "library-empty"
    case library
    case section
    case lecture
    case lectureComplete = "lecture-complete"
    case courseLanding = "course-landing"
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

    /// Writes the store that a screen needs into `root` and returns the course to select, if any.
    public static func seedStore(for screen: SnapshotScreen, root: URL, fixture: URL) throws -> String? {
        let store = try CourseStore(root: root)
        switch screen {
        case .libraryEmpty:
            return nil
        case .library:
            let course = course(from: try ManifestLoader.load(courseFolder: fixture))
            try store.saveCourse(course)
            // Mixed completion: one of the two learner lectures is complete.
            try store.setCompleted(true, courseID: course.id, lectureID: "welcome")
            return course.id
        case .section, .lecture, .lectureComplete, .courseLanding:
            // A real publish installs the media snapshot, so the section header image loads.
            let id = try CoursePublisher.publish(courseFolder: fixture, root: root).id
            if screen == .lectureComplete { try store.setCompleted(true, courseID: id, lectureID: "welcome") }
            if screen == .courseLanding { try store.saveLastOpenedLecture(courseID: id, lectureID: "read") }
            return id
        }
    }

    /// The page to open after the course is selected. The fixture lecture has a `recommended_next` target.
    public static func destination(for screen: SnapshotScreen) -> CourseDestination? {
        switch screen {
        case .libraryEmpty, .library: nil
        case .section: .section(sectionID: "plan")
        case .lecture, .lectureComplete: .lecture(sectionID: "plan", lectureID: "welcome")
        case .courseLanding: .overview
        }
    }

    static func course(from manifest: CourseManifest) -> Course {
        Course(id: manifest.id, title: manifest.title, subtitle: manifest.subtitle, state: state(manifest.state),
               sections: manifest.sections.map { section in
                   CourseSection(id: section.id, title: section.title, objective: section.objective, order: section.order,
                                 state: state(section.state), lectures: section.lectures.map { lecture in
                                     Lecture(id: lecture.id, title: lecture.title, type: LectureType(rawValue: lecture.type.rawValue)!,
                                             objective: lecture.objective, order: lecture.order, state: state(lecture.state),
                                             recommendedNext: lecture.recommendedNext)
                                 })
               })
    }

    private static func state(_ value: ManifestState) -> PublicationState {
        value == .published ? .published : .draft
    }
}
