import SwiftUI
import SkillgardenCore

/// The ungraded checks under the transcript of a video lecture. One click answers a check and locks its choices.
/// The result line and the explanation show for correct and wrong picks. "Try Again" unlocks one check.
struct QuickCheckCard: View {
    let session: QuickCheckSession
    let answer: (Int, String) -> Void
    let retry: (Int) -> Void
    /// The header "Close" button hides the card (#99). Nil shows no button.
    var close: (() -> Void)? = nil
    /// The check that gets the number keys 1–9.
    @FocusState private var focusedCheck: Int?

    static let scrollID = "quick-checks"

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(session.checks) { check in checkView(check) }
            }
            .padding(GardenSpacing.xxs)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            HStack {
                Label("Check your understanding", systemImage: "checkmark.bubble")
                Spacer()
                Text("Not graded").font(.caption).foregroundStyle(.secondary)
                if let close {
                    Button("Close", systemImage: "xmark", action: close)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("Close Quick Check")
                }
            }
        }
    }

    private func checkView(_ check: QuickCheck) -> some View {
        VStack(alignment: .leading, spacing: GardenSpacing.xs) {
            Text(check.prompt)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Array(check.choices.enumerated()), id: \.element.id) { index, choice in
                // Two checks show at once, so the rows have no number keys. `onKeyPress` below gives them to the focused check.
                ChoiceRow(text: choice.text, state: session.state(of: choice, in: check.id), number: index + 1,
                          usesNumberKey: false) {
                    focusedCheck = check.id
                    pick(check, choiceID: choice.id)
                }
            }
            if let result = session.resultLine(check.id) {
                Text(result).font(.subheadline.weight(.semibold))
                if let explanation = session.shownExplanation(check.id) {
                    Text(explanation)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button("Try Again") { retry(check.id) }
                    .buttonStyle(.borderless)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusable()
        .focusEffectDisabled()
        .focused($focusedCheck, equals: check.id)
        .onKeyPress(characters: .decimalDigits) { press in
            guard let number = Int(press.characters), (1...9).contains(number),
                  check.choices.indices.contains(number - 1) else { return .ignored }
            pick(check, choiceID: check.choices[number - 1].id)
            return .handled
        }
    }

    /// A locked check ignores the pick.
    private func pick(_ check: QuickCheck, choiceID: String) {
        guard session.answers[check.id] == nil else { return }
        answer(check.id, choiceID)
        AccessibilityNotification.Announcement(choiceID == check.correctChoiceID ? "Correct" : "Not quite").post()
    }
}

private struct SnapshotShowsQuickChecksKey: EnvironmentKey {
    static let defaultValue = false
}

private struct LectureScrollProxyKey: EnvironmentKey {
    static var defaultValue: ScrollViewProxy? { nil }
}

extension EnvironmentValues {
    /// The snapshot harness sets this, so the quick-check card shows after the load. The app sets none.
    var snapshotShowsQuickChecks: Bool {
        get { self[SnapshotShowsQuickChecksKey.self] }
        set { self[SnapshotShowsQuickChecksKey.self] = newValue }
    }

    /// The scroll proxy of the lecture page. The quick-check card uses it to scroll into view.
    var lectureScrollProxy: ScrollViewProxy? {
        get { self[LectureScrollProxyKey.self] }
        set { self[LectureScrollProxyKey.self] = newValue }
    }
}

struct QuickCheckCard_Previews: PreviewProvider {
    static let checks = [
        QuickCheck(id: 0, prompt: "Where does a course live?", choices: [QuizChoice(id: "a", text: "On this Mac"),
                                                                     QuizChoice(id: "b", text: "On a server")],
                   correctChoiceID: "a"),
        QuickCheck(id: 1, prompt: "What does the outline show first?", choices: [QuizChoice(id: "s", text: "The sections"),
                                                                             QuizChoice(id: "q", text: "The scores")],
                   correctChoiceID: "s", explanation: "The outline lists the sections in order."),
    ]

    static var previews: some View {
        var session = QuickCheckSession(checks: checks)
        session.answer(checkID: 1, choiceID: "q")
        return QuickCheckCard(session: session, answer: { _, _ in }, retry: { _ in })
            .padding()
            .frame(width: 640)
    }
}
