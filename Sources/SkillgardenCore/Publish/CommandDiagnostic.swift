import Foundation

/// The stable codes of `--json` diagnostics (#109). Add cases only. Never rename a raw value.
public enum DiagnosticCode: String, CaseIterable, Sendable {
    case usage
    case dataDirectoryRelative = "data_dir.relative"
    case courseFolderMissing = "course_folder.missing"
    case manifestMissing = "manifest.missing"
    case manifestDuplicate = "manifest.duplicate"
    case manifestSyntax = "manifest.syntax"
    case fieldRequired = "field.required"
    case fieldType = "field.type"
    case fieldChoice = "field.choice"
    case fieldNotAllowed = "field.not_allowed"
    /// A value of the right type that breaks a rule, such as a range, a URL or a hex color.
    case fieldValue = "field.value"
    case idDuplicate = "id.duplicate"
    case orderDuplicate = "order.duplicate"
    case referenceUnknown = "reference.unknown"
    case pathOutside = "path.outside"
    case pathMissing = "path.missing"
    case pathNotNormalized = "path.not_normalized"
    case mediaInvalid = "media.invalid"
    case courseNotFound = "course.not_found"
    case libraryBusy = "library.busy"
    case io
    /// `doctor` finds a file, not a folder, at the library path (#108).
    case dataDirectoryNotFolder = "data_dir.not_folder"
    /// `init` finds entries other than `.DS_Store` in the target folder (#110).
    case courseFolderNotEmpty = "course_folder.not_empty"
    /// `init` finds a file, not a folder, at the target path (#110).
    case courseFolderNotFolder = "course_folder.not_folder"
    /// `media inspect` finds no file at the path (#116).
    case fileNotFound = "file_not_found"
    /// `media inspect` finds a file that does not start with an MP4 `ftyp` box (#116).
    case notMP4 = "not_mp4"
    /// `media inspect` finds an MP4 file with no readable length (#116).
    case noVideoLength = "no_video_length"
}

/// One problem of a CLI run. Text mode prints `error: <text>`. JSON mode writes each field.
public struct CommandDiagnostic: Equatable, Sendable {
    public let code: DiagnosticCode
    public let file: String?
    public let fieldPath: String?
    public let message: String
    public let hint: String?

    public init(code: DiagnosticCode, file: String? = nil, fieldPath: String? = nil, message: String, hint: String? = nil) {
        self.code = code
        self.file = file
        self.fieldPath = fieldPath
        self.message = message
        self.hint = hint
    }

    public init(_ diagnostic: ManifestDiagnostic) {
        self.init(code: diagnostic.code, file: diagnostic.file, fieldPath: diagnostic.fieldPath,
                  message: diagnostic.message, hint: diagnostic.hint)
    }

    /// The text after `error: ` in text mode.
    public var text: String {
        guard let file, let fieldPath else { return message }
        return "\(file): \(fieldPath): \(message)"
    }
}

extension ManifestDiagnostic {
    /// The code comes from the message, so each message keeps one code.
    public var code: DiagnosticCode {
        let m = message
        if m == "no skillgarden.yaml or skillgarden.json found" { return .manifestMissing }
        if m.hasPrefix("found skillgarden.yaml and skillgarden.json") { return .manifestDuplicate }
        if m == "cannot read or parse manifest" { return .manifestSyntax }
        if m == "required field is missing" || m == "alt text is required" || m == "must not be empty"
            || m.hasPrefix("required when type is") || m.hasPrefix("must have at least") || m.hasSuffix("needs an entry with alt text") {
            return .fieldRequired
        }
        if m.hasPrefix("expected "), m.contains(", found ") { return .fieldType }
        if m.hasPrefix("must be one of: ") { return .fieldChoice }
        if m.hasPrefix("allowed only when type is") { return .fieldNotAllowed }
        if m.hasPrefix("duplicate id ") { return .idDuplicate }
        if m.hasPrefix("duplicate order ") { return .orderDuplicate }
        if m.hasPrefix("must refer to ") { return .referenceUnknown }
        if m.hasPrefix("path must stay inside") || m == "path must not be inside internal/"
            || m == "library must be outside the course folder" || m.hasSuffix("must be a file inside the course folder") {
            return .pathOutside
        }
        if m == "file does not exist" || m.hasPrefix("folder must contain ") || (m.hasPrefix("image \"") && m.contains("\" does not exist")) {
            return .pathMissing
        }
        if m.hasPrefix("path must be normalized") { return .pathNotNormalized }
        if m == ImagePipelineError.unsupportedFormat.message || m == ImagePipelineError.unreadable.message
            || m == "must be an .mp4 file" || m == "must be a .vtt file" || m == "file is not an MP4 video"
            || m.hasPrefix("must match the video length") || m == "cannot read the video length"
            || m.hasPrefix("invalid WebVTT file") || m.hasPrefix("cannot read the captions file")
            || m.hasPrefix("cannot read the Markdown file") || m.hasSuffix("is blocked in the app") {
            return .mediaInvalid
        }
        if m.hasPrefix("must be ") || m.hasPrefix("must have at most ") { return .fieldValue }
        return .io
    }

    /// A short fix for the agent, or nil when no fix is known.
    public var hint: String? {
        let path = fieldPath
        switch code {
        case .manifestMissing: return "Add skillgarden.yaml or skillgarden.json to the course folder."
        case .manifestDuplicate: return "Delete skillgarden.yaml or skillgarden.json."
        case .manifestSyntax: return "Fix the YAML or JSON syntax of the manifest."
        case .fieldRequired:
            if message == "must not be empty" { return "Give \(path) a value." }
            if message == "alt text is required" { return "Add alt text to \(path)." }
            if message.hasPrefix("must have at least") { return "Add items to \(path)." }
            if message.hasSuffix("needs an entry with alt text") { return "Add the image with alt text to \(path)." }
            return "Add \(path)."
        case .fieldType:
            guard let type = message.dropFirst("expected ".count).split(separator: ",").first else { return nil }
            let article = ["array", "object", "integer"].contains(String(type)) ? "an" : "a"
            return "Change \(path) to \(article) \(type)."
        case .fieldChoice: return "Change \(path) to one of: \(message.dropFirst("must be one of: ".count))."
        case .fieldNotAllowed: return "Remove \(path), or change the lecture type."
        case .idDuplicate: return "Give \(path) a unique id."
        case .orderDuplicate: return "Give \(path) a unique order."
        case .referenceUnknown: return "Change \(path) to an id that exists."
        case .pathOutside:
            if message == "library must be outside the course folder" { return "Use a data folder outside the course folder." }
            if message == "path must stay inside internal/" { return "Use a path that starts with internal/." }
            if message == "path must not be inside internal/" { return "Move the file out of internal/." }
            return "Use a relative path inside the course folder."
        case .pathMissing:
            if message.hasPrefix("folder must contain ") {
                return "Add \(message.dropFirst("folder must contain ".count)) to the folder at \(path)."
            }
            return "Add the file to the course folder, or change \(path)."
        case .pathNotNormalized:
            guard let range = message.range(of: "use ") else { return nil }
            return "Change \(path) to \(message[range.upperBound...])."
        case .usage, .dataDirectoryRelative, .courseFolderMissing, .fieldValue, .mediaInvalid, .courseNotFound, .libraryBusy, .io,
             .dataDirectoryNotFolder, .courseFolderNotEmpty, .courseFolderNotFolder, .fileNotFound, .notMP4, .noVideoLength:
            return nil
        }
    }
}
