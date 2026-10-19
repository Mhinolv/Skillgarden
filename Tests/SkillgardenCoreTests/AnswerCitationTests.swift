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
    // A Markdown link shows only its text (#158).
    #expect(citations.text == "Both [1][2] and [2]. Not [1], [x] or link.")
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

    let qa = LectureQA(library: library, provider: BundledAnswerProvider(client: LlamaClient(transport: NoTransport()), endpoint: { nil }))
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

    let qa = LectureQA(library: library, provider: BundledAnswerProvider(client: LlamaClient(transport: NoTransport()), endpoint: { nil }))
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

    let qa = LectureQA(library: library, provider: BundledAnswerProvider(client: LlamaClient(transport: NoTransport()), endpoint: { nil }))
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

// MARK: Inline Markdown (#158)

@Test func answerTextHasNoInlineMarkdownSyntax() {
    let citations = AnswerCitations(answer: "BF16 uses **2 bytes per weight [t1]**, *not* `4`. See [the guide](https://example.com) or ~~FP32~~.",
                                    context: videoContext, isStale: false)
    #expect(citations.text == "BF16 uses 2 bytes per weight [1], not 4. See the guide or FP32.")
}

/// The runs of `styled` as (text, intent, marker number) for checks.
private func runs(_ citations: AnswerCitations) -> [(String, InlinePresentationIntent?, String?)] {
    citations.styled.runs.map {
        (String(citations.styled[$0.range].characters), $0.inlinePresentationIntent, $0[AnswerMarkerAttribute.self]?.id)
    }
}

@Test func styledAnswerKeepsAMarkerInsideABoldSpanBoldAndRemovesLinks() {
    let citations = AnswerCitations(answer: "BF16 uses **2 bytes [t1] per weight**, *not* `4`. See [the guide](https://example.com) or ~~FP32~~.",
                                    context: videoContext, isStale: false)
    let styled = runs(citations)
    #expect(styled.map(\.0) == ["BF16 uses ", "2 bytes ", "[1]", " per weight", ", ", "not", " ", "4", ". See the guide or ", "FP32", "."])
    #expect(styled[1].1 == .stronglyEmphasized && styled[2].1 == .stronglyEmphasized && styled[3].1 == .stronglyEmphasized)
    #expect(styled.map(\.2) == [nil, nil, "1", nil, nil, nil, nil, nil, nil, nil, nil])
    #expect(styled[5].1 == .emphasized)
    #expect(styled[7].1 == .code)
    #expect(styled[9].1 == .strikethrough)
    #expect(citations.styled.runs.allSatisfy { $0.link == nil })
    #expect(citations.sources.map(\.title) == ["1 · 4:12"])
}

@Test func styledAnswerKeepsStaleAndUnknownMarkersAndTheirSources() {
    let stale = AnswerCitations(answer: "**Dig [t0]** then [x9].", context: videoContext, isStale: true)
    #expect(stale.text == "Dig [1] then [?].")
    let markers = stale.styled.runs.compactMap { $0[AnswerMarkerAttribute.self] }
    #expect(markers.map(\.kind) == [.stale, .unknown])
    #expect(markers.map(\.isActionable) == [false, false])
    // A list of IDs gives one marker for each ID.
    let list = AnswerCitations(answer: "Mulch [t1, t0].", context: videoContext, isStale: false)
    #expect(runs(list).map(\.0) == ["Mulch ", "[1]", "[2]", "."])
}

@Test func styledAnswerKeepsLineBreaksListsAndPlainBrackets() {
    let answer = "Steps:\n\n1. Dig [t0]\n- Mulch * twice\n  [1] and [x] stay"
    let citations = AnswerCitations(answer: answer, context: videoContext, isStale: false)
    #expect(citations.text == "Steps:\n\n1. Dig [1]\n- Mulch * twice\n  [1] and [x] stay")
    #expect(citations.styled.runs.compactMap { $0[AnswerMarkerAttribute.self]?.id } == ["1"])
}

@Test func styledDraftShowsAnOpenBoldMarkAsTextUntilItCloses() {
    let open = AnswerCitations(answer: "It uses **2 bytes [t1]", context: videoContext, isStale: false)
    #expect(open.text == "It uses **2 bytes [1]")
    #expect(open.styled.runs.allSatisfy { $0.inlinePresentationIntent == nil })
    let closed = AnswerCitations(answer: "It uses **2 bytes [t1]**", context: videoContext, isStale: false)
    #expect(closed.text == "It uses 2 bytes [1]")
}

@Test func styledAnswerHandlesEmptyTextMarkerOnlyAndPlaceholderCharacters() {
    #expect(AnswerCitations(answer: "", context: videoContext, isStale: false).text == "")
    #expect(AnswerCitations(answer: "[t1]", context: videoContext, isStale: false).text == "[1]")
    // Private-use characters from the model never become markers.
    let model = AnswerCitations(answer: "A\u{E000}B [t0] C\u{F8FF}", context: videoContext, isStale: false)
    #expect(model.text == "AB [1] C")
    // A marker in a link address is gone, and the next marker keeps its own source.
    let link = AnswerCitations(answer: "[see](https://x.com/[t1]) then [t0]", context: videoContext, isStale: false)
    #expect(link.styled.runs.compactMap { $0[AnswerMarkerAttribute.self]?.id } == ["2"])
}

@Test func turnAccessibilityLabelHasNoMarkdownSyntax() {
    let turn = QATurn(id: 1, question: "What is BF16?", answer: "It uses **2 bytes** [t1], `bf16`, ~~not~~ *4*.",
                      status: .complete, sourceRevision: "r", askedAt: Date())
    let citations = AnswerCitations(answer: turn.answer, context: videoContext, isStale: false)
    let label = turn.accessibilityLabel(answer: citations.text)
    #expect(!label.contains("*") && !label.contains("`") && !label.contains("~"))
    #expect(label.hasPrefix("Question: What is BF16?. Answer: It uses 2 bytes [1], bf16, not 4."))
}
