import Foundation

/// The progress of one course on its Library tile. Only learner lectures count.
public struct CourseSummary: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case noLectures, new, inProgress, done
    }

    /// One stone per learner lecture, in outline order.
    public let stones: [SteppingStone]
    public let completed: Int
    /// The first incomplete learner lecture. Nil if the course has no lectures or all are done.
    public let nextLecture: Lecture?
    public let nextDestination: CourseDestination?

    public init(course: Course, progress: [String: LectureProgress]) {
        let lectures = course.learnerLectures
        let isComplete = { (id: String) in progress[id]?.completed == true }
        stones = SteppingStone.states(lectureIDs: lectures.map(\.lecture.id), isComplete: isComplete)
        completed = stones.filter { $0 == .done }.count
        let next = lectures.first { !isComplete($0.lecture.id) }
        nextLecture = next?.lecture
        nextDestination = next.map { .lecture(sectionID: $0.sectionID, lectureID: $0.lecture.id) }
    }

    public var total: Int { stones.count }

    public var status: Status {
        if total == 0 { return .noLectures }
        if completed == total { return .done }
        return completed == 0 ? .new : .inProgress
    }

    /// The percent of complete lectures, rounded down. 0 if the course has no lectures.
    public var percent: Int { total == 0 ? 0 : completed * 100 / total }

    /// The tile meta line.
    public var meta: String {
        let count = "\(total) \(total == 1 ? "lecture" : "lectures")"
        switch status {
        case .noLectures: return "No lectures yet"
        case .new: return count
        case .inProgress: return "Next: \(nextLecture?.title ?? "")"
        case .done: return "\(count) · all done"
        }
    }

    /// The tile status at the end of the stones. Nil if the course has no lectures.
    public var statusText: String? {
        switch status {
        case .noLectures: nil
        case .new: "New"
        case .inProgress: "\(percent)%"
        case .done: "Done"
        }
    }
}

/// One cell of the Library bento grid.
public struct BentoCell: Equatable, Sendable {
    public let row: Int
    public let column: Int

    public init(row: Int, column: Int) {
        self.row = row
        self.column = column
    }
}

/// The Library bento grid: an optional 2×2 hero at the top leading corner, then 1×1 tiles in reading order.
public enum LibraryBento {
    /// The grid has 4 columns at this width or wider, else 3.
    public static let wideWidth: Double = 1180

    public static func columns(forWidth width: Double) -> Int {
        width >= wideWidth ? 4 : 3
    }

    /// The cells of `count` tiles. With a hero, the tiles fill the columns to the right of it first.
    public static func tileCells(count: Int, columns: Int, hasHero: Bool) -> [BentoCell] {
        precondition(columns > 2, "The hero needs 2 columns and the tiles need at least 1 more.")
        var cells: [BentoCell] = []
        var row = 0
        while cells.count < count {
            for column in 0..<columns where cells.count < count && !(hasHero && row < 2 && column < 2) {
                cells.append(BentoCell(row: row, column: column))
            }
            row += 1
        }
        return cells
    }

    /// The Library header meta line, for example "6 courses · 3 in progress".
    public static func meta(courses: Int, inProgress: Int) -> String {
        "\(courses) \(courses == 1 ? "course" : "courses") · \(inProgress) in progress"
    }
}
