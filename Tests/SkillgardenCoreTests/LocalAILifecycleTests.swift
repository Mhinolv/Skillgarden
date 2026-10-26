import Darwin
import Foundation
import Testing
@testable import SkillgardenCore

// #123: the app owns one llama-server. These tests cover the status words, the supervisor with a fake backend,
// the real backend with a fake server script, and the SkillgardenAIHost helper with harmless children.

private final class TestBundleMarker {}

/// `swift test` builds the helper next to the test bundle.
private func builtHost() throws -> URL {
    let host = Bundle(for: TestBundleMarker.self).bundleURL.deletingLastPathComponent().appending(path: "SkillgardenAIHost")
    try #require(FileManager.default.isExecutableFile(atPath: host.path), "build SkillgardenAIHost before the tests")
    return host
}

private func temporaryFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appending(path: "LocalAILifecycleTests-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

private let model = LocalModel(url: URL(fileURLWithPath: "/models/qwen.gguf"), sizeBytes: 1)
private let otherModel = LocalModel(url: URL(fileURLWithPath: "/models/llama.gguf"), sizeBytes: 2)
private let runtime = LocalAIRuntime(server: URL(fileURLWithPath: "/app/llama-server"), host: URL(fileURLWithPath: "/app/host"),
                                     version: "b11669")

/// Waits until `condition` is true, at most `seconds`. The long default is for slow CI runners.
/// Use it only where no signal is available. The tests must not depend on the time that a step takes.
private func eventually(_ seconds: Double = 120, isolation: isolated (any Actor)? = #isolation, _ condition: () -> Bool) async -> Bool {
    let deadline = Date(timeIntervalSinceNow: seconds)
    while !condition() {
        if Date() > deadline { return false }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return true
}

/// True while a process with `pid` exists.
private func isAlive(_ pid: pid_t) -> Bool {
    kill(pid, 0) == 0 || errno != ESRCH
}

// MARK: - Fakes

private final class FakeProcess: LocalAIProcess, @unchecked Sendable {
    private let lock = NSLock()
    private var status: Int32?
    private var waiters: [CheckedContinuation<Int32, Never>] = []
    private(set) var terminateCount = 0
    let output: String
    let owns: Bool

    init(output: String = "", owns: Bool = true) {
        self.output = output
        self.owns = owns
    }

    var exitStatus: Int32? { lock.withLock { status } }

    func exit(_ code: Int32) {
        let waiting: [CheckedContinuation<Int32, Never>] = lock.withLock {
            guard status == nil else { return [] }
            status = code
            defer { waiters = [] }
            return waiters
        }
        waiting.forEach { $0.resume(returning: code) }
    }

    func terminate() {
        lock.withLock { terminateCount += 1 }
        exit(143)
    }

    func waitForExit() async -> Int32 {
        await withCheckedContinuation { continuation in
            lock.withLock {
                if let status { continuation.resume(returning: status) } else { waiters.append(continuation) }
            }
        }
    }

    func waitUntilExit(timeout: TimeInterval) -> Bool { exitStatus != nil }

    func ownsPort(_ port: Int) -> Bool { owns }
}

private final class FakeBackend: LocalAIBackend, @unchecked Sendable {
    struct Launch { let model: LocalModel; let port: Int; let apiKey: String }

    private let lock = NSLock()
    var runtimeResult: Result<LocalAIRuntime, LocalAIProblem> = .success(runtime)
    /// The next ports. When it is empty, the port is 8000 + the launch count.
    var ports: [Int?] = []
    var healthy = true
    /// When true, `isHealthy` waits for `setHealthy(true)` and does not answer false. The tests then need no clock.
    var waitsUntilHealthy = false
    /// The process of each launch, by launch index. Nil gives a process that runs.
    var processes: [Int: FakeProcess] = [:]
    private(set) var launches: [Launch] = []
    private(set) var launched: [FakeProcess] = []
    private var healthChecks = 0
    private var checkWaiters: [CheckedContinuation<Void, Never>] = []
    private var healthWaiters: [CheckedContinuation<Void, Never>] = []

    func locateRuntime() -> Result<LocalAIRuntime, LocalAIProblem> { lock.withLock { runtimeResult } }

    func freePort() -> Int? {
        lock.withLock { ports.isEmpty ? 8000 + launches.count : ports.removeFirst() }
    }

    func launch(_ runtime: LocalAIRuntime, model: LocalModel, port: Int, apiKey: String) throws -> any LocalAIProcess {
        lock.withLock {
            let process = processes[launches.count] ?? FakeProcess()
            launches.append(Launch(model: model, port: port, apiKey: apiKey))
            launched.append(process)
            return process
        }
    }

    func isHealthy(port: Int) async -> Bool {
        let (answer, waits, checkers) = lock.withLock {
            healthChecks += 1
            defer { checkWaiters = [] }
            return (healthy, waitsUntilHealthy, checkWaiters)
        }
        checkers.forEach { $0.resume() }
        guard !answer && waits else { return answer }
        await withCheckedContinuation { continuation in
            lock.withLock {
                if healthy { continuation.resume() } else { healthWaiters.append(continuation) }
            }
        }
        return true
    }

    func setHealthy(_ on: Bool) {
        let waiting: [CheckedContinuation<Void, Never>] = lock.withLock {
            healthy = on
            guard on else { return [] }
            defer { healthWaiters = [] }
            return healthWaiters
        }
        waiting.forEach { $0.resume() }
    }

    /// Returns after the first health check. The server then runs and the status is Starting.
    func waitForHealthCheck() async {
        await withCheckedContinuation { continuation in
            lock.withLock {
                if healthChecks > 0 { continuation.resume() } else { checkWaiters.append(continuation) }
            }
        }
    }
}

/// The success paths never wait for the timeout. The long time limit is for slow CI runners only.
@MainActor
private func supervisor(_ backend: FakeBackend, enabled: Bool = true, saved: ((Bool) -> Void)? = nil,
                        readyTimeout: Duration = .seconds(120)) -> RuntimeSupervisor {
    RuntimeSupervisor(isEnabled: enabled, backend: backend, saveEnabled: saved, pollInterval: .milliseconds(5), readyTimeout: readyTimeout)
}

// MARK: - Status words

@Test func statusWordsMatchTheDesignNotes() {
    #expect(LocalAIStatus.off.text == "Off")
    #expect(LocalAIStatus.noModel.text == "No model. Choose a model to use local AI.")
    #expect(LocalAIStatus.starting.text == "Starting…")
    #expect(LocalAIStatus.ready(version: "b11669").text == "Ready · llama.cpp b11669")
    #expect(LocalAIStatus.failed(.noFreePort).text == "Can't start local AI.")
    #expect(LocalAIStatus.stopping.text == "Stopping…")

    #expect(LocalAIProblem.noFreePort.message == "No free port on this Mac.")
    #expect(LocalAIProblem.modelDidNotLoad.message == "The model did not load. It can need more memory than this Mac has.")
    #expect(LocalAIProblem.serverStopped(exitCode: 9).message == "The server stopped. Exit code 9.")
    #expect(LocalAIProblem.runtimeMissing.message == "The local AI runtime is missing from the app.")

    let all: [LocalAIStatus] = [.off, .noModel, .starting, .ready(version: "b1"), .failed(.runtimeMissing), .stopping]
    #expect(all.filter { $0.reason != nil } == [.failed(.runtimeMissing)])
    #expect(all.filter { $0.announcement != nil } == [.ready(version: "b1"), .failed(.runtimeMissing)])
    #expect(LocalAIStatus.off.accessibilityLabel == "Status, Off")
    #expect(LocalAIStatus.failed(.noFreePort).accessibilityLabel == "Status, Can't start local AI. No free port on this Mac.")
    #expect(LocalAIStatus.failed(.noFreePort).announcement == "Can't start local AI. No free port on this Mac.")
    #expect(LocalAIStatus.ready(version: "b1").announcement == "Ready · llama.cpp b1")
}

@Test func serverLogGivesTheProblem() {
    #expect(LocalAIProblem.classify(exitCode: 1, output: "couldn't bind HTTP server socket, hostname: 127.0.0.1, port: 8080") == .noFreePort)
    #expect(LocalAIProblem.classify(exitCode: 1, output: "bind: Address already in use") == .noFreePort)
    #expect(LocalAIProblem.classify(exitCode: 1, output: "llama_model_load: error loading model: tensor data is not within file bounds")
        == .modelDidNotLoad)
    #expect(LocalAIProblem.classify(exitCode: 1, output: "main: exiting due to model loading error") == .modelDidNotLoad)
    #expect(LocalAIProblem.classify(exitCode: 1, output: "ggml_metal: failed to allocate buffer") == .modelDidNotLoad)
    #expect(LocalAIProblem.classify(exitCode: 139, output: "") == .serverStopped(exitCode: 139))
}

@Test func localAIChoiceIsOnWhenNothingIsSaved() {
    #expect(Skillgarden.localAIKey == "LocalAI")
    #expect(Skillgarden.autoPlay(savedValue: nil))
    #expect(!Skillgarden.autoPlay(savedValue: false))
}

// MARK: - Supervisor

@MainActor @Test func validSetupStartsAsynchronouslyAndBecomesReady() async throws {
    let backend = FakeBackend()
    backend.healthy = false
    backend.waitsUntilHealthy = true
    let ai = supervisor(backend)
    #expect(ai.status == .noModel)
    ai.setModel(model)
    // The call returns at once. The start runs in a task.
    #expect(backend.launches.isEmpty)
    await backend.waitForHealthCheck()
    #expect(ai.status == .starting)
    #expect(ai.endpoint == nil && ai.verifiedEndpoint() == nil)
    backend.setHealthy(true)
    await ai.waitForChanges()
    #expect(ai.status == .ready(version: "b11669"))
    let launch = try #require(backend.launches.first)
    #expect(backend.launches.count == 1)
    #expect(launch.model == model)
    #expect(ai.endpoint == LocalAIEndpoint(port: launch.port, apiKey: launch.apiKey, modelID: "qwen.gguf"))
    #expect(ai.verifiedEndpoint()?.baseURL.absoluteString == "http://127.0.0.1:\(launch.port)")
    // The same model again does not restart the server.
    ai.setModel(model)
    await ai.waitForChanges()
    #expect(backend.launches.count == 1)
}

@MainActor @Test func noModelStartsNothing() async {
    let backend = FakeBackend()
    let ai = supervisor(backend)
    ai.setModel(nil)
    await ai.waitForChanges()
    #expect(ai.status == .noModel)
    #expect(backend.launches.isEmpty)
}

@MainActor @Test func aiOffPreventsTheStartUntilTheLearnerTurnsItOn() async {
    let backend = FakeBackend()
    var saved: [Bool] = []
    let ai = supervisor(backend, enabled: false, saved: { saved.append($0) })
    #expect(ai.status == .off)
    ai.setModel(model)
    await ai.waitForChanges()
    #expect(ai.status == .off)
    #expect(backend.launches.isEmpty)
    ai.retry()
    await ai.waitForChanges()
    #expect(backend.launches.isEmpty)

    ai.setEnabled(true)
    await ai.waitForChanges()
    #expect(ai.status == .ready(version: "b11669"))
    #expect(backend.launches.count == 1)

    // Off stops the owned server: Stopping, then Off.
    ai.setEnabled(false)
    await ai.waitForChanges()
    #expect(ai.status == .off)
    #expect(backend.launched[0].terminateCount == 1)
    #expect(ai.endpoint == nil)
    #expect(saved == [true, false])
    // The same value again saves nothing.
    ai.setEnabled(false)
    #expect(saved == [true, false])
}

@MainActor @Test func aMissingRuntimeShowsTheError() async {
    let backend = FakeBackend()
    backend.runtimeResult = .failure(.runtimeMissing)
    let ai = supervisor(backend)
    ai.setModel(model)
    await ai.waitForChanges()
    #expect(ai.status == .failed(.runtimeMissing))
    #expect(backend.launches.isEmpty)
}

@MainActor @Test func aTakenPortTriesANewPort() async throws {
    let backend = FakeBackend()
    let taken = FakeProcess(output: "couldn't bind HTTP server socket")
    taken.exit(1)
    backend.processes = [0: taken]
    backend.ports = [9001, 9002]
    let ai = supervisor(backend)
    ai.setModel(model)
    await ai.waitForChanges()
    #expect(ai.status == .ready(version: "b11669"))
    #expect(backend.launches.map(\.port) == [9001, 9002])
    #expect(ai.endpoint?.port == 9002)
    // Each start has a new 256-bit secret.
    #expect(backend.launches.map(\.apiKey.count) == [64, 64])
    #expect(backend.launches[0].apiKey != backend.launches[1].apiKey)
}

@MainActor @Test func threeTakenPortsOrNoPortShowNoFreePort() async {
    let backend = FakeBackend()
    for index in 0..<3 {
        let taken = FakeProcess(output: "Address already in use")
        taken.exit(1)
        backend.processes[index] = taken
    }
    let ai = supervisor(backend)
    ai.setModel(model)
    await ai.waitForChanges()
    #expect(ai.status == .failed(.noFreePort))
    #expect(backend.launches.count == RuntimeSupervisor.portAttempts)

    let none = FakeBackend()
    none.ports = [nil]
    let noPort = supervisor(none)
    noPort.setModel(model)
    await noPort.waitForChanges()
    #expect(noPort.status == .failed(.noFreePort))
    #expect(none.launches.isEmpty)
}

@MainActor @Test func aModelThatDoesNotLoadShowsTheErrorAndTryAgainStartsAgain() async {
    let backend = FakeBackend()
    let failed = FakeProcess(output: "llama_model_load: error loading model")
    failed.exit(1)
    backend.processes = [0: failed]
    let ai = supervisor(backend)
    ai.setModel(model)
    await ai.waitForChanges()
    #expect(ai.status == .failed(.modelDidNotLoad))
    #expect(ai.endpoint == nil)

    ai.retry()
    await ai.waitForChanges()
    #expect(ai.status == .ready(version: "b11669"))
    #expect(backend.launches.count == 2)
}

@MainActor @Test func aSlowLoadTimesOutAndStopsTheServer() async {
    let backend = FakeBackend()
    backend.healthy = false
    let ai = supervisor(backend, readyTimeout: .milliseconds(50))
    ai.setModel(model)
    await ai.waitForChanges()
    #expect(ai.status == .failed(.modelDidNotLoad))
    #expect(backend.launched[0].terminateCount == 1)
}

@MainActor @Test func aServerThatStopsAfterReadyShowsTheExitCode() async {
    let backend = FakeBackend()
    let ai = supervisor(backend)
    ai.setModel(model)
    await ai.waitForChanges()
    #expect(ai.status == .ready(version: "b11669"))
    backend.launched[0].exit(9)
    #expect(await eventually { ai.status == .failed(.serverStopped(exitCode: 9)) })
    #expect(ai.endpoint == nil)
}

@MainActor @Test func aNewModelRestartsTheServer() async {
    let backend = FakeBackend()
    let ai = supervisor(backend)
    ai.setModel(model)
    await ai.waitForChanges()
    ai.setModel(otherModel)
    await ai.waitForChanges()
    #expect(ai.status == .ready(version: "b11669"))
    #expect(backend.launches.map(\.model) == [model, otherModel])
    #expect(backend.launched.map(\.terminateCount) == [1, 0])
    // An intended stop is not an error.
    #expect(ai.endpoint?.port == backend.launches[1].port)

    // A model that becomes invalid stops the server.
    ai.setModel(nil)
    await ai.waitForChanges()
    #expect(ai.status == .noModel)
    #expect(backend.launched.map(\.terminateCount) == [1, 1])
}

@MainActor @Test func quitStopsTheOwnedServerAndCancelsTheStart() async {
    let backend = FakeBackend()
    let ai = supervisor(backend)
    ai.setModel(model)
    await ai.waitForChanges()
    ai.stopForQuit()
    #expect(ai.status == .off)
    #expect(ai.endpoint == nil)
    #expect(backend.launched[0].terminateCount == 1)

    // A quit during Starting cancels the start, so the server never becomes Ready.
    let slow = FakeBackend()
    slow.healthy = false
    slow.waitsUntilHealthy = true
    let starting = supervisor(slow)
    starting.setModel(model)
    await slow.waitForHealthCheck()
    #expect(starting.status == .starting && slow.launched.count == 1)
    starting.stopForQuit()
    slow.setHealthy(true)
    try? await Task.sleep(for: .milliseconds(50))
    #expect(starting.status == .off)
    #expect(slow.launched[0].terminateCount == 1)
    #expect(slow.launches.count == 1)
}

@MainActor @Test func verifiedEndpointNeedsTheOwnedServerOnThePort() async {
    let backend = FakeBackend()
    backend.processes = [0: FakeProcess(owns: false)]
    let ai = supervisor(backend)
    ai.setModel(model)
    await ai.waitForChanges()
    #expect(ai.status == .ready(version: "b11669"))
    #expect(ai.endpoint != nil)
    #expect(ai.verifiedEndpoint() == nil)
}

@MainActor @Test func snapshotSupervisorStartsNoRuntime() async {
    let ai = RuntimeSupervisor(isEnabled: true, backend: nil, status: .failed(.noFreePort))
    ai.setModel(model)
    ai.retry()
    await ai.waitForChanges()
    #expect(ai.status == .failed(.noFreePort))
    #expect(SnapshotScreen.allCases.compactMap(\.localAIStatus)
        == [.ready(version: "b11669"), .noModel, .off, .failed(.noFreePort), .ready(version: "b11669"), .ready(version: "b11669"),
            .ready(version: "b11669"), .ready(version: "b11669"), .ready(version: "b11669"), .ready(version: "b11669"),
            .ready(version: "b11669"), .ready(version: "b11669"), .ready(version: "b11669"), .ready(version: "b11669"),
            .ready(version: "b11669"), .ready(version: "b11669"), .ready(version: "b11669"), .ready(version: "b11669"),
            .ready(version: "b11669"), .ready(version: "b11669"), .ready(version: "b11669"), .ready(version: "b11669"),
            .ready(version: "b11669")])
    #expect(SnapshotScreen.allCases.filter { $0.localAIStatus != nil } == SnapshotScreen.allCases.filter(\.isSettings))
}

// MARK: - Real backend

@Test func serverArgumentsUseOneSlotOnLoopback() {
    let arguments = BundledRuntime.serverArguments(model: URL(fileURLWithPath: "/Users/a b/m.gguf"), port: 8123)
    #expect(arguments == ["--model", "/Users/a b/m.gguf", "--host", "127.0.0.1", "--port", "8123", "--parallel", "1",
                          "--ctx-size", "8192", "--cache-ram", "0"])
    #expect(!arguments.contains("--api-key"))
}

/// #193: llama.cpp b11669 keeps the context of earlier prompts in a prompt cache of up to 8 GB (`--cache-ram`).
/// Each new lecture prompt adds to it, so the peak memory of the #176 check grew to 7.4 GB. The cache must be off.
@Test func serverArgumentsTurnOffThePromptCache() throws {
    let arguments = BundledRuntime.serverArguments(model: URL(fileURLWithPath: "/m.gguf"), port: 8123)
    let index = try #require(arguments.firstIndex(of: "--cache-ram"), "the prompt cache is on by default")
    #expect(arguments.indices.contains(index + 1) && arguments[index + 1] == "0")
}

/// A Helpers folder with the built helper and `llama/llama-server` as a shell script.
private func helpersFolder(server script: String?, version: String? = "b11669") throws -> URL {
    let helpers = try temporaryFolder().appending(path: "Helpers")
    let llama = helpers.appending(path: "llama")
    try FileManager.default.createDirectory(at: llama, withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: try builtHost(), to: helpers.appending(path: "SkillgardenAIHost"))
    if let script {
        let server = llama.appending(path: "llama-server")
        try "#!/bin/sh\n\(script)\n".write(to: server, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: server.path)
    }
    if let version {
        let manifest = BundledRuntime.manifest(helpersDirectory: helpers)
        try FileManager.default.createDirectory(at: manifest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"name":"llama.cpp","version":"\#(version)"}"#.utf8).write(to: manifest)
    }
    return helpers
}

@Test func bundledRuntimeNeedsTheServerTheHelperAndTheManifest() throws {
    let complete = try helpersFolder(server: "exit 0")
    defer { try? FileManager.default.removeItem(at: complete) }
    let found = try BundledRuntime(helpersDirectory: complete).locateRuntime().get()
    #expect(found.version == "b11669")
    #expect(found.server.lastPathComponent == "llama-server")
    #expect(found.host.lastPathComponent == "SkillgardenAIHost")

    for folder in [try helpersFolder(server: nil), try helpersFolder(server: "exit 0", version: nil)] {
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(BundledRuntime(helpersDirectory: folder).locateRuntime() == .failure(.runtimeMissing))
    }
    let noHost = try helpersFolder(server: "exit 0")
    defer { try? FileManager.default.removeItem(at: noHost) }
    try FileManager.default.removeItem(at: noHost.appending(path: "SkillgardenAIHost"))
    #expect(BundledRuntime(helpersDirectory: noHost).locateRuntime() == .failure(.runtimeMissing))
    // Outside an app bundle, as with `swift run`, the runtime is missing.
    #expect(BundledRuntime(helpersDirectory: URL(fileURLWithPath: "/nowhere")).locateRuntime() == .failure(.runtimeMissing))
}

@Test func freePortIsALoopbackPortThatTheOwnerCheckSees() throws {
    let port = try #require(LoopbackPorts.freePort())
    #expect(port > 0 && port <= 65535)
    // This process listens on the port, so the owner check finds it.
    let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    try #require(socket >= 0)
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = UInt16(port).bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    try #require(bound == 0)
    #expect(!LoopbackPorts.isListening(pid: getpid(), port: port))
    try #require(listen(socket, 1) == 0)
    #expect(LoopbackPorts.isListening(pid: getpid(), port: port))
    #expect(!LoopbackPorts.isListening(pid: getpid(), port: port == 65535 ? 65534 : port + 1))
    close(socket)
    #expect(!LoopbackPorts.isListening(pid: getpid(), port: port))
}

@Test func hostedServerGetsTheSecretInItsEnvironmentAndKeepsItsLog() async throws {
    let helpers = try helpersFolder(server: #"echo "key=$LLAMA_API_KEY args=$*"; echo "couldn't bind HTTP server socket" >&2; exit 1"#)
    defer { try? FileManager.default.removeItem(at: helpers) }
    let backend = BundledRuntime(helpersDirectory: helpers)
    let found = try backend.locateRuntime().get()
    let process = try backend.launch(found, model: model, port: 8123, apiKey: "secret")
    #expect(await process.waitForExit() == 1)
    #expect(process.exitStatus == 1)
    #expect(process.output.contains("key=secret args=--model /models/qwen.gguf --host 127.0.0.1 --port 8123 --parallel 1"))
    #expect(LocalAIProblem.classify(exitCode: 1, output: process.output) == .noFreePort)
    #expect(!process.ownsPort(8123))
}

@MainActor @Test func supervisorWithTheRealHelperTriesThreePortsThenShowsNoFreePort() async throws {
    let helpers = try helpersFolder(server: #"echo "couldn't bind HTTP server socket" >&2; exit 1"#)
    defer { try? FileManager.default.removeItem(at: helpers) }
    let ai = RuntimeSupervisor(isEnabled: true, backend: BundledRuntime(helpersDirectory: helpers), pollInterval: .milliseconds(10))
    ai.setModel(model)
    await ai.waitForChanges()
    #expect(ai.status == .failed(.noFreePort))
}

@MainActor @Test func quitStopsTheRealServerChild() async throws {
    let folder = try temporaryFolder()
    let pidFile = folder.appending(path: "server.pid")
    let helpers = try helpersFolder(server: "echo $$ > '\(pidFile.path)'; exec /bin/sleep 600")
    defer { try? FileManager.default.removeItem(at: helpers); try? FileManager.default.removeItem(at: folder) }
    let ai = RuntimeSupervisor(isEnabled: true, backend: BundledRuntime(helpersDirectory: helpers), pollInterval: .milliseconds(10))
    ai.setModel(model)
    #expect(await eventually { ai.status == .starting && FileManager.default.fileExists(atPath: pidFile.path) })
    let pid = try #require(await serverPID(pidFile))
    #expect(isAlive(pid))
    ai.stopForQuit(timeout: 120)
    #expect(ai.status == .off)
    #expect(await eventually { !isAlive(pid) })
}

/// The pid that the child writes to `file`. Nil after `seconds`.
private func serverPID(_ file: URL, seconds: Double = 120) async -> pid_t? {
    let deadline = Date(timeIntervalSinceNow: seconds)
    while Date() < deadline {
        if let text = try? String(contentsOf: file, encoding: .utf8), let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return pid
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return nil
}

// MARK: - Helper

@Test func hostParsesItsArguments() {
    #expect(LocalAIHost.parse(["--parent-pid", "42", "--", "/bin/sleep", "1"])?.parent == 42)
    #expect(LocalAIHost.parse(["--parent-pid", "42", "--", "/bin/sleep", "1"])?.command == ["/bin/sleep", "1"])
    #expect(LocalAIHost.parse(["--parent-pid", "42", "--"]) == nil)
    #expect(LocalAIHost.parse(["--parent-pid", "1", "--", "/bin/sleep"]) == nil)
    #expect(LocalAIHost.parse(["--parent-pid", "x", "--", "/bin/sleep"]) == nil)
    #expect(LocalAIHost.parse(["/bin/sleep"]) == nil)
}

/// Starts the built helper with a stdin pipe that the test holds open. The child writes its pid to `pidFile`.
private func startHost(parent: pid_t = getpid(), child script: String, pidFile: URL) throws -> (Process, Pipe) {
    let host = Process()
    host.executableURL = try builtHost()
    host.arguments = ["--parent-pid", String(parent), "--", "/bin/sh", "-c", "echo $$ > '\(pidFile.path)'; \(script)"]
    let input = Pipe()
    host.standardInput = input
    host.standardOutput = FileHandle.nullDevice
    host.standardError = FileHandle.nullDevice
    try host.run()
    return (host, input)
}

private func waitForExit(_ process: Process, seconds: Double = 120, isolation: isolated (any Actor)? = #isolation) async -> Bool {
    await eventually(seconds) { !process.isRunning }
}

@Test func hostShowsUsageAndPassesTheExitStatus() async throws {
    let usage = Process()
    usage.executableURL = try builtHost()
    usage.arguments = ["/bin/sleep", "1"]
    let errors = Pipe()
    usage.standardError = errors
    try usage.run()
    usage.waitUntilExit()
    #expect(usage.terminationStatus == 64)
    #expect(String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) == LocalAIHost.usage + "\n")

    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let (host, input) = try startHost(child: "exit 3", pidFile: folder.appending(path: "child.pid"))
    #expect(await waitForExit(host))
    #expect(host.terminationStatus == 3)
    try input.fileHandleForWriting.close()
}

/// The app crash case: the pipe from the app closes, so the helper stops its harmless child.
@Test func hostStopsTheChildWhenThePipeFromTheParentCloses() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let pidFile = folder.appending(path: "child.pid")
    let (host, input) = try startHost(child: "exec /bin/sleep 600", pidFile: pidFile)
    let child = try #require(await serverPID(pidFile))
    try await Task.sleep(for: .milliseconds(100))
    #expect(isAlive(child))
    #expect(host.isRunning)
    try input.fileHandleForWriting.close()
    #expect(await waitForExit(host))
    #expect(host.terminationStatus == 128 + SIGTERM)
    #expect(!isAlive(child))
}

/// Simulated parent death: a shell starts the helper with its own pid as the parent, then exits.
/// The stdin pipe stays open, so only the Dispatch parent watcher can stop the child.
@Test func hostStopsTheChildWhenTheParentDies() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let pidFile = folder.appending(path: "child.pid")
    let script = """
        "$1" --parent-pid $$ -- /bin/sh -c 'echo $$ > "$0"; exec /bin/sleep 600' "$2" <&0 >/dev/null 2>&1 &
        while [ ! -s "$2" ]; do sleep 0.05; done
        exit 0
        """
    let parent = Process()
    parent.executableURL = URL(fileURLWithPath: "/bin/sh")
    parent.arguments = ["-c", script, "sh", try builtHost().path, pidFile.path]
    let input = Pipe()
    parent.standardInput = input
    try parent.run()
    #expect(await waitForExit(parent))
    let child = try #require(await serverPID(pidFile))
    #expect(await eventually { !isAlive(child) })
    try input.fileHandleForWriting.close()
}

@Test func hostStopsTheChildOnSIGTERMAndKillsAChildThatIgnoresIt() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let pidFile = folder.appending(path: "child.pid")
    let (host, input) = try startHost(child: "exec /bin/sleep 600", pidFile: pidFile)
    let child = try #require(await serverPID(pidFile))
    host.terminate()
    #expect(await waitForExit(host))
    #expect(host.terminationStatus == 128 + SIGTERM)
    #expect(!isAlive(child))
    try input.fileHandleForWriting.close()

    // An ignored SIGTERM survives `exec`, so the sleep ignores it. SIGKILL follows after the kill delay.
    // The child writes its pid before the trap, so the test waits for a second file after the trap.
    let stubbornFile = folder.appending(path: "stubborn.pid")
    let trapped = folder.appending(path: "trapped")
    let (stubbornHost, stubbornInput) = try startHost(child: "trap '' TERM; touch '\(trapped.path)'; exec /bin/sleep 600",
                                                      pidFile: stubbornFile)
    let stubborn = try #require(await serverPID(stubbornFile))
    #expect(await eventually { FileManager.default.fileExists(atPath: trapped.path) })
    stubbornHost.terminate()
    #expect(await waitForExit(stubbornHost))
    #expect(stubbornHost.terminationStatus == 128 + SIGKILL)
    #expect(!isAlive(stubborn))
    try stubbornInput.fileHandleForWriting.close()
}
