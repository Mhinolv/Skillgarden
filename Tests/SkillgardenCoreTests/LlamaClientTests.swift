import Darwin
import Foundation
import Testing
@testable import SkillgardenCore

// #124: incremental answers and cancel. These tests cover the event decoder, the client with a scripted transport,
// and the real transport against a stub server on the loopback address. No test needs a model or a clock.

/// A secret in the `RuntimeSupervisor.makeSecret()` format.
private let secret = String(repeating: "0123456789abcdef", count: 4)
private let question = [ChatMessage(role: .user, content: "What is a loop?")]

/// One `data:` event of a chat chunk with `content`.
private func chunk(_ content: String, finish: String? = nil) -> String {
    let text = String(data: try! JSONEncoder().encode(content), encoding: .utf8)!
    let reason = finish.map { "\"\($0)\"" } ?? "null"
    return "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\(text)},\"finish_reason\":\(reason)}]}\n\n"
}

private let done = "data: [DONE]\n\n"

private func collect(_ request: AnswerRequest) async -> [AnswerUpdate] {
    var updates: [AnswerUpdate] = []
    for await update in request.updates { updates.append(update) }
    return updates
}

// MARK: - Fake transport

/// Gives each request stream to the test, which then sends the events by hand.
private final class ScriptedTransport: LlamaTransport, @unchecked Sendable {
    typealias Continuation = AsyncThrowingStream<LlamaTransportEvent, any Error>.Continuation

    private let lock = NSLock()
    private var ready: [Continuation] = []
    private var waiters: [CheckedContinuation<Continuation, Never>] = []
    private(set) var requests: [URLRequest] = []
    private(set) var terminated = 0

    func send(_ request: URLRequest) -> AsyncThrowingStream<LlamaTransportEvent, any Error> {
        let (stream, continuation) = AsyncThrowingStream<LlamaTransportEvent, any Error>.makeStream()
        continuation.onTermination = { [weak self] _ in self?.lock.withLock { self?.terminated += 1 } }
        let waiter: CheckedContinuation<Continuation, Never>? = lock.withLock {
            requests.append(request)
            if waiters.isEmpty { ready.append(continuation); return nil }
            return waiters.removeFirst()
        }
        waiter?.resume(returning: continuation)
        return stream
    }

    /// The stream of the next request.
    func next() async -> Continuation {
        await withCheckedContinuation { waiter in
            let found: Continuation? = lock.withLock {
                if ready.isEmpty { waiters.append(waiter); return nil }
                return ready.removeFirst()
            }
            if let found { waiter.resume(returning: found) }
        }
    }
}

/// Runs one request on the scripted transport: the status, then `body` in the given chunks, then `end`.
private func answer(status: Int = 200, _ body: [Data], end: (any Error)? = nil) async -> [AnswerUpdate] {
    let transport = ScriptedTransport()
    let client = LlamaClient(transport: transport)
    let request = client.ask(question, endpoint: LocalAIEndpoint(port: 8080, apiKey: secret))
    let stream = await transport.next()
    stream.yield(.response(status: status))
    body.forEach { stream.yield(.data($0)) }
    stream.finish(throwing: end)
    let updates = await collect(request)
    #expect(!client.isBusy)
    return updates
}

private func answer(status: Int = 200, _ body: String..., end: (any Error)? = nil) async -> [AnswerUpdate] {
    await answer(status: status, body.map { Data($0.utf8) }, end: end)
}

// MARK: - Learner text

@Test func answerTextMatchesTheDesignNotes() {
    #expect(AnswerOutcome.finished.learnerText == nil)
    #expect(AnswerOutcome.canceled.learnerText == "Canceled")
    #expect(AnswerOutcome.disconnected.learnerText == "The answer stopped because local AI stopped. Try again.")
    #expect(AnswerOutcome.empty.learnerText == "The model gave no answer. Try again.")
    #expect(AnswerOutcome.malformed.learnerText == "Local AI sent data that Skillgarden can't read. Try again.")
    #expect(AnswerOutcome.httpError(status: 503).learnerText == "Local AI returned an error (503). Try again.")
    #expect(AnswerOutcome.untrusted.learnerText == "Skillgarden stopped the request. The server is not the one that it started.")
    #expect(AnswerOutcome.busy.learnerText == "Local AI is answering another question. Wait, or cancel it.")

    let all: [AnswerOutcome] = [.finished, .canceled, .disconnected, .empty, .malformed, .httpError(status: 500), .untrusted, .busy]
    #expect(all.filter(\.keepsText) == [.finished, .canceled, .disconnected, .malformed])
    // Only the credential row may name the server.
    for outcome in all where outcome != .untrusted {
        let text = outcome.learnerText?.lowercased() ?? ""
        #expect(!["llama", "server", "llm"].contains(where: text.contains), "\(outcome)")
    }
}

// MARK: - Event decoder

@Test func decoderJoinsFramesThatAnyByteSplits() {
    let body = Array((chunk("Café ") + ": a comment\n" + "event: message\nid: 7\n" + chunk("🌱 ok") + done).utf8)
    let whole: [[UInt8]] = {
        var decoder = ServerSentEventDecoder()
        return decoder.decode(body)
    }()
    #expect(whole.count == 3)
    #expect(ChatStreamEvent(data: whole[0]) == .content("Café "))
    #expect(ChatStreamEvent(data: whole[1]) == .content("🌱 ok"))
    #expect(ChatStreamEvent(data: whole[2]) == .finished(""))
    // A cut at each byte, also in the middle of "é" and of the emoji, gives the same events.
    for cut in 1..<body.count {
        var decoder = ServerSentEventDecoder()
        let events = decoder.decode(body[..<cut]) + decoder.decode(body[cut...])
        #expect(events == whole, "cut at \(cut)")
    }
    // One byte for each chunk.
    var decoder = ServerSentEventDecoder()
    #expect(body.flatMap { decoder.decode([$0]) } == whole)
}

@Test func decoderAcceptsEachLineEnd() {
    for end in ["\n", "\r\n", "\r"] {
        let body = Array("data: one\(end)data:two\(end)\(end)data: [DONE]\(end)\(end)".utf8)
        let expected = [Array("one\ntwo".utf8), Array("[DONE]".utf8)]
        for cut in 0...body.count {
            var decoder = ServerSentEventDecoder()
            #expect(decoder.decode(body[..<cut]) + decoder.decode(body[cut...]) == expected, "\(end.debugDescription) cut at \(cut)")
        }
    }
}

@Test func decoderSkipsAnEventWithNoBlankLine() {
    var decoder = ServerSentEventDecoder()
    #expect(decoder.decode(Array("\n\n: ping\n\ndata: half".utf8)).isEmpty)
}

@Test func chatEventsGiveTheMeaningOfEachChunk() {
    func event(_ text: String) -> ChatStreamEvent { ChatStreamEvent(data: Array(text.utf8)) }
    #expect(event(#"{"choices":[{"delta":{"content":"Hi"},"finish_reason":null}]}"#) == .content("Hi"))
    #expect(event(#"{"choices":[{"delta":{"role":"assistant"}}]}"#) == .content(""))
    #expect(event(#"{"choices":[{"delta":{},"finish_reason":"stop"}]}"#) == .finished(""))
    #expect(event(#"{"choices":[{"delta":{"content":"."},"finish_reason":"length"}]}"#) == .finished("."))
    #expect(event(#"{"choices":[],"usage":{"completion_tokens":3}}"#) == .content(""))
    #expect(event(#"{"choices":[{"delta":{"content":"🌱"}}]}"#) == .content("🌱"))
    #expect(event("[DONE]") == .finished(""))
    #expect(event(#"{"error":{"code":503,"message":"Loading model","type":"unavailable_error"}}"#) == .error(status: 503))
    #expect(event(#"{"error":{"message":"no code"}}"#) == .error(status: 500))
    // #152: LM Studio and Ollama can send a text code or a plain text.
    #expect(event(#"{"error":{"code":"model_not_found","message":"x"}}"#) == .error(status: 500))
    #expect(event(#"{"error":"Model crashed"}"#) == .error(status: 500))
    #expect(event(#"{"choices":[{"delta":{"content":"Hi"#) == .malformed)
    #expect(event("not json") == .malformed)
    #expect(event(#"{"id":"x"}"#) == .malformed)
    #expect(event(#"{"choices":"nope"}"#) == .malformed)
    #expect(ChatStreamEvent(data: [0x7B, 0xC3, 0x7D]) == .malformed)
}

// MARK: - Client outcomes

@Test func answerGrowsWithTheFullTextInEachUpdate() async throws {
    let updates = await answer(chunk("A loop "), chunk("repeats"), chunk(" steps.", finish: "stop"), done)
    #expect(updates == [.delta(text: "A loop "), .delta(text: "A loop repeats"), .delta(text: "A loop repeats steps."),
                        .ended(.finished, text: "A loop repeats steps.")])
}

@Test func splitFramesAndCharactersGiveWholeText() async throws {
    let body = Array((chunk("Café") + chunk(" 🌱") + done).utf8)
    // Cut inside "é" and inside the emoji, and inside the `data:` field names.
    let cuts = [3, body.firstIndex(of: 0xC3)! + 1, body.lastIndex(of: 0xF0)! + 2, body.count - 3]
    var parts: [Data] = []
    var start = 0
    for cut in cuts {
        parts.append(Data(body[start..<cut]))
        start = cut
    }
    parts.append(Data(body[start...]))
    let updates = await answer(parts)
    #expect(updates == [.delta(text: "Café"), .delta(text: "Café 🌱"), .ended(.finished, text: "Café 🌱")])
}

@Test func malformedDataKeepsThePartialAnswer() async throws {
    #expect(await answer(chunk("Part"), "data: {\"choices\":\n\n", chunk("never")) == [
        .delta(text: "Part"), .ended(.malformed, text: "Part"),
    ])
    #expect(await answer([Data(chunk("Part").utf8), Data([0x64, 0x61, 0x74, 0x61, 0x3A, 0xFF, 0x0A, 0x0A])]) == [
        .delta(text: "Part"), .ended(.malformed, text: "Part"),
    ])
}

@Test func errorsGiveTheStatusWithNoText() async throws {
    #expect(await answer(status: 500, "{\"error\":{\"code\":500}}") == [.ended(.httpError(status: 500), text: "")])
    #expect(await answer(status: 503) == [.ended(.httpError(status: 503), text: "")])
    #expect(await answer(chunk("Half"), "data: {\"error\":{\"code\":400,\"message\":\"context full\"}}\n\n") == [
        .delta(text: "Half"), .ended(.httpError(status: 400), text: ""),
    ])
    for status in [301, 302, 307, 401, 403] {
        #expect(await answer(status: status) == [.ended(.untrusted, text: "")], "\(status)")
    }
}

@Test func disconnectKeepsThePartialAnswer() async throws {
    #expect(await answer(chunk("Half"), end: URLError(.networkConnectionLost)) == [
        .delta(text: "Half"), .ended(.disconnected, text: "Half"),
    ])
    // The body ends with no finish event.
    #expect(await answer(chunk("Half"), chunk(" more")) == [
        .delta(text: "Half"), .delta(text: "Half more"), .ended(.disconnected, text: "Half more"),
    ])
    #expect(await answer(end: URLError(.cannotConnectToHost)) == [.ended(.disconnected, text: "")])
}

@Test func emptyStreamsGiveNoAnswer() async throws {
    #expect(await answer() == [.ended(.empty, text: "")])
    #expect(await answer(done) == [.ended(.empty, text: "")])
    #expect(await answer(chunk(""), chunk("", finish: "stop"), done) == [.ended(.empty, text: "")])
    #expect(await answer(": ping\n\n", "data: {\"choices\":[{\"delta\":{\"role\":\"assistant\"}}]}\n\n") == [.ended(.empty, text: "")])
}

// MARK: - Cancel and request identity

@Test func cancelEndsAtOnceAndIgnoresLateEvents() async throws {
    let transport = ScriptedTransport()
    let client = LlamaClient(transport: transport)
    let first = client.ask(question, endpoint: LocalAIEndpoint(port: 8080, apiKey: secret))
    let stream = await transport.next()
    stream.yield(.response(status: 200))
    stream.yield(.data(Data(chunk("Partial").utf8)))
    var updates = first.updates.makeAsyncIterator()
    #expect(await updates.next() == .delta(text: "Partial"))

    // The transport stays open. Cancel does not wait for it.
    client.cancel(first.id)
    #expect(!client.isBusy)
    #expect(await updates.next() == .ended(.canceled, text: "Partial"))
    #expect(await updates.next() == nil)

    // Late events of the first request go nowhere, also after a new request starts.
    let second = client.ask(question, endpoint: LocalAIEndpoint(port: 8080, apiKey: secret))
    stream.yield(.data(Data((chunk(" late") + done).utf8)))
    stream.finish()
    let next = await transport.next()
    next.yield(.response(status: 200))
    next.yield(.data(Data((chunk("New") + done).utf8)))
    next.finish()
    #expect(await collect(second) == [.delta(text: "New"), .ended(.finished, text: "New")])

    // A second cancel and a cancel of an old id do nothing.
    client.cancel(first.id)
    client.cancel(second.id)
    #expect(transport.requests.count == 2)
    #expect(transport.terminated == 2)
}

@Test func cancelBeforeAnyTextGivesNoPartialAnswer() async throws {
    let transport = ScriptedTransport()
    let client = LlamaClient(transport: transport)
    let request = client.ask(question, endpoint: LocalAIEndpoint(port: 8080, apiKey: secret))
    client.cancel(request.id)
    #expect(await collect(request) == [.ended(.canceled, text: "")])
    #expect(!client.isBusy)
}

@Test func secondQuestionIsBusyWhileTheFirstRuns() async throws {
    let transport = ScriptedTransport()
    let client = LlamaClient(transport: transport)
    let first = client.ask(question, endpoint: LocalAIEndpoint(port: 8080, apiKey: secret))
    let stream = await transport.next()
    let second = client.ask(question, endpoint: LocalAIEndpoint(port: 8080, apiKey: secret))
    #expect(second.id != first.id)
    #expect(await collect(second) == [.ended(.busy, text: "")])
    // A cancel with the busy id does not stop the first request.
    client.cancel(second.id)
    #expect(client.isBusy)
    stream.yield(.response(status: 200))
    stream.yield(.data(Data((chunk("One") + done).utf8)))
    stream.finish()
    #expect(await collect(first) == [.delta(text: "One"), .ended(.finished, text: "One")])
    #expect(transport.requests.count == 1)
}

@Test func consumerThatStopsReadingCancelsTheRequest() async throws {
    let transport = ScriptedTransport()
    let client = LlamaClient(transport: transport)
    let request = client.ask(question, endpoint: LocalAIEndpoint(port: 8080, apiKey: secret))
    let stream = await transport.next()
    let reader = Task { await collect(request) }
    stream.yield(.response(status: 200))
    stream.yield(.data(Data(chunk("Hi").utf8)))
    // The #128 tab cancels its reader task when the lecture closes.
    reader.cancel()
    _ = await reader.value
    #expect(!client.isBusy)
    // The canceled request also stops the transport.
    while transport.terminated == 0 { await Task.yield() }
}

// MARK: - Endpoint and secret

@Test func clientRejectsEndpointsThatAreNotTheOwnedLoopbackServer() async throws {
    let transport = ScriptedTransport()
    let client = LlamaClient(transport: transport)
    let rejected = ["http://example.com:8080", "http://localhost:8080", "https://127.0.0.1:8080", "http://127.0.0.2:8080",
                    "http://10.0.0.1:8080", "http://127.0.0.1", "http://user:pass@127.0.0.1:8080", "http://127.0.0.1:8080/proxy",
                    "http://127.0.0.1:8080?to=example.com", "file:///tmp/socket", "http://0.0.0.0:8080"]
    for text in rejected {
        let request = client.ask(question, baseURL: URL(string: text)!, apiKey: secret)
        #expect(await collect(request) == [.ended(.untrusted, text: "")], "\(text)")
    }
    for key in ["", "secret", String(secret.dropLast()), secret.uppercased(), secret + "\r\nX-Other: 1", String(secret.dropLast()) + " "] {
        let request = client.ask(question, endpoint: LocalAIEndpoint(port: 8080, apiKey: key))
        #expect(await collect(request) == [.ended(.untrusted, text: "")], "\(key.debugDescription)")
    }
    #expect(transport.requests.isEmpty)
    #expect(!client.isBusy)
    #expect(LlamaClient.isLoopback(URL(string: "http://127.0.0.1:8080")!))
    #expect(LlamaClient.isLoopback(URL(string: "http://127.0.0.1:8080/")!))
    #expect(LlamaClient.isLoopback(URL(string: "http://[::1]:8080")!))
}

@Test func chatRequestCarriesTheSecretAndNoCookies() throws {
    let request = try #require(LlamaClient.chatRequest(question, baseURL: URL(string: "http://127.0.0.1:8080")!, apiKey: secret))
    #expect(request.url?.absoluteString == "http://127.0.0.1:8080/v1/chat/completions")
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(secret)")
    #expect(request.value(forHTTPHeaderField: "Accept") == "text/event-stream")
    #expect(!request.httpShouldHandleCookies)
    let data = try #require(request.httpBody)
    let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(body["stream"] as? Bool == true)
    #expect((body["messages"] as? [[String: String]]) == [["role": "user", "content": "What is a loop?"]])
}

// MARK: - Real transport with a stub server

/// An HTTP/1.1 server on 127.0.0.1 for the transport tests. It reads each request, then runs `respond` on the socket.
final class StubServer: @unchecked Sendable {
    let port: Int
    private let listener: Int32
    private let lock = NSLock()
    private var received: [String] = []

    var requests: [String] { lock.withLock { received } }

    init(respond: @escaping @Sendable (_ request: String, _ socket: Int32) -> Void) throws {
        let listening = socket(AF_INET, SOCK_STREAM, 0)
        try #require(listening >= 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listening, $0, length) == 0 && listen(listening, 8) == 0 && getsockname(listening, $0, &length) == 0
            }
        }
        try #require(bound)
        listener = listening
        port = Int(UInt16(bigEndian: address.sin_port))
        Thread.detachNewThread { [weak self] in
            while true {
                let connection = accept(listening, nil, nil)
                guard connection >= 0 else { return }
                var on: Int32 = 1
                setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
                let request = Self.readRequest(connection)
                self?.lock.withLock { self?.received.append(request) }
                respond(request, connection)
                close(connection)
            }
        }
    }

    deinit {
        shutdown(listener, SHUT_RDWR)
        close(listener)
    }

    /// The head and the body, by `Content-Length`.
    private static func readRequest(_ connection: Int32) -> String {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            if let head = data.range(of: Data("\r\n\r\n".utf8)) {
                let text = String(decoding: data[..<head.lowerBound], as: UTF8.self).lowercased()
                let length = text.split(separator: "\r\n").first { $0.hasPrefix("content-length:") }
                    .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) } ?? 0
                if data.count - head.upperBound >= length { break }
            }
            let count = read(connection, &buffer, buffer.count)
            guard count > 0 else { break }
            data.append(contentsOf: buffer[..<count])
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func write(_ socket: Int32, _ text: String) {
        let bytes = Array(text.utf8)
        var sent = 0
        while sent < bytes.count {
            let count = bytes[sent...].withUnsafeBytes { Darwin.write(socket, $0.baseAddress, $0.count) }
            guard count > 0 else { return }
            sent += count
        }
    }

    static func head(_ status: String, _ headers: String = "") -> String {
        "HTTP/1.1 \(status)\r\n\(headers)Connection: close\r\n\r\n"
    }

    static let streamHead = head("200 OK", "Content-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n")

    /// One chunk of a chunked body.
    static func part(_ text: String) -> String {
        String(Array(text.utf8).count, radix: 16) + "\r\n" + text + "\r\n"
    }
}

private func ask(_ server: StubServer) async -> [AnswerUpdate] {
    let client = LlamaClient(transport: LoopbackTransport())
    return await collect(client.ask(question, endpoint: LocalAIEndpoint(port: server.port, apiKey: secret)))
}

@Test func loopbackTransportStreamsTheAnswer() async throws {
    let server = try StubServer { _, socket in
        StubServer.write(socket, StubServer.streamHead + StubServer.part(chunk("Caf")))
        StubServer.write(socket, StubServer.part(chunk("é 🌱")) + StubServer.part(done) + "0\r\n\r\n")
    }
    let updates = await ask(server)
    #expect(updates.last == .ended(.finished, text: "Café 🌱"))
    #expect(updates.dropLast().allSatisfy { if case .delta(let text) = $0 { "Café 🌱".hasPrefix(text) } else { false } })
    let request = try #require(server.requests.first)
    #expect(request.hasPrefix("POST /v1/chat/completions HTTP/1.1\r\n"))
    #expect(request.contains("Authorization: Bearer \(secret)\r\n"))
    #expect(!request.lowercased().contains("\r\ncookie:"))
    #expect(request.contains("\"stream\":true"))
}

@Test func loopbackTransportGivesDisconnectWhenTheServerStops() async throws {
    let server = try StubServer { _, socket in
        StubServer.write(socket, StubServer.streamHead + StubServer.part(chunk("Half")))
    }
    #expect(await ask(server) == [.delta(text: "Half"), .ended(.disconnected, text: "Half")])
}

@Test func loopbackTransportGivesTheStatusOfAnError() async throws {
    let server = try StubServer { _, socket in
        let body = #"{"error":{"code":500,"message":"boom"}}"#
        StubServer.write(socket, StubServer.head("500 Internal Server Error", "Content-Length: \(body.utf8.count)\r\n") + body)
    }
    #expect(await ask(server) == [.ended(.httpError(status: 500), text: "")])
}

@Test func loopbackTransportStopsAtAWrongSecretAndARedirect() async throws {
    let unauthorized = try StubServer { _, socket in
        let body = #"{"error":{"code":401,"message":"Invalid API Key"}}"#
        StubServer.write(socket, StubServer.head("401 Unauthorized", "WWW-Authenticate: Bearer\r\nContent-Length: \(body.utf8.count)\r\n") + body)
    }
    #expect(await ask(unauthorized) == [.ended(.untrusted, text: "")])

    let other = try StubServer { _, socket in StubServer.write(socket, StubServer.streamHead + StubServer.part(done) + "0\r\n\r\n") }
    let redirect = try StubServer { _, socket in
        StubServer.write(socket, StubServer.head("307 Temporary Redirect",
                                                 "Location: http://127.0.0.1:\(other.port)/v1/chat/completions\r\nContent-Length: 0\r\n"))
    }
    #expect(await ask(redirect) == [.ended(.untrusted, text: "")])
    #expect(other.requests.isEmpty)
}
