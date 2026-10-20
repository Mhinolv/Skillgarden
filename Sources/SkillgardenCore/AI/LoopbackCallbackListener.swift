import Foundation
import Network

/// The loopback redirect target of Sign in with ChatGPT (#156). It listens on `127.0.0.1` at a free port, accepts local
/// connections only and reads one HTTP request line from each connection. A GET of `path` goes to `callbacks` and gets a
/// short page. Other requests get 404. It never logs the query, because the query holds the authorization code.
public final class LoopbackCallbackListener: @unchecked Sendable {
    public let path: String
    /// The callback URLs, in order of arrival.
    public let callbacks: AsyncStream<URL>
    private let continuation: AsyncStream<URL>.Continuation
    private let queue = DispatchQueue(label: "com.skillgarden.chatgpt-callback")
    private let lock = NSLock()
    private var listener: NWListener?

    public static let finishedPage = """
        <!doctype html><html><head><meta charset="utf-8"><title>Skillgarden</title></head>\
        <body><p>Sign-in finished. Go back to Skillgarden.</p></body></html>
        """

    public init(path: String = "/auth/callback") {
        self.path = path
        (callbacks, continuation) = AsyncStream<URL>.makeStream()
    }

    deinit { stop() }

    /// Starts the listener and gives the redirect URI, for example `http://127.0.0.1:53682/auth/callback`.
    public func start() async throws(ChatGPTAuthError) -> URL {
        let parameters = NWParameters.tcp
        parameters.acceptLocalOnly = true
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        guard let listener = try? NWListener(using: parameters) else { throw .listenerFailed }
        lock.withLock { self.listener = listener }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        let port: UInt16? = await withCheckedContinuation { (ready: CheckedContinuation<UInt16?, Never>) in
            let once = Once(ready)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: once.resume(listener.port?.rawValue)
                case .failed, .cancelled: once.resume(nil)
                default: break
                }
            }
            listener.start(queue: queue)
        }
        guard let port else { stop(); throw .listenerFailed }
        return URL(string: "http://127.0.0.1:\(port)\(path)")!
    }

    public func stop() {
        let listener = lock.withLock { () -> NWListener? in
            defer { self.listener = nil }
            return self.listener
        }
        listener?.cancel()
        continuation.finish()
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    /// Reads until the end of the request head, up to 16 KB.
    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if buffer.range(of: Data("\r\n\r\n".utf8)) != nil || isComplete || error != nil || buffer.count >= 16_384 {
                self.respond(connection, head: buffer)
            } else {
                self.receive(connection, buffer: buffer)
            }
        }
    }

    private func respond(_ connection: NWConnection, head: Data) {
        let callback = callbackURL(requestHead: head, port: lock.withLock { listener?.port?.rawValue })
        let (status, body) = callback == nil ? ("404 Not Found", "Not found.") : ("200 OK", Self.finishedPage)
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\n"
            + "Cache-Control: no-store\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
        if let callback { continuation.yield(callback) }
    }

    /// The callback URL of a `GET <path>?<query> HTTP/1.1` request line. Nil for another method or path.
    func callbackURL(requestHead: Data, port: UInt16?) -> URL? {
        guard let port, let line = String(decoding: requestHead, as: UTF8.self).components(separatedBy: "\r\n").first else { return nil }
        let parts = line.split(separator: " ")
        guard parts.count == 3, parts[0] == "GET", parts[2].hasPrefix("HTTP/1."), parts[1].hasPrefix("/"),
              let url = URL(string: "http://127.0.0.1:\(port)\(parts[1])"), url.path == path else { return nil }
        return url
    }
}

/// Resumes a continuation one time only.
private final class Once<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?

    init(_ continuation: CheckedContinuation<Value, Never>) { self.continuation = continuation }

    func resume(_ value: Value) {
        let continuation = lock.withLock { () -> CheckedContinuation<Value, Never>? in
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(returning: value)
    }
}
