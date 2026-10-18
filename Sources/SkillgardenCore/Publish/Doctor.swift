import Foundation

/// The read-only report of `skillgarden doctor` (#108): the library of the CLI, the library of the app and the sandbox.
/// It writes nothing. Write access is an estimate from `FileManager.isWritableFile`.
public struct Doctor: Equatable, Sendable {
    public enum FolderState: String, Sendable {
        case exists, missing
        case notAFolder = "not_a_folder"

        public var text: String {
            switch self {
            case .exists: "exists"
            case .missing: "missing (publish creates it)"
            case .notAFolder: "not a folder"
            }
        }
    }

    public enum WriteAccess: String, Sendable {
        case likely, no, unknown

        public var text: String { self == .likely ? "likely (estimate)" : rawValue }
    }

    /// One resolved library. `url` is nil when the setting of `source` is a relative path.
    public struct Library: Equatable, Sendable {
        public let url: URL?
        public let source: DataDirectorySource
        public let error: DataDirectoryError?

        init(_ resolve: () throws(DataDirectoryError) -> (url: URL, source: DataDirectorySource)) {
            do {
                let (url, source) = try resolve()
                (self.url, self.source, error) = (url, source, nil)
            } catch {
                (url, source, self.error) = (nil, DataDirectorySource(name: error.source) ?? .environment, error)
            }
        }
    }

    /// The environment variable that macOS sets in an App Sandbox process.
    public static let sandboxVariable = "APP_SANDBOX_CONTAINER_ID"

    public let version: String
    public let cliPath: String?
    /// The library of the CLI: environment, then saved setting, then default.
    public let library: Library
    /// Nil when the library setting is not valid.
    public let folder: FolderState?
    public let writeAccess: WriteAccess?
    /// The library of the app. The app does not read shell variables, so the environment is not used.
    public let appLibrary: Library
    public let sandbox: Bool

    public init(environment: [String: String], savedSetting: String?,
                home: URL = FileManager.default.homeDirectoryForCurrentUser,
                defaultDirectory: URL = Skillgarden.defaultDataDirectory, cliPath: String?) {
        version = Skillgarden.version
        self.cliPath = cliPath
        library = Library { () throws(DataDirectoryError) in
            try Skillgarden.resolveDataDirectory(environment: environment, savedSetting: savedSetting, home: home,
                                                 defaultDirectory: defaultDirectory)
        }
        appLibrary = Library { () throws(DataDirectoryError) in
            try Skillgarden.resolveDataDirectory(environment: [:], savedSetting: savedSetting, home: home,
                                                 defaultDirectory: defaultDirectory)
        }
        if let url = library.url {
            let folder = Self.folderState(url)
            self.folder = folder
            writeAccess = Self.writeAccess(url, folder: folder)
        } else {
            (folder, writeAccess) = (nil, nil)
        }
        sandbox = environment[Self.sandboxVariable] != nil
    }

    /// The report for the running process: the real environment, the saved setting and the CLI executable.
    public static func current() -> Doctor {
        Doctor(environment: ProcessInfo.processInfo.environment, savedSetting: Skillgarden.savedDataDirectory(),
               cliPath: Bundle.main.executablePath)
    }

    /// True when the CLI and the app use the same folder. Nil when one of the settings is not valid.
    public var match: Bool? {
        guard let cli = library.url, let app = appLibrary.url else { return nil }
        return cli.standardizedFileURL.path == app.standardizedFileURL.path
    }

    /// 2 for a relative setting, 3 for a library path that is not a folder, else 0.
    public var exitCode: Int32 {
        if library.error != nil || appLibrary.error != nil { return 2 }
        return folder == .notAFolder ? 3 : 0
    }

    public var diagnostics: [CommandDiagnostic] {
        if let error = library.error ?? appLibrary.error {
            return [CommandDiagnostic(code: .dataDirectoryRelative, message: error.localizedDescription,
                                      hint: "Set \(error.source) to an absolute path that starts with /.")]
        }
        if folder == .notAFolder, let url = library.url {
            return [CommandDiagnostic(code: .dataDirectoryNotFolder, file: url.path, message: "library path is not a folder: \(url.path)",
                                      hint: "Set \(library.source.name) to a folder path.")]
        }
        return []
    }

    /// The labelled lines on stdout, one column for the values.
    public var text: String {
        var lines = ["skillgarden \(version)"]
        func row(_ label: String, _ value: String) {
            lines.append((label + ":").padding(toLength: 16, withPad: " ", startingAt: 0) + value)
        }
        row("CLI", cliPath ?? "unknown")
        row("Library", library.url?.path ?? "invalid")
        row("Source", library.source.label)
        if let folder, let writeAccess {
            row("Folder", folder.text)
            row("Write access", writeAccess.text)
        }
        row("App library", appLibrary.url?.path ?? "invalid")
        row("App source", appLibrary.source.label)
        if let match { row("Match", match ? "yes" : "no") }
        row("Sandbox", sandbox ? "yes (\(Self.sandboxVariable) is set)" : "no")
        if match == false, let url = library.url {
            lines.append("Note: The app does not read shell variables. "
                + "Run: defaults write \(Skillgarden.defaultsDomain) \(Skillgarden.dataDirectoryKey) \"\(url.path)\"")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The `result` object of `--json`. A value that is not known is `null`.
    public var result: [String: Any] {
        func value(_ text: String?) -> Any { text ?? NSNull() }
        return [
            "version": version, "cli_path": value(cliPath),
            "library_path": value(library.url?.path), "source": library.source.rawValue,
            "folder": value(folder?.rawValue), "write_access": value(writeAccess?.rawValue),
            "app_library_path": value(appLibrary.url?.path), "app_source": appLibrary.source.rawValue,
            "match": match.map { $0 as Any } ?? NSNull(), "sandbox": sandbox,
        ]
    }

    static func folderState(_ url: URL) -> FolderState {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return .missing }
        return isDirectory.boolValue ? .exists : .notAFolder
    }

    /// Checks the folder, or for a missing folder its nearest parent that exists. It does not write a test file.
    static func writeAccess(_ url: URL, folder: FolderState) -> WriteAccess {
        switch folder {
        case .exists: return FileManager.default.isWritableFile(atPath: url.path) ? .likely : .no
        case .notAFolder: return .no
        case .missing:
            // A path has few components, so the walk ends at `/`. Unknown means that no parent was found.
            var parent = url
            for _ in url.pathComponents {
                parent = parent.deletingLastPathComponent()
                switch folderState(parent) {
                case .exists: return FileManager.default.isWritableFile(atPath: parent.path) ? .likely : .no
                case .notAFolder: return .no
                case .missing: continue
                }
            }
            return .unknown
        }
    }
}
