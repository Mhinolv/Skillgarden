import AppKit
import SwiftUI
import SkillgardenCore

/// One answer row. Quiz, assignment (#14) and spaced review (#17) questions share it.
/// Symbols carry the meaning, so the row never uses color alone.
struct ChoiceRow: View {
    let text: String
    let state: ChoiceState
    /// The 1-based position. Positions 1–9 get a number key.
    let number: Int
    let select: () -> Void

    private var symbol: String {
        switch state {
        case .normal, .dimmed: "circle"
        case .selected: "largecircle.fill.circle"
        case .correct: "checkmark.circle.fill"
        case .incorrect: "xmark.circle.fill"
        }
    }

    private var symbolStyle: AnyShapeStyle {
        switch state {
        case .normal, .dimmed: AnyShapeStyle(.secondary)
        case .selected: AnyShapeStyle(.tint)
        case .correct: AnyShapeStyle(.green)
        case .incorrect: AnyShapeStyle(.red)
        }
    }

    private var borderStyle: AnyShapeStyle {
        switch state {
        case .correct: AnyShapeStyle(.green)
        case .incorrect: AnyShapeStyle(.red)
        case .normal, .selected, .dimmed: AnyShapeStyle(.separator)
        }
    }

    private var accessibilityText: String {
        switch state {
        case .normal, .dimmed: text
        case .selected: "\(text), selected"
        case .correct(let picked): picked ? "\(text), selected, correct" : "\(text), correct"
        case .incorrect: "\(text), selected, incorrect"
        }
    }

    var body: some View {
        Button(action: select) {
            HStack(spacing: CourseStyle.spacing) {
                Image(systemName: symbol).foregroundStyle(symbolStyle)
                Text(text).frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .contentShape(.rect)
            .overlay(RoundedRectangle(cornerRadius: CourseStyle.cornerRadius).strokeBorder(borderStyle, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .opacity(state == .dimmed ? 0.6 : 1)
        .keyboardShortcut(number <= 9 ? KeyboardShortcut(KeyEquivalent(Character(String(number))), modifiers: []) : nil)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(state == .selected ? .isSelected : [])
    }
}

/// A question image: aspect fit, 320 pt high at most. The file loads off the main actor.
struct QuizImageView: View {
    let image: QuizImage
    @Environment(\.imageLoads) private var imageLoads
    @State private var loaded: NSImage?

    var body: some View {
        Group {
            if let loaded {
                Image(nsImage: loaded).resizable().aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "photo").font(.largeTitle).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            }
        }
        .frame(maxHeight: 320)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(image.alt)
        .accessibilityAddTraits(.isImage)
        .task(id: image.url) {
            loaded = nil
            imageLoads?.start()
            let url = image.url
            let data = await Task.detached { try? Data(contentsOf: url) }.value
            loaded = data.flatMap(NSImage.init(data:))
            imageLoads?.finish(loaded: loaded != nil)
        }
    }
}

/// The quiz lecture body: one question at a time, then the results screen.
struct QuizView: View {
    let attempt: QuizAttempt
    let perform: (QuizAction) -> Void

    private var count: Int { attempt.quiz.questions.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Quiz · \(count) \(count == 1 ? "question" : "questions")", systemImage: "checklist")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let question = attempt.question {
                questionView(question)
            } else {
                QuizResultsView(result: attempt.result) { perform(.retake) }
            }
        }
    }

    private func questionView(_ question: QuizQuestion) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: CourseStyle.spacing) {
                Text("Question \(attempt.index + 1) of \(count)").font(.subheadline).foregroundStyle(.secondary)
                ProgressView(value: Double(attempt.index + 1), total: Double(count))
                    .progressViewStyle(.linear)
                    .accessibilityHidden(true)
            }
            Text(question.prompt)
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if let image = question.image { QuizImageView(image: image) }
            VStack(spacing: CourseStyle.spacing) {
                ForEach(Array(question.choices.enumerated()), id: \.element.id) { index, choice in
                    ChoiceRow(text: choice.text, state: attempt.state(of: choice), number: index + 1) {
                        perform(.select(choiceID: choice.id))
                    }
                }
            }
            if let correct = attempt.isAnswerCorrect {
                VStack(alignment: .leading, spacing: 4) {
                    Text(correct ? "Correct" : "Not quite").font(.headline)
                    Text(question.explanation)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
            Group {
                if attempt.isSubmitted {
                    Button(attempt.isLastQuestion ? "See Results" : "Next Question") { perform(.next) }
                } else {
                    Button("Submit") { perform(.submit) }.disabled(attempt.selection == nil)
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
    }
}

/// The percent score and the skills to review.
struct QuizResultsView: View {
    let result: QuizResult
    let retake: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(result.percent)%").font(.largeTitle.weight(.bold))
                Text("\(result.correct) of \(result.total) correct").font(.title3).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            if result.weakSkills.isEmpty {
                Label {
                    Text("You answered every question correctly.")
                } icon: {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                }
            } else {
                SkillsToReviewList(skills: result.weakSkills)
            }
            Button("Retake Quiz", action: retake).buttonStyle(.bordered)
        }
    }
}

/// The "Skills to review" heading and one row for each weak skill. Quiz and interactive results share it.
struct SkillsToReviewList: View {
    let skills: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: CourseStyle.spacing) {
            Text("Skills to review").font(.headline).accessibilityAddTraits(.isHeader)
            ForEach(skills, id: \.self) { skill in
                Label {
                    Text(skill).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                }
            }
        }
    }
}

struct QuizView_Previews: PreviewProvider {
    static let quiz = Quiz(questions: [
        QuizQuestion(id: "q1", prompt: "Which section comes first?", objectiveTag: "Order course sections",
                     choices: [QuizChoice(id: "a", text: "The lowest order value"), QuizChoice(id: "b", text: "The newest")],
                     correctChoiceID: "a", explanation: "Sections sort by their order value."),
    ])

    static var previews: some View {
        var answered = QuizAttempt(quiz: quiz)
        answered.perform(.select(choiceID: "b"))
        answered.perform(.submit)
        return Group {
            QuizView(attempt: QuizAttempt(quiz: quiz)) { _ in }
            QuizView(attempt: answered) { _ in }
            QuizResultsView(result: QuizResult(correct: 4, total: 5, weakSkills: ["Order course sections"])) {}
        }
        .padding()
        .frame(width: 720)
    }
}
