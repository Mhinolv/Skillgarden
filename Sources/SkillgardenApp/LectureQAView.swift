import SwiftUI
import SkillgardenCore

/// The Q&A "tab" of a video or article lecture (#128): a pill in the controls row or the meta row, and the panel.
/// The window keeps the open state, like theater. It is not saved.
@MainActor
struct LectureQAPanel {
    let qa: LectureQA
    let localAI: RuntimeSupervisor
    /// The "Answer with" choice (#151).
    let providers: ProviderSettings
    let isOn: Binding<Bool>
    /// The value of `isOn` when the page made the panel. A plain struct does not track a binding,
    /// so the value makes the page draw again when the panel opens or closes.
    let isShown: Bool

    init(qa: LectureQA, localAI: RuntimeSupervisor, providers: ProviderSettings, isOn: Binding<Bool>) {
        self.qa = qa
        self.localAI = localAI
        self.providers = providers
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

    /// The page draws again on each caption cue and progress save. The panel skips these redraws (#165).
    func panel(focusChanged: @escaping (Bool) -> Void = { _ in }) -> some View {
        LectureQAView(qa: qa, localAI: localAI, providers: providers, focusChanged: focusChanged).equatable()
    }
}

/// The Q&A panel: the header with "Clear History", the thread or the service state, the question field and "Send".
/// "Send" is bordered, so "Mark as Complete" stays the only accent button of the page.
/// A question for a provider profile opens the consent sheet first, once for each course and destination (#151).
/// The panel observes its models, so a page redraw does not draw it again (#165). The closure is not compared.
struct LectureQAView: View, Equatable {
    let qa: LectureQA
    let localAI: RuntimeSupervisor
    let providers: ProviderSettings
    /// Gets true while the question field has focus, so Space types text and does not start the video.
    var focusChanged: (Bool) -> Void = { _ in }
    @Environment(\.gardenPalette) private var palette
    @Environment(\.snapshotQADraft) private var snapshotDraft
    @Environment(\.snapshotOpensCitationExcerpt) private var snapshotOpensExcerpt
    @Environment(\.snapshotQAConsentQuestion) private var snapshotConsentQuestion
    /// The snapshot harness draws the consent sheet in the window, so the panel shows no real sheet.
    @Environment(\.showsReviewInline) private var showsSheetsInline
    @State private var question = ""
    @State private var confirmsClear = false
    /// The one open article excerpt of the panel (#129).
    @State private var openExcerpt: OpenExcerpt?
    @FocusState private var fieldFocused: Bool

    static let threadHeight: CGFloat = 320
    private static let endID = "qa-end"

    nonisolated static func == (lhs: LectureQAView, rhs: LectureQAView) -> Bool {
        lhs.qa === rhs.qa && lhs.localAI === rhs.localAI && lhs.providers === rhs.providers
    }

    /// A provider profile does not use the local runtime, so its state follows the lecture text only (#151).
    private var panelState: LectureQAState {
        qa.provider.kind == .local ? LectureQAState(status: localAI.status, content: qa.content) : LectureQAState(content: qa.content)
    }

    var body: some View {
        let state = panelState
        let profile = providers.selected
        VStack(alignment: .leading, spacing: GardenSpacing.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text("Q&A").gardenText(.cardTitle).accessibilityAddTraits(.isHeader)
                if let profile {
                    Text(profile.title).gardenText(.label).lineLimit(1).help(profile.host)
                }
                Spacer()
                Button("Clear History", systemImage: "trash") { confirmsClear = true }
                    .buttonStyle(.garden(.plain))
                    .disabled(qa.conversation.turns.isEmpty && !qa.isAnswering)
            }
            thread(state)
                .frame(maxWidth: .infinity)
                .frame(height: Self.threadHeight)
            // The composer reads the question, so a key press draws the composer only.
            QAComposer(qa: qa, canSendState: state.canSend, question: $question, fieldFocused: $fieldFocused)
            Text(profile?.answerFooter ?? "Answers come from a local model and can be wrong.")
                .gardenText(.label)
        }
        .gardenCard(padding: GardenSpacing.s)
        .task(id: qa.key) {
            openExcerpt = nil
            await qa.load()
            if let snapshotDraft { qa.showSnapshotDraft(question: snapshotDraft.question, text: snapshotDraft.text) }
            if let snapshotConsentQuestion { qa.send(snapshotConsentQuestion) }
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
        .sheet(item: Binding(get: { showsSheetsInline ? nil : qa.consentRequest }, set: { if $0 == nil { qa.cancelConsent() } })) { request in
            RemoteConsentSheet(request: request, showsText: false,
                               allow: { if qa.allowAndSend() { question = "" } }, cancel: { qa.cancelConsent() })
        }
    }

    /// Saved turns show in every service state (#160). A status row under them shows a state that is not Ready.
    @ViewBuilder private func thread(_ state: LectureQAState) -> some View {
        if state.showsTurns(hasHistory: qa.hasHistory) {
            VStack(spacing: GardenSpacing.xs) {
                turns
                if state.showsStatusRow(hasHistory: qa.hasHistory) { statusRow(state) }
            }
        } else {
            stateView(state)
        }
    }

    /// The #128 full view of a state with no history.
    @ViewBuilder private func stateView(_ state: LectureQAState) -> some View {
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
            message("Ask a question about this lecture.", systemImage: LectureQAPanel.symbol)
        }
    }

    /// One line at the bottom of the thread frame: the state, then its action (#160).
    @ViewBuilder private func statusRow(_ state: LectureQAState) -> some View {
        HStack(spacing: GardenSpacing.xs) {
            HStack(spacing: GardenSpacing.xs) {
                switch state {
                case .starting, .stopping:
                    ProgressView().controlSize(.mini)
                case .error:
                    Image(systemName: "exclamationmark.triangle").font(GardenFont.small).foregroundStyle(palette.muted)
                default:
                    Image(systemName: "cpu").font(GardenFont.small).foregroundStyle(palette.muted)
                }
                Text(Self.statusText(state))
                    .gardenText(.meta)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(Self.statusText(state))
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            switch state {
            case .off, .noModel:
                SettingsLink { Text("Open Settings…") }
                    .buttonStyle(.garden(.plain, .small))
            case .error:
                Button("Retry") { localAI.retry() }
                    .buttonStyle(.garden(.plain, .small))
            default:
                EmptyView()
            }
        }
    }

    /// The status row text. The error reason follows on the same line.
    private static func statusText(_ state: LectureQAState) -> String {
        switch state {
        case .off: "Local AI is off."
        case .noModel: "No AI model."
        case .starting: "Starting the local model…"
        case .stopping: "Stopping the local model…"
        case .error(let reason): ["The local model stopped.", reason].compactMap { $0 }.joined(separator: " ")
        case .loading, .unavailable, .ready: ""
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
                    // The draft view reads the draft, so a flush draws the draft only (#165).
                    QADraftView(qa: qa) { proxy.scrollTo(Self.endID, anchor: .bottom) }
                    Color.clear.frame(height: 1).id(Self.endID)
                }
                .font(GardenFont.body)
                .foregroundStyle(palette.ink)
                .padding(.vertical, GardenSpacing.xxs)
            }
            .onAppear { proxy.scrollTo(Self.endID, anchor: .bottom) }
            .onChange(of: qa.conversation.turns.count) { proxy.scrollTo(Self.endID, anchor: .bottom) }
            .onChange(of: qa.notice) { proxy.scrollTo(Self.endID, anchor: .bottom) }
        }
    }

    private func turn(_ turn: QATurn) -> some View {
        let openID = openExcerpt?.turnID == turn.id ? openExcerpt?.sourceID : nil
        return QATurnView(turn: turn, citations: qa.citations(for: turn), sourceText: providers.sourceText(for: turn.origin),
                          canRetry: qa.conversation.canRetry(turn), retryDisabled: qa.isAnswering || panelState != .ready,
                          openID: openID, setOpenID: { openExcerpt = $0.map { OpenExcerpt(turnID: turn.id, sourceID: $0) } },
                          seek: { qa.seek(to: $0) }, retry: { qa.retry(turn) })
            .equatable()
    }
}

/// The answer with inline Markdown styles (#158) and `[1]`, `[2]` in place of passage IDs.
/// Valid markers use the accent ink, the others the muted color. Markers and links are plain text, not links.
@MainActor
private func answerText(_ citations: AnswerCitations, palette: GardenPalette) -> AttributedString {
    var text = citations.styled
    for (source, range) in text.runs[AnswerMarkerAttribute.self] {
        guard let source else { continue }
        text[range].foregroundColor = source.isActionable ? palette.accentInk : palette.muted
    }
    return text
}

/// One saved turn (#165). A redraw of the panel skips it when its values are equal. Actions are not compared.
private struct QATurnView: View, Equatable {
    let turn: QATurn
    let citations: AnswerCitations
    let sourceText: String?
    let canRetry: Bool
    let retryDisabled: Bool
    /// The open excerpt of this turn. Opening an excerpt closes the excerpt of any other turn.
    let openID: String?
    let setOpenID: (String?) -> Void
    let seek: (AnswerSource) -> Void
    let retry: () -> Void
    @Environment(\.gardenPalette) private var palette

    nonisolated static func == (lhs: QATurnView, rhs: QATurnView) -> Bool {
        lhs.turn == rhs.turn && lhs.sourceText == rhs.sourceText && lhs.canRetry == rhs.canRetry
            && lhs.retryDisabled == rhs.retryDisabled && lhs.openID == rhs.openID && lhs.citations == rhs.citations
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 6) {
                QuestionBubble(text: turn.question)
                if !turn.answer.isEmpty {
                    Text(answerText(citations, palette: palette))
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
            if let sourceText {
                Text(sourceText).gardenText(.label)
            }
            if !citations.sources.isEmpty {
                SourcesRow(sources: citations.sources, openID: Binding(get: { openID }, set: { setOpenID($0) }), seek: seek)
            }
            if canRetry {
                Button("Retry", systemImage: "arrow.clockwise", action: retry)
                    .buttonStyle(.garden(.plain, .small))
                    .disabled(retryDisabled)
            }
        }
    }
}

/// The draft answer of the running request. It alone reads the draft, so a flush draws only this view (#165).
private struct QADraftView: View {
    let qa: LectureQA
    let scrollToEnd: () -> Void
    @Environment(\.gardenPalette) private var palette

    var body: some View {
        Group {
            if let draft = qa.draft {
                VStack(alignment: .leading, spacing: 6) {
                    QuestionBubble(text: draft.question)
                    if draft.text.isEmpty {
                        ProgressView().controlSize(.small).accessibilityLabel("Answering")
                    } else {
                        Text(answerText(draft.citations, palette: palette)).fixedSize(horizontal: false, vertical: true)
                    }
                    // Escape cancels the answer. Theater does not take Escape while an answer runs.
                    Button("Cancel", systemImage: "stop.circle") { qa.cancel() }
                        .buttonStyle(.garden(.plain, .small))
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
        .onChange(of: qa.draft) { scrollToEnd() }
    }
}

/// The question field and "Send". It alone reads the question, so a key press draws only this view (#165).
private struct QAComposer: View {
    let qa: LectureQA
    /// True when the panel state allows "Send".
    let canSendState: Bool
    @Binding var question: String
    var fieldFocused: FocusState<Bool>.Binding

    var body: some View {
        let canSend = canSendState && !qa.isAnswering && !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        HStack(alignment: .bottom, spacing: GardenSpacing.xs) {
            TextField("Ask about this lecture", text: $question, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
                .focused(fieldFocused)
                .onSubmit { if canSend { send() } }
                .disabled(!canSendState)
            Button("Send", action: send)
                .buttonStyle(.garden(.bordered))
                .disabled(!canSend)
        }
    }

    private func send() {
        if qa.send(question) { question = "" }
    }
}

/// The consent sheet (#151): the destination, what leaves the Mac and the exact text of the request.
/// "Cancel" keeps the question in the field. "Allow and Send" saves the consent of the course, then sends.
struct RemoteConsentSheet: View {
    let request: RemoteConsentRequest
    @State var showsText: Bool
    let allow: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(request.title).font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                row("Provider", request.providerName)
                row("Host", request.destination.host)
                row("Model", request.destination.modelID)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Skillgarden sends:")
                ForEach(request.items, id: \.self) { item in
                    Text("• " + item).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let cloudNote = request.cloudNote { Text(cloudNote).fixedSize(horizontal: false, vertical: true) }
            Text("Provider charges and data policies apply.").font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("Show exact text", isExpanded: $showsText) {
                ScrollView {
                    Text(request.exactText)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                }
                .frame(height: 240)
                .background(.background.secondary, in: .rect(cornerRadius: 6))
                .accessibilityLabel(request.exactText)
            }
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Allow and Send", action: allow).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
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
    /// The excerpt, parsed once when the excerpt opens (#165). `ViewThatFits` uses it twice.
    let styled: AttributedString
    @Environment(\.gardenPalette) private var palette

    /// Inline Markdown styles show, as in the article. Links stay text because the excerpt has no link action.
    init(text: String) {
        var styled = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
        for run in styled.runs where run.link != nil { styled[run.range].link = nil }
        self.styled = styled
    }

    var body: some View {
        ViewThatFits(in: .vertical) {
            excerpt
            ScrollView { excerpt }
        }
        .frame(maxHeight: 160, alignment: .top)
        .padding(.leading, GardenSpacing.s)
        .overlay(alignment: .leading) { Capsule().fill(palette.line).frame(width: 2) }
    }

    private var excerpt: some View {
        Text(styled)
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

private struct SnapshotQAConsentQuestionKey: EnvironmentKey {
    static let defaultValue: String? = nil
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

    /// The snapshot harness sets this, so the Q&A panel sends the question and the consent sheet opens (#151). The app sets none.
    var snapshotQAConsentQuestion: String? {
        get { self[SnapshotQAConsentQuestionKey.self] }
        set { self[SnapshotQAConsentQuestionKey.self] = newValue }
    }
}
