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
