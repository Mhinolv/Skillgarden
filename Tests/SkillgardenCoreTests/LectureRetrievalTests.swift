import Foundation
import Testing
@testable import SkillgardenCore

/// Gives each test an empty snapshot folder.
private func withFolder(_ body: (URL) async throws -> Void) async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "LectureRetrievalTests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: folder) }
    try FileManager.default.createDirectory(at: folder.appending(path: "content"), withIntermediateDirectories: true)
    try await body(folder)
}

private let fillers = ["Water the bed in the morning", "Keep the rows straight and clean", "Check the leaves for spots",
                       "Turn the soil before you plant", "Put the seeds in a dry box", "Cut the old stems at the base"]

/// A caption file of `cues` one-second cues. `special` replaces the text of some cues.
private func longCaptions(cues: Int, special: [Int: String]) -> String {
    "WEBVTT\n" + (0..<cues).map { index in
        let start = String(format: "%02d:%02d:%02d", index / 3600, index / 60 % 60, index % 60)
        return "\n\(start).000 --> \(start).900\n\(special[index] ?? "\(fillers[index % fillers.count]), step \(index).")\n"
    }.joined()
}

private func publishedCourse(_ type: LectureType) -> Course {
    Course(id: "c", title: "Garden Basics", state: .published, sections: [
        CourseSection(id: "s", title: "Start", order: 0, state: .published,
                      lectures: [Lecture(id: "l", title: "Soil", type: type, order: 0, state: .published)]),
    ])
}

/// A long video lecture: 3,000 cues, about 7 times the standard budget. Cue 2,900 is the only cue about compost.
private func longVideo(_ folder: URL, budget: LectureContextBudget = .standard) throws -> LectureContext {
    try Data(longCaptions(cues: 3_000, special: [
        2_900: "Add compost to the beds in late autumn.",
        40: "Dig each hole two hands deep.",
    ]).utf8).write(to: folder.appending(path: "content/v.vtt"))
    let video = LectureVideo(folder: folder, video: ManifestVideo(path: "content/v.mp4", durationSeconds: 3_000,
                                                                  captions: ManifestCaptions(path: "content/v.vtt")))
    guard case .ready(let context) = LectureContextBuilder.build(course: publishedCourse(.video), lectureID: "l",
                                                                 video: video, article: nil, budget: budget) else {
        Issue.record("Expected a ready context")
        throw CancellationError()
    }
    return context
}

/// A long article lecture: 600 paragraphs under headings. Block IDs count headings too.
private func longArticle(_ folder: URL, budget: LectureContextBudget = .standard) throws -> LectureContext {
    let blocks = (0..<600).map { index in
        index == 550 ? "Mulch stops weeds from growing." : index % 50 == 0 ? "# Part \(index / 50)" : "\(fillers[index % fillers.count]), step \(index)."
    }
    try Data(blocks.joined(separator: "\n\n").utf8).write(to: folder.appending(path: "content/a.md"))
    let article = LectureArticle(folder: folder, path: "content/a.md", images: [])
    guard case .ready(let context) = LectureContextBuilder.build(course: publishedCourse(.article), lectureID: "l",
                                                                 video: nil, article: article, budget: budget) else {
        Issue.record("Expected a ready context")
        throw CancellationError()
    }
    return context
}

/// The prompt fits: the system message in its limit, and the system message with the question in the context.
private func expectFits(_ prompt: LecturePrompt, question: String, budget: LectureContextBudget,
                        sourceLocation: SourceLocation = #_sourceLocation) {
    let questionTokens = LectureContextBudget.estimatedTokens(question)
    #expect(prompt.estimatedTokens <= budget.contextTokens - budget.answerTokens - max(budget.questionTokens, questionTokens),
            sourceLocation: sourceLocation)
    #expect(prompt.estimatedTokens + questionTokens <= budget.contextTokens - budget.answerTokens, sourceLocation: sourceLocation)
}

// MARK: Selection

@Test func distantRelevantCueSurvivesSelectionOnALongLecture() async throws {
    try await withFolder { folder in
        let context = try longVideo(folder)
        #expect(!context.fitsBudget)
        #expect(context.estimatedTokens > 7 * LectureContextBudget.standard.promptTokens)
        let question = "When do I add compost?"
        let prompt = context.prompt(question: question)
        #expect(!prompt.noEvidence)
        #expect(prompt.isPartial)
        expectFits(prompt, question: question, budget: .standard)
        // The cue keeps its original ID and time label, and its neighbors give it context.
        let cue = try #require(prompt.passages.first { $0.id == "t2900" })
        #expect(cue == context.passage(id: "t2900"))
        #expect(cue.label == "48:20")
        #expect(prompt.passages.contains { $0.id == "t2899" } && prompt.passages.contains { $0.id == "t2901" })
        #expect(prompt.systemPrompt.contains("\n[t2900] Add compost to the beds in late autumn."))
        // The budget is filled with passages in lecture order, but not with the whole lecture.
        #expect(prompt.estimatedTokens > LectureContextBudget.standard.promptTokens * 9 / 10)
        let indices = prompt.passages.map { context.passages.firstIndex(of: $0)! }
        #expect(indices == indices.sorted())
        #expect(prompt.passages.count < context.passages.count)
        #expect(!prompt.passages.contains { $0.id == "t0" })
        // A partial prompt never asks for a summary of the whole lecture.
        #expect(prompt.systemPrompt.contains("The passages are only the parts of the lecture that match the question."))
        #expect(prompt.systemPrompt.contains("Do not summarize the whole lecture."))
        #expect(prompt.messages == [ChatMessage(role: .system, content: prompt.systemPrompt), ChatMessage(role: .user, content: question)])
    }
}

@Test func articleSelectionKeepsBlockIDsAndHeadingLabels() async throws {
    try await withFolder { folder in
        let context = try longArticle(folder)
        #expect(!context.fitsBudget)
        let prompt = context.prompt(question: "Does mulch stop weeds?")
        #expect(prompt.isPartial && !prompt.noEvidence)
        expectFits(prompt, question: "Does mulch stop weeds?", budget: .standard)
        #expect(prompt.passages.contains(LecturePassage(id: "a550", label: "Part 10", text: "Mulch stops weeds from growing.")))
    }
}

@Test func everyPromptFitsTheBudgetAndIsDeterministic() async throws {
    try await withFolder { folder in
        let questions = ["When do I add compost?", "Does mulch stop weeds?", "Check the leaves for spots", "Water",
                         String(repeating: "How deep do I dig the compost holes? ", count: 200)]
        let budgets = [LectureContextBudget.standard,
                       LectureContextBudget(contextTokens: 4096, answerTokens: 512, questionTokens: 256),
                       LectureContextBudget(contextTokens: 1200, answerTokens: 300, questionTokens: 100),
                       LectureContextBudget(contextTokens: 400, answerTokens: 100, questionTokens: 50)]
        var checked = 0
        for budget in budgets {
            for context in [try longVideo(folder, budget: budget), try longArticle(folder, budget: budget)] {
                for question in questions {
                    let prompt = context.prompt(question: question, priorQuestions: ["Why add compost?"])
                    #expect(prompt == context.prompt(question: question, priorQuestions: ["Why add compost?"]))
                    guard !prompt.noEvidence else { continue }
                    #expect(prompt.isPartial)
                    expectFits(prompt, question: question, budget: budget)
                    checked += 1
                }
            }
        }
        #expect(checked >= 20)
    }
}

@Test func longQuestionTakesTokensFromThePassages() async throws {
    try await withFolder { folder in
        let context = try longVideo(folder)
        let short = context.prompt(question: "Add compost?")
        let question = "Add compost? " + String(repeating: "x", count: 3 * 2_000)
        let long = context.prompt(question: question)
        expectFits(long, question: question, budget: .standard)
        #expect(long.estimatedTokens < short.estimatedTokens - 1_000)
        #expect(long.passages.contains { $0.id == "t2900" })
    }
}

// MARK: No evidence

@Test func noMatchInALongLectureIsNoEvidence() async throws {
    try await withFolder { folder in
        #expect(LecturePrompt.noEvidenceText == "No part of this lecture matches your question. Try words that the lecture uses.")
        for context in [try longVideo(folder), try longArticle(folder)] {
            for question in ["Which tractor brand?", "What is it?", "", "?!"] {
                let prompt = context.prompt(question: question)
                #expect(prompt.noEvidence, "\(question)")
                #expect(!prompt.isPartial)
                #expect(prompt.passages.isEmpty && prompt.messages.isEmpty && prompt.systemPrompt.isEmpty)
            }
        }
    }
}

@Test func matchThatCannotFitIsNoEvidence() {
    let big = LecturePassage(id: "a0", label: "Soil", text: "Compost " + String(repeating: "dirt ", count: 3_000))
    let others = (1...20).map { LecturePassage(id: "a\($0)", label: "Soil", text: "Water the bed, step \($0).") }
    let budget = LectureContextBudget(contextTokens: 1_000, answerTokens: 200, questionTokens: 100)
    let context = LectureContext(courseTitle: "Garden Basics", lectureTitle: "Soil", passages: [big] + others, budget: budget)
    #expect(context.prompt(question: "Compost?").noEvidence)
    let water = context.prompt(question: "Water?")
    #expect(!water.noEvidence && water.isPartial && !water.passages.contains(big))
    expectFits(water, question: "Water?", budget: budget)
    // A budget with no space for passages has no evidence.
    let none = LectureContext(courseTitle: "Garden Basics", lectureTitle: "Soil", passages: others,
                              budget: LectureContextBudget(contextTokens: 100, answerTokens: 100, questionTokens: 100))
    #expect(none.prompt(question: "Water?").noEvidence)
}

// MARK: Follow-up questions

@Test func followUpUsesThePriorQuestionTerms() async throws {
    try await withFolder { folder in
        let context = try longVideo(folder)
        #expect(context.prompt(question: "Why?").noEvidence)
        let followUp = context.prompt(question: "Why?", priorQuestions: ["Which tractor?", "When do I add compost?"])
        #expect(!followUp.noEvidence)
        #expect(followUp.passages.contains { $0.id == "t2900" })
        // The terms of the new question rank first, and the prior terms fill the space that is left.
        let index = try #require(context.retrievalIndex)
        let ranked = index.ranked(question: "How deep do I dig?", priorQuestions: ["When do I add compost?"])
        let first = try #require(ranked.first)
        #expect(index.windows[first].contains(40))
        let dig = context.prompt(question: "How deep do I dig?", priorQuestions: ["When do I add compost?"])
        #expect(dig.passages.contains { $0.id == "t40" } && dig.passages.contains { $0.id == "t2900" })
    }
}

// MARK: Windows and rank

@Test func windowsAreBoundedOverlapAndCoverEveryPassage() async throws {
    try await withFolder { folder in
        let context = try longVideo(folder)
        let index = try #require(context.retrievalIndex)
        #expect(index.windows.first?.lowerBound == 0)
        #expect(index.windows.last?.upperBound == context.passages.count)
        for (window, next) in zip(index.windows, index.windows.dropFirst()) {
            // Each window starts after the one before it and shares its last passages.
            #expect(next.lowerBound > window.lowerBound)
            #expect(next.lowerBound < window.upperBound)
            #expect(window.upperBound - next.lowerBound >= 1)
            #expect(window.map { index.lineBytes[$0] }.reduce(0, +) <= LectureRetrievalIndex.windowBytes)
            #expect((next.lowerBound..<window.upperBound).map { index.lineBytes[$0] }.reduce(0, +) <= LectureRetrievalIndex.overlapBytes)
        }
        // A passage over the window size is a window alone.
        let big = LecturePassage(id: "a1", label: "Soil", text: String(repeating: "dirt ", count: 300))
        let small = LecturePassage(id: "a0", label: "Soil", text: "Dig.")
        let alone = LectureRetrievalIndex(passages: [small, big, small])
        #expect(alone.windows == [0..<1, 1..<2, 2..<3])
        #expect(LectureRetrievalIndex(passages: []).windows.isEmpty)
    }
}

@Test func equalScoresKeepLectureOrder() {
    let passages = (0..<40).map { LecturePassage(id: "t\($0)", label: "0:00", text: String(repeating: "Water the bed. ", count: 12)) }
    let index = LectureRetrievalIndex(passages: passages)
    #expect(index.windows.count > 5)
    let ranked = index.ranked(question: "water", priorQuestions: [])
    #expect(ranked == ranked.sorted())
    #expect(ranked.count == index.windows.count)
}

@Test func termsFoldCaseAccentsPluralsAndStopWords() {
    #expect(LectureRetrievalIndex.terms("What are the Berries in the Beds?") == ["berry", "bed"])
    #expect(LectureRetrievalIndex.terms("Café grass, cactus, analysis! 42 x") == ["cafe", "grass", "cactus", "analysis", "42"])
    #expect(LectureRetrievalIndex.terms("Why is it so?").isEmpty)
}
