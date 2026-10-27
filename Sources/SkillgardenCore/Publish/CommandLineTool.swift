import Foundation

/// Skillgarden > "Install Command Line Tool…" (#250): `~/.local/bin/skillgarden` becomes a symlink to the CLI of the app.
/// An app update replaces the app at the same path, so the command on PATH runs the new CLI. No admin password.
public struct CommandLineTool: Sendable {
    /// What is at the link path before the install.
    public enum Target: Equatable, Sendable {
        case absent
        case symlink
        /// A copy from `scripts/install_cli.sh`. The app asks before it replaces it.
        case regularFile
    }

    public enum InstallError: Error, Equatable, LocalizedError {
        /// The app is translocated or is not in an Applications folder. A link to it would break.
        case notInApplications
        case noBundledCLI(path: String)
        /// A folder or another item that is not a file or a symlink is at the link path.
        case notAFile(path: String)
        case write(description: String)

        public var errorDescription: String? {
            switch self {
            case .notInApplications: CommandLineTool.notInApplicationsInformation
            case .noBundledCLI(let path): "The app has no skillgarden command at \(path)."
            case .notAFile(let path): "\(path) is not a file. Move it away, then try again."
            case .write(let description): description
            }
        }
    }

    public static let successMessage = "The skillgarden command is installed."
    /// A GUI app cannot read the Terminal PATH, so the alert always names the PATH line (owner decision 2026-10-26).
    public static let successInformation = "Run skillgarden --help in Terminal. If Terminal does not find it, add the PATH line to ~/.zshrc."
    public static let pathLine = #"export PATH="$HOME/.local/bin:$PATH""#
    public static let replaceMessage = "Replace the existing skillgarden command?"
    public static let replaceInformation = "The new command follows app updates."
    public static let failureMessage = "Can't install the command line tool."
    public static let notInApplicationsInformation = "Move Skillgarden to the Applications folder, then try again."

    public let app: URL
    public let home: URL
    /// The folders that the app can be in. Subfolders count too.
    public let applicationFolders: [URL]

    public init(app: URL = Bundle.main.bundleURL, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                applicationFolders: [URL]? = nil) {
        self.app = app.standardizedFileURL
        self.home = home.standardizedFileURL
        self.applicationFolders = applicationFolders
            ?? [URL(fileURLWithPath: "/Applications", isDirectory: true), self.home.appending(path: "Applications", directoryHint: .isDirectory)]
    }

    /// `~/.local/bin/skillgarden`.
    public var link: URL { home.appending(path: ".local/bin/skillgarden") }
    /// `Contents/Helpers/skillgarden` of the app.
    public var cli: URL { app.appending(path: "Contents/Helpers/skillgarden") }

    public var isInApplications: Bool {
        let path = app.path
        // Gatekeeper runs a quarantined app from a random read-only path. That path goes away when the app quits.
        guard !path.contains("/AppTranslocation/") else { return false }
        return applicationFolders.contains { path.hasPrefix($0.standardizedFileURL.path + "/") }
    }

    /// Checks the app and the link path. It changes nothing.
    public func check() throws(InstallError) -> Target {
        guard isInApplications else { throw .notInApplications }
        guard FileManager.default.isExecutableFile(atPath: cli.path) else { throw .noBundledCLI(path: cli.path) }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: link.path) else { return .absent }
        switch attributes[.type] as? FileAttributeType {
        case .typeSymbolicLink: return .symlink
        case .typeRegular: return .regularFile
        default: throw .notAFile(path: link.path)
        }
    }

    /// Makes `~/.local/bin` if it is missing, then puts the symlink at the link path in one step.
    /// It replaces an earlier symlink or file. Call `check()` first and ask before it replaces a regular file.
    public func install() throws(InstallError) {
        _ = try check()
        let folder = link.deletingLastPathComponent()
        let temporary = folder.appending(path: ".skillgarden-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: temporary, withDestinationURL: cli)
        } catch {
            throw .write(description: error.localizedDescription)
        }
        // rename(2) replaces the old link or file at once, so the command is never missing.
        guard rename(temporary.path, link.path) == 0 else {
            let description = String(cString: strerror(errno))
            try? FileManager.default.removeItem(at: temporary)
            throw .write(description: "\(link.path): \(description)")
        }
    }
}
