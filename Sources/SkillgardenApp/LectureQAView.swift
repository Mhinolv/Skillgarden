import SwiftUI
import SkillgardenCore

/// The Q&A "tab" of a video or article lecture (#128): a pill in the controls row or the meta row, and the panel.
/// The window keeps the open state, like theater. It is not saved.
@MainActor
struct LectureQAPanel {
    let qa: LectureQA
    let localAI: RuntimeSupervisor
    let isOn: Binding<Bool>
    /// The value of `isOn` when the page made the panel. A plain struct does not track a binding,
    /// so the value makes the page draw again when the panel opens or closes.
    let isShown: Bool

    init(qa: LectureQA, localAI: RuntimeSupervisor, isOn: Binding<Bool>) {
        self.qa = qa
        self.localAI = localAI
        self.isOn = isOn
        isShown = isOn.wrappedValue
    }

    static let symbol = "bubble.left.and.text.bubble.right"

    func pill(iconOnly: Bool = false) -> some View {
        Toggle(isOn: isOn) { Label("Q&A", systemImage: Self.symbol) }
            .help(isShown ? "Hide Q&A (⌥⌘A)" : "Show Q&A (⌥⌘A)")
            .toggleStyle(GardenPillToggleStyle())
            .labelStyle(ToolbarLabelStyle(iconOnly: iconOnly))
    }

    func panel(focusChanged: @escaping (Bool) -> Void = { _ in }) -> some View {
        LectureQAView(qa: qa, localAI: localAI, focusChanged: focusChanged)
    }
}

/// The Q&A panel: the header with "Clear History", the thread or the service state, the question field and "Send".
/// "Send" is bordered, so "Mark as Complete" stays the only accent button of the page.
struct LectureQAView: View {
    let qa: LectureQA
    let localAI: RuntimeSupervisor
    /// Gets true while the question field has focus, so Space types text and does not start the video.
    var focusChanged: (Bool) -> Void = { _ in }
    @Environment(\.gardenPalette) private var palette
    @Environment(\.snapshotQADraft) private var snapshotDraft
    @State private var question = ""
    @State private var confirmsClear = false
    @FocusState private var fieldFocused: Bool

    static let threadHeight: CGFloat = 320
    private static let endID = "qa-end"

    var body: some View {
        let state = LectureQAState(status: localAI.status, content: qa.content)
        VStack(alignment: .leading, spacing: GardenSpacing.xs) {
            HStack {
                Text("Q&A").gardenText(.cardTitle).accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Clear History", systemImage: "trash") { confirmsClear = true }
                    .buttonStyle(.garden(.plain))
                    .disabled(qa.conversation.turns.isEmpty && !qa.isAnswering)
            }
            thread(state)
                .frame(maxWidth: .infinity)
                .frame(height: Self.threadHeight)
            composer(state)
            Text("Answers come from a local model and can be wrong.")
                .gardenText(.label)
        }
        .gardenCard(padding: GardenSpacing.s)
        .task(id: qa.key) {
            await qa.load()
            if let snapshotDraft { qa.showSnapshotDraft(question: snapshotDraft.question, text: snapshotDraft.text) }
        }
        .onChange(of: fieldFocused) { _, focused in focusChanged(focused) }
        .onDisappear { if fieldFocused { focusChanged(false) } }
        .confirmationDialog("Clear the Q&A history for this lecture?", isPresented: $confirmsClear) {
            Button("Clear History", role: .destructive) { qa.clearHistory() }
        } message: {
            Text("You cannot undo this.")
        }
    }

    @ViewBuilder private func thread(_ state: LectureQAState) -> some View {
        switch state {
        case .loading:
            ProgressView().controlSize(.small)
        case .unavailable(let text):
            message(text, systemImage: "text.badge.xmark")
        case .off:
            ContentUnavailableView {
                Label("Local AI is off", systemImage: "cpu")
            } description: {
                Text("Turn on local AI in Settings.")
            } actions: {
                SettingsLink { Text("Open Settings…") }
            }
        case .noModel:
            ContentUnavailableView {
                Label("No AI model", systemImage: "cpu")
            } actions: {
                SettingsLink { Text("Open Settings…") }
            }
        case .starting:
            progress("Starting the local model…")
        case .stopping:
            progress("Stopping the local model…")
        case .error(let reason):
            VStack(spacing: GardenSpacing.xs) {
                Image(systemName: "exclamationmark.triangle").font(.title2).foregroundStyle(palette.muted)
                Text("The local model stopped.").gardenText(.cardTitle)
                if let reason { Text(reason).gardenText(.meta).multilineTextAlignment(.center) }
                Button("Retry") { localAI.retry() }
                    .buttonStyle(.garden(.bordered))
            }
            .padding(GardenSpacing.m)
        case .ready:
            if qa.conversation.turns.isEmpty && qa.draft == nil && qa.notice == nil {
                message("Ask a question about this lecture.", systemImage: LectureQAPanel.symbol)
            } else {
                turns
            }
        }
    }

    private func message(_ text: String, systemImage: String) -> some View {
        VStack(spacing: GardenSpacing.xs) {
            Image(systemName: systemImage).font(.title2)
            Text(text).multilineTextAlignment(.center)
        }
        .font(GardenFont.body)
        .foregroundStyle(palette.muted)
        .padding(GardenSpacing.m)
        .accessibilityElement(children: .combine)
    }

    private func progress(_ text: String) -> some View {
        VStack(spacing: GardenSpacing.xs) {
            ProgressView().controlSize(.small)
            Text(text).gardenText(.meta)
        }
        .accessibilityElement(children: .combine)
    }

    /// The saved turns, the earlier-version divider (#127), the notice and the draft. The newest text stays in view.
    private var turns: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: GardenSpacing.s) {
                    let earlier = qa.conversation.earlierTurns
                    ForEach(earlier) { turn($0) }
                    if !earlier.isEmpty {
                        HStack(spacing: GardenSpacing.xs) {
                            Rectangle().fill(palette.line).frame(height: 1)
                            Text("Earlier version of this lecture").gardenText(.label).fixedSize()
                            Rectangle().fill(palette.line).frame(height: 1)
                        }
                    }
                    ForEach(qa.conversation.currentTurns) { turn($0) }
                    if let notice = qa.notice {
                        VStack(alignment: .leading, spacing: 6) {
                            QuestionBubble(text: notice.question)
                            Text(notice.text).foregroundStyle(palette.muted)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    if let draft = qa.draft { draftView(draft) }
                    Color.clear.frame(height: 1).id(Self.endID)
                }
                .font(GardenFont.body)
                .foregroundStyle(palette.ink)
                .padding(.vertical, GardenSpacing.xxs)
            }
            .onAppear { proxy.scrollTo(Self.endID, anchor: .bottom) }
            .onChange(of: qa.conversation.turns.count) { proxy.scrollTo(Self.endID, anchor: .bottom) }
            .onChange(of: qa.draft) { proxy.scrollTo(Self.endID, anchor: .bottom) }
            .onChange(of: qa.notice) { proxy.scrollTo(Self.endID, anchor: .bottom) }
        }
    }

    private func turn(_ turn: QATurn) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 6) {
                QuestionBubble(text: turn.question)
                if !turn.answer.isEmpty {
                    Text(turn.answer)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let label = turn.status.label {
                    Label(label, systemImage: turn.status.systemImage ?? "info.circle")
                        .font(GardenFont.small)
                        .foregroundStyle(palette.muted)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(turn.accessibilityLabel)
            if qa.conversation.canRetry(turn) {
                Button("Retry", systemImage: "arrow.clockwise") { qa.retry(turn) }
                    .buttonStyle(.garden(.plain, .small))
                    .disabled(qa.isAnswering || LectureQAState(status: localAI.status, content: qa.content) != .ready)
            }
        }
    }

    private func draftView(_ draft: LectureQA.Draft) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            QuestionBubble(text: draft.question)
            if draft.text.isEmpty {
                ProgressView().controlSize(.small).accessibilityLabel("Answering")
            } else {
                Text(draft.text).fixedSize(horizontal: false, vertical: true)
            }
            // Escape cancels the answer. Theater does not take Escape while an answer runs.
            Button("Cancel", systemImage: "stop.circle") { qa.cancel() }
                .buttonStyle(.garden(.plain, .small))
                .keyboardShortcut(.cancelAction)
        }
    }

    private func composer(_ state: LectureQAState) -> some View {
        let canSend = state.canSend && !qa.isAnswering && !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return HStack(alignment: .bottom, spacing: GardenSpacing.xs) {
            TextField("Ask about this lecture", text: $question, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
                .focused($fieldFocused)
                .onSubmit { if canSend { send() } }
                .disabled(!state.canSend)
            Button("Send", action: send)
                .buttonStyle(.garden(.bordered))
                .disabled(!canSend)
        }
    }

    private func send() {
        if qa.send(question) { question = "" }
    }
}

/// A question of the learner: right side, the neutral fill.
private struct QuestionBubble: View {
    let text: String
    @Environment(\.gardenPalette) private var palette

    var body: some View {
        HStack {
            Spacer(minLength: GardenSpacing.xl)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .background(palette.fill, in: .garden(GardenRadius.card))
        }
    }
}

private struct ShowsQAFocusKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

extension FocusedValues {
    /// Set while a video or article lecture shows. View > Show Q&A uses it (#128).
    var showsQA: Binding<Bool>? {
        get { self[ShowsQAFocusKey.self] }
        set { self[ShowsQAFocusKey.self] = newValue }
    }
}

private struct SnapshotShowsQAKey: EnvironmentKey {
    static let defaultValue = false
}

private struct SnapshotQADraftKey: EnvironmentKey {
    static let defaultValue: (question: String, text: String)? = nil
}

extension EnvironmentValues {
    /// The snapshot harness sets this, so the window opens with the Q&A panel open (#128). The app sets none.
    var snapshotShowsQA: Bool {
        get { self[SnapshotShowsQAKey.self] }
        set { self[SnapshotShowsQAKey.self] = newValue }
    }

    /// The snapshot harness sets this, so the Q&A panel shows a draft answer with no request. The app sets none.
    var snapshotQADraft: (question: String, text: String)? {
        get { self[SnapshotQADraftKey.self] }
        set { self[SnapshotQADraftKey.self] = newValue }
    }
}
