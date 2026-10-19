import Foundation

/// One message of a chat request.
public struct ChatMessage: Equatable, Sendable, Encodable {
    public enum Role: String, Sendable, Encodable { case system, user, assistant }

    public let role: Role
    public let content: String

    public init(role: Role, content: String) {
        self.role = role
        self.content = content
    }
}

/// One answer that the client streams. Use `id` to cancel it.
public struct AnswerRequest: Sendable {
    public let id: UUID
    /// The deltas, then one `.ended` update. The sequence then finishes.
    public let updates: AsyncStream<AnswerUpdate>
}

/// What the transport gives for one HTTP request: the status once, then the body bytes.
public enum LlamaTransportEvent: Sendable {
    case response(status: Int)
    case data(Data)
}

/// Sends one HTTP request and streams the response. The real one is `LoopbackTransport`. Tests use a fake.
/// A clean end of the body finishes the sequence. A lost connection throws.
public protocol LlamaTransport: Sendable {
    func send(_ request: URLRequest) -> AsyncThrowingStream<LlamaTransportEvent, any Error>
}

/// Streams chat answers from the owned llama-server (#124). Only one request runs at a time.
/// `cancel(_:)` ends the request at once and keeps the partial answer. Later events of that request are ignored.
public final class LlamaClient: @unchecked Sendable {
    private struct Active {
        let id: UUID
        let continuation: AsyncStream<AnswerUpdate>.Continuation
        var text = ""
        var task: Task<Void, Never>?
    }

    private let transport: any LlamaTransport
    private let lock = NSLock()
    private var active: Active?

    public init(transport: any LlamaTransport = LoopbackTransport()) {
        self.transport = transport
    }

    /// True while a request runs.
    public var isBusy: Bool { lock.withLock { active != nil } }

    /// Asks the owned server. Get `endpoint` from `RuntimeSupervisor.verifiedEndpoint()`.
    public func ask(_ messages: [ChatMessage], endpoint: LocalAIEndpoint) -> AnswerRequest {
        ask(messages, baseURL: endpoint.baseURL, apiKey: endpoint.apiKey)
    }

    func ask(_ messages: [ChatMessage], baseURL: URL, apiKey: String) -> AnswerRequest {
        let id = UUID()
        let (updates, continuation) = AsyncStream<AnswerUpdate>.makeStream()
        guard let request = Self.chatRequest(messages, baseURL: baseURL, apiKey: apiKey) else {
            continuation.yield(.ended(.untrusted, text: ""))
            continuation.finish()
            return AnswerRequest(id: id, updates: updates)
        }
        let started: Bool = lock.withLock {
            guard active == nil else { return false }
            active = Active(id: id, continuation: continuation)
            return true
        }
        guard started else {
            continuation.yield(.ended(.busy, text: ""))
            continuation.finish()
            return AnswerRequest(id: id, updates: updates)
        }
        // A consumer that stops reading cancels the request.
        continuation.onTermination = { [weak self] _ in self?.cancel(id) }
        let task = Task { [weak self, transport] in
            let outcome = await Self.pump(transport.send(request)) { text in self?.deliver(id, .delta(text: text)) ?? false }
            self?.end(id, outcome)
        }
        lock.withLock {
            if active?.id == id { active?.task = task } else { task.cancel() }
        }
        return AnswerRequest(id: id, updates: updates)
    }

    /// Ends the request with `id` at once, with the partial answer. It does nothing for an old id.
    public func cancel(_ id: UUID) {
        end(id, .canceled)?.cancel()
    }

    /// Reads the response. `send` gets the full text after each delta and gives false when the request ended.
    static func pump(_ events: AsyncThrowingStream<LlamaTransportEvent, any Error>,
                     send: (String) -> Bool) async -> AnswerOutcome {
        var decoder = ServerSentEventDecoder()
        var text = ""
        do {
            for try await event in events {
                switch event {
                case .response(let status):
                    switch status {
                    case 200: continue
                    case 300..<400, 401, 403: return .untrusted
                    default: return .httpError(status: status)
                    }
                case .data(let data):
                    for event in decoder.decode(data) {
                        switch ChatStreamEvent(data: event) {
                        case .content(let delta):
                            guard !delta.isEmpty else { continue }
                            text += delta
                            guard send(text) else { return .canceled }
                        case .finished(let delta):
                            text += delta
                            if !delta.isEmpty { guard send(text) else { return .canceled } }
                            return text.isEmpty ? .empty : .finished
                        case .error(let status):
                            return .httpError(status: status)
                        case .malformed:
                            return .malformed
                        }
                    }
                }
            }
        } catch {
            return Task.isCancelled ? .canceled : .disconnected
        }
        if Task.isCancelled { return .canceled }
        // The body ended with no finish event.
        return text.isEmpty ? .empty : .disconnected
    }

    /// Gives a delta of the active request. False when `id` is not active.
    private func deliver(_ id: UUID, _ update: AnswerUpdate) -> Bool {
        lock.withLock {
            guard active?.id == id else { return false }
            if case .delta(let text) = update { active?.text = text }
            active?.continuation.yield(update)
            return true
        }
    }

    /// Ends the request with `id` and gives its task. Nil when `id` is not active.
    @discardableResult
    private func end(_ id: UUID, _ outcome: AnswerOutcome) -> Task<Void, Never>? {
        let ended: Active? = lock.withLock {
            guard let current = active, current.id == id else { return nil }
            active = nil
            current.continuation.yield(.ended(outcome, text: outcome.keepsText ? current.text : ""))
            return current
        }
        guard let ended else { return nil }
        // `finish` calls `onTermination`, which calls `cancel`. The id is not active then, so that does nothing.
        ended.continuation.finish()
        return ended.task
    }

    /// The `/v1/chat/completions` request, or nil when the endpoint is not the owned loopback server.
    static func chatRequest(_ messages: [ChatMessage], baseURL: URL, apiKey: String) -> URLRequest? {
        guard isLoopback(baseURL), isValidSecret(apiKey) else { return nil }
        var request = URLRequest(url: baseURL.appending(path: "v1/chat/completions"))
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try? JSONEncoder().encode(ChatBody(messages: messages, stream: true))
        return request
    }

    private struct ChatBody: Encodable {
        let messages: [ChatMessage]
        let stream: Bool
    }

    /// `http://127.0.0.1:<port>` or `http://[::1]:<port>`, with no user, password, query or fragment.
    /// A host name such as `localhost` is not accepted, because a hosts file can send it to another address.
    static func isLoopback(_ url: URL) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false), parts.scheme == "http",
              let host = parts.host, ["127.0.0.1", "::1", "[::1]"].contains(host),
              let port = parts.port, (1...65535).contains(port),
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil else { return false }
        return parts.path.isEmpty || parts.path == "/"
    }

    /// The session secret of `RuntimeSupervisor`: 64 lowercase hex characters.
    static func isValidSecret(_ apiKey: String) -> Bool {
        apiKey.utf8.count == 64 && apiKey.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }
}

/// The real transport: an ephemeral URLSession with no cookies, cache, credential store, proxy or redirects.
public final class LoopbackTransport: LlamaTransport {
    private let router = Router()
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.waitsForConnectivity = false
        // The prompt of a long lecture can take minutes before the first token.
        configuration.timeoutIntervalForRequest = 600
        session = URLSession(configuration: configuration, delegate: router, delegateQueue: nil)
    }

    deinit {
        session.invalidateAndCancel()
    }

    public func send(_ request: URLRequest) -> AsyncThrowingStream<LlamaTransportEvent, any Error> {
        let (stream, continuation) = AsyncThrowingStream<LlamaTransportEvent, any Error>.makeStream()
        let task = session.dataTask(with: request)
        router.add(continuation, for: task)
        continuation.onTermination = { _ in task.cancel() }
        task.resume()
        return stream
    }

    /// The session delegate. It is a separate object because the session keeps its delegate until it is invalidated.
    private final class Router: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var streams: [Int: AsyncThrowingStream<LlamaTransportEvent, any Error>.Continuation] = [:]

        func add(_ continuation: AsyncThrowingStream<LlamaTransportEvent, any Error>.Continuation, for task: URLSessionTask) {
            lock.withLock { streams[task.taskIdentifier] = continuation }
        }

        private func stream(_ task: URLSessionTask) -> AsyncThrowingStream<LlamaTransportEvent, any Error>.Continuation? {
            lock.withLock { streams[task.taskIdentifier] }
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
            stream(dataTask)?.yield(.response(status: (response as? HTTPURLResponse)?.statusCode ?? 0))
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            stream(dataTask)?.yield(.data(data))
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
            let continuation = lock.withLock { streams.removeValue(forKey: task.taskIdentifier) }
            continuation?.finish(throwing: error)
        }

        /// The client talks only to the owned server, so it does not follow a redirect. The 3xx response comes through.
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }

        /// No response goes into a cache.
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, willCacheResponse proposedResponse: CachedURLResponse,
                        completionHandler: @escaping @Sendable (CachedURLResponse?) -> Void) {
            completionHandler(nil)
        }
    }
}
