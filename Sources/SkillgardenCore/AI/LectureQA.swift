import Foundation
import Observation

/// What the thread area of the Q&A panel shows (#128). A lecture without text comes first, then the local AI service state.
public enum LectureQAState: Equatable, Sendable {
    /// The lecture text and the saved thread load.
    case loading
    /// The lecture has no text for local AI, or Skillgarden can't read it. `message` is the design-note text.
    case unavailable(message: String)
    /// The Settings "Use local AI" toggle is off.
    case off
    case noModel
    case starting
    case stopping
    /// The local model stopped. `reason` is the `LocalAIProblem` text.
    case error(reason: String?)
    case ready

    /// The state of a provider other than the bundled model (#151). The local runtime state does not apply to it.
    public init(content: LectureQA.Content) {
        switch content {
        case .loading: self = .loading
        case .unavailable(let message): self = .unavailable(message: message)
        case .ready: self = .ready
        }
    }

    public init(status: LocalAIStatus, content: LectureQA.Content) {
        if case .unavailable(let message) = content { self = .unavailable(message: message); return }
        switch status {
        case .off: self = .off
        case .noModel: self = .noModel
        case .starting: self = .starting
        case .stopping: self = .stopping
        case .failed: self = .error(reason: status.reason)
        case .ready: self = content == .ready ? .ready : .loading
        }
    }

    /// Only Ready turns on "Send".
    public var canSend: Bool { self == .ready }

    /// True when the thread area shows the saved turns (#160). Each state but loading and "No captions" keeps them.
    /// With no history, each state keeps its #128 full view.
    public func showsTurns(hasHistory: Bool) -> Bool {
        switch self {
        case .loading, .unavailable: false
        case .off, .noModel, .starting, .stopping, .error, .ready: hasHistory
        }
    }

    /// True when a one-line status row under the turns shows the service state and its action (#160).
    public func showsStatusRow(hasHistory: Bool) -> Bool {
        showsTurns(hasHistory: hasHistory) && self != .ready
    }
}

/// The slot under the video controls row (#128 owner decision). One of Transcript, Q&A or Notes (#181) shows at a time.
/// The saved Transcript choice changes only when the learner uses the Transcript pill or menu item.
public enum LecturePanelSlot {
    /// The panels that the window opens in the slot. The saved Transcript choice shows when none is open.
    public enum Panel: Sendable {
        case qa, notes
    }

    /// True when the Transcript panel shows and its pill is on.
    public static func showsTranscript(saved: Bool, open: Panel?) -> Bool {
        saved && open == nil
    }

    /// A Transcript change from the pill, the menu or a transcript search result: the new saved choice and open panel.
    public static func setTranscript(_ on: Bool, open: Panel?) -> (saved: Bool, open: Panel?) {
        (on, on ? nil : open)
    }

    /// A Q&A or Notes change from its pill or menu item: the new open panel. On closes the other panel.
    public static func set(_ panel: Panel, _ on: Bool, open: Panel?) -> Panel? {
        on ? panel : (open == panel ? nil : open)
    }
}

/// The draft answer of the Q&A panel changes 10 times a second at most (#128).
struct DraftThrottle {
    let interval: Duration
    private var last: ContinuousClock.Instant?

    init(interval: Duration) {
        self.interval = interval
    }

    /// Nil when the draft can change now. Otherwise the time to wait.
    func delay(at now: ContinuousClock.Instant) -> Duration? {
        guard let last, now < last + interval else { return nil }
        return last + interval - now
    }

    mutating func published(at now: ContinuousClock.Instant) {
        last = now
    }
}

/// The Q&A panel of one window (#128): the thread of the open video or article lecture, the draft answer, Send, Cancel,
/// Retry and Clear History. A lecture change cancels the request, so no answer goes into the thread of another lecture.
@MainActor @Observable
public final class LectureQA {
    /// The lecture of the panel. The course is part of the key, because two courses can use the same lecture id.
    public struct Key: Hashable, Sendable {
        public let courseID: String
        public let lectureID: String

        public init(courseID: String, lectureID: String) {
            self.courseID = courseID
            self.lectureID = lectureID
        }
    }

    /// The lecture text for local AI.
    public enum Content: Equatable, Sendable {
        case loading
        case unavailable(String)
        case ready
    }

    /// The question and the answer so far of the active request.
    public struct Draft: Equatable, Sendable {
        public let question: String
        public fileprivate(set) var text: String
        /// The numbered markers of `text` (#165). Each flush parses the text once, so a redraw parses nothing.
        public fileprivate(set) var citations: AnswerCitations

        fileprivate init(question: String, text: String, context: LectureContext?) {
            self.question = question
            self.text = text
            citations = AnswerCitations(answer: text, context: context, isStale: false)
        }
    }

    /// A question with a fixed answer and no request: no part of the lecture matches it (#126), or the save failed.
    /// It is not saved. The next question removes it.
    public struct Notice: Equatable, Sendable {
        public let question: String
        public let text: String
    }

    public static let noTextMessage = "This lecture has no transcript, so Q&A is not available."
    public static let noArticleTextMessage = "This lecture has no text, so Q&A is not available."
    public static let notAvailableMessage = "Q&A is not available for this lecture."
    public static let saveFailedText = "Skillgarden can't save the question. Try again."
    /// The VoiceOver announcement at the end of an answer.
    public static let answerReadyText = "Answer ready"
    /// The VoiceOver announcement after "Remove" (#170).
    public static let questionRemovedText = "Question removed"

    public private(set) var key: Key?
    public private(set) var content: Content = .loading
    public private(set) var conversation = LectureConversation(turns: [], sourceRevision: nil)
    /// Nil when no request runs.
    public private(set) var draft: Draft?
    /// True while a request runs. It changes only at the start and the end of a request, not on each draft flush (#165),
    /// so the window and the page do not draw again while the answer streams.
    public private(set) var isAnswering = false
    public private(set) var notice: Notice?
    /// The consent sheet (#151). A question for a provider other than the bundled model waits here until the learner
    /// allows the course for the destination. Nil when no question waits.
    public private(set) var consentRequest: RemoteConsentRequest?

    @ObservationIgnored private let library: LibraryModel
    /// The bundled model, or the only provider when `providers` is nil.
    @ObservationIgnored private let bundled: any AnswerProvider
    /// The app-wide "Answer with" choice and the course consents (#151).
    @ObservationIgnored private let providers: ProviderSettings?
    /// The provider of the running request. Cancel goes to it, also after the "Answer with" choice changes.
    @ObservationIgnored private var requestProvider: (any AnswerProvider)?
    @ObservationIgnored private let announce: @MainActor (String) -> Void
    @ObservationIgnored private var context: LectureContext?
    /// Goes up on each lecture change, Clear History and "Remove" of the draft. A request of an earlier generation changes no state.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var requestID: UUID?
    /// The saved pending turn of the running request. Nil until its save ends.
    @ObservationIgnored private var requestTurn: QATurn?
    /// The generations whose draft the learner removed (#170). Their turn is removed, not finished.
    @ObservationIgnored private var removedGenerations: Set<Int> = []
    @ObservationIgnored private var cancelRequested = false
    @ObservationIgnored private var throttle: DraftThrottle
    @ObservationIgnored private var pendingText = ""
    /// Removes an echo of the system prompt from the draft and the saved answer of the running request (#192).
    @ObservationIgnored private var echoGuard: PromptEchoGuard?
    @ObservationIgnored private var flush: Task<Void, Never>?
    @ObservationIgnored private var request: Task<Void, Never>?
    /// The citations of the saved turns (#129), so a draft change does not parse each answer again.
    @ObservationIgnored private var citationCache: [Int64: (answer: String, isStale: Bool, citations: AnswerCitations)] = [:]

    /// `provider` answers each question (#150). With `providers`, the "Answer with" choice answers and `provider` is
    /// the bundled model (#151). `announce` posts a VoiceOver announcement.
    public init(library: LibraryModel, provider: any AnswerProvider, providers: ProviderSettings? = nil,
                draftInterval: Duration = .milliseconds(100), announce: @escaping @MainActor (String) -> Void = { _ in }) {
        self.library = library
        bundled = provider
        self.providers = providers
        self.announce = announce
        throttle = DraftThrottle(interval: draftInterval)
    }

    /// The key of the selected lecture if it gets the Q&A tab: a video or an article (owner decision). Nil for other pages.
    public static func key(library: LibraryModel) -> Key? {
        guard let courseID = library.selectedCourseID, let lecture = library.selectedLecture,
              lecture.type == .video || lecture.type == .article, library.selectedQuizAttempt == nil else { return nil }
        return Key(courseID: courseID, lectureID: lecture.id)
    }

    /// The provider that answers the next question (#151).
    public var provider: any AnswerProvider { providers?.activeProvider(bundled: bundled) ?? bundled }

    /// True when the thread has saved turns, a notice or a draft (#160).
    public var hasHistory: Bool { !conversation.turns.isEmpty || isAnswering || notice != nil }

    /// The open lecture changed. A new lecture cancels the request and clears the thread until `load()`.
    public func show(_ key: Key?) {
        guard key != self.key else { return }
        stopRequest()
        self.key = key
        content = .loading
        context = nil
        citationCache = [:]
        conversation = LectureConversation(turns: [], sourceRevision: nil)
        notice = nil
        consentRequest = nil
    }

    /// Reads the lecture text and the saved thread of `key`. It does nothing while a request runs.
    public func load() async {
        guard let key, draft == nil, library.selectedCourseID == key.courseID else { return }
        let generation = generation
        let outcome = await library.lectureContext(forLecture: key.lectureID)
        let loaded = try? await library.lectureConversation(forLecture: key.lectureID)
        guard generation == self.generation, key == self.key, draft == nil else { return }
        // Each panel open loads again (#168). The citations stay while the lecture text is the same.
        let value: LectureContext? = if case .ready(let value) = outcome { value } else { nil }
        if value != context { citationCache = [:] }
        switch outcome {
        case .ready(let value):
            context = value
            if content != .ready { content = .ready }
        case .noText:
            context = nil
            let isArticle = library.selectedLecture?.type == .article
            content = .unavailable(isArticle ? Self.noArticleTextMessage : Self.noTextMessage)
        case .tooLong, .cantLoad, .notAvailable:
            context = nil
            content = .unavailable(outcome.learnerText ?? Self.notAvailableMessage)
        }
        // The same thread does not draw the panel again.
        if let loaded, loaded != conversation { conversation = loaded }
    }

    /// Asks the question. False when the panel can't send now: no text, a running request, no lecture text,
    /// or a provider that can't answer now. False also when the course has no consent for the destination of the
    /// provider (#151): `consentRequest` then holds the question, and the question stays in the field.
    @discardableResult
    public func send(_ text: String) -> Bool {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let provider = provider
        guard !question.isEmpty, draft == nil, let key, let context, let answer = provider.prepare(),
              library.selectedCourseID == key.courseID else { return false }
        notice = nil
        consentRequest = nil
        guard let prompt = conversation.prompt(context: context, question: question) else {
            notice = Notice(question: question, text: LecturePrompt.noEvidenceText)
            return true
        }
        if let destination = provider.destination, providers?.hasConsent(courseID: key.courseID, destination: destination) != true {
            let vendor = providers?.profiles.first { $0.id == destination.profileID }?.vendor ?? provider.displayName
            consentRequest = RemoteConsentRequest(courseID: key.courseID, question: question, providerName: provider.displayName,
                                                  destination: destination, vendor: vendor, context: context, prompt: prompt)
            return false
        }
        return start(question: question, context: context, key: key, messages: prompt.messages, provider: provider, answer: answer)
    }

    /// "Allow and Send" of the consent sheet (#151): saves the consent of the course, then sends the exact messages of
    /// the sheet. False when the save fails, the lecture changed, or the "Answer with" choice changed.
    @discardableResult
    public func allowAndSend() -> Bool {
        guard let request = consentRequest else { return false }
        consentRequest = nil
        let provider = provider
        guard let providers, draft == nil, let key, key.courseID == request.courseID, let context,
              library.selectedCourseID == key.courseID, provider.destination == request.destination,
              let answer = provider.prepare() else { return false }
        do {
            try providers.allow(courseID: key.courseID, destination: request.destination)
        } catch {
            notice = Notice(question: request.question, text: Self.saveFailedText)
            return false
        }
        return start(question: request.question, context: context, key: key, messages: request.messages, provider: provider,
                     answer: answer)
    }

    /// "Cancel" of the consent sheet. Nothing leaves the Mac, and the question stays in the field.
    public func cancelConsent() {
        consentRequest = nil
    }

    /// Retry asks the question of the turn again as a new turn (#127).
    @discardableResult
    public func retry(_ turn: QATurn) -> Bool {
        guard conversation.canRetry(turn) else { return false }
        return send(turn.question)
    }

    /// "Cancel" and Escape. The partial answer stays in the thread.
    public func cancel() {
        guard draft != nil else { return }
        cancelRequested = true
        if let requestID { requestProvider?.cancel(requestID) }
    }

    /// Clear History, after the learner confirms. It cancels the request first.
    public func clearHistory() {
        guard let key else { return }
        stopRequest()
        library.clearQAHistory(forLecture: key.lectureID)
        conversation = LectureConversation(turns: [], sourceRevision: conversation.sourceRevision)
        notice = nil
        consentRequest = nil
    }

    /// "Remove" of a saved turn, after the learner confirms (#170). The other turns stay. A running request continues.
    public func remove(_ turn: QATurn) {
        guard let key, conversation.turns.contains(where: { $0.id == turn.id }) else { return }
        library.removeQATurn(turn, courseID: key.courseID, lectureID: key.lectureID)
        conversation = LectureConversation(turns: conversation.turns.filter { $0.id != turn.id },
                                           sourceRevision: conversation.sourceRevision)
        citationCache[turn.id] = nil
        announce(Self.questionRemovedText)
    }

    /// "Remove" of the draft (#170): cancels the request, clears the draft and saves no turn.
    public func removeDraft() {
        guard draft != nil, let key else { return }
        if let requestTurn {
            library.removeQATurn(requestTurn, courseID: key.courseID, lectureID: key.lectureID)
        } else {
            // The question is not saved yet. The request removes its turn when the save ends.
            removedGenerations.insert(generation)
        }
        stopRequest()
        announce(Self.questionRemovedText)
    }

    /// The sources of a saved turn (#129). A turn of an earlier version of the lecture text gets stale sources.
    public func citations(for turn: QATurn) -> AnswerCitations {
        let isStale = conversation.isEarlierVersion(turn)
        if let entry = citationCache[turn.id], entry.answer == turn.answer, entry.isStale == isStale { return entry.citations }
        let citations = AnswerCitations(answer: turn.answer, context: context, isStale: isStale)
        citationParseCount += 1
        citationCache[turn.id] = (turn.answer, isStale, citations)
        return citations
    }

    /// The parses of saved answers. Tests use it.
    @ObservationIgnored private(set) var citationParseCount = 0

    /// The numbered markers of the draft answer. The draft is always of the current lecture text.
    public var draftCitations: AnswerCitations? { draft?.citations }

    /// A video source chip: the player of the open lecture seeks to the stored cue start and stays paused.
    /// Other sources do nothing.
    public func seek(to source: AnswerSource) {
        guard case .video(let seconds, _) = source.kind, let key, library.selectedCourseID == key.courseID else { return }
        library.seekCitation(lectureID: key.lectureID, seconds: seconds)
    }

    /// The snapshot harness shows a draft with no request.
    public func showSnapshotDraft(question: String, text: String) {
        setDraft(Draft(question: question, text: text, context: context))
    }

    /// Starts the request of a question. It is the only place that starts a request, so it checks the consent again:
    /// a provider with a destination sends only with a saved consent of the course (#151).
    private func start(question: String, context: LectureContext, key: Key, messages: [ChatMessage],
                       provider: any AnswerProvider, answer: PreparedAnswer) -> Bool {
        if let destination = provider.destination {
            guard providers?.hasConsent(courseID: key.courseID, destination: destination) == true else { return false }
        }
        setDraft(Draft(question: question, text: "", context: context))
        echoGuard = PromptEchoGuard(context: context)
        cancelRequested = false
        requestProvider = provider
        let generation = generation
        request = Task {
            await run(question: question, context: context, key: key, messages: messages, answer: answer, generation: generation)
        }
        return true
    }

    /// Waits until the last request ends. Tests use it.
    func waitForRequest() async {
        await request?.value
    }

    /// Cancels the request and forgets it. Its end still saves the turn, but it changes no state of the panel.
    private func stopRequest() {
        cancel()
        generation += 1
        flush?.cancel()
        flush = nil
        requestID = nil
        requestTurn = nil
        setDraft(nil)
    }

    private func run(question: String, context: LectureContext, key: Key, messages: [ChatMessage], answer prepared: PreparedAnswer,
                     generation: Int) async {
        // The store call reads the course id before its first suspension, so the check and the save see the same lecture.
        guard generation == self.generation else { return }
        guard library.selectedCourseID == key.courseID else { setDraft(nil); return }
        let turn: QATurn
        do {
            turn = try await library.startQATurn(question: question, context: context, origin: prepared.origin,
                                                 lectureID: key.lectureID)
        } catch {
            guard generation == self.generation else { return }
            setDraft(nil)
            notice = Notice(question: question, text: Self.saveFailedText)
            return
        }
        if removedGenerations.remove(generation) != nil {
            library.removeQATurn(turn, courseID: key.courseID, lectureID: key.lectureID)
            return
        }
        if generation == self.generation { requestTurn = turn }
        guard generation == self.generation, !cancelRequested else {
            library.finishQATurn(turn, outcome: .canceled, text: "")
            if generation == self.generation { await end(generation) }
            return
        }
        let answer = prepared.ask(messages)
        requestID = answer.id
        for await update in answer.updates {
            switch update {
            case .delta(let text):
                if generation == self.generation { publish(text, generation: generation) }
            case .ended(var outcome, let text):
                // #192: the saved answer has no echo. If no text stays, the turn fails with the fixed text and Retry.
                let answer = PromptEchoGuard(context: context).clean(text)
                if outcome == .finished, answer.isEmpty, answer != text { outcome = .refused(reason: PromptEchoGuard.echoText) }
                library.finishQATurn(turn, outcome: outcome, text: answer)
                guard generation == self.generation else { return }
                if outcome == .finished { announce(Self.answerReadyText) }
                await end(generation)
            }
        }
    }

    /// Reads the saved thread with the finished turn, then removes the draft.
    private func end(_ generation: Int) async {
        flush?.cancel()
        flush = nil
        if let key, let loaded = try? await library.lectureConversation(forLecture: key.lectureID), generation == self.generation {
            conversation = loaded
        }
        guard generation == self.generation else { return }
        requestID = nil
        requestTurn = nil
        setDraft(nil)
    }

    /// Sets the draft. `isAnswering` changes only when a request starts or ends.
    private func setDraft(_ value: Draft?) {
        draft = value
        if isAnswering != (value != nil) { isAnswering = value != nil }
    }

    /// One flush: the new text with no echo (#192) and its citations, parsed once.
    private func setDraftText(_ text: String) {
        let text = echoGuard?.clean(text, isComplete: false) ?? text
        guard var value = draft, value.text != text else { return }
        value.text = text
        value.citations = AnswerCitations(answer: text, context: context, isStale: false)
        draftParseCount += 1
        draft = value
    }

    /// The parses of draft text. Tests use it.
    @ObservationIgnored private(set) var draftParseCount = 0

    /// Changes the draft at once, or after the rest of the throttle interval with the newest text.
    private func publish(_ text: String, generation: Int) {
        pendingText = text
        guard let delay = throttle.delay(at: .now) else {
            setDraftText(text)
            throttle.published(at: .now)
            return
        }
        guard flush == nil else { return }
        flush = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled, generation == self.generation else { return }
            self.flush = nil
            self.setDraftText(self.pendingText)
            self.throttle.published(at: .now)
        }
    }
}
