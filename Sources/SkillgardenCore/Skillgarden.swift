import Foundation

/// Shared facts about the Skillgarden library.
public enum Skillgarden {
    public static let version = "0.1.0"

    /// Default data folder: ~/Library/Application Support/Skillgarden.
    public static var defaultDataDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "Skillgarden", directoryHint: .isDirectory)
    }

    /// The environment variable that names the data folder. It has priority over the saved setting.
    public static let dataDirectoryVariable = "SKILLGARDEN_DATA_DIR"
    /// The defaults domain and key of the saved setting: `defaults write dev.skillgarden.app DataDirectory <path>`.
    public static let defaultsDomain = "dev.skillgarden.app"
    public static let dataDirectoryKey = "DataDirectory"

    /// Data folder for the CLI and the app: `SKILLGARDEN_DATA_DIR`, then the saved setting, then Application Support.
    /// An empty value is skipped. A leading `~` expands to `home`. A relative path is an error.
    public static func dataDirectory(environment: [String: String], savedSetting: String?,
                                     home: URL = FileManager.default.homeDirectoryForCurrentUser) throws(DataDirectoryError) -> URL {
        try resolveDataDirectory(environment: environment, savedSetting: savedSetting, home: home).url
    }

    /// The data folder and the source that names it (#108). `defaultDirectory` lets tests replace Application Support.
    public static func resolveDataDirectory(environment: [String: String], savedSetting: String?,
                                            home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                            defaultDirectory: URL = defaultDataDirectory) throws(DataDirectoryError)
        -> (url: URL, source: DataDirectorySource) {
        for (source, value) in [(DataDirectorySource.environment, environment[dataDirectoryVariable]), (.savedSetting, savedSetting)] {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { continue }
            var path = value
            if path == "~" { path = home.path }
            else if path.hasPrefix("~/") { path = home.path + path.dropFirst() }
            guard path.hasPrefix("/") else { throw DataDirectoryError(source: source.name) }
            return (URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL, source)
        }
        return (defaultDirectory, .applicationSupport)
    }

    /// Reads the saved `DataDirectory` setting of the `dev.skillgarden.app` domain.
    public static func savedDataDirectory() -> String? {
        CFPreferencesCopyAppValue(dataDirectoryKey as CFString, defaultsDomain as CFString) as? String
    }

    /// The path to show in the app when `root` is not the default data folder, else nil.
    public static func customDataDirectoryPath(_ root: URL) -> String? {
        let path = root.standardizedFileURL.path(percentEncoded: false)
        let defaultPath = defaultDataDirectory.standardizedFileURL.path(percentEncoded: false)
        func trimmed(_ text: String) -> String { text.count > 1 && text.hasSuffix("/") ? String(text.dropLast()) : text }
        return trimmed(path) == trimmed(defaultPath) ? nil : trimmed(path)
    }

    /// Reads the real environment and the saved setting of the `dev.skillgarden.app` domain.
    public static func dataDirectory() throws(DataDirectoryError) -> URL {
        try dataDirectory(environment: ProcessInfo.processInfo.environment, savedSetting: savedDataDirectory())
    }

    /// The key of the View > Appearance setting in the `dev.skillgarden.app` domain.
    public static let appearanceKey = "Appearance"

    /// The saved View > Appearance choice. A missing or unknown value is Dark.
    public static func savedAppearance() -> AppAppearance {
        AppAppearance(savedValue: CFPreferencesCopyAppValue(appearanceKey as CFString, defaultsDomain as CFString) as? String)
    }

    public static func saveAppearance(_ appearance: AppAppearance) {
        CFPreferencesSetAppValue(appearanceKey as CFString, appearance.rawValue as CFString, defaultsDomain as CFString)
        CFPreferencesAppSynchronize(defaultsDomain as CFString)
    }

    /// The saved Captions and Transcript choices (#97).
    public static func savedVideoTextChoices() -> VideoTextChoices {
        VideoTextChoices { CFPreferencesCopyAppValue($0 as CFString, defaultsDomain as CFString) }
    }

    public static func saveVideoTextChoices(_ choices: VideoTextChoices) {
        for (key, value) in choices.savedValues {
            CFPreferencesSetAppValue(key as CFString, value ? kCFBooleanTrue : kCFBooleanFalse, defaultsDomain as CFString)
        }
        CFPreferencesAppSynchronize(defaultsDomain as CFString)
    }

    /// The key of the Settings "Auto-play next lecture" choice in the `dev.skillgarden.app` domain (#99).
    public static let autoPlayKey = "AutoPlay"

    /// A missing value or a value that is not a Boolean is on.
    public static func autoPlay(savedValue: Any?) -> Bool {
        savedValue as? Bool ?? true
    }

    /// The saved Settings "Auto-play next lecture" choice (#99).
    public static func savedAutoPlay() -> Bool {
        autoPlay(savedValue: CFPreferencesCopyAppValue(autoPlayKey as CFString, defaultsDomain as CFString))
    }

    public static func saveAutoPlay(_ on: Bool) {
        CFPreferencesSetAppValue(autoPlayKey as CFString, on ? kCFBooleanTrue : kCFBooleanFalse, defaultsDomain as CFString)
        CFPreferencesAppSynchronize(defaultsDomain as CFString)
    }
}

/// The app appearance of the View menu (#83). Dark and Light win over a course manifest appearance (#93).
public enum AppAppearance: String, CaseIterable, Identifiable, Sendable {
    // The menu order of the owner: Dark, Light, System.
    case dark, light, system

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .dark: "Dark"
        case .light: "Light"
        case .system: "System"
        }
    }

    /// The fixed appearance, or nil for System.
    public var courseAppearance: CourseAppearance? {
        switch self {
        case .dark: .dark
        case .light: .light
        case .system: nil
        }
    }

    /// The appearance of a window with this setting (#93 owner decision). Dark and Light always win.
    /// System uses the course manifest appearance. Nil means the macOS appearance.
    public func resolved(course: CourseAppearance?) -> CourseAppearance? {
        courseAppearance ?? course
    }

    /// A missing or unknown saved value is Dark.
    public init(savedValue: String?) {
        self = savedValue.flatMap(AppAppearance.init(rawValue:)) ?? .dark
    }
}

/// The Captions and Transcript choices of the learner (#97 owner decision). They apply to every video lecture.
/// The app saves each change at once in the `dev.skillgarden.app` domain, so they stay after the app starts again.
public struct VideoTextChoices: Equatable, Sendable {
    public static let captionsKey = "Captions"
    public static let transcriptKey = "Transcript"

    public var showsCaptions: Bool
    public var showsTranscript: Bool

    public init(showsCaptions: Bool = true, showsTranscript: Bool = true) {
        self.showsCaptions = showsCaptions
        self.showsTranscript = showsTranscript
    }

    /// Reads each key with `savedValue`. A missing value or a value that is not a Boolean is on.
    public init(savedValue: (String) -> Any?) {
        func read(_ key: String) -> Bool { savedValue(key) as? Bool ?? true }
        self.init(showsCaptions: read(Self.captionsKey), showsTranscript: read(Self.transcriptKey))
    }

    /// The keys and the values to save.
    public var savedValues: [(String, Bool)] {
        [(Self.captionsKey, showsCaptions), (Self.transcriptKey, showsTranscript)]
    }
}

/// The setting that names the data folder, in lookup order.
public enum DataDirectorySource: String, CaseIterable, Sendable {
    case environment
    case savedSetting = "saved_setting"
    case applicationSupport = "default"

    /// The name of the variable or the key: `SKILLGARDEN_DATA_DIR`, `DataDirectory` or `Application Support`.
    public var name: String {
        switch self {
        case .environment: Skillgarden.dataDirectoryVariable
        case .savedSetting: Skillgarden.dataDirectoryKey
        case .applicationSupport: "Application Support"
        }
    }

    /// The `doctor` text: `SKILLGARDEN_DATA_DIR (environment)`.
    public var label: String {
        switch self {
        case .environment: "\(name) (environment)"
        case .savedSetting: "\(name) (saved setting)"
        case .applicationSupport: "\(name) (default)"
        }
    }

    init?(name: String) {
        guard let source = Self.allCases.first(where: { $0.name == name }) else { return nil }
        self = source
    }
}

/// The data folder setting is not an absolute path.
public struct DataDirectoryError: Error, Equatable, Sendable, LocalizedError {
    /// `SKILLGARDEN_DATA_DIR` or `DataDirectory`.
    public let source: String

    public var errorDescription: String? { "\(source) must be an absolute path" }
}
