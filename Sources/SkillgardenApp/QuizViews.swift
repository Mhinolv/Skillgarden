import AppKit
import SwiftUI
import SkillgardenCore

/// One answer row: a key badge and the choice text with a hairline. A selected row has a tint and an accent ring. Quiz, assignment (#14) and spaced review (#17) questions share it.
/// The badge symbols carry the meaning, so the row never uses color alone.
struct ChoiceRow: View {
    let text: String
    let state: ChoiceState
    /// The 1-based position. Positions 1–9 get a number key.
    let number: Int
    /// The review sheet shows more than one question, so its rows have no number keys.
    var usesNumberKey = true
    let select: () -> Void
    @Environment(\.gardenPalette) private var palette
    /// True while a notes field has focus (#181). The number keys then type text.
    @Environment(\.textEntryFocused) private var textEntryFocused

    private static let radius = GardenRadius.button

    private var fill: Color {
        switch state {
        case .correct, .selected: palette.tint
        case .incorrect: palette.wrongFill
        case .normal, .dimmed: palette.card
        }
    }

    private var badgeFill: Color {
        switch state {
        case .normal, .dimmed: palette.fill
        case .selected, .correct: palette.accent
        case .incorrect: palette.wrong
        }
    }

    private var badgeText: Color {
        switch state {
        case .normal, .dimmed: palette.muted
        case .selected, .correct: palette.onAccent
        case .incorrect: .white
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
            HStack(spacing: 10) {
                badge
                Text(text)
                    .font(GardenFont.body)
                    .foregroundStyle(palette.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, GardenSpacing.s)
            .background(fill, in: .garden(Self.radius))
            .overlay {
                RoundedRectangle.garden(Self.radius)
                    .strokeBorder(state == .selected ? palette.accent : palette.line, lineWidth: state == .selected ? 1.5 : 1)
            }
            .contentShape(.garden(Self.radius))
        }
        .buttonStyle(.plain)
        .contentShape(.focusEffect, .garden(Self.radius))
        .opacity(state == .dimmed ? 0.6 : 1)
        .keyboardShortcut(usesNumberKey && number <= 9 && !textEntryFocused ? KeyboardShortcut(KeyEquivalent(Character(String(number))), modifiers: []) : nil)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(state == .selected ? .isSelected : [])
    }

    /// The key number, or a check or a cross after Submit.
    private var badge: some View {
        Group {
            switch state {
            case .correct: Image(systemName: "checkmark")
            case .incorrect: Image(systemName: "xmark")
            case .normal, .selected, .dimmed: Text(number <= 9 ? "\(number)" : "")
            }
        }
        .font(.system(size: 11, weight: .medium)).monospacedDigit()
        .foregroundStyle(badgeText)
        .frame(width: 18, height: 18)
        .background(badgeFill, in: .garden(4))
        .accessibilityHidden(true)
    }
}

/// A question image: aspect fit, 320 pt high at most. The file loads off the main actor.
struct QuizImageView: View {
    let image: QuizImage
    var maxHeight: CGFloat = 320
    @Environment(\.imageLoads) private var imageLoads
    @Environment(\.gardenPalette) private var palette
    @State private var loaded: NSImage?

    var body: some View {
        Group {
            if let loaded {
                Image(nsImage: loaded).resizable().aspectRatio(contentMode: .fit)
                    .clipShape(.garden(GardenRadius.image))
            } else {
                Image(systemName: "photo").font(.largeTitle).foregroundStyle(palette.muted)
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

/// The quiz lecture body: one question at a time in a card, then the results card.
struct QuizView: View {
    let attempt: QuizAttempt
    let perform: (QuizAction) -> Void
    @Environment(\.gardenPalette) private var palette
    /// True while a notes field has focus (#181). Return then adds the note and does not check the answer.
    @Environment(\.textEntryFocused) private var textEntryFocused

    private var count: Int { attempt.quiz.questions.count }

    var body: some View {
        VStack(alignment: .leading, spacing: GardenSpacing.xs) {
            Label("Quiz · \(count) \(count == 1 ? "question" : "questions")", systemImage: "checklist")
                .gardenText(.meta)
            if let question = attempt.question {
                GardenCard(padding: 20) { questionView(question) }
            } else {
                QuizResultsView(result: attempt.result) { perform(.retake) }
            }
        }
    }

    private func questionView(_ question: QuizQuestion) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Question \(attempt.index + 1) of \(count)").gardenText(.label).monospacedDigit()
                // The question stones replace the linear progress bar. The label above reads the position.
                SteppingStones(states: attempt.questionStones).accessibilityHidden(true)
            }
            Text(question.prompt)
                .gardenText(.heading)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if let image = question.image { QuizImageView(image: image) }
            VStack(spacing: GardenSpacing.xs) {
                ForEach(Array(question.choices.enumerated()), id: \.element.id) { index, choice in
                    ChoiceRow(text: choice.text, state: attempt.state(of: choice), number: index + 1) {
                        perform(.select(choiceID: choice.id))
                    }
                }
            }
            if let correct = attempt.isAnswerCorrect {
                QuizFeedback(correct: correct, explanation: question.explanation)
            }
            HStack {
                Spacer()
                Group {
                    if attempt.isSubmitted {
                        Button(attempt.isLastQuestion ? "See Results" : "Next Question") { perform(.next) }
                    } else {
                        Button("Check Answer") { perform(.submit) }.disabled(attempt.selection == nil)
                    }
                }
                .buttonStyle(.garden())
                .keyboardShortcut(textEntryFocused ? nil : .defaultAction)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The feedback box after Submit: a check or a cross, "Correct" or "Not quite", then the explanation.
/// Quiz and spaced review (#17) questions share it.
struct QuizFeedback: View {
    let correct: Bool
    let explanation: String
    @Environment(\.gardenPalette) private var palette

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: correct ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(correct ? palette.accent : palette.wrong)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(correct ? "Correct" : "Not quite").font(GardenFont.cardTitle).foregroundStyle(palette.ink)
                Text(explanation)
                    .font(.system(size: 12.5))
                    .foregroundStyle(palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, GardenSpacing.s)
        .background(correct ? palette.tint : palette.wrongFill, in: .garden(GardenRadius.button))
        .accessibilityElement(children: .combine)
    }
}

/// The results card: the score, the percent, the skills to review and "Retake Quiz".
/// `QuizResult` has no answer for each question, so the card shows no question pebbles.
struct QuizResultsView: View {
    let result: QuizResult
    let retake: () -> Void
    @Environment(\.gardenPalette) private var palette

    var body: some View {
        GardenCard(padding: 20) {
            VStack(alignment: .leading, spacing: GardenSpacing.m) {
                VStack(alignment: .leading, spacing: GardenSpacing.xxs) {
                    (Text("\(result.correct)").font(.system(size: 32, weight: .semibold))
                        + Text(" of \(result.total)").font(.system(size: 20, weight: .regular)).foregroundStyle(palette.muted))
                        .foregroundStyle(palette.ink)
                        .monospacedDigit()
                    Text("\(result.percent)% correct").gardenText(.meta).monospacedDigit()
                }
                .accessibilityElement(children: .combine)
                if result.weakSkills.isEmpty {
                    Label {
                        Text("You answered every question correctly.").font(GardenFont.body.weight(.medium)).foregroundStyle(palette.ink)
                    } icon: {
                        Image(systemName: "checkmark.seal.fill").foregroundStyle(palette.accent)
                    }
                } else {
                    SkillsToReviewList(skills: result.weakSkills)
                }
                Button("Retake Quiz", systemImage: "arrow.clockwise", action: retake).buttonStyle(.garden())
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The "Skills to review" label and one row for each weak skill. Quiz and interactive results share it.
struct SkillsToReviewList: View {
    let skills: [String]
    @Environment(\.gardenPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: GardenSpacing.xs) {
            Text("Skills to review").gardenText(.cardTitle).accessibilityAddTraits(.isHeader)
            ForEach(skills, id: \.self) { skill in
                Label {
                    Text(skill)
                        .font(GardenFont.body)
                        .foregroundStyle(palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(palette.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 10)
                .padding(.horizontal, GardenSpacing.s)
                .background(palette.card, in: .garden(GardenRadius.button))
                .overlay { RoundedRectangle.garden(GardenRadius.button).strokeBorder(palette.line, lineWidth: 1) }
            }
        }
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
        VStack(alignment: .leading, spacing: GardenSpacing.m) {
            VStack(alignment: .leading, spacing: GardenSpacing.xxs) {
                Label("Quick review", systemImage: "arrow.counterclockwise.circle")
                    .gardenText(.heading)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($titleFocused)
                Text("Answer \(count) \(count == 1 ? "question" : "questions") from earlier lectures before you start \(review.sectionTitle).")
                    .gardenText(.meta)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // A tall review scrolls. A short review takes only the height that it needs.
            ViewThatFits(in: .vertical) {
                questions
                ScrollView { questions }
            }
            HStack(spacing: GardenSpacing.xs) {
                Spacer()
                Button("Skip Review", action: close)
                    .buttonStyle(.garden(.bordered))
                    .keyboardShortcut(.cancelAction)
                Button("Continue to Section", action: close)
                    .buttonStyle(.garden())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(GardenSpacing.l)
        .frame(width: 560)
        .tint(palette.accent)
        .background(palette.page)
        .onAppear { titleFocused = true }
    }

    private var questions: some View {
        VStack(alignment: .leading, spacing: GardenSpacing.s) {
            ForEach(review.questions) { item in
                GardenCard { questionView(item) }
            }
        }
    }

    private func questionView(_ item: ReviewQuestion) -> some View {
        VStack(alignment: .leading, spacing: GardenSpacing.s) {
            Text("From \(item.lectureTitle)").gardenText(.label)
            Text(item.question.prompt)
                .gardenText(.cardTitle)
                .fixedSize(horizontal: false, vertical: true)
            if let image = item.question.image { QuizImageView(image: image, maxHeight: 200) }
            VStack(spacing: GardenSpacing.xs) {
                ForEach(Array(item.question.choices.enumerated()), id: \.element.id) { index, choice in
                    ChoiceRow(text: choice.text, state: review.state(of: choice, in: item.id), number: index + 1,
                              usesNumberKey: false) {
                        answer(item.id, choice.id)
                    }
                }
            }
            if let correct = review.isCorrect(item.id) {
                QuizFeedback(correct: correct, explanation: item.question.explanation)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
        .gardenTheme(CourseTheme(accentColor: "#286644", appearance: .light))
    }
}
