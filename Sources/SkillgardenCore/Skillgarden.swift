import Foundation

/// Shared facts about the Skillgarden library.
public enum Skillgarden {
    public static let version = "0.1.0"

    /// Default data folder: ~/Library/Application Support/Skillgarden.
    public static var defaultDataDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "Skillgarden", directoryHint: .isDirectory)
    }
}
