import Foundation

/// One quiz question that the spaced review shows, with the quiz lecture it comes from.
public struct ReviewQuestion: Identifiable, Equatable, Sendable {
    public let lectureID: String
    public let lectureTitle: String
    public let question: QuizQuestion

    /// Question ids are unique only in their quiz, so the id includes the lecture id.
    public var id: String { "\(lectureID)/\(question.id)" }

    public init(lectureID: String, lectureTitle: String, question: QuizQuestion) {
        self.lectureID = lectureID
        self.lectureTitle = lectureTitle
        self.question = question
    }
}

/// Spaced review: before a section opens for the first time, the learner answers questions from earlier quizzes.
public enum SpacedReview {
    public static let minimumCount = 2
    public static let maximumCount = 3

    /// The questions of the learner quiz lectures in the sections before `sectionID`, in outline order.
    /// Empty if the learner cannot see the section.
    public static func candidates(course: Course, sectionID: String, quizzes: [String: Quiz]) -> [ReviewQuestion] {
        let sections = course.learnerSections
        guard let index = sections.firstIndex(where: { $0.id == sectionID }) else { return [] }
        var seen: Set<String> = []
        return sections[..<index].flatMap(\.lectures).filter { $0.type == .quiz }.flatMap { lecture in
            (quizzes[lecture.id]?.questions ?? []).map {
                ReviewQuestion(lectureID: lecture.id, lectureTitle: lecture.title, question: $0)
            }
        }
        .filter { seen.insert($0.id).inserted }
    }

    /// Two or three distinct random questions: three if there are three or more. Empty if there are fewer than two.
    public static func select(from candidates: [ReviewQuestion], using generator: inout some RandomNumberGenerator) -> [ReviewQuestion] {
        var seen: Set<String> = []
        let distinct = candidates.filter { seen.insert($0.id).inserted }
        guard distinct.count >= minimumCount else { return [] }
        return Array(distinct.shuffled(using: &generator).prefix(maximumCount))
    }
}

/// The open review sheet of one section. One click answers a question. The review saves no grade.
public struct SectionReview: Identifiable, Equatable, Sendable {
    public let courseID: String
    public let sectionID: String
    public let sectionTitle: String
    public let questions: [ReviewQuestion]
    /// Choice ids by review question id.
    public private(set) var answers: [String: String] = [:]

    public var id: String { "\(courseID)/\(sectionID)" }

    public init(courseID: String, sectionID: String, sectionTitle: String, questions: [ReviewQuestion]) {
        self.courseID = courseID
        self.sectionID = sectionID
        self.sectionTitle = sectionTitle
        self.questions = questions
    }

    /// The first answer counts. Unknown questions and choices do nothing.
    public mutating func answer(questionID: String, choiceID: String) {
        guard answers[questionID] == nil,
              let item = questions.first(where: { $0.id == questionID }),
              item.question.choices.contains(where: { $0.id == choiceID }) else { return }
        answers[questionID] = choiceID
    }

    /// True if the answer is correct. Nil before the learner answers.
    public func isCorrect(_ questionID: String) -> Bool? {
        guard let choice = answers[questionID], let item = questions.first(where: { $0.id == questionID }) else { return nil }
        return choice == item.question.correctChoiceID
    }

    /// The same marks as a submitted quiz question.
    public func state(of choice: QuizChoice, in questionID: String) -> ChoiceState {
        guard let picked = answers[questionID], let item = questions.first(where: { $0.id == questionID }) else { return .normal }
        if choice.id == item.question.correctChoiceID { return .correct(picked: choice.id == picked) }
        return choice.id == picked ? .incorrect : .dimmed
    }
}

/// A small seeded generator (SplitMix64). Tests and the snapshot harness use it for a fixed question order.
public struct SeededRandomNumberGenerator: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
