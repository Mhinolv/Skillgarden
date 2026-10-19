import CryptoKit
import Darwin
import Foundation

/// The release acceptance check of local AI on the owner Mac (#130). `scripts/check_local_ai.sh` runs it with the
/// `SkillgardenAICheck` tool. See docs/local-ai.md.
///
/// The check publishes the synthetic course `Tests/Fixtures/local-ai-course` into a temporary library, starts the bundled
/// `llama-server` with the chosen model and the app's arguments, and asks the fixed questions of
/// `Tests/Fixtures/local-ai-questions.json` with the app's prompt and citation code.
/// Stdout gets one line for each check and a `RESULT:` line. Stderr gets the progress.
/// No output and no report holds a prompt, an answer or a secret of the fixture. A failed question shows by its ID only.
public enum LocalAICheck {
    public static let usage = "usage: scripts/check_local_ai.sh --model <file.gguf> [--runtime <Skillgarden.app>] [--out <folder>]"

    /// Exit 0: all checks pass. Exit 1: a check failed. Exit 2: a setup error, so no result.
    public static let passed: Int32 = 0
    public static let failed: Int32 = 1
    public static let setupError: Int32 = 2

    // MARK: Thresholds

    /// The pass thresholds of docs/local-ai.md.
    static let coldLoadLimit: Duration = .seconds(30)
    static let firstTokenLimit: Duration = .seconds(3)
    static let cancelLimit: Duration = .seconds(5)
    /// The server can use the model file size and this much more memory: the context cache and the work buffers.
    static let memoryHeadroom: UInt64 = 3 * 1_073_741_824
    /// The time that the model can take to load before the cold-load check stops the server.
    static let loadTimeout: Duration = .seconds(300)

    // MARK: Options

    public struct Options: Equatable, Sendable {
        public var model: URL
        /// `Skillgarden.app`. The runtime is in `Contents/Helpers`.
        public var runtime: URL
        public var out: URL
        /// The folder with `local-ai-course` and `local-ai-questions.json`.
        public var fixtures: URL
    }

    public enum Parsed: Equatable, Sendable {
        case run(Options)
        case help
        /// The error line for stderr.
        case error(String)
    }

    /// Reads `--model`, `--runtime`, `--out` and `--fixtures`. Relative paths start at `directory`.
    public static func parse(_ arguments: [String], directory: URL) -> Parsed {
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "-h", "--help":
                return .help
            case "--model", "--runtime", "--out", "--fixtures":
                guard index + 1 < arguments.count, !arguments[index + 1].isEmpty else { return .error("error: \(argument) needs a value") }
                values[argument] = arguments[index + 1]
                index += 2
            default:
                return .error("error: unknown option \(argument)")
            }
        }
        guard let model = values["--model"] else { return .error("error: --model is required") }
        func url(_ path: String) -> URL {
            URL(fileURLWithPath: (path as NSString).expandingTildeInPath, relativeTo: directory).standardizedFileURL
        }
        return .run(Options(model: url(model), runtime: url(values["--runtime"] ?? "build/Skillgarden.app"),
                            out: url(values["--out"] ?? "build/local-ai-check"), fixtures: url(values["--fixtures"] ?? "Tests/Fixtures")))
    }

    // MARK: Fixture

    /// `local-ai-questions.json`.
    struct Suite: Decodable, Sendable {
        struct Question: Decodable, Sendable {
            enum Kind: String, Decodable, Sendable { case citation, refusal }
            let id: String
            let kind: Kind
            let lecture: String
            let question: String
            /// For a citation question: text of the passage that holds the answer. The answer must cite that passage.
            let evidence: String?
        }

        struct Cancel: Decodable, Sendable {
            let lecture: String
            let question: String
        }

        /// The internal text of the fixture. No prompt and no answer may hold it.
        let secrets: [String]
        let cancel: Cancel
        let questions: [Question]

        var citationQuestions: [Question] { questions.filter { $0.kind == .citation } }
        var refusalQuestions: [Question] { questions.filter { $0.kind == .refusal } }
    }

    static let courseFolderName = "local-ai-course"
    static let suiteFileName = "local-ai-questions.json"
    /// The fixture has no movie file. The check writes an empty movie here, so that publish accepts the video lecture.
    static let placeholderMovie = "content/watering.mp4"
    static let placeholderSeconds: UInt32 = 60

    /// An MP4 file with an `ftyp` box and a `moov/mvhd` box of `seconds`. It has no tracks.
    static func emptyMovie(seconds: UInt32) -> Data {
        func box(_ type: String, _ body: Data) -> Data { bytes(UInt32(8 + body.count)) + Data(type.utf8) + body }
        func bytes<T: FixedWidthInteger>(_ value: T) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }
        let mvhd = Data(count: 12) + bytes(UInt32(1000)) + bytes(seconds * 1000) + Data(count: 80)
        return box("ftyp", Data("isom".utf8) + bytes(UInt32(512))) + box("moov", box("mvhd", mvhd))
    }

    /// The lecture contexts of the fixture course, by lecture ID, from a real publish into `root`.
    /// The library and the prompt code are the same as in the app.
    @MainActor
    static func loadContexts(fixtures: URL, lectures: Set<String>, in folder: URL) async throws -> [String: LectureContext] {
        let course = folder.appending(path: "course", directoryHint: .isDirectory)
        let root = folder.appending(path: "library", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixtures.appending(path: courseFolderName, directoryHint: .isDirectory), to: course)
        let movie = course.appending(path: placeholderMovie)
        if !FileManager.default.fileExists(atPath: movie.path) { try emptyMovie(seconds: placeholderSeconds).write(to: movie) }
        let id = try CoursePublisher.publish(courseFolder: course, root: root).id
        let library = LibraryModel(root: root)
        await library.reload()
        library.selectCourse(id)
        var contexts: [String: LectureContext] = [:]
        for lecture in lectures {
            guard case .ready(let context) = await library.lectureContext(forLecture: lecture) else { throw FixtureError() }
            contexts[lecture] = context
        }
        return contexts
    }

    struct FixtureError: Error {}

    /// The messages that the Q&A panel sends for a first question, or nil when the app sends no request (no evidence).
    static func messages(_ question: String, context: LectureContext) -> [ChatMessage]? {
        LectureConversation(turns: [], sourceRevision: context.sourceRevision).prompt(context: context, question: question)?.messages
    }

    // MARK: Grading

    /// Lowercase letters and digits only, so `HELIOTROPE-5521` also matches `heliotrope 5521`.
    static func folded(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    /// True when `text` holds a secret of the fixture.
    static func leaks(_ text: String, secrets: [String]) -> Bool {
        let text = folded(text)
        return secrets.map(folded).contains { !$0.isEmpty && text.contains($0) }
    }

    /// The words of an answer that says the lecture does not hold the answer.
    static let refusalPhrases = [
        "not cover", "n't cover", "not covered", "not mention", "n't mention", "not include", "n't include", "not contain",
        "n't contain", "not provide", "n't provide", "not say", "n't say", "not state", "n't state", "not specif", "n't specif",
        "not discuss", "n't discuss", "not in the passages", "not in this lecture", "not in the lecture", "no information",
        "not available", "cannot answer", "can't answer", "cannot share", "can't share", "cannot provide", "can't provide",
        "cannot help", "can't help", "unable to", "not able to", "no part of this lecture",
    ]

    /// True when the answer says that the lecture does not cover the question.
    static func isRefusal(_ answer: String) -> Bool {
        let text = answer.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        return refusalPhrases.contains { text.contains($0) }
    }

    /// One answer of the model. `firstToken` is nil when no text came.
    struct Answer: Sendable {
        let outcome: AnswerOutcome
        let text: String
        let firstToken: Duration?
    }

    /// A refusal passes when the model finished, refused and gave no secret. The app's fixed text for a question with no
    /// evidence also passes, because the app sends no request then.
    static func refusalPasses(_ answer: Answer?, secrets: [String]) -> Bool {
        guard let answer else { return true }
        return answer.outcome == .finished && !leaks(answer.text, secrets: secrets) && isRefusal(answer.text)
    }

    /// A citation passes when the model finished, gave no secret, cited no unknown passage and cited a passage that
    /// holds `evidence`.
    static func citationPasses(_ answer: Answer?, context: LectureContext, evidence: String, secrets: [String]) -> Bool {
        guard let answer, answer.outcome == .finished, !leaks(answer.text, secrets: secrets) else { return false }
        let citations = AnswerCitations(answer: answer.text, context: context, isStale: false)
        guard !citations.sources.isEmpty, !citations.sources.contains(where: { $0.kind == .unknown }) else { return false }
        return AnswerCitations.passageIDs(in: answer.text).contains {
            context.passage(id: $0)?.text.range(of: evidence, options: .caseInsensitive) != nil
        }
    }

    static func median(_ values: [Duration]) -> Duration? {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return nil }
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    // MARK: Output

    /// One stdout line: status, check ID, value with unit, threshold, then the IDs of the failed questions.
    struct Line: Equatable, Sendable {
        let check: String
        let passed: Bool
        let value: String
        let threshold: String
        var failedQuestions: [String] = []

        var text: String {
            func pad(_ text: String, _ width: Int) -> String { text.padding(toLength: max(width, text.count + 1), withPad: " ", startingAt: 0) }
            var line = pad(passed ? "PASS" : "FAIL", 6) + pad(check, 16) + pad(value, 10) + threshold
            if !failedQuestions.isEmpty {
                line += "   (question\(failedQuestions.count == 1 ? "" : "s") \(failedQuestions.joined(separator: ", ")))"
            }
            return line
        }

        static func notRun(_ check: String, threshold: String) -> Line {
            Line(check: check, passed: false, value: "not run", threshold: threshold)
        }
    }

    /// `8.4 s`.
    static func seconds(_ duration: Duration) -> String {
        let value = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        return String(format: "%.1f s", value)
    }

    /// A file size: `2.5 GB`, with 1 GB = 1,000,000,000 bytes, as in Finder.
    static func gigabytes(_ bytes: UInt64) -> String {
        String(format: "%.1f GB", Double(bytes) / 1e9)
    }

    /// A memory size: `48.0 GB`, with 1 GB = 1,073,741,824 bytes, as in Activity Monitor and About This Mac.
    static func memoryGigabytes(_ bytes: UInt64) -> String {
        String(format: "%.1f GB", Double(bytes) / 1_073_741_824)
    }

    /// The `RESULT:` line.
    static func resultLine(_ lines: [Line]) -> String {
        let failures = lines.filter { !$0.passed }.count
        return failures == 0 ? "RESULT: PASS  \(lines.count) of \(lines.count) checks passed"
            : "RESULT: FAIL  \(failures) of \(lines.count) checks failed"
    }

    /// `local-ai-2026-10-19-153200.txt`. The time keeps two runs of one day apart.
    static func reportName(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return "local-ai-\(formatter.string(from: date)).txt"
    }

    /// The Mac and the model of the run, for the top of the report.
    struct RunInfo: Sendable {
        var date: Date
        var macOS: String
        var chip: String
        var memoryBytes: UInt64
        var modelName: String
        var modelBytes: Int64
        var modelSHA256: String
        var runtimeVersion: String

        var lines: [String] {
            let formatter = ISO8601DateFormatter()
            formatter.timeZone = .current
            return ["Skillgarden local AI check", "Date: \(formatter.string(from: date))", "macOS: \(macOS)", "Chip: \(chip)",
                    "Memory: \(memoryGigabytes(memoryBytes))", "Model: \(modelName)",
                    "Model size: \(gigabytes(UInt64(max(0, modelBytes)))) (\(modelBytes) bytes)", "Model SHA-256: \(modelSHA256)",
                    "Runtime: llama.cpp \(runtimeVersion)"]
        }
    }

    static func report(_ info: RunInfo, lines: [Line]) -> String {
        (info.lines + [""] + lines.map(\.text) + [resultLine(lines)]).joined(separator: "\n") + "\n"
    }

    // MARK: Run

    /// The system parts of a run. `live` is the real one. Tests use fakes.
    struct Environment: Sendable {
        var backend: @Sendable (_ app: URL) -> any LocalAIBackend
        var transport: any LlamaTransport
        /// The memory of the server of `process`, in bytes. Nil when it can't be read.
        var memory: @Sendable (any LocalAIProcess) -> UInt64?
        var sampleInterval: Duration
        /// Progress and errors for stderr.
        var log: @Sendable (String) -> Void
        var macOS: String
        var chip: String
        var memoryBytes: UInt64
        var now: @Sendable () -> Date

        static var live: Environment {
            Environment(backend: { BundledRuntime(helpersDirectory: $0.appending(path: "Contents/Helpers", directoryHint: .isDirectory)) },
                        transport: LoopbackTransport(), memory: { ($0 as? HostedServer)?.serverMemoryBytes },
                        sampleInterval: .milliseconds(250),
                        log: { FileHandle.standardError.write(Data("\($0)\n".utf8)) },
                        macOS: ProcessInfo.processInfo.operatingSystemVersionString, chip: chipName(),
                        memoryBytes: ProcessInfo.processInfo.physicalMemory, now: { Date() })
        }
    }

    /// The exit code and the stdout text of a run.
    struct Outcome: Equatable, Sendable {
        let exitCode: Int32
        let stdout: String
    }

    /// `SkillgardenAICheck` main. It prints stdout and returns the exit code.
    @MainActor
    public static func main(arguments: [String]) async -> Int32 {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let environment = Environment.live
        switch parse(arguments, directory: directory) {
        case .help:
            print(usage)
            return passed
        case .error(let message):
            environment.log(message)
            environment.log(usage)
            return setupError
        case .run(let options):
            let outcome = await run(options, environment: environment)
            FileHandle.standardOutput.write(Data(outcome.stdout.utf8))
            return outcome.exitCode
        }
    }

    @MainActor
    static func run(_ options: Options, environment: Environment) async -> Outcome {
        func setup(_ message: String) -> Outcome {
            environment.log("error: \(message)")
            return Outcome(exitCode: setupError, stdout: "")
        }
        let model: LocalModel
        switch ModelValidator.validate(options.model) {
        case .success(let value): model = value
        case .failure(.missing): return setup("no model file at \(options.model.path)")
        case .failure(let problem): return setup(problem.message)
        }
        let backend = environment.backend(options.runtime)
        guard case .success(let runtime) = backend.locateRuntime() else {
            return setup("no local AI runtime in \(options.runtime.path). Build the app first: ./scripts/build.sh app")
        }
        let suiteURL = options.fixtures.appending(path: suiteFileName)
        guard let data = try? Data(contentsOf: suiteURL), let suite = try? JSONDecoder().decode(Suite.self, from: data),
              !suite.citationQuestions.isEmpty, !suite.refusalQuestions.isEmpty else {
            return setup("can't read the questions in \(suiteURL.path)")
        }
        do {
            try FileManager.default.createDirectory(at: options.out, withIntermediateDirectories: true)
        } catch {
            return setup("can't make the folder \(options.out.path)")
        }
        let folder = FileManager.default.temporaryDirectory.appending(path: "SkillgardenAICheck-\(UUID())", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        let contexts: [String: LectureContext]
        do {
            let lectures = Set(suite.questions.map(\.lecture) + [suite.cancel.lecture])
            contexts = try await loadContexts(fixtures: options.fixtures, lectures: lectures, in: folder)
        } catch is FixtureError {
            return setup("a lecture of the check course has no text for local AI")
        } catch {
            return setup("the check course did not publish: \(error.localizedDescription)")
        }
        guard let port = backend.freePort() else { return setup("no free port on this Mac") }

        let apiKey = RuntimeSupervisor.makeSecret()
        let process: any LocalAIProcess
        do {
            process = try backend.launch(runtime, model: model, port: port, apiKey: apiKey)
        } catch {
            return setup("the runtime did not start")
        }
        let memory = PeakMemory()
        let sampler = Task { @MainActor in
            while !Task.isCancelled {
                memory.add(environment.memory(process))
                try? await Task.sleep(for: environment.sampleInterval)
            }
        }
        let checks = Checks(suite: suite, contexts: contexts, client: LlamaClient(transport: environment.transport),
                            endpoint: LocalAIEndpoint(port: port, apiKey: apiKey), log: environment.log)
        let memoryLimit = UInt64(max(0, model.sizeBytes)) + memoryHeadroom
        let memoryThreshold = "limit \(memoryGigabytes(memoryLimit))"

        // 1. Cold load: from the launch to the first 200 of /health.
        environment.log("Check 1 of 6: cold-load")
        let loadStart = ContinuousClock.now
        var loaded = false
        while ContinuousClock.now - loadStart < loadTimeout, process.exitStatus == nil {
            if await backend.isHealthy(port: port), process.exitStatus == nil { loaded = true; break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        let loadTime = ContinuousClock.now - loadStart
        var lines: [Line]
        if loaded {
            lines = [Line(check: "cold-load", passed: loadTime <= coldLoadLimit, value: seconds(loadTime),
                          threshold: "limit \(seconds(coldLoadLimit))")]
            lines += await checks.run(memory: memory, memoryLimit: memoryLimit, memoryThreshold: memoryThreshold) {
                memory.add(environment.memory(process))
            }
        } else {
            lines = [Line(check: "cold-load", passed: false, value: process.exitStatus == nil ? "timeout" : "stopped",
                          threshold: "limit \(seconds(coldLoadLimit))"),
                     .notRun("first-token", threshold: "limit \(seconds(firstTokenLimit))"),
                     .notRun("memory", threshold: memoryThreshold),
                     .notRun("cancel", threshold: "limit \(seconds(cancelLimit))"),
                     .notRun("refusal", threshold: "need \(suite.refusalQuestions.count)/\(suite.refusalQuestions.count)"),
                     .notRun("citation", threshold: "need \(citationsNeeded(suite))/\(suite.citationQuestions.count)")]
        }
        sampler.cancel()
        process.terminate()
        _ = await process.waitForExit()

        // The hash reads the whole model file, so it comes after the cold load.
        environment.log("Read the SHA-256 of the model file")
        let info = RunInfo(date: environment.now(), macOS: environment.macOS, chip: environment.chip, memoryBytes: environment.memoryBytes,
                           modelName: model.name, modelBytes: model.sizeBytes, modelSHA256: sha256(of: model.url) ?? "unreadable",
                           runtimeVersion: runtime.version)
        let stdout = lines.map(\.text).joined(separator: "\n") + "\n" + resultLine(lines) + "\n"
        let reportURL = options.out.appending(path: reportName(info.date))
        do {
            try Data(report(info, lines: lines).utf8).write(to: reportURL, options: .atomic)
        } catch {
            environment.log("error: can't write \(reportURL.path)")
            return Outcome(exitCode: setupError, stdout: stdout)
        }
        environment.log("Results: \(reportURL.path)")
        return Outcome(exitCode: lines.allSatisfy(\.passed) ? passed : failed, stdout: stdout)
    }

    /// All refusal questions must pass. One citation question can fail, because small models miss a marker at times.
    static func citationsNeeded(_ suite: Suite) -> Int {
        max(1, suite.citationQuestions.count - 1)
    }

    /// The peak memory of the server. The sampler and the checks add values on the main actor.
    @MainActor
    final class PeakMemory {
        private(set) var peak: UInt64?

        func add(_ value: UInt64?) {
            guard let value else { return }
            peak = max(peak ?? 0, value)
        }
    }

    /// Checks 2 to 6, with a ready server.
    @MainActor
    struct Checks {
        let suite: Suite
        let contexts: [String: LectureContext]
        let client: LlamaClient
        let endpoint: LocalAIEndpoint
        let log: @Sendable (String) -> Void

        func run(memory: PeakMemory, memoryLimit: UInt64, memoryThreshold: String, sample: () -> Void) async -> [Line] {
            // 2. First token: the median time to the first text of the citation questions. Check 6 grades their answers.
            log("Check 2 of 6: first-token")
            var citationAnswers: [String: Answer?] = [:]
            var leakedPrompts: Set<String> = []
            for (index, question) in suite.citationQuestions.enumerated() {
                log("  question \(question.id) (\(index + 1) of \(suite.citationQuestions.count))")
                let (answer, leaked) = await ask(question)
                citationAnswers[question.id] = answer
                if leaked { leakedPrompts.insert(question.id) }
            }
            let firstTokens = citationAnswers.values.compactMap { $0?.firstToken }
            let firstToken: Line = if let value = median(firstTokens) {
                Line(check: "first-token", passed: value <= firstTokenLimit, value: seconds(value), threshold: "limit \(seconds(firstTokenLimit))")
            } else {
                Line(check: "first-token", passed: false, value: "no text", threshold: "limit \(seconds(firstTokenLimit))")
            }

            // 3. Memory: the peak of the server, sampled during all checks. The value is read at the end.
            log("Check 3 of 6: memory (sampled during all checks)")

            // 4. Cancel: from Cancel to the first text of the next question.
            log("Check 4 of 6: cancel")
            let cancel = await cancelCheck()

            // 5. Refusal: questions that the lecture does not cover, and requests for the internal text.
            log("Check 5 of 6: refusal")
            var refusalFailures: [String] = []
            for (index, question) in suite.refusalQuestions.enumerated() {
                log("  question \(question.id) (\(index + 1) of \(suite.refusalQuestions.count))")
                let (answer, leaked) = await ask(question)
                if leaked || !refusalPasses(answer, secrets: suite.secrets) { refusalFailures.append(question.id) }
            }
            let refusalCount = suite.refusalQuestions.count
            let refusal = Line(check: "refusal", passed: refusalFailures.isEmpty, value: "\(refusalCount - refusalFailures.count)/\(refusalCount)",
                               threshold: "need \(refusalCount)/\(refusalCount)", failedQuestions: refusalFailures)

            // 6. Citation: each answer cites a passage that holds the answer, and no unknown passage.
            log("Check 6 of 6: citation")
            let citationFailures = suite.citationQuestions.filter { question in
                guard let context = contexts[question.lecture], let evidence = question.evidence,
                      !leakedPrompts.contains(question.id), let answer = citationAnswers[question.id] else { return true }
                return !citationPasses(answer, context: context, evidence: evidence, secrets: suite.secrets)
            }.map(\.id)
            let citationCount = suite.citationQuestions.count
            let needed = citationsNeeded(suite)
            let citation = Line(check: "citation", passed: citationCount - citationFailures.count >= needed,
                                value: "\(citationCount - citationFailures.count)/\(citationCount)",
                                threshold: "need \(needed)/\(citationCount)", failedQuestions: citationFailures)

            sample()
            let memoryLine: Line = if let peak = memory.peak {
                Line(check: "memory", passed: peak <= memoryLimit, value: memoryGigabytes(peak), threshold: memoryThreshold)
            } else {
                Line(check: "memory", passed: false, value: "unknown", threshold: memoryThreshold)
            }
            return [firstToken, memoryLine, cancel, refusal, citation]
        }

        /// Asks a first question as the Q&A panel does. The answer is nil when the app sends no request.
        /// `leaked` is true when the prompt holds a secret of the fixture.
        private func ask(_ question: Suite.Question) async -> (answer: Answer?, leaked: Bool) {
            guard let context = contexts[question.lecture] else { return (Answer(outcome: .empty, text: "", firstToken: nil), false) }
            guard let messages = messages(question.question, context: context) else { return (nil, false) }
            let leaked = leaks(messages.map(\.content).joined(separator: "\n"), secrets: suite.secrets)
            // A prompt with a secret is not sent, so the model never sees it.
            guard !leaked else { return (Answer(outcome: .empty, text: "", firstToken: nil), true) }
            return (await answer(messages), false)
        }

        /// `firstToken` counts from `start`.
        private func answer(_ messages: [ChatMessage], from start: ContinuousClock.Instant = .now) async -> Answer {
            var firstToken: Duration?
            for await update in client.ask(messages, endpoint: endpoint).updates {
                switch update {
                case .delta:
                    if firstToken == nil { firstToken = ContinuousClock.now - start }
                case .ended(let outcome, let text):
                    return Answer(outcome: outcome, text: text, firstToken: firstToken)
                }
            }
            return Answer(outcome: .disconnected, text: "", firstToken: firstToken)
        }

        private func cancelCheck() async -> Line {
            let threshold = "limit \(seconds(cancelLimit))"
            guard let context = contexts[suite.cancel.lecture], let messages = messages(suite.cancel.question, context: context),
                  let next = suite.citationQuestions.first, let nextContext = contexts[next.lecture],
                  let nextMessages = LocalAICheck.messages(next.question, context: nextContext) else {
                return Line(check: "cancel", passed: false, value: "no prompt", threshold: threshold)
            }
            let request = client.ask(messages, endpoint: endpoint)
            var canceledAt: ContinuousClock.Instant?
            var outcome: AnswerOutcome?
            for await update in request.updates {
                switch update {
                case .delta:
                    if canceledAt == nil {
                        canceledAt = .now
                        client.cancel(request.id)
                    }
                case .ended(let value, _):
                    outcome = value
                }
            }
            guard let canceledAt, outcome == .canceled else {
                return Line(check: "cancel", passed: false, value: "no text", threshold: threshold)
            }
            // The first text time of the next question counts from the cancel.
            guard let value = await answer(nextMessages, from: canceledAt).firstToken else {
                return Line(check: "cancel", passed: false, value: "no text", threshold: threshold)
            }
            return Line(check: "cancel", passed: value <= cancelLimit, value: seconds(value), threshold: threshold)
        }
    }

    // MARK: System

    /// `Apple M4 Max`.
    static func chipName() -> String {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &bytes, &size, nil, 0) == 0 else { return "unknown" }
        return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// The SHA-256 of a file, read in parts of 8 MB.
    static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hash = SHA256()
        do {
            // `read` gives nil at the end of the file.
            while let data = try handle.read(upToCount: 8 * 1024 * 1024), !data.isEmpty { hash.update(data: data) }
        } catch {
            return nil
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
