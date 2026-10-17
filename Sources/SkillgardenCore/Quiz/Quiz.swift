import Foundation

/// A question image, resolved inside the installed course snapshot.
public struct QuizImage: Equatable, Sendable {
    public let url: URL
    public let alt: String

    public init(url: URL, alt: String) {
        self.url = url
        self.alt = alt
    }
}

public struct QuizChoice: Identifiable, Equatable, Sendable {
    public let id: String
    public let text: String

    public init(id: String, text: String) {
        self.id = id
        self.text = text
    }
}

public struct QuizQuestion: Identifiable, Equatable, Sendable {
    public let id: String
    public let prompt: String
    public let image: QuizImage?
    /// A readable skill name. The results screen shows it as written.
    public let objectiveTag: String
    public let choices: [QuizChoice]
    public let correctChoiceID: String
    public let explanation: String

    public init(id: String, prompt: String, image: QuizImage? = nil, objectiveTag: String, choices: [QuizChoice],
                correctChoiceID: String, explanation: String) {
        self.id = id
        self.prompt = prompt
        self.image = image
        self.objectiveTag = objectiveTag
        self.choices = choices
        self.correctChoiceID = correctChoiceID
        self.explanation = explanation
    }
}

public struct Quiz: Equatable, Sendable {
    public let questions: [QuizQuestion]

    public init(questions: [QuizQuestion]) {
        self.questions = questions
    }

    /// Resolves question images inside `folder`. An image path outside the folder is ignored.
    public init(manifest: ManifestQuiz, folder: URL) {
        let folder = folder.standardizedFileURL
        questions = manifest.questions.map { question in
            let image = question.image.flatMap { image -> QuizImage? in
                let url = folder.appending(path: image.path).standardizedFileURL
                return url.path.hasPrefix(folder.path + "/") ? QuizImage(url: url, alt: image.alt) : nil
            }
            return QuizQuestion(id: question.id, prompt: question.prompt, image: image, objectiveTag: question.objectiveTag,
                                choices: question.choices.map { QuizChoice(id: $0.id, text: $0.text) },
                                correctChoiceID: question.correctChoiceID, explanation: question.explanation)
        }
    }
}

/// The answer to one question, tagged with its skill.
public struct SkillOutcome: Equatable, Sendable {
    public let objectiveTag: String
    public let correct: Bool

    public init(objectiveTag: String, correct: Bool) {
        self.objectiveTag = objectiveTag
        self.correct = correct
    }
}

public enum SkillReview {
    /// The weak-skill rule. A skill is weak if the learner answered one or more of its questions wrong.
    /// Tags are trimmed, empty tags are ignored, and each tag shows once, in the order of its first wrong answer.
    public static func weakSkills(_ outcomes: [SkillOutcome]) -> [String] {
        var seen: Set<String> = []
        return outcomes.compactMap { outcome in
            let tag = outcome.objectiveTag.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !outcome.correct, !tag.isEmpty, seen.insert(tag).inserted else { return nil }
            return tag
        }
    }
}

/// The score of one finished quiz attempt.
public struct QuizResult: Equatable, Sendable {
    public let correct: Int
    public let total: Int
    /// Objective tags of wrong answers, from `SkillReview.weakSkills`.
    public let weakSkills: [String]

    public init(correct: Int, total: Int, weakSkills: [String]) {
        self.correct = correct
        self.total = total
        self.weakSkills = weakSkills
    }

    /// The percent of correct answers, rounded to the nearest whole number. 0 if the quiz has no questions.
    public var percent: Int {
        total == 0 ? 0 : Int((Double(correct) * 100 / Double(total)).rounded())
    }

    /// Counts correct choices. `answers` holds a choice id by question id. A question without an answer is wrong.
    public init(quiz: Quiz, answers: [String: String]) {
        let outcomes = quiz.questions.map {
            SkillOutcome(objectiveTag: $0.objectiveTag, correct: answers[$0.id] == $0.correctChoiceID)
        }
        self.init(correct: outcomes.filter(\.correct).count, total: outcomes.count,
                  weakSkills: SkillReview.weakSkills(outcomes))
    }
}

/// How a choice row looks.
public enum ChoiceState: Equatable, Sendable {
    case normal, selected
    /// After Submit: the correct choice. `picked` is true if the learner selected it.
    case correct(picked: Bool)
    /// After Submit: the wrong choice that the learner selected.
    case incorrect
    /// After Submit: any other choice.
    case dimmed
}

public enum QuizAction: Equatable, Sendable {
    case select(choiceID: String)
    /// Number keys 1–9 select the choice at that 1-based position.
    case selectNumber(Int)
    case submit
    /// "Next Question", or "See Results" on the last question.
    case next
    case retake
}

/// One attempt at a quiz, one question at a time. The learner selects, submits, then moves on.
public struct QuizAttempt: Equatable, Sendable {
    public let quiz: Quiz
    public private(set) var index = 0
    public private(set) var selection: String?
    public private(set) var isSubmitted = false
    public private(set) var showsResults: Bool
    /// Submitted choice ids by question id.
    public private(set) var answers: [String: String] = [:]

    public init(quiz: Quiz) {
        self.quiz = quiz
        showsResults = quiz.questions.isEmpty
    }

    /// The current question. Nil on the results screen.
    public var question: QuizQuestion? {
        showsResults || !quiz.questions.indices.contains(index) ? nil : quiz.questions[index]
    }

    public var isLastQuestion: Bool { index == quiz.questions.count - 1 }

    /// After Submit: true if the submitted choice is correct.
    public var isAnswerCorrect: Bool? {
        guard isSubmitted, let question else { return nil }
        return answers[question.id] == question.correctChoiceID
    }

    public var result: QuizResult { QuizResult(quiz: quiz, answers: answers) }

    public func state(of choice: QuizChoice) -> ChoiceState {
        guard let question else { return .normal }
        guard isSubmitted else { return choice.id == selection ? .selected : .normal }
        if choice.id == question.correctChoiceID { return .correct(picked: choice.id == answers[question.id]) }
        return choice.id == answers[question.id] ? .incorrect : .dimmed
    }

    /// Applies one learner action. Actions that do not fit the current step do nothing.
    public mutating func perform(_ action: QuizAction) {
        switch action {
        case let .select(choiceID):
            guard !isSubmitted, let question, question.choices.contains(where: { $0.id == choiceID }) else { return }
            selection = choiceID
        case let .selectNumber(number):
            guard let choices = question?.choices, choices.indices.contains(number - 1) else { return }
            perform(.select(choiceID: choices[number - 1].id))
        case .submit:
            guard !isSubmitted, let question, let selection else { return }
            answers[question.id] = selection
            isSubmitted = true
        case .next:
            guard isSubmitted else { return }
            if isLastQuestion {
                showsResults = true
            } else {
                index += 1
            }
            selection = nil
            isSubmitted = false
        case .retake:
            self = QuizAttempt(quiz: quiz)
        }
    }
}
