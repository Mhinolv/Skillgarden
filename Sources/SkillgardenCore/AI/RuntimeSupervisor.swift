import Foundation
import Observation

/// Why local AI can't start (#123). The Settings status row shows `message` under "Can't start local AI.".
public enum LocalAIProblem: Error, Equatable, Sendable {
    case noFreePort
    /// The model did not load. Usually the Mac does not have enough memory for it.
    case modelDidNotLoad
    /// The server stopped by itself. A signal gives 128 + the signal number.
    case serverStopped(exitCode: Int32)
    /// The app has no `llama-server`, no `SkillgardenAIHost` or no `runtime.json`.
    case runtimeMissing

    /// The design-note reason for the `.caption` line.
    public var message: String {
        switch self {
        case .noFreePort: "No free port on this Mac."
        case .modelDidNotLoad: "The model did not load. It can need more memory than this Mac has."
        case .serverStopped(let code): "The server stopped. Exit code \(code)."
        case .runtimeMissing: "The local AI runtime is missing from the app."
        }
    }

    /// The problem of a server that stopped before it was ready, from the last lines of its log.
    /// A port that another program took gives `noFreePort`, so the supervisor tries another port.
    static func classify(exitCode: Int32, output: String) -> LocalAIProblem {
        let text = output.lowercased()
        if ["couldn't bind", "could not bind", "address already in use"].contains(where: text.contains) { return .noFreePort }
        if ["failed to load model", "error loading model", "model loading error", "failed to allocate", "out of memory"]
            .contains(where: text.contains) {
            return .modelDidNotLoad
        }
        return .serverStopped(exitCode: exitCode)
    }
}

/// The Settings "Local AI" status row (#123). #128 uses the same words.
public enum LocalAIStatus: Equatable, Sendable {
    case off
    case noModel
    case starting
    /// The server answers `/health`. `version` is the pinned llama.cpp release, for example `b11669`.
    case ready(version: String)
    case failed(LocalAIProblem)
    case stopping

    public var text: String {
        switch self {
        case .off: "Off"
        case .noModel: "No model. Choose a model to use local AI."
        case .starting: "Starting…"
        case .ready(let version): "Ready · llama.cpp \(version)"
        case .failed: "Can't start local AI."
        case .stopping: "Stopping…"
        }
    }

    /// The `.caption` line of the Error state. Nil for the other states.
    public var reason: String? {
        if case .failed(let problem) = self { problem.message } else { nil }
    }

    /// The VoiceOver text of the row: `Status, <text>`, then the reason.
    public var accessibilityLabel: String {
        "Status, \(text)" + (reason.map { " \($0)" } ?? "")
    }

    /// The accessibility announcement for Ready and Error. Nil for the other states.
    public var announcement: String? {
        switch self {
        case .ready: text
        case .failed: text + (reason.map { " \($0)" } ?? "")
        default: nil
        }
    }
}

/// The address and the session secret of the owned server. Send the secret as `Authorization: Bearer <apiKey>`.
public struct LocalAIEndpoint: Equatable, Sendable {
    public let port: Int
    public let apiKey: String
    /// The file name of the model that the server runs (#150). Nil when it is not known.
    public var modelID: String? = nil

    /// `http://127.0.0.1:<port>`. The server listens on the loopback address only.
    public var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }
}

/// The runtime files in the app bundle (#121).
public struct LocalAIRuntime: Equatable, Sendable {
    public let server: URL
    /// The `SkillgardenAIHost` helper that runs the server and stops it when the app dies.
    public let host: URL
    public let version: String

    public init(server: URL, host: URL, version: String) {
        self.server = server
        self.host = host
        self.version = version
    }
}

/// One started server. The real one is `HostedServer`. Tests use a fake.
public protocol LocalAIProcess: AnyObject, Sendable {
    /// Nil while the process runs.
    var exitStatus: Int32? { get }
    /// The last lines of the server log.
    var output: String { get }
    /// Asks the process to stop. It does not wait.
    func terminate()
    func waitForExit() async -> Int32
    /// Waits at most `timeout` seconds. True when the process stopped.
    func waitUntilExit(timeout: TimeInterval) -> Bool
    /// True when the owned server listens on `port`, so no other program can get lecture text.
    func ownsPort(_ port: Int) -> Bool
}

/// The system calls of the supervisor. The real one is `BundledRuntime`. Tests use a fake.
public protocol LocalAIBackend: Sendable {
    func locateRuntime() -> Result<LocalAIRuntime, LocalAIProblem>
    func freePort() -> Int?
    func launch(_ runtime: LocalAIRuntime, model: LocalModel, port: Int, apiKey: String) throws -> any LocalAIProcess
    func isHealthy(port: Int) async -> Bool
}

/// Owns the one `llama-server` of the app (#123). It starts at launch when AI is on and a valid model is set,
/// and it stops at quit. Closing the last window does not stop it.
@MainActor @Observable
public final class RuntimeSupervisor {
    /// The tries with a new port when another program takes the port first.
    static let portAttempts = 3

    public private(set) var status: LocalAIStatus
    /// The Settings "Use local AI" toggle. Off stops the server and skips the start.
    public private(set) var isEnabled: Bool
    /// The owned server while the status is Ready. Use `verifiedEndpoint()` before you send lecture text.
    public private(set) var endpoint: LocalAIEndpoint?

    @ObservationIgnored private var model: LocalModel?
    @ObservationIgnored private var hasStarted = false
    /// Nil for the snapshot harness, which injects `status` and starts no runtime.
    @ObservationIgnored private let backend: (any LocalAIBackend)?
    @ObservationIgnored private let saveEnabled: ((Bool) -> Void)?
    @ObservationIgnored private let pollInterval: Duration
    @ObservationIgnored private let readyTimeout: Duration
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var process: (any LocalAIProcess)?

    public init(isEnabled: Bool, backend: (any LocalAIBackend)?, saveEnabled: ((Bool) -> Void)? = nil, status: LocalAIStatus? = nil,
                pollInterval: Duration = .milliseconds(250), readyTimeout: Duration = .seconds(300)) {
        self.isEnabled = isEnabled
        self.backend = backend
        self.saveEnabled = saveEnabled
        self.status = status ?? (isEnabled ? .noModel : .off)
        self.pollInterval = pollInterval
        self.readyTimeout = readyTimeout
    }

    /// Sets the chosen model. The first call starts the server, and a new model restarts it.
    public func setModel(_ model: LocalModel?) {
        guard !hasStarted || model != self.model else { return }
        self.model = model
        apply()
    }

    /// The Settings toggle. Each change is saved at once.
    public func setEnabled(_ on: Bool) {
        guard on != isEnabled else { return }
        isEnabled = on
        saveEnabled?(on)
        apply()
    }

    /// The `Try Again` button of the Error state.
    public func retry() {
        apply()
    }

    /// Waits for the running change: a start until Ready or Error, or a stop.
    public func waitForChanges() async {
        await task?.value
    }

    /// The endpoint, only while the owned server runs and listens on its port.
    public func verifiedEndpoint() -> LocalAIEndpoint? {
        guard case .ready = status, let endpoint, let process, process.exitStatus == nil, process.ownsPort(endpoint.port) else {
            return nil
        }
        return endpoint
    }

    /// App quit (⌘Q): cancels the work and stops the server. It waits at most `timeout` seconds.
    /// If the app stops first, the helper stops the server when its pipe from the app closes.
    public func stopForQuit(timeout: TimeInterval = 2) {
        task?.cancel()
        task = nil
        guard let process else { return }
        self.process = nil
        endpoint = nil
        status = .stopping
        process.terminate()
        _ = process.waitUntilExit(timeout: timeout)
        status = .off
    }

    /// Cancels the running change, stops the server, then starts it again when AI is on and a model is set.
    private func apply() {
        hasStarted = true
        guard let backend else { return }
        let previous = task
        previous?.cancel()
        task = Task { [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled else { return }
            await self.stopServer()
            guard !Task.isCancelled else { return }
            await self.start(backend)
        }
    }

    private func stopServer() async {
        guard let process else { return }
        self.process = nil
        endpoint = nil
        status = .stopping
        process.terminate()
        _ = await process.waitForExit()
        status = .off
    }

    private func start(_ backend: any LocalAIBackend) async {
        guard isEnabled else { status = .off; return }
        guard let model else { status = .noModel; return }
        let runtime: LocalAIRuntime
        switch backend.locateRuntime() {
        case .success(let found): runtime = found
        case .failure(let problem): status = .failed(problem); return
        }
        status = .starting
        for _ in 0..<Self.portAttempts {
            guard let port = backend.freePort() else { status = .failed(.noFreePort); return }
            let apiKey = Self.makeSecret()
            let process: any LocalAIProcess
            do {
                process = try backend.launch(runtime, model: model, port: port, apiKey: apiKey)
            } catch {
                status = .failed(.runtimeMissing)
                return
            }
            self.process = process
            switch await waitUntilReady(process, port: port, backend: backend) {
            case .ready:
                endpoint = LocalAIEndpoint(port: port, apiKey: apiKey, modelID: model.name)
                status = .ready(version: runtime.version)
                watch(process)
                return
            case .cancelled:
                // The next change stops the process.
                return
            case .timedOut:
                self.process = nil
                process.terminate()
                _ = await process.waitForExit()
                status = .failed(.modelDidNotLoad)
                return
            case .exited(let code):
                self.process = nil
                let problem = LocalAIProblem.classify(exitCode: code, output: process.output)
                guard problem == .noFreePort else { status = .failed(problem); return }
            }
        }
        status = .failed(.noFreePort)
    }

    private enum Readiness { case ready, exited(Int32), cancelled, timedOut }

    private func waitUntilReady(_ process: any LocalAIProcess, port: Int, backend: any LocalAIBackend) async -> Readiness {
        let deadline = ContinuousClock.now + readyTimeout
        while !Task.isCancelled {
            if let code = process.exitStatus { return .exited(code) }
            if await backend.isHealthy(port: port) {
                // A quit during the check stops the process. That stop is not an error.
                if Task.isCancelled { return .cancelled }
                // The health answer must come from the owned server, not from a program that took the port.
                if let code = process.exitStatus { return .exited(code) }
                return .ready
            }
            if ContinuousClock.now >= deadline { return .timedOut }
            try? await Task.sleep(for: pollInterval)
        }
        return .cancelled
    }

    /// Shows Error when the server stops by itself after Ready. A stop of the supervisor clears `process` first.
    private func watch(_ process: any LocalAIProcess) {
        Task { [weak self] in
            let code = await process.waitForExit()
            guard let self, self.process === process else { return }
            self.process = nil
            self.endpoint = nil
            self.status = .failed(.serverStopped(exitCode: code))
        }
    }

    /// A new 256-bit session secret for each start.
    static func makeSecret() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }.joined()
    }
}
