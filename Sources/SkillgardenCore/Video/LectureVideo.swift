import Foundation

/// The video of a video lecture, resolved inside the installed course snapshot.
public struct LectureVideo: Equatable, Sendable {
    public let url: URL
    /// Nil when the manifest has no captions.
    public let captionsURL: URL?
    /// Nil when the manifest has no poster.
    public let posterURL: URL?
    public let posterAlt: String
    public let durationSeconds: Int
    /// The ungraded checks after the video. Empty when the manifest has no `quick_checks`.
    public let quickChecks: [QuickCheck]

    /// Returns nil if the video path is not a file inside the snapshot. A caption or poster path outside it is ignored.
    public init?(folder: URL, video: ManifestVideo) {
        func resolve(_ path: String?) -> URL? {
            path.flatMap(LectureArticle.normalize).map { folder.appending(path: $0) }
        }
        guard let url = resolve(video.path) else { return nil }
        self.url = url
        captionsURL = resolve(video.captions?.path)
        posterURL = resolve(video.poster?.path)
        posterAlt = video.poster?.alt ?? ""
        durationSeconds = video.durationSeconds
        quickChecks = QuickCheck.checks(manifest: video.quickChecks)
    }

    /// "Video · 12:34".
    public var metadataLabel: String { "Video · \(Self.durationLabel(seconds: durationSeconds))" }

    /// `m:ss`, or `h:mm:ss` for one hour or more. A negative value shows as 0:00.
    public static func durationLabel(seconds: Int) -> String {
        let total = max(seconds, 0)
        let hours = total / 3600, minutes = total / 60 % 60, rest = total % 60
        func two(_ value: Int) -> String { value < 10 ? "0\(value)" : "\(value)" }
        return hours > 0 ? "\(hours):\(two(minutes)):\(two(rest))" : "\(minutes):\(two(rest))"
    }

    /// Reads and parses the captions file. Call it off the main actor. Returns nil when the lecture has no captions.
    public func loadCaptions() throws -> WebVTT? {
        guard let captionsURL else { return nil }
        return try Self.captions(at: captionsURL)
    }

    static func captions(at url: URL) throws -> WebVTT {
        guard let text = String(data: try Data(contentsOf: url), encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return try WebVTT(text: text)
    }

    /// True if the file starts with an MP4 `ftyp` box.
    static func isMP4(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 8), header.count == 8 else { return false }
        return Data(header.dropFirst(4)) == Data("ftyp".utf8)
    }
}
