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

/// One stone per learner section in a course progress row. The stone fills as the learner completes its lectures.
public struct SectionStone: Equatable, Sendable {
    public let completed: Int
    public let total: Int
    /// True for the first section that is not done.
    public let isNext: Bool

    public init(completed: Int, total: Int, isNext: Bool) {
        self.completed = completed
        self.total = total
        self.isNext = isNext
    }

    public var isDone: Bool { completed >= total }

    /// The filled part of the stone, from 0 to 1.
    public var fraction: Double { total == 0 ? 0 : min(Double(completed) / Double(total), 1) }

    /// One stone per learner section with at least one learner lecture, in outline order.
    public static func stones(course: Course, progress: [String: LectureProgress]) -> [SectionStone] {
        var foundNext = false
        return course.learnerSections.filter { !$0.lectures.isEmpty }.map { section in
            let completed = section.lectures.filter { progress[$0.id]?.completed == true }.count
            let isNext = !foundNext && completed < section.lectures.count
            if isNext { foundNext = true }
            return SectionStone(completed: completed, total: section.lectures.count, isNext: isNext)
        }
    }

    /// The count next to the stones, for example "2 of 22 done". Lectures count, not sections.
    public static func countText(_ stones: [SectionStone]) -> String {
        "\(stones.map(\.completed).reduce(0, +)) of \(stones.map(\.total).reduce(0, +)) done"
    }

    /// The VoiceOver label for a row, for example "2 of 22 lectures done, 0 of 5 sections done".
    public static func accessibilityLabel(_ stones: [SectionStone]) -> String {
        let completed = stones.map(\.completed).reduce(0, +)
        let total = stones.map(\.total).reduce(0, +)
        let sections = stones.filter(\.isDone).count
        return "\(completed) of \(total) \(total == 1 ? "lecture" : "lectures") done, "
            + "\(sections) of \(stones.count) \(stones.count == 1 ? "section" : "sections") done"
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

/// Finds the play tick that passes 90% of a video, so the lecture completes automatically (#79).
/// Only a tick of continuous play counts. A seek past the mark does not complete the lecture.
public struct VideoAutoComplete: Equatable, Sendable {
    /// The part of the video length that the learner must play past.
    public static let threshold = 0.9
    /// The largest forward step between two play ticks that counts as play. A larger step is a seek.
    public static let maxPlayStep: Double = 2
    private var lastSeconds: Double?

    public init() {}

    /// Returns true when this play tick passes `threshold` of `duration` from the previous play tick.
    /// A tick that does not play, for example during a seek, starts the count again.
    public mutating func tick(seconds: Double, duration: Double?, isPlaying: Bool) -> Bool {
        let last = lastSeconds
        lastSeconds = isPlaying && seconds.isFinite ? seconds : nil
        guard isPlaying, let last, seconds.isFinite, let duration, duration.isFinite, duration > 0 else { return false }
        let mark = duration * Self.threshold
        let step = seconds - last
        return last < mark && seconds >= mark && step > 0 && step <= Self.maxPlayStep
    }

    /// Forgets the previous tick. A seek calls this.
    public mutating func reset() { lastSeconds = nil }
}
