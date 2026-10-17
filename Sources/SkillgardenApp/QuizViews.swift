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
    /// The review sheet shows more than one question, so its rows have no number keys.
    var usesNumberKey = true
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
        .keyboardShortcut(usesNumberKey && number <= 9 ? KeyboardShortcut(KeyEquivalent(Character(String(number))), modifiers: []) : nil)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(state == .selected ? .isSelected : [])
    }
}

/// A question image: aspect fit, 320 pt high at most. The file loads off the main actor.
struct QuizImageView: View {
    let image: QuizImage
    var maxHeight: CGFloat = 320
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
        .frame(maxHeight: maxHeight)
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
                AnswerFeedback(correct: correct, explanation: question.explanation)
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

/// The "Correct" or "Not quite" line and the explanation. Quiz and review questions share it.
struct AnswerFeedback: View {
    let correct: Bool
    let explanation: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(correct ? "Correct" : "Not quite").font(.headline)
            Text(explanation)
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The spaced review sheet: questions from earlier quizzes before a section opens. No score.
struct SectionReviewSheet: View {
    let review: SectionReview
    let answer: (_ questionID: String, _ choiceID: String) -> Void
    let close: () -> Void
    @Environment(\.gardenPalette) private var palette
    @AccessibilityFocusState private var titleFocused: Bool

    private var count: Int { review.questions.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Label("Quick review", systemImage: "arrow.counterclockwise.circle")
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($titleFocused)
                Text("Answer \(count) \(count == 1 ? "question" : "questions") from earlier lectures before you start \(review.sectionTitle).")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // A tall review scrolls. A short review takes only the height that it needs.
            ViewThatFits(in: .vertical) {
                questions
                ScrollView { questions }
            }
            HStack(spacing: CourseStyle.spacing) {
                Spacer()
                Button("Skip Review", action: close)
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
                Button("Continue to Section", action: close)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560)
        .tint(palette.accent)
        .background(palette.isCourseThemed ? palette.page : .clear)
        .onAppear { titleFocused = true }
    }

    private var questions: some View {
        VStack(alignment: .leading, spacing: 20) {
            ForEach(review.questions) { item in
                questionView(item)
            }
        }
    }

    private func questionView(_ item: ReviewQuestion) -> some View {
        VStack(alignment: .leading, spacing: CourseStyle.spacing) {
            Text("From \(item.lectureTitle)").font(.caption).foregroundStyle(.secondary)
            Text(item.question.prompt)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            if let image = item.question.image { QuizImageView(image: image, maxHeight: 200) }
            ForEach(Array(item.question.choices.enumerated()), id: \.element.id) { index, choice in
                ChoiceRow(text: choice.text, state: review.state(of: choice, in: item.id), number: index + 1,
                          usesNumberKey: false) {
                    answer(item.id, choice.id)
                }
            }
            if let correct = review.isCorrect(item.id) {
                AnswerFeedback(correct: correct, explanation: item.question.explanation)
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
        var review = SectionReview(courseID: "c", sectionID: "s", sectionTitle: "Plan the course", questions: quiz.questions.map {
            ReviewQuestion(lectureID: "check", lectureTitle: "Check the plan", question: $0)
        })
        review.answer(questionID: "check/q1", choiceID: "a")
        return Group {
            QuizView(attempt: QuizAttempt(quiz: quiz)) { _ in }
            QuizView(attempt: answered) { _ in }
            QuizResultsView(result: QuizResult(correct: 4, total: 5, weakSkills: ["Order course sections"])) {}
            SectionReviewSheet(review: review, answer: { _, _ in }, close: {})
        }
        .padding()
        .frame(width: 720)
    }
}
