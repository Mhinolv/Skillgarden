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
}

/// The slot under the video controls row (#128 owner decision). One of Transcript or Q&A shows at a time.
/// The saved Transcript choice changes only when the learner uses the Transcript pill or menu item.
public enum LecturePanelSlot {
    /// True when the Transcript panel shows and its pill is on.
    public static func showsTranscript(saved: Bool, showsQA: Bool) -> Bool {
        saved && !showsQA
    }

    /// A Transcript change from the pill, the menu or a transcript search result: the new saved choice and Q&A state.
    public static func setTranscript(_ on: Bool, showsQA: Bool) -> (saved: Bool, showsQA: Bool) {
        (on, on ? false : showsQA)
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

    public private(set) var key: Key?
    public private(set) var content: Content = .loading
    public private(set) var conversation = LectureConversation(turns: [], sourceRevision: nil)
    /// Nil when no request runs.
    public private(set) var draft: Draft?
    public private(set) var notice: Notice?

    @ObservationIgnored private let library: LibraryModel
    @ObservationIgnored private let client: LlamaClient
    @ObservationIgnored private let endpoint: @MainActor () -> LocalAIEndpoint?
    @ObservationIgnored private let announce: @MainActor (String) -> Void
    @ObservationIgnored private var context: LectureContext?
    /// Goes up on each lecture change and Clear History. A request of an earlier generation changes no state.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var requestID: UUID?
    @ObservationIgnored private var cancelRequested = false
    @ObservationIgnored private var throttle: DraftThrottle
    @ObservationIgnored private var pendingText = ""
    @ObservationIgnored private var flush: Task<Void, Never>?
    @ObservationIgnored private var request: Task<Void, Never>?

    /// `endpoint` is `RuntimeSupervisor.verifiedEndpoint()`. `announce` posts a VoiceOver announcement.
    public init(library: LibraryModel, client: LlamaClient, endpoint: @escaping @MainActor () -> LocalAIEndpoint?,
                draftInterval: Duration = .milliseconds(100), announce: @escaping @MainActor (String) -> Void = { _ in }) {
        self.library = library
        self.client = client
        self.endpoint = endpoint
        self.announce = announce
        throttle = DraftThrottle(interval: draftInterval)
    }

    /// The key of the selected lecture if it gets the Q&A tab: a video or an article (owner decision). Nil for other pages.
    public static func key(library: LibraryModel) -> Key? {
        guard let courseID = library.selectedCourseID, let lecture = library.selectedLecture,
              lecture.type == .video || lecture.type == .article, library.selectedQuizAttempt == nil else { return nil }
        return Key(courseID: courseID, lectureID: lecture.id)
    }

    /// True while a request runs.
    public var isAnswering: Bool { draft != nil }

    /// The open lecture changed. A new lecture cancels the request and clears the thread until `load()`.
    public func show(_ key: Key?) {
        guard key != self.key else { return }
        stopRequest()
        self.key = key
        content = .loading
        context = nil
        conversation = LectureConversation(turns: [], sourceRevision: nil)
        notice = nil
    }

    /// Reads the lecture text and the saved thread of `key`. It does nothing while a request runs.
    public func load() async {
        guard let key, draft == nil, library.selectedCourseID == key.courseID else { return }
        let generation = generation
        let outcome = await library.lectureContext(forLecture: key.lectureID)
        let loaded = try? await library.lectureConversation(forLecture: key.lectureID)
        guard generation == self.generation, key == self.key, draft == nil else { return }
        switch outcome {
        case .ready(let value):
            context = value
            content = .ready
        case .noText:
            context = nil
            let isArticle = library.selectedLecture?.type == .article
            content = .unavailable(isArticle ? Self.noArticleTextMessage : Self.noTextMessage)
        case .tooLong, .cantLoad, .notAvailable:
            context = nil
            content = .unavailable(outcome.learnerText ?? Self.notAvailableMessage)
        }
        if let loaded { conversation = loaded }
    }

    /// Asks the question. False when the panel can't send now: no text, a running request, no lecture text or no server.
    @discardableResult
    public func send(_ text: String) -> Bool {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, draft == nil, let key, let context, let endpoint = endpoint(),
              library.selectedCourseID == key.courseID else { return false }
        notice = nil
        guard let prompt = conversation.prompt(context: context, question: question) else {
            notice = Notice(question: question, text: LecturePrompt.noEvidenceText)
            return true
        }
        draft = Draft(question: question, text: "")
        cancelRequested = false
        let generation = generation
        request = Task {
            await run(question: question, context: context, key: key, messages: prompt.messages, endpoint: endpoint,
                      generation: generation)
        }
        return true
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
        if let requestID { client.cancel(requestID) }
    }

    /// Clear History, after the learner confirms. It cancels the request first.
    public func clearHistory() {
        guard let key else { return }
        stopRequest()
        library.clearQAHistory(forLecture: key.lectureID)
        conversation = LectureConversation(turns: [], sourceRevision: conversation.sourceRevision)
        notice = nil
    }

    /// The snapshot harness shows a draft with no request.
    public func showSnapshotDraft(question: String, text: String) {
        draft = Draft(question: question, text: text)
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
        draft = nil
    }

    private func run(question: String, context: LectureContext, key: Key, messages: [ChatMessage], endpoint: LocalAIEndpoint,
                     generation: Int) async {
        // The store call reads the course id before its first suspension, so the check and the save see the same lecture.
        guard generation == self.generation else { return }
        guard library.selectedCourseID == key.courseID else { draft = nil; return }
        let turn: QATurn
        do {
            turn = try await library.startQATurn(question: question, context: context, lectureID: key.lectureID)
        } catch {
            guard generation == self.generation else { return }
            draft = nil
            notice = Notice(question: question, text: Self.saveFailedText)
            return
        }
        guard generation == self.generation, !cancelRequested else {
            library.finishQATurn(turn, outcome: .canceled, text: "")
            if generation == self.generation { await end(generation) }
            return
        }
        let answer = client.ask(messages, endpoint: endpoint)
        requestID = answer.id
        for await update in answer.updates {
            switch update {
            case .delta(let text):
                if generation == self.generation { publish(text, generation: generation) }
            case .ended(let outcome, let text):
                library.finishQATurn(turn, outcome: outcome, text: text)
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
        draft = nil
    }

    /// Changes the draft at once, or after the rest of the throttle interval with the newest text.
    private func publish(_ text: String, generation: Int) {
        pendingText = text
        guard let delay = throttle.delay(at: .now) else {
            draft?.text = text
            throttle.published(at: .now)
            return
        }
        guard flush == nil else { return }
        flush = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled, generation == self.generation else { return }
            self.flush = nil
            self.draft?.text = self.pendingText
            self.throttle.published(at: .now)
        }
    }
}
