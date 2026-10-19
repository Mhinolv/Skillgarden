import Foundation

/// The token budget of a local AI prompt (#125). The prompt, the question and the answer share the model context.
public struct LectureContextBudget: Hashable, Sendable {
    /// The `--ctx-size` of llama-server.
    public var contextTokens: Int
    /// The tokens kept free for the answer.
    public var answerTokens: Int
    /// The tokens kept free for the learner question.
    public var questionTokens: Int

    public init(contextTokens: Int, answerTokens: Int, questionTokens: Int) {
        self.contextTokens = contextTokens
        self.answerTokens = answerTokens
        self.questionTokens = questionTokens
    }

    /// The budget of the bundled runtime.
    public static let standard = LectureContextBudget(contextTokens: 8192, answerTokens: 1024, questionTokens: 512)

    /// The most tokens that the system prompt with its passages can use.
    public var promptTokens: Int { max(0, contextTokens - answerTokens - questionTokens) }

    /// A source file larger than this is too long without a read. Each token is 3 bytes or more, and a
    /// caption cue has about 30 bytes of timing for each line of text, so 8 times the text size is a safe limit.
    var maximumFileBytes: Int { promptTokens * 3 * 8 }

    /// A high estimate of the tokens of `text`: one token for each 3 UTF-8 bytes.
    /// Most tokenizers give one token for each 4 characters of English.
    public static func estimatedTokens(_ text: String) -> Int {
        (text.utf8.count + 2) / 3
    }
}

/// One passage of the lecture text in the prompt (#125). #129 uses `id` and `label` for citations.
public struct LecturePassage: Equatable, Hashable, Sendable, Identifiable {
    /// `t<cue index>` for a transcript cue, `a<block index>` for an article block. Learners never see it.
    public let id: String
    /// The cue time, as in the Transcript panel, or the nearest article heading above the block.
    public let label: String
    public let text: String

    public init(id: String, label: String, text: String) {
        self.id = id
        self.label = label
        self.text = text
    }
}

/// The prompt context of one published lecture: all of its text, in passages that fit the budget.
public struct LectureContext: Equatable, Sendable {
    public let courseTitle: String
    public let lectureTitle: String
    public let passages: [LecturePassage]
    /// The system message: the framing, then each passage as `[<id>] <text>`.
    public let systemPrompt: String

    init(courseTitle: String, lectureTitle: String, passages: [LecturePassage]) {
        self.courseTitle = courseTitle
        self.lectureTitle = lectureTitle
        self.passages = passages
        systemPrompt = """
            You answer questions from a learner about one lecture of the course "\(courseTitle)".
            The lecture is "\(lectureTitle)".
            Answer only from the passages below. Each passage starts with its ID in square brackets.
            If the passages do not hold the answer, say that this lecture does not cover it. Do not guess.
            After each fact, put the ID of its passage in square brackets, for example [\(passages.first?.id ?? "t0")].

            Passages:
            """ + passages.map { "\n[\($0.id)] \($0.text)" }.joined()
    }

    public var estimatedTokens: Int { LectureContextBudget.estimatedTokens(systemPrompt) }

    /// The passage of a citation ID, or nil if the context has no such passage.
    public func passage(id: String) -> LecturePassage? {
        passages.first { $0.id == id }
    }

    /// The chat request: the system prompt, then the question of the learner.
    public func messages(question: String) -> [ChatMessage] {
        [ChatMessage(role: .system, content: systemPrompt), ChatMessage(role: .user, content: question)]
    }
}

/// The result of a context build (#125). The #128 lecture Q&A tab shows `learnerText`.
public enum LectureContextOutcome: Equatable, Sendable {
    case ready(LectureContext)
    /// A video with no captions or transcript, or an article with no text.
    case noText
    /// The text does not fit the budget. #126 adds retrieval for long lectures.
    case tooLong
    /// A draft lecture, a lecture outside the published outline, or a lecture type without text for AI.
    case notAvailable
    /// The text file is missing, unreadable, invalid or outside the snapshot.
    case cantLoad

    /// The design-note text for the learner. Nil when the tab shows no message.
    public var learnerText: String? {
        switch self {
        case .ready, .notAvailable: nil
        case .noText: "This lecture has no transcript, so local AI can't answer questions about it."
        case .tooLong: "This lecture is too long for local AI. Questions about long lectures are not available yet."
        case .cantLoad: "Skillgarden can't read the text of this lecture."
        }
    }
}

/// Builds the prompt context of a lecture from its published transcript or article only (#125).
/// It never reads manifest fields of quizzes or assignments, learner notes, downloads or internal files.
public enum LectureContextBuilder {
    /// The lecture if the learner can see it: a published course, section and lecture in the outline.
    /// The first section wins for a lecture id that repeats, as in the outline.
    public static func learnerLecture(_ lectureID: String, in course: Course) -> Lecture? {
        guard course.state == .published else { return nil }
        return course.learnerLectures.first { $0.lecture.id == lectureID }?.lecture
    }

    /// Reads the text of the lecture. Call it off the main actor.
    public static func build(course: Course, lectureID: String, video: LectureVideo?, article: LectureArticle?,
                             budget: LectureContextBudget = .standard) -> LectureContextOutcome {
        guard let lecture = learnerLecture(lectureID, in: course) else { return .notAvailable }
        let passages: [LecturePassage]
        switch lecture.type {
        case .video:
            guard let video else { return .cantLoad }
            guard let captionsURL = video.captionsURL else { return .noText }
            switch read(captionsURL, folder: video.folder, budget: budget) {
            case .failure(let outcome): return outcome
            case .success(let data):
                guard let text = String(data: data, encoding: .utf8), let captions = try? WebVTT(text: text) else { return .cantLoad }
                passages = transcriptPassages(Transcript(captions: captions))
            }
        case .article:
            guard let article else { return .cantLoad }
            switch read(article.url, folder: article.folder, budget: budget) {
            case .failure(let outcome): return outcome
            case .success(let data):
                guard let text = String(data: data, encoding: .utf8) else { return .cantLoad }
                passages = articlePassages(MarkdownDocument(markdown: text), lectureTitle: lecture.title)
            }
        case .quiz, .assignment, .interactive:
            return .notAvailable
        }
        guard !passages.isEmpty else { return .noText }
        let context = LectureContext(courseTitle: course.title, lectureTitle: lecture.title, passages: passages)
        return context.estimatedTokens <= budget.promptTokens ? .ready(context) : .tooLong
    }

    /// The cues of the Transcript panel and transcript search, so citation times match.
    static func transcriptPassages(_ transcript: Transcript) -> [LecturePassage] {
        transcript.lines.map { LecturePassage(id: "t\($0.id)", label: $0.timeLabel, text: $0.text) }
    }

    /// The text blocks of the article. Images and rules have no text. Links keep only their text.
    static func articlePassages(_ document: MarkdownDocument, lectureTitle: String) -> [LecturePassage] {
        var label = lectureTitle
        var passages: [LecturePassage] = []
        for (index, block) in document.blocks.enumerated() {
            let text: String
            switch block {
            case let .heading(_, heading):
                text = plainText(heading)
                if !text.isEmpty { label = text }
            case let .paragraph(value), let .quote(value): text = plainText(value)
            case let .code(value): text = value
            case let .list(ordered, start, items):
                text = items.enumerated().map { (ordered ? "\(start + $0). " : "- ") + plainText($1) }.joined(separator: "\n")
            case .image, .rule: continue
            }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            passages.append(LecturePassage(id: "a\(index)", label: label, text: text))
        }
        return passages
    }

    /// `[text](url)` and `![alt](url)` become `text` and `alt`, so the prompt holds no link targets.
    private static func plainText(_ markdown: String) -> String {
        markdown.replacingOccurrences(of: #"!?\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    private enum ReadResult {
        case success(Data)
        case failure(LectureContextOutcome)
    }

    /// Reads `url` after a new check that its real path is a regular file inside the snapshot and not in `internal/`.
    /// A file over the byte limit is too long, so it is not read.
    private static func read(_ url: URL, folder: URL, budget: LectureContextBudget) -> ReadResult {
        guard let file = resolvedFile(url, folder: folder) else { return .failure(.cantLoad) }
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= budget.maximumFileBytes else { return .failure(.tooLong) }
        guard let data = try? Data(contentsOf: file) else { return .failure(.cantLoad) }
        return .success(data)
    }

    /// The real file of `url`, or nil if a symbolic link or `..` leaves the snapshot, or the file is not a regular file.
    static func resolvedFile(_ url: URL, folder: URL) -> URL? {
        func realPath(_ url: URL) -> String {
            var path = url.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
            if path.count > 1, path.hasSuffix("/") { path.removeLast() }
            return path
        }
        let base = realPath(folder), file = url.standardizedFileURL.resolvingSymlinksInPath()
        let path = realPath(file)
        guard path.hasPrefix(base + "/") else { return nil }
        let relative = String(path.dropFirst(base.count + 1))
        guard LectureArticle.normalize(relative) == relative,
              (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
        return file
    }
}

/// Caches lecture contexts by course, lecture and source revision (#125). Reads run on this actor, off the main actor.
/// A republish installs a new snapshot folder, so the source path changes and the next call reads the new text.
public actor LectureContextCache {
    struct Revision: Hashable {
        let courseTitle: String
        let lectureTitle: String
        let source: String?
        let budget: LectureContextBudget
    }

    private struct Key: Hashable {
        let courseID: String
        let lectureID: String
    }

    /// One entry for each lecture. A new revision replaces the entry, so the cache does not grow.
    private var entries: [Key: (revision: Revision, outcome: LectureContextOutcome)] = [:]
    /// The number of source reads. Tests use it.
    private(set) var loadCount = 0

    public init() {}

    public func context(course: Course, lectureID: String, video: LectureVideo?, article: LectureArticle?,
                        budget: LectureContextBudget = .standard) -> LectureContextOutcome {
        // The outline gate runs on each call, so a lecture that goes back to draft is not available at once.
        guard let lecture = LectureContextBuilder.learnerLecture(lectureID, in: course) else { return .notAvailable }
        let source: URL? = switch lecture.type {
        case .video: video?.captionsURL
        case .article: article?.url
        case .quiz, .assignment, .interactive: nil
        }
        let key = Key(courseID: course.id, lectureID: lectureID)
        let revision = Revision(courseTitle: course.title, lectureTitle: lecture.title,
                                source: source?.standardizedFileURL.path(percentEncoded: false), budget: budget)
        if let entry = entries[key], entry.revision == revision { return entry.outcome }
        loadCount += 1
        let outcome = LectureContextBuilder.build(course: course, lectureID: lectureID, video: video, article: article, budget: budget)
        // A read error can pass, so the next call tries again.
        if outcome == .cantLoad { entries[key] = nil } else { entries[key] = (revision, outcome) }
        return outcome
    }
}
