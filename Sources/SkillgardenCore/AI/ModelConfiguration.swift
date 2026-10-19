import Foundation
import Observation

/// One local GGUF model that the learner chose in Settings (#122). The app reads it in place and does not copy it.
public struct LocalModel: Equatable, Sendable {
    public let url: URL
    public let sizeBytes: Int64

    public init(url: URL, sizeBytes: Int64) {
        self.url = url
        self.sizeBytes = sizeBytes
    }

    /// The file name, for example `qwen2.5-3b-instruct-q4_k_m.gguf`.
    public var name: String { url.lastPathComponent }

    /// The file size with `ByteCountFormatter` `.file`, for example `2.1 GB`.
    public var sizeText: String { ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file) }

    /// The path with `~` for the home folder.
    public func displayPath(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        LocalModel.displayPath(url.path(percentEncoded: false), home: home)
    }

    static func displayPath(_ path: String, home: URL) -> String {
        var homePath = home.standardizedFileURL.path(percentEncoded: false)
        if homePath.count > 1 && homePath.hasSuffix("/") { homePath.removeLast() }
        if path == homePath { return "~" }
        return path.hasPrefix(homePath + "/") ? "~" + path.dropFirst(homePath.count) : path
    }

    /// The caption under the file name: `<size> · <path>`.
    public func detailText(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        "\(sizeText) · \(displayPath(home: home))"
    }
}

/// Why Skillgarden can't use a model file. Each case holds the file name.
public enum ModelProblem: Error, Equatable, Sendable {
    /// The saved model was moved or deleted.
    case missing(String)
    case unreadable(String)
    case notGGUF(String)
    /// One part of a model that `gguf-split` cut into more files.
    case splitPart(String)

    /// The file name.
    public var name: String {
        switch self {
        case .missing(let name), .unreadable(let name), .notGGUF(let name), .splitPart(let name): name
        }
    }

    /// The design-note text for the row or the alert.
    public var message: String {
        switch self {
        case .missing: "The model file is missing. It was moved or deleted. Choose it again."
        case .unreadable(let name): "Skillgarden can't read \"\(name)\". Check its permissions, then choose it again."
        case .notGGUF(let name): "\"\(name)\" is not a GGUF model file."
        case .splitPart(let name): "\"\(name)\" is one part of a split model. Choose a single-file GGUF model."
        }
    }
}

/// Checks that a file is one readable, single-file GGUF model.
public enum ModelValidator {
    /// The first 4 bytes of each GGUF file.
    static let magic = Data("GGUF".utf8)
    /// The `gguf-split` part names: `<name>-00001-of-00003.gguf`.
    nonisolated(unsafe) static let splitName = /-\d{5}-of-\d{5}\.gguf$/.ignoresCase()
    /// The metadata to read for the `split.count` key. `gguf-split` writes the split keys first.
    static let headerLimit = 64 * 1024

    public static func validate(_ url: URL) -> Result<LocalModel, ModelProblem> {
        let name = url.lastPathComponent
        let path = url.path(percentEncoded: false)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isTrashed(path) else {
            return .failure(.missing(name))
        }
        guard !isDirectory.boolValue else { return .failure(.notGGUF(name)) }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .failure(.unreadable(name)) }
        defer { try? handle.close() }
        let header: Data
        do { header = try handle.read(upToCount: headerLimit) ?? Data() } catch { return .failure(.unreadable(name)) }
        guard header.prefix(4) == magic else { return .failure(.notGGUF(name)) }
        if name.contains(splitName) || (splitCount(header) ?? 1) > 1 { return .failure(.splitPart(name)) }
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0
        return .success(LocalModel(url: url, sizeBytes: size))
    }

    /// A bookmark follows a file into the Trash, so a model in the Trash counts as deleted.
    static func isTrashed(_ path: String) -> Bool {
        path.contains("/.Trash/") || path.contains("/.Trashes/")
    }

    /// The `split.count` value in the GGUF metadata, or nil when the header has none.
    /// The scan stops at the first array or at the end of `header`, because only the first keys matter.
    static func splitCount(_ header: Data) -> Int? {
        var reader = GGUFReader(data: header, offset: 4)
        guard let version = reader.uint32(), version >= 2, reader.uint64() != nil, let keyCount = reader.uint64() else { return nil }
        for _ in 0..<min(keyCount, 64) {
            guard let key = reader.string(), let type = reader.uint32() else { return nil }
            if key == "split.count" { return reader.integer(type: type) }
            guard reader.skip(type: type) else { return nil }
        }
        return nil
    }
}

/// Reads little-endian GGUF values from the start of a file.
struct GGUFReader {
    let data: Data
    var offset: Int

    /// The byte count of each fixed-size GGUF value type: uint8 … float64. Type 8 is a string and type 9 is an array.
    static let sizes: [UInt32: Int] = [0: 1, 1: 1, 2: 2, 3: 2, 4: 4, 5: 4, 6: 4, 7: 1, 10: 8, 11: 8, 12: 8]

    mutating func bytes(_ count: Int) -> Data? {
        guard count >= 0, offset + count <= data.count else { return nil }
        defer { offset += count }
        let start = data.startIndex + offset
        return data[start..<start + count]
    }

    mutating func unsigned(_ count: Int) -> UInt64? {
        bytes(count).map { $0.reversed().reduce(UInt64(0)) { $0 << 8 | UInt64($1) } }
    }

    mutating func uint32() -> UInt32? { unsigned(4).map(UInt32.init) }
    mutating func uint64() -> UInt64? { unsigned(8) }

    mutating func string() -> String? {
        guard let length = uint64(), length <= UInt64(data.count), let bytes = bytes(Int(length)) else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// An integer value of the types uint8 … int64. Other types give nil.
    mutating func integer(type: UInt32) -> Int? {
        guard type <= 5 || type >= 10 && type <= 11, let size = Self.sizes[type], let value = unsigned(size) else { return nil }
        return Int(truncatingIfNeeded: value)
    }

    mutating func skip(type: UInt32) -> Bool {
        if type == 8 { return string() != nil }
        guard let size = Self.sizes[type] else { return false }
        return bytes(size) != nil
    }
}

/// The saved model choice: `LocalModel.json` in Application Support. It holds a security-scoped bookmark, not a copy.
struct SavedModel: Codable, Equatable {
    static let currentVersion = 1

    var version: Int
    var bookmark: Data
    /// The last known path. The row uses its file name when the bookmark no longer resolves.
    var path: String

    init(bookmark: Data, path: String) {
        version = Self.currentVersion
        self.bookmark = bookmark
        self.path = path
    }

    /// A missing version is version 1, so a later version can read this file.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        bookmark = try container.decode(Data.self, forKey: .bookmark)
        path = try container.decodeIfPresent(String.self, forKey: .path) ?? ""
    }
}

/// Saves and resolves the bookmark of the chosen model (#122).
public struct ModelBookmarkStore: Sendable {
    /// The JSON file with the bookmark.
    public let fileURL: URL
    /// `.withSecurityScope` in the app. Tests can use no options.
    let creationOptions: URL.BookmarkCreationOptions
    let resolutionOptions: URL.BookmarkResolutionOptions

    /// `directory` is Application Support/Skillgarden in the app and a temporary folder in tests.
    public init(directory: URL = Skillgarden.defaultDataDirectory, securityScoped: Bool = true) {
        fileURL = directory.appending(path: "LocalModel.json")
        creationOptions = securityScoped ? [.withSecurityScope, .securityScopeAllowOnlyReadAccess] : []
        resolutionOptions = securityScoped ? [.withSecurityScope, .withoutUI] : [.withoutUI]
    }

    /// The suggested folder for models: Application Support/Skillgarden/Models. The learner can choose a model anywhere.
    public static var suggestedModelsDirectory: URL {
        Skillgarden.defaultDataDirectory.appending(path: "Models", directoryHint: .isDirectory)
    }

    public func save(_ url: URL) throws {
        let saved = SavedModel(bookmark: try url.bookmarkData(options: creationOptions), path: url.path(percentEncoded: false))
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(saved).write(to: fileURL, options: .atomic)
    }

    /// The saved model, nil when there is none, or the problem of the saved model.
    /// A stale bookmark that resolves is saved again with no message.
    public func load() -> Result<LocalModel, ModelProblem>? {
        guard let data = try? Data(contentsOf: fileURL), let saved = try? JSONDecoder().decode(SavedModel.self, from: data) else {
            return nil
        }
        let name = URL(fileURLWithPath: saved.path).lastPathComponent
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: saved.bookmark, options: resolutionOptions, bookmarkDataIsStale: &isStale) else {
            return .failure(.missing(name))
        }
        let result = withAccess(to: url) { ModelValidator.validate(url) }
        if case .success = result, isStale || url.path(percentEncoded: false) != saved.path {
            withAccess(to: url) { try? save(url) }
        }
        return result
    }

    /// Runs `body` while the app has access to the bookmarked `url`. Callers use it to read the model in place.
    public func withAccess<T>(to url: URL, _ body: () throws -> T) rethrows -> T {
        let started = creationOptions.contains(.withSecurityScope) && url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }
        return try body()
    }
}

/// The Settings "Local AI" model row state (#122).
@MainActor @Observable
public final class ModelSettings {
    public enum State: Equatable, Sendable {
        case none
        case ready(LocalModel)
        /// The saved model can't be used. The row shows the message in red.
        case problem(ModelProblem)
    }

    public private(set) var state: State
    /// True while a new choice is validated.
    public private(set) var isChecking = false
    /// Nil for the snapshot harness, which injects `state` and saves nothing.
    private let store: ModelBookmarkStore?

    public init(store: ModelBookmarkStore?, state: State = .none) {
        self.store = store
        self.state = state
    }

    /// The valid model, or nil.
    public var model: LocalModel? {
        if case .ready(let model) = state { model } else { nil }
    }

    /// Resolves the saved bookmark off the main actor.
    public func load() async {
        guard let store else { return }
        let result = await Task.detached { store.load() }.value
        switch result {
        case nil: state = .none
        case .success(let model): state = .ready(model)
        case .failure(let problem): state = .problem(problem)
        }
    }

    /// Validates `url` off the main actor and saves it when it is valid.
    /// It returns the problem of an invalid choice, and the earlier model stays.
    @discardableResult
    public func choose(_ url: URL) async -> ModelProblem? {
        guard !isChecking else { return nil }
        isChecking = true
        defer { isChecking = false }
        let store = store
        let result: Result<LocalModel, ModelProblem> = await Task.detached {
            let result = ModelValidator.validate(url)
            guard case .success = result, let store else { return result }
            do { try store.save(url) } catch { return .failure(.unreadable(url.lastPathComponent)) }
            return result
        }.value
        switch result {
        case .success(let model):
            state = .ready(model)
            return nil
        case .failure(let problem):
            return problem
        }
    }
}
