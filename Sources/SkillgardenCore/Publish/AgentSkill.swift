import Foundation

/// The agent skill and the publishing guide in `Skillgarden.app/Contents/Resources/AgentSkill` (#250).
/// `skillgarden skill install <folder>` copies them to `<folder>/skillgarden-publish`.
public enum AgentSkill {
    public static let name = "skillgarden-publish"
    /// The folder below `Contents/Resources`. Contents/Helpers holds only code (#248).
    public static let resourceFolder = "AgentSkill"
    public static let skillFile = "SKILL.md"
    public static let guideFile = "agent-publishing.md"
    public static let files = [skillFile, guideFile]

    /// `Contents/Resources/AgentSkill` of the app that holds the CLI. A symlink on PATH resolves to the app first.
    public static func bundledFolder(executable: URL? = Bundle.main.executableURL) -> URL? {
        guard let executable else { return nil }
        return executable.resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Resources/\(resourceFolder)", directoryHint: .isDirectory)
    }

    /// The installed SKILL.md links the guide next to it, not the repository path.
    public static func installedSkill(_ text: String) -> String {
        text.replacingOccurrences(of: "](../\(guideFile))", with: "](\(guideFile))")
            .replacingOccurrences(of: "docs/\(guideFile)", with: guideFile)
    }

    public enum InstallError: Error, Equatable, LocalizedError {
        /// The bundled folder or one of its files is missing, such as for a CLI from a source build.
        case notBundled(path: String)
        /// The target folder or `<folder>/skillgarden-publish` is a file.
        case notAFolder(path: String)
        case write(path: String, description: String)

        public var errorDescription: String? {
            switch self {
            case .notBundled(let path): "no bundled agent skill at \(path)"
            case .notAFolder(let path): "not a folder: \(path)"
            case .write(let path, let description): "\(path): \(description)"
            }
        }
    }

    /// Writes `<folder>/skillgarden-publish/SKILL.md` and `agent-publishing.md`. It makes missing folders and replaces old files.
    /// Returns the skill folder.
    @discardableResult
    public static func install(from source: URL, into folder: URL) throws(InstallError) -> URL {
        var texts: [String: String] = [:]
        for file in files {
            guard let text = try? String(contentsOf: source.appending(path: file), encoding: .utf8) else {
                throw .notBundled(path: source.appending(path: file).path)
            }
            texts[file] = file == skillFile ? installedSkill(text) : text
        }
        let skill = folder.appending(path: name, directoryHint: .isDirectory)
        for path in [folder, skill] {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: path.path, isDirectory: &isDirectory), !isDirectory.boolValue {
                throw .notAFolder(path: path.path)
            }
        }
        do {
            try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
        } catch {
            throw .write(path: skill.path, description: error.localizedDescription)
        }
        for file in files {
            let target = skill.appending(path: file)
            do {
                try Data(texts[file, default: ""].utf8).write(to: target, options: .atomic)
            } catch {
                throw .write(path: target.path, description: error.localizedDescription)
            }
        }
        return skill
    }
}
