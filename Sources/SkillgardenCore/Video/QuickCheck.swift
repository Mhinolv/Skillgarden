import Foundation

/// One ungraded question after a video. The manifest gives no id, so the id is the position in the lecture.
public struct QuickCheck: Identifiable, Equatable, Sendable {
    /// A video lecture has one or two checks.
    public static let maximumCount = 2

    public let id: Int
    public let prompt: String
    public let choices: [QuizChoice]
    public let correctChoiceID: String
    /// Nil when the manifest has no explanation.
    public let explanation: String?

    public init(id: Int, prompt: String, choices: [QuizChoice], correctChoiceID: String, explanation: String? = nil) {
        self.id = id
        self.prompt = prompt
        self.choices = choices
        self.correctChoiceID = correctChoiceID
        self.explanation = explanation
    }

    /// Checks in manifest order. A blank explanation counts as none.
    public static func checks(manifest: [ManifestQuickCheck]?) -> [QuickCheck] {
        (manifest ?? []).enumerated().map { index, check in
            let explanation = check.explanation?.trimmingCharacters(in: .whitespacesAndNewlines)
            return QuickCheck(id: index, prompt: check.prompt, choices: check.choices.map { QuizChoice(id: $0.id, text: $0.text) },
                              correctChoiceID: check.correctChoiceID, explanation: explanation?.isEmpty == false ? explanation : nil)
        }
    }
}

/// The learner's answers to the quick checks of one video. One click answers a check and locks it.
/// There is no score. The app keeps the answers for the session only.
public struct QuickCheckSession: Equatable, Sendable {
    public let checks: [QuickCheck]
    /// Choice ids by check id.
    public private(set) var answers: [Int: String] = [:]

    public init(checks: [QuickCheck]) {
        self.checks = checks
    }

    /// The button title of the controls row, for example "Quick Check (2)".
    public var buttonTitle: String { "Quick Check (\(checks.count))" }

    /// The first answer locks the check. Unknown checks and choices do nothing.
    public mutating func answer(checkID: Int, choiceID: String) {
        guard answers[checkID] == nil, let check = checks.first(where: { $0.id == checkID }),
              check.choices.contains(where: { $0.id == choiceID }) else { return }
        answers[checkID] = choiceID
    }

    /// "Try Again" clears the answer of one check only.
    public mutating func tryAgain(checkID: Int) {
        answers[checkID] = nil
    }

    /// True if the answer is correct. Nil before the learner answers.
    public func isCorrect(_ checkID: Int) -> Bool? {
        guard let choice = answers[checkID], let check = checks.first(where: { $0.id == checkID }) else { return nil }
        return choice == check.correctChoiceID
    }

    /// "Correct" or "Not quite". Nil before the learner answers.
    public func resultLine(_ checkID: Int) -> String? {
        isCorrect(checkID).map { $0 ? "Correct" : "Not quite" }
    }

    /// The explanation after a correct or a wrong answer. Nil before the learner answers or if the check has none.
    public func shownExplanation(_ checkID: Int) -> String? {
        guard answers[checkID] != nil else { return nil }
        return checks.first { $0.id == checkID }?.explanation
    }

    /// The same marks as a submitted quiz question.
    public func state(of choice: QuizChoice, in checkID: Int) -> ChoiceState {
        guard let picked = answers[checkID], let check = checks.first(where: { $0.id == checkID }) else { return .normal }
        if choice.id == check.correctChoiceID { return .correct(picked: choice.id == picked) }
        return choice.id == picked ? .incorrect : .dimmed
    }
}
