import Foundation

/// Screens that `scripts/snapshot.sh` renders for QA. Add new screens here with the same name rule.
public enum SnapshotScreen: String, CaseIterable, Sendable {
    case libraryEmpty = "library-empty"
    case library
    case section
    case lecture
    case lectureComplete = "lecture-complete"
    /// The fixture course, which has a light theme. The learner opened a lecture, so "Resume" shows.
    case courseLanding = "course-landing"
    /// The fixture course with `theme.appearance: dark` and a light accent. No lecture is opened, so "Start Course" shows.
    case courseLandingDarkTheme = "course-landing-dark-theme"
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

    /// The accent of the dark-theme fixture copy. It has more than 3:1 contrast on the dark background.
    public static let darkThemeAccent = "#7FD3A0"

    /// Writes the store that a screen needs into `root` and returns the course to select, if any.
    public static func seedStore(for screen: SnapshotScreen, root: URL, fixture: URL) throws -> String? {
        switch screen {
        case .libraryEmpty:
            _ = try CourseStore(root: root)
            return nil
        case .library, .section, .lecture, .lectureComplete, .courseLanding:
            // A real publish installs the media snapshot and image metadata, so the course and header images load.
            let id = try CoursePublisher.publish(courseFolder: fixture, root: root).id
            let store = try CourseStore(root: root)
            // Mixed completion: one of the two learner lectures is complete.
            if screen == .library || screen == .lectureComplete { try store.setCompleted(true, courseID: id, lectureID: "welcome") }
            if screen == .courseLanding { try store.saveLastOpenedLecture(courseID: id, lectureID: "read") }
            return id
        case .courseLandingDarkTheme:
            let copy = FileManager.default.temporaryDirectory.appending(path: "SkillgardenDarkFixture-\(UUID())")
            defer { try? FileManager.default.removeItem(at: copy) }
            try FileManager.default.copyItem(at: fixture, to: copy)
            let manifest = copy.appending(path: "skillgarden.yaml")
            let text = try String(contentsOf: manifest, encoding: .utf8)
                .replacingOccurrences(of: "appearance: light", with: "appearance: dark")
                .replacingOccurrences(of: "accent_color: '#286644'", with: "accent_color: '\(darkThemeAccent)'")
            try text.write(to: manifest, atomically: true, encoding: .utf8)
            return try CoursePublisher.publish(courseFolder: copy, root: root).id
        }
    }

    /// The page to open after the course is selected. The fixture lecture has a `recommended_next` target.
    public static func destination(for screen: SnapshotScreen) -> CourseDestination? {
        switch screen {
        case .libraryEmpty, .library: nil
        case .section: .section(sectionID: "plan")
        case .lecture, .lectureComplete: .lecture(sectionID: "plan", lectureID: "welcome")
        case .courseLanding, .courseLandingDarkTheme: .overview
        }
    }
}
