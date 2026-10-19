import Foundation
import Testing
@testable import SkillgardenCore

// #129: answer citations. Markers are checked against the stored passages of the lecture text that the learner asked about.
// Only valid markers get an action. The seek time and the excerpt come from the stored passage, never from the model text.

private let fixture = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Fixtures/sample-course")

private let videoContext = LectureContext(
    courseTitle: "C", lectureTitle: "L",
    passages: [LecturePassage(id: "t0", label: "0:00", text: "Dig a bed."),
               LecturePassage(id: "t1", label: "4:12", text: "Mulch keeps the soil wet.")],
    seekTimes: ["t0": 0.5, "t1": 252.4])

private let articleContext = LectureContext(
    courseTitle: "C", lectureTitle: "L",
    passages: [LecturePassage(id: "a0", label: "Soil", text: "Soil holds water."),
               LecturePassage(id: "a2", label: "Tools", text: "A spade is enough.")])

/// No request runs in these tests.
private struct NoTransport: LlamaTransport {
    func send(_ request: URLRequest) -> AsyncThrowingStream<LlamaTransportEvent, any Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

// MARK: Parse

@Test func validVideoMarkersGetNumbersInOrderOfFirstUseAndTheStoredCueStart() {
    let citations = AnswerCitations(answer: "Mulch it [t1]. Dig first [t0]. Mulch again [t1].", context: videoContext, isStale: false)
    #expect(citations.text == "Mulch it [1]. Dig first [2]. Mulch again [1].")
    #expect(citations.sources == [AnswerSource(number: 1, kind: .video(seconds: 252.4, cueText: "Mulch keeps the soil wet.")),
                                  AnswerSource(number: 2, kind: .video(seconds: 0.5, cueText: "Dig a bed."))])
    #expect(citations.sources.map(\.title) == ["1 · 4:12", "2 · 0:00"])
    #expect(citations.sources.map(\.isActionable) == [true, true])
    #expect(citations.sources[0].help == "Mulch keeps the soil wet.")
    #expect(citations.sources[0].accessibilityLabel(locale: Locale(identifier: "en_US")) == "Source 1, at 4 minutes 12 seconds")
    #expect(citations.sources[0].accessibilityHint == "Shows this moment in the video. Playback pauses.")
}

@Test func aTimeInTheModelTextIsNeverASeekTime() {
    // The model writes a wrong time next to the marker. Only the stored cue start counts.
    let citations = AnswerCitations(answer: "At 9:59 [t1] you mulch.", context: videoContext, isStale: false)
    #expect(citations.sources.map(\.kind) == [.video(seconds: 252.4, cueText: "Mulch keeps the soil wet.")])
}

@Test func unknownAndWrongLectureMarkersAreOneNonActionableSource() {
    let citations = AnswerCitations(answer: "One [L12]. Two [t9]. Three [a0]. Four [t0].", context: videoContext, isStale: false)
    #expect(citations.text == "One [?]. Two [?]. Three [?]. Four [1].")
    #expect(citations.sources.map(\.id) == ["1", "?"])
    let unknown = citations.sources[1]
    #expect(!unknown.isActionable)
    #expect(unknown.kind == .unknown)
    #expect(unknown.title == "? · Unknown source")
    #expect(unknown.help == "This lecture has no source with this name.")
    #expect(unknown.accessibilityLabel() == "Unknown source, not available")
    #expect(unknown.accessibilityHint == nil)
}

@Test func staleMarkersKeepNumbersButHaveNoAction() {
    let citations = AnswerCitations(answer: "Dig [t0], then mulch [t1]. Odd [x7].", context: videoContext, isStale: true)
    #expect(citations.text == "Dig [1], then mulch [2]. Odd [?].")
    #expect(citations.sources.map(\.kind) == [.stale, .stale, .unknown])
    #expect(citations.sources.map(\.isActionable) == [false, false, false])
    #expect(citations.sources[0].title == "1 · Earlier version")
    #expect(citations.sources[0].help == "This source is from an earlier version of the lecture.")
    #expect(citations.sources[0].accessibilityLabel() == "Source 1, not available")
}

@Test func articleMarkersShowTheStoredExcerpt() {
    let citations = AnswerCitations(answer: "Use a spade [a2] in wet soil [a0].", context: articleContext, isStale: false)
    #expect(citations.text == "Use a spade [1] in wet soil [2].")
    #expect(citations.sources.map(\.kind) == [.article(excerpt: "A spade is enough."), .article(excerpt: "Soil holds water.")])
    #expect(citations.sources[0].title == "1 · Excerpt")
    #expect(citations.sources[0].accessibilityLabel() == "Source 1, excerpt")
    #expect(citations.sources[0].accessibilityHint == "Shows the excerpt.")
    // A transcript ID is not a passage of the article.
    #expect(AnswerCitations(answer: "Dig [t0].", context: articleContext, isStale: false).sources.map(\.kind) == [.unknown])
}

@Test func markerListsSpacesAndPlainBracketsParse() {
    let citations = AnswerCitations(answer: "Both [t0, t1] and [ t1 ]. Not [1], [x] or [link](https://example.com).",
                                    context: videoContext, isStale: false)
    #expect(citations.text == "Both [1][2] and [2]. Not [1], [x] or [link](https://example.com).")
    #expect(citations.sources.map(\.id) == ["1", "2"])
}

@Test func anAnswerWithNoMarkersOrNoContextHasNoActions() {
    let plain = AnswerCitations(answer: "This lecture does not cover it.", context: videoContext, isStale: false)
    #expect(plain.sources.isEmpty)
    #expect(plain.segments == [.text("This lecture does not cover it.")])
    #expect(AnswerCitations(answer: "", context: videoContext, isStale: false).segments.isEmpty)
    let noContext = AnswerCitations(answer: "Dig [t0].", context: nil, isStale: false)
    #expect(noContext.sources.map(\.kind) == [.unknown])
    // A marker that the stream did not finish stays plain text.
    #expect(AnswerCitations(answer: "Dig [t0", context: videoContext, isStale: false).text == "Dig [t0")
}

@Test func videoHelpIsTheCueTextShortenedTo120Characters() throws {
    let long = String(repeating: "word ", count: 40)
    let source = AnswerSource(number: 1, kind: .video(seconds: 3, cueText: long))
    let help = try #require(source.help)
    #expect(help.count <= 120)
    #expect(help.hasSuffix("…"))
    let exact = String(repeating: "a", count: 120)
    #expect(AnswerSource(number: 1, kind: .video(seconds: 3, cueText: exact)).help == exact)
}

@Test func theTurnLabelUsesTheNumberedAnswer() {
    let turn = QATurn(id: 1, question: "Why?", answer: "Because [t0].", status: .complete, sourceRevision: "r", askedAt: .now)
    let citations = AnswerCitations(answer: turn.answer, context: videoContext, isStale: false)
    #expect(turn.accessibilityLabel(answer: citations.text) == "Question: Why?. Answer: Because [1].")
}

// MARK: Lecture context

@MainActor @Test func transcriptContextsStoreTheCueStartOfEachPassage() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "AnswerCitationTests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let courseID = try #require(try SnapshotPlan.seedStore(for: .qaCitations, root: root, fixture: fixture))
    let library = LibraryModel(root: root)
    await library.reload()
    library.selectCourse(courseID)
    guard case .ready(let video) = await library.lectureContext(forLecture: "welcome") else {
        Issue.record("The welcome lecture has no context"); return
    }
    #expect(video.seekTimes == ["t0": 0, "t1": 2])
    guard case .ready(let article) = await library.lectureContext(forLecture: "read") else {
        Issue.record("The read lecture has no context"); return
    }
    #expect(article.seekTimes.isEmpty)
    // The snapshot answer of the article cites the Steps list and the Notes list.
    #expect(article.passage(id: "a4")?.text.hasPrefix("1. Write the **goal**") == true)
    #expect(article.passage(id: "a6")?.text.hasPrefix("- Keep each lecture short.") == true)
}

// MARK: Seek

@MainActor @Test func aVideoSourceSeeksTheOpenLecturePausedAndKeepsTheQAPanel() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "AnswerCitationTests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let courseID = try #require(try SnapshotPlan.seedStore(for: .qaCitations, root: root, fixture: fixture))
    let library = LibraryModel(root: root)
    await library.reload()
    library.selectCourse(courseID)
    library.selectDestination(.lecture(sectionID: "plan", lectureID: "welcome"))
    try await SnapshotPlan.seedQATurns(for: .qaCitations, library: library)

    let qa = LectureQA(library: library, client: LlamaClient(transport: NoTransport()), endpoint: { nil })
    qa.show(LectureQA.key(library: library))
    await qa.load()
    let turn = try #require(qa.conversation.turns.first)
    let citations = qa.citations(for: turn)
    #expect(citations.text == "It starts with a welcome [1]. Then you plan the course step by step [2]. The guide has more help [?].")
    #expect(citations.sources.map(\.title) == ["1 · 0:00", "2 · 0:02", "? · Unknown source"])

    // Unknown sources do not seek.
    qa.seek(to: citations.sources[2])
    #expect(library.transcriptSeek == nil)

    qa.seek(to: citations.sources[1])
    let seek = try #require(library.transcriptSeek)
    #expect(seek.lectureID == "welcome" && seek.seconds == 2)
    #expect(!seek.showsTranscript)
    #expect(library.destination == .lecture(sectionID: "plan", lectureID: "welcome"))
    // A second click seeks again.
    qa.seek(to: citations.sources[1])
    #expect(library.transcriptSeek?.id != seek.id)

    // A seek for a lecture that is not open does nothing.
    let before = library.transcriptSeek
    library.seekCitation(lectureID: "read", seconds: 2)
    library.seekCitation(lectureID: "welcome", seconds: -1)
    library.seekCitation(lectureID: "welcome", seconds: .nan)
    #expect(library.transcriptSeek == before)
}

@MainActor @Test func turnsOfAnEarlierLectureVersionGetStaleSources() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "AnswerCitationTests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let courseID = try #require(try SnapshotPlan.seedStore(for: .qaCitationsStale, root: root, fixture: fixture))
    let library = LibraryModel(root: root)
    await library.reload()
    library.selectCourse(courseID)
    library.selectDestination(.lecture(sectionID: "plan", lectureID: "welcome"))
    try await SnapshotPlan.seedQATurns(for: .qaCitationsStale, library: library)

    let qa = LectureQA(library: library, client: LlamaClient(transport: NoTransport()), endpoint: { nil })
    qa.show(LectureQA.key(library: library))
    await qa.load()
    let turn = try #require(qa.conversation.earlierTurns.first)
    let citations = qa.citations(for: turn)
    #expect(citations.text == "It starts with a welcome [1], then a plan [2].")
    #expect(citations.sources.map(\.kind) == [.stale, .stale])
    qa.seek(to: citations.sources[0])
    #expect(library.transcriptSeek == nil)
    // The draft is always of the current text.
    #expect(qa.citations(forDraft: "Dig [t0]").sources.map(\.title) == ["1 · 0:00"])
}

@MainActor @Test func articleSourcesDoNotSeek() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "AnswerCitationTests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let courseID = try #require(try SnapshotPlan.seedStore(for: .qaCitationExcerpt, root: root, fixture: fixture))
    let library = LibraryModel(root: root)
    await library.reload()
    library.selectCourse(courseID)
    library.selectDestination(SnapshotPlan.destination(for: .qaCitationExcerpt))
    try await SnapshotPlan.seedQATurns(for: .qaCitationExcerpt, library: library)

    let qa = LectureQA(library: library, client: LlamaClient(transport: NoTransport()), endpoint: { nil })
    qa.show(LectureQA.key(library: library))
    await qa.load()
    let turn = try #require(qa.conversation.turns.first)
    let citations = qa.citations(for: turn)
    #expect(citations.text == "Write the goal of the course first [1]. Keep each lecture short [2].")
    guard case .article(let excerpt) = citations.sources.first?.kind else { Issue.record("No article source"); return }
    #expect(excerpt.hasPrefix("1. Write the **goal** of the course."))
    qa.seek(to: citations.sources[0])
    #expect(library.transcriptSeek == nil)
    // A video seek on an article page does nothing.
    library.seekCitation(lectureID: "read", seconds: 1)
    #expect(library.transcriptSeek == nil)
}
