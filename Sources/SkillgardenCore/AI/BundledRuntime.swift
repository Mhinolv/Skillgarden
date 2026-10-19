import Darwin
import Foundation

/// The real supervisor backend: the runtime in `Skillgarden.app/Contents/Helpers` (#121, #123).
public struct BundledRuntime: LocalAIBackend {
    /// `Contents/Helpers`: `SkillgardenAIHost` and `llama/llama-server` with `llama/runtime.json`.
    public let helpersDirectory: URL
    private let session: URLSession

    public init(helpersDirectory: URL = Bundle.main.bundleURL.appending(path: "Contents/Helpers", directoryHint: .isDirectory)) {
        self.helpersDirectory = helpersDirectory
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        session = URLSession(configuration: configuration)
    }

    public func locateRuntime() -> Result<LocalAIRuntime, LocalAIProblem> {
        let llama = helpersDirectory.appending(path: "llama", directoryHint: .isDirectory)
        let server = llama.appending(path: "llama-server")
        let host = helpersDirectory.appending(path: "SkillgardenAIHost")
        guard FileManager.default.isExecutableFile(atPath: server.path), FileManager.default.isExecutableFile(atPath: host.path),
              let data = try? Data(contentsOf: llama.appending(path: "runtime.json")),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = manifest["version"] as? String, !version.isEmpty else {
            return .failure(.runtimeMissing)
        }
        return .success(LocalAIRuntime(server: server, host: host, version: version))
    }

    public func freePort() -> Int? {
        LoopbackPorts.freePort()
    }

    public func launch(_ runtime: LocalAIRuntime, model: LocalModel, port: Int, apiKey: String) throws -> any LocalAIProcess {
        try HostedServer(host: runtime.host,
                         arguments: ["--parent-pid", String(getpid()), "--", runtime.server.path]
                             + Self.serverArguments(model: model.url, port: port),
                         // llama-server reads `--api-key` from LLAMA_API_KEY, so the secret is not in the process list.
                         environment: ["LLAMA_API_KEY": apiKey])
    }

    /// One inference slot, on the loopback address only.
    static func serverArguments(model: URL, port: Int) -> [String] {
        ["--model", model.path(percentEncoded: false), "--host", "127.0.0.1", "--port", String(port), "--parallel", "1",
         "--ctx-size", String(LectureContextBudget.standard.contextTokens)]
    }

    /// `/health` gives 200 when the model is loaded and 503 while it loads.
    public func isHealthy(port: Int) async -> Bool {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/health")!)
        request.timeoutInterval = 2
        guard let (_, response) = try? await session.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }
}

/// `SkillgardenAIHost` with its `llama-server` child. The app keeps the write end of the helper stdin open.
/// When the app stops for any reason, the pipe closes and the helper stops the server.
final class HostedServer: LocalAIProcess, @unchecked Sendable {
    /// The log text to keep for the error reason.
    static let outputLimit = 64 * 1024

    private let process = Process()
    private let input = Pipe()
    private let lock = NSLock()
    private var log = Data()
    private var status: Int32?
    private var outputClosed = false
    private var processStatus: Int32?
    private var waiters: [CheckedContinuation<Int32, Never>] = []

    init(host: URL, arguments: [String], environment: [String: String]) throws {
        process.executableURL = host
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        // Later children must not keep the pipe open, or the helper misses the close.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETFD, FD_CLOEXEC)
        process.standardInput = input
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        process.terminationHandler = { [weak self] process in
            let code = process.terminationReason == .uncaughtSignal ? 128 + process.terminationStatus : process.terminationStatus
            self?.finish(processStatus: code)
        }
        try process.run()
        let reader = output.fileHandleForReading
        Thread.detachNewThread { [weak self] in
            while true {
                let data = reader.availableData
                guard !data.isEmpty else { break }
                self?.append(data)
            }
            try? reader.close()
            self?.finish(outputClosed: true)
        }
    }

    var exitStatus: Int32? { lock.withLock { status } }

    var output: String { lock.withLock { String(decoding: log, as: UTF8.self) } }

    func terminate() {
        guard process.isRunning else { return }
        process.terminate()
    }

    func waitForExit() async -> Int32 {
        await withCheckedContinuation { continuation in
            lock.withLock {
                if let status { continuation.resume(returning: status) } else { waiters.append(continuation) }
            }
        }
    }

    func waitUntilExit(timeout: TimeInterval) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while exitStatus == nil && Date() < deadline { usleep(20_000) }
        return exitStatus != nil
    }

    func ownsPort(_ port: Int) -> Bool {
        LoopbackPorts.childPIDs(of: process.processIdentifier).contains { LoopbackPorts.isListening(pid: $0, port: port) }
    }

    private func append(_ data: Data) {
        lock.withLock {
            log.append(data)
            if log.count > Self.outputLimit { log.removeFirst(log.count - Self.outputLimit) }
        }
    }

    /// The exit counts after the process stopped and its log closed, so the error reason sees the last lines.
    private func finish(processStatus code: Int32? = nil, outputClosed closed: Bool = false) {
        let resumed: (Int32, [CheckedContinuation<Int32, Never>])? = lock.withLock {
            if let code { processStatus = code }
            if closed { outputClosed = true }
            guard status == nil, let processStatus, outputClosed else { return nil }
            status = processStatus
            defer { waiters = [] }
            return (processStatus, waiters)
        }
        if let (code, waiters) = resumed { waiters.forEach { $0.resume(returning: code) } }
    }
}

/// Loopback ports and the owner check of a listening port.
enum LoopbackPorts {
    /// A port on 127.0.0.1 that no program uses now. Nil when the system gives none.
    static func freePort() -> Int? {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { return nil }
        defer { close(socket) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let found = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socket, $0, length) == 0 && getsockname(socket, $0, &length) == 0
            }
        }
        let port = Int(UInt16(bigEndian: address.sin_port))
        return found && port > 0 ? port : nil
    }

    /// The direct children of `pid`.
    static func childPIDs(of pid: pid_t) -> [pid_t] {
        var pids = [pid_t](repeating: 0, count: 64)
        let bytes = proc_listpids(UInt32(PROC_PPID_ONLY), UInt32(pid), &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard bytes > 0 else { return [] }
        return pids.prefix(Int(bytes) / MemoryLayout<pid_t>.size).filter { $0 > 0 }
    }

    /// True when `pid` has a TCP socket that listens on `port`.
    static func isListening(pid: pid_t, port: Int) -> Bool {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return false }
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / MemoryLayout<proc_fdinfo>.stride)
        let used = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &descriptors, Int32(descriptors.count * MemoryLayout<proc_fdinfo>.stride))
        guard used > 0 else { return false }
        return descriptors.prefix(Int(used) / MemoryLayout<proc_fdinfo>.stride).contains { descriptor in
            guard descriptor.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) else { return false }
            var info = socket_fdinfo()
            let infoSize = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO, &info, infoSize) == infoSize,
                  info.psi.soi_kind == Int32(SOCKINFO_TCP) else { return false }
            let tcp = info.psi.soi_proto.pri_tcp
            return tcp.tcpsi_state == TSI_S_LISTEN && Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport))) == port
        }
    }
}
