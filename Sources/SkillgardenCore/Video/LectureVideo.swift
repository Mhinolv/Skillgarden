import Foundation

/// The video of a video lecture, resolved inside the installed course snapshot.
public struct LectureVideo: Equatable, Sendable {
    public let url: URL
    /// The snapshot folder. The local AI context (#125) checks that the captions file is inside it.
    public let folder: URL
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
        self.folder = folder
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

    /// The spoken length for VoiceOver, for example "4 minutes, 32 seconds" in English. A negative value speaks as 0 seconds.
    public static func spokenDuration(seconds: Int, locale: Locale = .current) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = [.hour, .minute, .second]
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        formatter.calendar = calendar
        return formatter.string(from: TimeInterval(max(seconds, 0))) ?? durationLabel(seconds: seconds)
    }

    /// The trailing length of a lecture row in the sidebar outline (#103), for example "4:32".
    /// Nil for a lecture that is not a video, or a video lecture that has no resolved video in the snapshot.
    public static func outlineDurationLabel(type: LectureType, video: LectureVideo?) -> String? {
        guard type == .video, let video else { return nil }
        return durationLabel(seconds: video.durationSeconds)
    }

    /// The VoiceOver label of a lecture row in the sidebar outline: the title, the type, the spoken length of a video and "Completed".
    /// For example "Set up the garden bed, video, 4 minutes, 32 seconds, Completed".
    public static func outlineAccessibilityLabel(lecture: Lecture, video: LectureVideo?, isDone: Bool,
                                                 locale: Locale = .current) -> String {
        let duration = lecture.type == .video ? video.map { spokenDuration(seconds: $0.durationSeconds, locale: locale) } : nil
        return ([lecture.title, lecture.type.rawValue] + [duration, isDone ? "Completed" : nil].compactMap { $0 })
            .joined(separator: ", ")
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

    /// The movie length from the `moov/mvhd` box, rounded to the nearest second. Nil if the file has no readable length.
    /// It reads only box headers, so a large `mdat` box costs nothing.
    static func length(of url: URL) -> Int? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        func read(_ offset: UInt64, _ count: Int) -> Data? {
            guard (try? handle.seek(toOffset: offset)) != nil, let data = try? handle.read(upToCount: count),
                  data.count == count else { return nil }
            return data
        }
        func integer(_ data: Data, _ start: Int, _ size: Int) -> UInt64 {
            data.dropFirst(start).prefix(size).reduce(0) { $0 << 8 | UInt64($1) }
        }
        /// Finds the body of the first box of `type` between `start` and `end`.
        func find(_ type: String, from start: UInt64, to end: UInt64) -> (start: UInt64, end: UInt64)? {
            var offset = start
            while offset + 8 <= end, let header = read(offset, 8) {
                var size = integer(header, 0, 4), body = offset + 8
                if size == 1 {
                    guard let large = read(offset + 8, 8) else { return nil }
                    size = integer(large, 0, 8)
                    body += 8
                } else if size == 0 {
                    size = end - offset
                }
                guard size >= body - offset, offset + size <= end else { return nil }
                if header.dropFirst(4) == Data(type.utf8) { return (body, offset + size) }
                offset += size
            }
            return nil
        }
        guard let fileSize = try? handle.seekToEnd(), let moov = find("moov", from: 0, to: fileSize),
              let mvhd = find("mvhd", from: moov.start, to: moov.end), let version = read(mvhd.start, 1)?.first else { return nil }
        // Version 1 has 64-bit times and duration. Version 0 has 32-bit fields.
        let (offset, size) = version == 1 ? (20, 8) : (12, 4)
        guard let fields = read(mvhd.start + UInt64(offset), 4 + size), mvhd.start + UInt64(offset + 4 + size) <= mvhd.end else {
            return nil
        }
        let timescale = integer(fields, 0, 4)
        var duration = integer(fields, 4, size)
        // A fragmented MP4 can give 0 in `mvhd` and the length in `moov/mvex/mehd`.
        if duration == 0 {
            guard let mvex = find("mvex", from: moov.start, to: moov.end), let mehd = find("mehd", from: mvex.start, to: mvex.end),
                  let header = read(mehd.start, 1)?.first else { return nil }
            let size = header == 1 ? 8 : 4
            guard mehd.start + UInt64(4 + size) <= mehd.end, let field = read(mehd.start + 4, size) else { return nil }
            duration = integer(field, 0, size)
        }
        guard timescale > 0, duration > 0, duration < UInt64(Int.max) else { return nil }
        return Int((Double(duration) / Double(timescale)).rounded())
    }
}
