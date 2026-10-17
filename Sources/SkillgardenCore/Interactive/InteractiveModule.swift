import Foundation

/// The HTML bundle of an interactive lecture in the installed course snapshot.
public struct InteractiveModule: Equatable, Sendable {
    /// The bundle folder. The web view can read only files inside it.
    public let folder: URL

    public init(folder: URL) {
        self.folder = folder.standardizedFileURL
    }

    /// Resolves `bundlePath` inside `snapshot`. Returns nil for a path outside the snapshot or inside `internal/`.
    public init?(snapshot: URL, bundlePath: String) {
        guard let path = LectureArticle.normalize(bundlePath) else { return nil }
        self.init(folder: snapshot.appending(path: path, directoryHint: .isDirectory))
    }

    public static let entryFile = "index.html"

    /// The page that the web view loads first.
    public var entryURL: URL { folder.appending(path: Self.entryFile) }

    /// False if the snapshot lost `index.html`. Call it off the main actor.
    public func entryExists() -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: entryURL.path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }
}

/// The navigation rule of the module web view. Only files inside the bundle can load.
public enum InteractiveNavigationPolicy {
    /// True for a file URL inside `bundle`, and for `about:blank` and `about:srcdoc` frames.
    /// False for every other URL: off-bundle files, HTTP, HTTPS, data, blob and JavaScript URLs.
    public static func allows(_ url: URL, bundle: URL) -> Bool {
        if url.scheme?.lowercased() == "about" {
            return ["blank", "srcdoc"].contains(url.absoluteString.dropFirst("about:".count).lowercased())
        }
        guard url.isFileURL else { return false }
        // Parse the decoded path again, so an encoded "%2F.." part cannot leave the bundle.
        let target = URL(fileURLWithPath: url.path).standardizedFileURL
        // The library folder can be under a link, for example /var to /private/var. Compare the plain and the resolved paths.
        let folders = Set([bundle.standardizedFileURL.path, bundle.standardizedFileURL.resolvingSymlinksInPath().path])
        let targets = Set([target.path, target.resolvingSymlinksInPath().path])
        return targets.contains { path in folders.contains { path.hasPrefix($0 + "/") } }
    }

    /// The file types that publish scans for URL references.
    static let scannedExtensions: Set<String> = ["html", "css", "js"]

    /// XML namespace names. Pages use them as plain text, for example in `createElementNS`. The page never loads them.
    private static let namespaces: Set<String> = [
        "http://www.w3.org/1999/xhtml", "http://www.w3.org/2000/svg", "http://www.w3.org/1999/xlink",
        "http://www.w3.org/1998/Math/MathML", "http://www.w3.org/XML/1998/namespace", "http://www.w3.org/2000/xmlns/",
    ]

    // Group 1 is the attribute name. Groups 2 to 4 are the value in double, single or no quotes.
    private static let attributePattern = try! NSRegularExpression(pattern: #"""
        (?i)(?<![\w:-])(href|src|srcset|action|formaction|poster|data|background|xlink:href)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))
        """#)
    private static let cssPattern = try! NSRegularExpression(pattern: #"""
        (?i)(?:\burl\(\s*(?:"([^"]*)"|'([^']*)'|([^)"'\s]*))\s*\)|@import\s+(?:"([^"]*)"|'([^']*)'))
        """#)
    /// Absolute URLs anywhere in the text, for example in script strings.
    private static let absolutePattern = try! NSRegularExpression(pattern: #"(?i)\b(?:https?://|mailto:)[^\s"'`<>()\\]+"#)
    private static let doctypePattern = try! NSRegularExpression(pattern: #"(?i)<!DOCTYPE[^>]*>"#)

    /// The URL references in the text of `file` that the module web view blocks, in text order.
    /// It finds HTML attributes, CSS `url()` and `@import`, and absolute URLs in other text.
    /// It allows `data:`, `blob:`, and every URL that `allows(_:bundle:)` accepts, such as in-bundle files and `#fragment`.
    static func blockedReferences(in text: String, file: URL, bundle: URL) -> [(line: Int, url: String)] {
        let source = text as NSString
        let whole = NSRange(location: 0, length: source.length)
        var references: [(location: Int, value: String)] = []
        var values: [NSRange] = []
        func value(_ match: NSTextCheckingResult, groups: ClosedRange<Int>) -> NSRange? {
            groups.lazy.map { match.range(at: $0) }.first { $0.location != NSNotFound }
        }
        for match in attributePattern.matches(in: text, range: whole) {
            guard let range = value(match, groups: 2...4) else { continue }
            values.append(range)
            let text = source.substring(with: range)
            // A `srcset` value lists "url size" pairs, separated by commas.
            let items = source.substring(with: match.range(at: 1)).lowercased() == "srcset"
                ? text.split(separator: ",").compactMap { $0.split(whereSeparator: \.isWhitespace).first.map(String.init) }
                : [text]
            references += items.map { (range.location, $0) }
        }
        for match in cssPattern.matches(in: text, range: whole) {
            guard let range = value(match, groups: 1...5) else { continue }
            values.append(range)
            references.append((range.location, source.substring(with: range)))
        }
        let doctypes = doctypePattern.matches(in: text, range: whole).map(\.range)
        for match in absolutePattern.matches(in: text, range: whole) {
            let inside = { (range: NSRange) in NSLocationInRange(match.range.location, range) }
            guard !values.contains(where: inside), !doctypes.contains(where: inside) else { continue }
            references.append((match.range.location, source.substring(with: match.range)))
        }
        // Line starts as UTF-16 offsets, the same unit as the match locations.
        var lineStarts = [0]
        for (offset, unit) in text.utf16.enumerated() where unit == 0x0A { lineStarts.append(offset + 1) }
        func line(_ location: Int) -> Int {
            var low = 0, high = lineStarts.count
            while low + 1 < high {
                let middle = (low + high) / 2
                if lineStarts[middle] <= location { low = middle } else { high = middle }
            }
            return low + 1
        }
        return references.sorted { $0.location < $1.location }.compactMap { location, value in
            let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if ["data:", "blob:"].contains(where: value.lowercased().hasPrefix) || namespaces.contains(value) { return nil }
            guard let url = URL(string: value, relativeTo: file)?.absoluteURL, !allows(url, bundle: bundle) else { return nil }
            return (line(location), value)
        }
    }

    /// A WebKit content rule list that blocks every load that is not a local file, `about:`, `data:` or `blob:` URL.
    /// It stops network requests from scripts, images, styles and frames.
    /// WebKit filters do not support disjunctions (`a|b`), so each scheme has its own rule.
    public static let contentRules = """
        [
          {"trigger": {"url-filter": ".*"}, "action": {"type": "block"}},
          {"trigger": {"url-filter": "^file:"}, "action": {"type": "ignore-previous-rules"}},
          {"trigger": {"url-filter": "^about:"}, "action": {"type": "ignore-previous-rules"}},
          {"trigger": {"url-filter": "^data:"}, "action": {"type": "ignore-previous-rules"}},
          {"trigger": {"url-filter": "^blob:"}, "action": {"type": "ignore-previous-rules"}}
        ]
        """
}

/// A message that the module sends with `Skillgarden.complete()` or `Skillgarden.submitScore(number)`.
public enum InteractiveBridgeMessage: Equatable, Sendable {
    case complete
    /// A score from 0 to 100.
    case score(Int)

    /// The name of the WebKit message handler.
    public static let handlerName = "skillgarden"

    /// Defines `window.Skillgarden`. The web view adds it to each page before the page scripts run.
    public static let bridgeScript = """
        (function () {
          var post = function (message) { window.webkit.messageHandlers.skillgarden.postMessage(message); };
          Object.defineProperty(window, "Skillgarden", {
            value: Object.freeze({
              complete: function () { post({ type: "complete" }); },
              submitScore: function (score) { post({ type: "score", score: score }); }
            }),
            writable: false, configurable: false
          });
        })();
        """

    /// Reads a message body from WebKit. A score is rounded and clamped to 0–100.
    /// Returns nil for an unknown type and for a score that is not a finite number.
    public init?(body: Any) {
        guard let object = body as? [String: Any], let type = object["type"] as? String else { return nil }
        switch type {
        case "complete":
            self = .complete
        case "score":
            guard let number = object["score"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            let value = number.doubleValue
            guard value.isFinite else { return nil }
            self = .score(Int(min(100, max(0, value)).rounded()))
        default:
            return nil
        }
    }
}

/// The latest score of an interactive lecture, with the weak-skill result for the lecture objective.
public struct InteractiveResult: Equatable, Sendable {
    /// From 0 to 100. The app shows it as a percent.
    public let score: Int
    /// The lecture objective if the score is weak, from `SkillReview.weakSkills`.
    public let weakSkills: [String]

    public init(score: Int, weakSkills: [String]) {
        self.score = score
        self.weakSkills = weakSkills
    }

    /// The quiz rule (#11): a skill is weak if the learner lost points. So a score below 100 is weak.
    public static let metScore = 100

    public init(score: Int, objective: String) {
        let score = min(100, max(0, score))
        self.init(score: score, weakSkills: SkillReview.weakSkills([
            SkillOutcome(objectiveTag: objective, correct: score >= Self.metScore),
        ]))
    }
}
