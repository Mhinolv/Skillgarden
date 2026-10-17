import Foundation

/// Complete lectures of one section. Only lectures in the section count, so draft and removed lectures are ignored.
public struct SectionProgress: Equatable, Sendable {
    public let completed: Int
    public let total: Int

    public init(section: CourseSection, progress: [String: LectureProgress]) {
        total = section.lectures.count
        completed = section.lectures.filter { progress[$0.id]?.completed == true }.count
    }

    /// The percent of complete lectures, rounded down. Nil if the section has no lectures.
    public var percent: Int? {
        total == 0 ? nil : completed * 100 / total
    }

    public var fraction: Double {
        total == 0 ? 0 : Double(completed) / Double(total)
    }
}

/// The state of one lecture in a stepping-stone progress row.
public enum SteppingStone: Equatable, Sendable {
    case done, next, todo, missed

    /// One stone per lecture, in order. The first incomplete lecture is `next`. The other incomplete lectures are `todo`.
    public static func states(lectureIDs: [String], isComplete: (String) -> Bool) -> [SteppingStone] {
        var foundNext = false
        return lectureIDs.map { id in
            if isComplete(id) { return .done }
            if foundNext { return .todo }
            foundNext = true
            return .next
        }
    }

    /// The VoiceOver label for a row, for example "7 of 16 lectures complete".
    public static func accessibilityLabel(_ states: [SteppingStone]) -> String {
        "\(states.filter { $0 == .done }.count) of \(states.count) \(states.count == 1 ? "lecture" : "lectures") complete"
    }
}

/// Rules for the saved video position.
public enum PlaybackResume {
    /// The player saves the position at this interval, on pause and when the learner leaves the lecture.
    public static let saveInterval: Double = 5
    /// A saved position this close to the start or the end starts the video at 0.
    public static let margin: Double = 5

    /// The time to seek to when a video opens. `duration` is nil until the player knows it.
    public static func startSeconds(saved: Double, duration: Double?) -> Double {
        guard saved.isFinite, saved >= margin else { return 0 }
        if let duration, duration.isFinite, saved > duration - margin { return 0 }
        return saved
    }
}
