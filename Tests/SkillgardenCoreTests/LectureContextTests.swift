import Foundation
import Testing
@testable import SkillgardenCore

private let fixture = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Fixtures/sample-course")

/// Gives each test an empty snapshot folder.
private func withFolder(_ body: (URL) async throws -> Void) async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "LectureContextTests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: folder) }
    try FileManager.default.createDirectory(at: folder.appending(path: "content"), withIntermediateDirectories: true)
    try await body(folder)
}

private func write(_ text: String, _ path: String, in folder: URL) throws {
    let url = folder.appending(path: path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
}

private func course(_ lectures: [Lecture], state: PublicationState = .published, sectionState: PublicationState = .published) -> Course {
    Course(id: "c", title: "Garden Basics", state: state, sections: [
        CourseSection(id: "s", title: "Start", order: 0, state: sectionState, lectures: lectures),
    ])
}

private func lecture(_ id: String, _ type: LectureType, title: String = "Soil", state: PublicationState = .published) -> Lecture {
    Lecture(id: id, title: title, type: type, order: 0, state: state)
}

private func video(_ folder: URL, captions: String?) -> LectureVideo? {
    LectureVideo(folder: folder, video: ManifestVideo(path: "content/v.mp4", durationSeconds: 60,
                                                      captions: captions.map { ManifestCaptions(path: $0) }))
}

private func vtt(cues: Int, text: String = "Water the bed") -> String {
    "WEBVTT\n" + (0..<cues).map { index in
        let start = LectureVideo.durationLabel(seconds: index)
        return "\n\(start.count == 4 ? "0" : "")\(start).000 --> \(start.count == 4 ? "0" : "")\(start).900\n\(text) \(index).\n"
    }.joined()
}

private func ready(_ outcome: LectureContextOutcome) throws -> LectureContext {
    guard case .ready(let context) = outcome else {
        Issue.record("Expected a ready context, got \(outcome)")
        throw CancellationError()
    }
    return context
}

// MARK: Short lectures

@Test func transcriptPromptHasLabeledCuePassagesThatFitTheBudget() async throws {
    try await withFolder { folder in
        try write("""
            WEBVTT

            00:05.000 --> 00:07.000
            <v Ana>Mulch keeps the soil wet.</v>

            00:01.000 --> 00:03.000
            Dig a bed
            in the sun.

            00:03.000 --> 00:04.000
            \("  ")
            """, "content/v.vtt", in: folder)
        let outcome = LectureContextBuilder.build(course: course([lecture("v", .video)]), lectureID: "v",
                                                  video: video(folder, captions: "content/v.vtt"), article: nil)
        let context = try ready(outcome)
        #expect(outcome.learnerText == nil)
        // The same lines as the Transcript panel: start order, blank cues left out, line breaks as spaces.
        #expect(context.passages == [LecturePassage(id: "t0", label: "0:01", text: "Dig a bed in the sun."),
                                     LecturePassage(id: "t1", label: "0:05", text: "Mulch keeps the soil wet.")])
        let captions = try #require(try video(folder, captions: "content/v.vtt")?.loadCaptions())
        let search = TranscriptCue.cues(lectureID: "v", captions: captions)
        #expect(context.passages.map(\.id) == search.map { "t\($0.index)" })
        // All the text fits, so the prompt has all passages, even for a question with no match.
        let prompt = context.prompt(question: "Why mulch?")
        #expect(context.fitsBudget)
        #expect(context.prompt(question: "Which tractor?").passages == context.passages)
        #expect(!prompt.isPartial && !prompt.noEvidence)
        #expect(prompt.systemPrompt.contains("\"Garden Basics\""))
        #expect(prompt.systemPrompt.contains("\"Soil\""))
        // #175: tutor mode. General knowledge is allowed and marked. IDs only for lecture claims.
        #expect(!prompt.systemPrompt.contains("Answer only from the passages"))
        #expect(!prompt.systemPrompt.contains("Do not guess"))
        #expect(prompt.systemPrompt.contains("""
            You are a tutor. Help the learner understand this lecture.
            The passages below are from the lecture. Each passage starts with its ID in square brackets.
            Use the passages first. Use general knowledge to explain ideas, give examples and answer related questions.
            Put passage IDs only after claims about what the lecture says. Do not put IDs after general knowledge.
            If the lecture does not explain a point, start that part with "The lecture doesn't explain this, but".
            If general knowledge differs from the lecture, say what the lecture says, then explain the difference.
            Never say that the instructor said something that is not in the passages.
            After each fact,
            """))
        #expect(!prompt.systemPrompt.contains("Do not summarize"))
        // #171: one ID, of the first passage, for each fact. #185: square brackets and no ranges.
        #expect(prompt.systemPrompt.hasSuffix("After each fact, put the ID of the first passage that states it, for example [t0]. "
            + "Give one ID for each fact. Do not add IDs of later passages that repeat it. "
            + "Use square brackets. Do not write ranges such as [t3-5].\n\nPassages:\n"
            + "[t0] Dig a bed in the sun.\n[t1] Mulch keeps the soil wet."))
        #expect(prompt.estimatedTokens == context.estimatedTokens)
        #expect(context.estimatedTokens <= LectureContextBudget.standard.promptTokens)
        #expect(context.passage(id: "t1")?.label == "0:05")
        #expect(context.passage(id: "t9") == nil)
        #expect(prompt.messages == [ChatMessage(role: .system, content: prompt.systemPrompt), ChatMessage(role: .user, content: "Why mulch?")])
    }
}

@Test func articlePassagesUseTheNearestHeadingOrTheLectureTitle() async throws {
    try await withFolder { folder in
        try write("""
            Read this first. See the [guide](https://example.com/guide).

            ![A bed](bed.png)

            # Steps

            1. Dig.
            2. Plant.

            ---

            ## Tools

            > A spade is enough.

            ```
            skillgarden publish ./course
            ```
            """, "content/a.md", in: folder)
        let article = LectureArticle(folder: folder, path: "content/a.md", images: [])
        let context = try ready(LectureContextBuilder.build(course: course([lecture("a", .article)]), lectureID: "a",
                                                            video: nil, article: article))
        #expect(context.passages == [
            LecturePassage(id: "a0", label: "Soil", text: "Read this first. See the guide."),
            LecturePassage(id: "a2", label: "Steps", text: "Steps"),
            LecturePassage(id: "a3", label: "Steps", text: "1. Dig.\n2. Plant."),
            LecturePassage(id: "a5", label: "Tools", text: "Tools"),
            LecturePassage(id: "a6", label: "Tools", text: "A spade is enough."),
            LecturePassage(id: "a7", label: "Tools", text: "skillgarden publish ./course"),
        ])
        #expect(!context.prompt(question: "Which guide?").systemPrompt.contains("https://"))
    }
}

// MARK: No text, too long, not available, can't load

@Test func videoWithoutCaptionsOrTranscriptTextHasNoText() async throws {
    try await withFolder { folder in
        let lectures = course([lecture("v", .video)])
        let none = LectureContextBuilder.build(course: lectures, lectureID: "v", video: video(folder, captions: nil), article: nil)
        #expect(none == .noText)
        #expect(none.learnerText == "This lecture has no transcript, so local AI can't answer questions about it.")
        try write("WEBVTT\n\n00:00.000 --> 00:01.000\n \n", "content/v.vtt", in: folder)
        #expect(LectureContextBuilder.build(course: lectures, lectureID: "v", video: video(folder, captions: "content/v.vtt"),
                                            article: nil) == .noText)
        try write("![Only an image](a.png)\n\n---\n", "content/a.md", in: folder)
        #expect(LectureContextBuilder.build(course: course([lecture("a", .article)]), lectureID: "a", video: nil,
                                            article: LectureArticle(folder: folder, path: "content/a.md", images: [])) == .noText)
    }
}

@Test func longLectureIsReadyForRetrievalAndOnlyAHugeFileIsTooLong() async throws {
    try await withFolder { folder in
        let lectures = course([lecture("v", .video)])
        try write(vtt(cues: 40), "content/v.vtt", in: folder)
        let captions = video(folder, captions: "content/v.vtt")
        let context = try ready(LectureContextBuilder.build(course: lectures, lectureID: "v", video: captions, article: nil))
        // The limit is exact: all the text fits at its own size, and retrieval starts one token below.
        let fits = LectureContextBudget(contextTokens: context.estimatedTokens + 30, answerTokens: 20, questionTokens: 10)
        let all = try ready(LectureContextBuilder.build(course: lectures, lectureID: "v", video: captions, article: nil, budget: fits))
        #expect(all.fitsBudget && all.passages == context.passages)
        #expect(!all.prompt(question: "Water?").isPartial)
        let short = LectureContextBudget(contextTokens: context.estimatedTokens + 29, answerTokens: 20, questionTokens: 10)
        let long = try ready(LectureContextBuilder.build(course: lectures, lectureID: "v", video: captions, article: nil, budget: short))
        #expect(!long.fitsBudget && long.passages == context.passages)
        #expect(long.prompt(question: "Water?").isPartial)
        // A file over the byte limit is too long before a read.
        try Data(repeating: 0x61, count: LectureContextBudget.maximumFileBytes + 1).write(to: folder.appending(path: "content/v.vtt"))
        let tooLong = LectureContextBuilder.build(course: lectures, lectureID: "v", video: captions, article: nil)
        #expect(tooLong == .tooLong)
        #expect(tooLong.learnerText == "This lecture is too long for local AI.")
    }
}

@Test func draftHiddenAndNonTextLecturesAreNotAvailable() async throws {
    try await withFolder { folder in
        try write("Draft secret text.", "content/a.md", in: folder)
        let article = LectureArticle(folder: folder, path: "content/a.md", images: [])
        func build(_ course: Course, _ id: String = "a") -> LectureContextOutcome {
            LectureContextBuilder.build(course: course, lectureID: id, video: nil, article: article)
        }
        #expect(build(course([lecture("a", .article)])) != .notAvailable)
        #expect(build(course([lecture("a", .article, state: .draft)])) == .notAvailable)
        #expect(build(course([lecture("a", .article)], sectionState: .draft)) == .notAvailable)
        #expect(build(course([lecture("a", .article)], state: .draft)) == .notAvailable)
        #expect(build(course([lecture("a", .article)]), "missing") == .notAvailable)
        for type in [LectureType.quiz, .assignment, .interactive] {
            #expect(build(course([lecture("a", type)])) == .notAvailable)
        }
        #expect(LectureContextOutcome.notAvailable.learnerText == nil)
    }
}

@Test func unreadableOrEscapedTextCantLoad() async throws {
    try await withFolder { folder in
        let lectures = course([lecture("v", .video)]), articles = course([lecture("a", .article)])
        func caption(_ path: String) -> LectureContextOutcome {
            LectureContextBuilder.build(course: lectures, lectureID: "v", video: video(folder, captions: path), article: nil)
        }
        func article(_ path: String) -> LectureContextOutcome {
            LectureContextBuilder.build(course: articles, lectureID: "a", video: nil,
                                        article: LectureArticle(folder: folder, path: path, images: []))
        }
        #expect(caption("content/missing.vtt") == .cantLoad)
        #expect(LectureContextOutcome.cantLoad.learnerText == "Skillgarden can't read the text of this lecture.")
        try write("not a caption file", "content/bad.vtt", in: folder)
        #expect(caption("content/bad.vtt") == .cantLoad)
        try Data([0xFF, 0xFE, 0x00]).write(to: folder.appending(path: "content/bad.md"))
        #expect(article("content/bad.md") == .cantLoad)
        #expect(LectureContextBuilder.build(course: lectures, lectureID: "v", video: nil, article: nil) == .cantLoad)
        #expect(LectureContextBuilder.build(course: articles, lectureID: "a", video: nil, article: nil) == .cantLoad)
        // A symbolic link out of the snapshot, a folder and a path inside `internal/` are never read.
        let outside = folder.deletingLastPathComponent().appending(path: "secret-\(UUID()).vtt")
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data(vtt(cues: 1, text: "Internal secret").utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: folder.appending(path: "content/link.vtt"), withDestinationURL: outside)
        #expect(caption("content/link.vtt") == .cantLoad)
        try FileManager.default.createDirectory(at: folder.appending(path: "content/dir.md"), withIntermediateDirectories: true)
        #expect(article("content/dir.md") == .cantLoad)
        try write("Internal secret", "Internal/notes.md", in: folder)
        #expect(article("Internal/notes.md") == .cantLoad)
        #expect(article("../\(outside.lastPathComponent)") == .cantLoad)
    }
}

// MARK: Cache

@Test func cacheReadsEachRevisionOnceAndRechecksTheOutline() async throws {
    try await withFolder { folder in
        try write("First text.", "content/a.md", in: folder)
        try write("Second text.", "content/b.md", in: folder)
        let cache = LectureContextCache()
        let first = LectureArticle(folder: folder, path: "content/a.md", images: [])
        let published = course([lecture("a", .article)])
        let outcome = await cache.context(course: published, lectureID: "a", video: nil, article: first)
        #expect(try ready(outcome).passages.map(\.text) == ["First text."])
        #expect(await cache.context(course: published, lectureID: "a", video: nil, article: first) == outcome)
        #expect(await cache.loadCount == 1)
        // A republish gives a new source path, so the cache reads the new text.
        let second = LectureArticle(folder: folder, path: "content/b.md", images: [])
        #expect(try ready(await cache.context(course: published, lectureID: "a", video: nil, article: second)).passages.map(\.text)
                == ["Second text."])
        #expect(await cache.loadCount == 2)
        // A new title or budget is a new revision too.
        let renamed = course([lecture("a", .article, title: "Beds")])
        #expect(try ready(await cache.context(course: renamed, lectureID: "a", video: nil, article: second)).lectureTitle == "Beds")
        #expect(await cache.loadCount == 3)
        // A lecture that goes back to draft is not available at once, with no read.
        #expect(await cache.context(course: course([lecture("a", .article, state: .draft)]), lectureID: "a", video: nil,
                                    article: second) == .notAvailable)
        #expect(await cache.loadCount == 3)
        // A failed read is not kept, so the next call tries again.
        let missing = LectureArticle(folder: folder, path: "content/c.md", images: [])
        #expect(await cache.context(course: published, lectureID: "a", video: nil, article: missing) == .cantLoad)
        try write("Third text.", "content/c.md", in: folder)
        #expect(try ready(await cache.context(course: published, lectureID: "a", video: nil, article: missing)).passages.map(\.text)
                == ["Third text."])
        #expect(await cache.loadCount == 5)
    }
}

@Test func serverContextSizeIsTheBudgetContext() {
    #expect(LectureContextBudget.standard.contextTokens == 8192)
    #expect(LectureContextBudget.standard.promptTokens == 8192 - 1024 - 512)
    #expect(LectureContextBudget.estimatedTokens("") == 0)
    #expect(LectureContextBudget.estimatedTokens("abcd") == 2)
}

// MARK: Published fixture

private let secrets = [
    "INTERNAL-SECRET-4410", "Team transcript placeholder", "This placeholder belongs to the team",
    "DRAFT-SECRET-7731", "DRAFT-CAPTION-2093",
    // Quiz answers, quick-check answers, the assignment brief and rubric, and source cards.
    "Each column is one section", "On a web server", "The outline lists the sections in order",
    "Write a one-page plan", "Cut detail that the learner does not need", "Plan a course on one page",
]

@MainActor @Test func publishedFixtureNeverPutsInternalOrDraftTextInAPrompt() async throws {
    let base = FileManager.default.temporaryDirectory.appending(path: "LectureContextFixture-\(UUID())")
    defer { try? FileManager.default.removeItem(at: base) }
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let folder = base.appending(path: "course"), root = base.appending(path: "library")
    try FileManager.default.copyItem(at: fixture, to: folder)
    try FileManager.default.removeItem(at: folder.appending(path: "equivalent.json"))
    try write("# Team material\n\nINTERNAL-SECRET-4410\n", "internal/research.md", in: folder)
    try write("# Draft\n\nDRAFT-SECRET-7731\n", "content/draft.md", in: folder)
    try write("WEBVTT\n\n00:00.000 --> 00:01.000\nDRAFT-CAPTION-2093\n", "content/draft.vtt", in: folder)
    let manifest = folder.appending(path: "skillgarden.yaml")
    let draftLectures = """
              - id: draft-article
                title: Draft article
                type: article
                objective: Describe the draft
                state: draft
                order: 2
                article:
                  path: content/draft.md
              - id: draft-video
                title: Draft video
                type: video
                objective: Describe the draft
                state: draft
                order: 3
                video:
                  path: content/welcome.mp4
                  duration_seconds: 4
                  captions:
                    path: content/draft.vtt
          - id: practice
        """
    let text = try String(contentsOf: manifest, encoding: .utf8)
    #expect(text.contains("  - id: practice\n"))
    try text.replacingOccurrences(of: "  - id: practice\n", with: draftLectures + "\n").write(to: manifest, atomically: true, encoding: .utf8)
    try CoursePublisher.publish(courseFolder: folder, root: root)
    let snapshot = try #require(try CoursePublisher.assetDirectory(courseID: "sample-course", root: root))
    // The draft files are in the learner snapshot, so only the outline gate keeps them out.
    #expect(FileManager.default.fileExists(atPath: snapshot.appending(path: "content/draft.md").path))

    let library = LibraryModel(root: root)
    await library.reload()
    library.selectCourse("sample-course")
    var prompts: [String] = []
    var outcomes: [String: LectureContextOutcome] = [:]
    for id in ["welcome", "read", "check", "apply", "draft-article", "draft-video", "unknown"] {
        let outcome = await library.lectureContext(forLecture: id)
        outcomes[id] = outcome
        if case .ready(let context) = outcome { prompts.append(context.prompt(question: "What is in this lecture?").messages.map(\.content).joined()) }
    }
    let welcome = try ready(try #require(outcomes["welcome"]))
    #expect(welcome.courseTitle == "Local Course Basics")
    #expect(welcome.passages == [LecturePassage(id: "t0", label: "0:00", text: "Welcome to Local Course Basics."),
                                 LecturePassage(id: "t1", label: "0:02", text: "You will plan a course step by step.")])
    let read = try ready(try #require(outcomes["read"]))
    #expect(read.passages.first == LecturePassage(id: "a0", label: "Course plan", text: "Course plan"))
    for id in ["check", "apply", "draft-article", "draft-video", "unknown"] {
        #expect(outcomes[id] == .notAvailable, "\(id)")
    }
    #expect(prompts.count == 2)
    for prompt in prompts {
        for secret in secrets { #expect(!prompt.contains(secret), "\(secret)") }
    }
    // A caption file that links to the internal area of the library can't load.
    let internalFile = try #require(FileManager.default.enumerator(at: root.appending(path: "internal"), includingPropertiesForKeys: nil)?
        .compactMap { $0 as? URL }.first { $0.lastPathComponent == "transcript.vtt" })
    let captions = snapshot.appending(path: "content/welcome.vtt")
    try FileManager.default.removeItem(at: captions)
    try FileManager.default.createSymbolicLink(at: captions, withDestinationURL: internalFile)
    let course = try #require(library.selectedCourse)
    #expect(LectureContextBuilder.build(course: course, lectureID: "welcome", video: library.video(forLecture: "welcome"),
                                        article: nil) == .cantLoad)
    #expect(await library.selectCourseNone() == .notAvailable)
}

private extension LibraryModel {
    /// With no selected course, no lecture is available.
    func selectCourseNone() async -> LectureContextOutcome {
        selectCourse(nil)
        return await lectureContext(forLecture: "welcome")
    }
}
