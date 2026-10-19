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
    @Environment(\.snapshotOpensCitationExcerpt) private var snapshotOpensExcerpt
    @State private var question = ""
    @State private var confirmsClear = false
    /// The one open article excerpt of the panel (#129).
    @State private var openExcerpt: OpenExcerpt?
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
            openExcerpt = nil
            await qa.load()
            if let snapshotDraft { qa.showSnapshotDraft(question: snapshotDraft.question, text: snapshotDraft.text) }
            if snapshotOpensExcerpt, let turn = qa.conversation.turns.last,
               let source = qa.citations(for: turn).sources.first(where: { if case .article = $0.kind { true } else { false } }) {
                openExcerpt = OpenExcerpt(turnID: turn.id, sourceID: source.id)
            }
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
        let citations = qa.citations(for: turn)
        return VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 6) {
                QuestionBubble(text: turn.question)
                if !turn.answer.isEmpty {
                    Text(answerText(citations))
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
            .accessibilityLabel(turn.accessibilityLabel(answer: citations.text))
            if !citations.sources.isEmpty {
                SourcesRow(sources: citations.sources, openID: excerptBinding(turn.id), seek: { qa.seek(to: $0) })
            }
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
                Text(answerText(qa.citations(forDraft: draft.text))).fixedSize(horizontal: false, vertical: true)
            }
            // Escape cancels the answer. Theater does not take Escape while an answer runs.
            Button("Cancel", systemImage: "stop.circle") { qa.cancel() }
                .buttonStyle(.garden(.plain, .small))
                .keyboardShortcut(.cancelAction)
        }
    }

    /// The answer with `[1]`, `[2]` in place of passage IDs. Valid markers use the accent ink, the others the muted color.
    /// Markers are plain text, not links.
    private func answerText(_ citations: AnswerCitations) -> AttributedString {
        var text = AttributedString()
        for segment in citations.segments {
            switch segment {
            case .text(let value):
                text += AttributedString(value)
            case .marker(let source):
                var marker = AttributedString(AnswerCitations.markerText(source))
                marker.foregroundColor = source.isActionable ? palette.accentInk : palette.muted
                text += marker
            }
        }
        return text
    }

    /// The open excerpt of one turn. Opening an excerpt closes the excerpt of any other turn.
    private func excerptBinding(_ turnID: Int64) -> Binding<String?> {
        Binding(get: { openExcerpt?.turnID == turnID ? openExcerpt?.sourceID : nil },
                set: { openExcerpt = $0.map { OpenExcerpt(turnID: turnID, sourceID: $0) } })
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

private struct OpenExcerpt: Equatable {
    let turnID: Int64
    let sourceID: String
}

/// The "Sources" row under an answer (#129): one chip for each source, then the open article excerpt.
/// Stale and unknown sources are faint labels with a tooltip, never buttons.
private struct SourcesRow: View {
    let sources: [AnswerSource]
    @Binding var openID: String?
    let seek: (AnswerSource) -> Void
    @Environment(\.gardenPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: GardenSpacing.xs) {
            GardenFlowLayout(spacing: GardenSpacing.xs) {
                Text("Sources").gardenText(.label)
                ForEach(sources) { chip($0) }
            }
            if let openID, let source = sources.first(where: { $0.id == openID }), case .article(let excerpt) = source.kind {
                ExcerptView(text: excerpt)
            }
        }
    }

    @ViewBuilder private func chip(_ source: AnswerSource) -> some View {
        switch source.kind {
        case .video:
            Button { seek(source) } label: { Label(source.title, systemImage: "play.circle") }
                .buttonStyle(.garden(.bordered, .small))
                .help(source.help ?? "")
                .accessibilityLabel(source.accessibilityLabel())
                .accessibilityHint(source.accessibilityHint ?? "")
        case .article:
            Toggle(isOn: Binding(get: { openID == source.id }, set: { openID = $0 ? source.id : nil })) {
                Label(source.title, systemImage: "text.quote")
            }
            .toggleStyle(GardenPillToggleStyle(size: .small))
            .accessibilityLabel(source.accessibilityLabel())
            .accessibilityHint(source.accessibilityHint ?? "")
        case .stale, .unknown:
            Text(source.title)
                .font(GardenFont.small)
                .foregroundStyle(palette.faint)
                .help(source.help ?? "")
                // Tab reaches the label, so keyboard users hear why it has no action.
                .focusable()
                .accessibilityLabel(source.accessibilityLabel())
        }
    }
}

/// An article excerpt in the Markdown quote style: a 2 pt bar and muted text, 160 pt high at most.
private struct ExcerptView: View {
    let text: String
    @Environment(\.gardenPalette) private var palette

    var body: some View {
        ViewThatFits(in: .vertical) {
            excerpt
            ScrollView { excerpt }
        }
        .frame(maxHeight: 160, alignment: .top)
        .padding(.leading, GardenSpacing.s)
        .overlay(alignment: .leading) { Capsule().fill(palette.line).frame(width: 2) }
    }

    /// Inline Markdown styles show, as in the article. Links stay text because the excerpt has no link action.
    private var excerpt: some View {
        var styled = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
        for run in styled.runs where run.link != nil { styled[run.range].link = nil }
        return Text(styled)
            .foregroundStyle(palette.muted)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
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

private struct SnapshotOpensCitationExcerptKey: EnvironmentKey {
    static let defaultValue = false
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

    /// The snapshot harness sets this, so the first article excerpt of the last answer opens (#129). The app sets none.
    var snapshotOpensCitationExcerpt: Bool {
        get { self[SnapshotOpensCitationExcerptKey.self] }
        set { self[SnapshotOpensCitationExcerptKey.self] = newValue }
    }
}
