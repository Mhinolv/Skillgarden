import Foundation

/// An image of an article, resolved inside the installed course snapshot.
public struct ArticleImage: Equatable, Sendable {
    public let url: URL
    public let alt: String

    public init(url: URL, alt: String) {
        self.url = url
        self.alt = alt
    }
}

/// The Markdown file of an article lecture in the installed course snapshot, with the manifest alt text of its images.
public struct LectureArticle: Equatable, Sendable {
    public let url: URL
    /// The snapshot folder. Image references resolve inside it.
    public let folder: URL
    /// Alt text by image path, relative to the course folder.
    public let alts: [String: String]
    /// The course-relative path of the Markdown file.
    public let path: String

    public init(folder: URL, path: String, images: [ManifestImage]) {
        self.folder = folder
        self.path = path
        url = folder.appending(path: path)
        alts = Dictionary(images.compactMap { image in
            Self.normalize(image.path).map { ($0, image.alt) }
        }, uniquingKeysWith: { first, _ in first })
    }

    /// The image for a Markdown reference, or nil if the reference is not a file inside the snapshot.
    /// The alt text is nil when the manifest does not list the image.
    public func image(for source: String) -> (url: URL, alt: String?)? {
        guard let relative = Self.resolve(source, article: path) else { return nil }
        return (folder.appending(path: relative), alts[relative])
    }

    /// Reads and parses the Markdown file. Call it off the main actor.
    public func load() throws -> MarkdownDocument {
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else { throw CocoaError(.fileReadInapplicableStringEncoding) }
        return MarkdownDocument(markdown: text)
    }

    /// The course-relative path of a Markdown image reference. Returns nil for a URL with a scheme,
    /// an absolute path, a path outside the course folder and a path inside `internal/`.
    public static func resolve(_ source: String, article: String) -> String? {
        let decoded = source.removingPercentEncoding ?? source
        guard !decoded.isEmpty, !decoded.hasPrefix("/"), !decoded.hasPrefix("\\"),
              decoded.range(of: "^[A-Za-z][A-Za-z0-9+.-]*:", options: .regularExpression) == nil else { return nil }
        let folder = article.replacingOccurrences(of: "\\", with: "/").split(separator: "/").dropLast().joined(separator: "/")
        return normalize(folder.isEmpty ? decoded : folder + "/" + decoded)
    }

    /// Removes `.` and `..` parts. Returns nil if the path leaves the course folder or is inside `internal/`.
    static func normalize(_ path: String) -> String? {
        var parts: [Substring] = []
        for part in path.replacingOccurrences(of: "\\", with: "/").split(separator: "/") {
            switch part {
            case ".": continue
            case "..":
                guard !parts.isEmpty else { return nil }
                parts.removeLast()
            default: parts.append(part)
            }
        }
        guard let first = parts.first, !isInternalFolder(first) else { return nil }
        return parts.joined(separator: "/")
    }

    /// True for the team-only folder name `internal` in any case. Mac volumes often ignore case.
    static func isInternalFolder(_ name: some StringProtocol) -> Bool {
        name.lowercased() == "internal"
    }
}

/// A standalone Markdown audio link resolved inside the installed learner snapshot.
public struct ArticleAudio: Equatable, Sendable {
    public let url: URL
    public let title: String

    public init?(paragraph: String, article: LectureArticle) {
        let pattern = #"^\[([^\]]+)\]\(([^()\s]+)\)$"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: paragraph, range: NSRange(paragraph.startIndex..., in: paragraph)),
              let titleRange = Range(match.range(at: 1), in: paragraph),
              let sourceRange = Range(match.range(at: 2), in: paragraph),
              let relative = LectureArticle.resolve(String(paragraph[sourceRange]), article: article.path) else { return nil }
        let candidate = article.folder.appending(path: relative).resolvingSymlinksInPath()
        let root = article.folder.resolvingSymlinksInPath()
        guard candidate.path.hasPrefix(root.path + "/"),
              LectureArticle.resolve(String(candidate.path.dropFirst(root.path.count + 1)), article: "root.md") != nil,
              ["mp3", "m4a", "wav", "aiff", "aac", "flac"].contains(candidate.pathExtension.lowercased()),
              (try? candidate.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
        url = candidate
        title = String(paragraph[titleRange])
    }
}
