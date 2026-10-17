import Foundation

/// One "Sources and further watching" card of a lecture, in manifest order.
public struct LectureSource: Equatable, Sendable {
    public let title: String
    public let channel: String
    /// Nil when the manifest has no `url` or the value is not an http or https URL. The app hides "Open" then.
    public let url: URL?
    /// Seconds from the start of the source.
    public let start: Int?
    /// Seconds from the start of the source.
    public let end: Int?

    public init(title: String, channel: String, url: URL? = nil, start: Int? = nil, end: Int? = nil) {
        self.title = title
        self.channel = channel
        self.url = url
        self.start = start
        self.end = end
    }

    public init(manifest: ManifestSource) {
        self.init(title: manifest.title, channel: manifest.channel, url: manifest.url.flatMap(Self.webURL),
                  start: manifest.timestampStart, end: manifest.timestampEnd)
    }

    /// The time range line: "4:10 – 9:32", "From 4:10" or "Until 9:32". Nil when the source has no timestamps.
    public var rangeText: String? {
        switch (start, end) {
        case let (start?, end?): "\(LectureVideo.durationLabel(seconds: start)) – \(LectureVideo.durationLabel(seconds: end))"
        case let (start?, nil): "From \(LectureVideo.durationLabel(seconds: start))"
        case let (nil, end?): "Until \(LectureVideo.durationLabel(seconds: end))"
        case (nil, nil): nil
        }
    }

    /// The card label for VoiceOver: "<title>, <channel>, <time range>".
    public var accessibilityLabel: String {
        ([title, channel] + (rangeText.map { [$0] } ?? [])).joined(separator: ", ")
    }

    /// The URL if the text is an http or https URL with a host, else nil.
    public static func webURL(_ text: String) -> URL? {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host?.isEmpty == false else { return nil }
        return url
    }
}
