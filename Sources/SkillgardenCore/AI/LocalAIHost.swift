import Darwin
import Foundation

/// `SkillgardenAIHost --parent-pid <pid> -- <server> [<argument> ...]` (#123).
/// The helper runs the server as its child and stops it when the app stops, also after an app crash:
/// - Its stdin is a pipe from the app. The app never writes to it, so end of file means that the app is gone.
/// - A Dispatch process source watches the parent pid.
/// - SIGTERM, SIGINT and SIGHUP stop the server. The helper sends SIGTERM, then SIGKILL after `killDelay`.
/// The helper exits with the exit status of the server, or 128 + the signal number.
public enum LocalAIHost {
    public static let usage = "usage: SkillgardenAIHost --parent-pid <pid> -- <server> [<argument> ...]"
    static let killDelay: DispatchTimeInterval = .seconds(3)

    /// The parent pid and the server command, or nil for a usage error.
    static func parse(_ arguments: [String]) -> (parent: pid_t, command: [String])? {
        guard arguments.count >= 4, arguments[0] == "--parent-pid", let parent = pid_t(arguments[1]), parent > 1,
              arguments[2] == "--" else { return nil }
        return (parent, Array(arguments[3...]))
    }

    /// Runs the helper. `arguments` has no program name. It does not return.
    public static func run(arguments: [String]) -> Never {
        guard let (parent, command) = parse(arguments) else {
            FileHandle.standardError.write(Data("\(usage)\n".utf8))
            exit(64)
        }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: command[0])
        child.arguments = Array(command.dropFirst())
        // The server must not hold the pipe from the app. Its log goes to the helper stdout and stderr.
        child.standardInput = FileHandle.nullDevice
        child.terminationHandler = { process in
            exit(process.terminationReason == .uncaughtSignal ? 128 + process.terminationStatus : process.terminationStatus)
        }
        do {
            try child.run()
        } catch {
            FileHandle.standardError.write(Data("SkillgardenAIHost: can't start \(command[0]): \(error.localizedDescription)\n".utf8))
            exit(127)
        }

        let queue = DispatchQueue(label: "dev.skillgarden.ai-host")
        let pid = child.processIdentifier
        let stopping = StopFlag()
        // Each caller runs on `queue`, so the flag needs no lock.
        let stop: @Sendable () -> Void = {
            guard !stopping.isSet else { return }
            stopping.isSet = true
            kill(pid, SIGTERM)
            queue.asyncAfter(deadline: .now() + killDelay) { kill(pid, SIGKILL) }
        }
        var sources: [any DispatchSourceProtocol] = []
        for number in [SIGTERM, SIGINT, SIGHUP] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
            source.setEventHandler(handler: stop)
            sources.append(source)
        }
        // The parent-death pipe: a read of 0 bytes is end of file.
        let pipe = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: queue)
        pipe.setEventHandler {
            var byte: UInt8 = 0
            if read(STDIN_FILENO, &byte, 1) <= 0 { pipe.cancel(); stop() }
        }
        sources.append(pipe)
        let watcher = DispatchSource.makeProcessSource(identifier: parent, eventMask: .exit, queue: queue)
        watcher.setEventHandler(handler: stop)
        sources.append(watcher)
        sources.forEach { $0.activate() }
        // The parent can stop before the watcher starts. Then the helper has a new parent.
        queue.async {
            if getppid() != parent || (kill(parent, 0) != 0 && errno == ESRCH) { stop() }
        }
        withExtendedLifetime(sources) { dispatchMain() }
    }

    private final class StopFlag: @unchecked Sendable {
        var isSet = false
    }
}
