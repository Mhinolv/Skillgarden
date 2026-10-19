import Foundation
import Testing
@testable import SkillgardenCore

private let fixture = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Fixtures/sample-course")

/// Two video lectures for the end of the "plan" section. Their captions share the token "plan" with the welcome video.
private let recapLecture = """
      - id: recap
        title: Recap the plan
        type: video
        objective: Review the course plan
        state: published
        order: 2
        video:
          path: content/welcome.mp4
          duration_seconds: 4
          captions:
            path: content/recap.vtt
      - id: extra
        title: Team notes
        type: video
        objective: Review the team notes
        state: draft
        order: 3
        video:
          path: content/welcome.mp4
          duration_seconds: 4
          captions:
            path: content/recap.vtt

"""

private let recapCaptions = """
WEBVTT

00:00.500 --> 00:01.500

00:01.500 --> 00:03.000
Your PLAN has
two sections.

01:05.000 --> 01:07.000
Keep the plan short.
"""

/// Gives each test a copy of the sample course with the recap lecture and an empty library root.
private func withCourse(isolation: isolated (any Actor)? = #isolation, _ body: (URL, URL) async throws -> Void) async throws {
    let base = FileManager.default.temporaryDirectory.appending(path: "SkillgardenSearchTests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: base) }
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let folder = base.appending(path: "course")
    try FileManager.default.copyItem(at: fixture, to: folder)
    try FileManager.default.removeItem(at: folder.appending(path: "equivalent.json"))
    let manifest = folder.appending(path: "skillgarden.yaml")
    let text = try String(contentsOf: manifest, encoding: .utf8)
    // The "practice" section follows the "plan" section. Its key line is stable, so the lectures go in before it.
    let anchor = try #require(text.range(of: "\n  - id: practice\n"))
    var patched = text
    patched.insert(contentsOf: "\n" + recapLecture, at: anchor.lowerBound)
    try patched.write(to: manifest, atomically: true, encoding: .utf8)
    try recapCaptions.write(to: folder.appending(path: "content/recap.vtt"), atomically: true, encoding: .utf8)
    try await body(folder, base.appending(path: "library"))
}

// MARK: Publish and store

@Test func publishIndexesCuesFromTwoVideoLecturesAndSearchFindsBoth() async throws {
    try await withCourse { folder, root in
        let id = try CoursePublisher.publish(courseFolder: folder, root: root).id
        let store = try CourseStore(root: root)
        let cues = try #require(try store.allTranscriptCues()[id])
        // The empty recap cue is left out. Line breaks become spaces, and tags are removed.
        #expect(cues == [
            TranscriptCue(lectureID: "extra", index: 0, start: 1.5, end: 3, text: "Your PLAN has two sections."),
            TranscriptCue(lectureID: "extra", index: 1, start: 65, end: 67, text: "Keep the plan short."),
            TranscriptCue(lectureID: "recap", index: 0, start: 1.5, end: 3, text: "Your PLAN has two sections."),
            TranscriptCue(lectureID: "recap", index: 1, start: 65, end: 67, text: "Keep the plan short."),
            TranscriptCue(lectureID: "welcome", index: 0, start: 0, end: 2, text: "Welcome to Local Course Basics."),
            TranscriptCue(lectureID: "welcome", index: 1, start: 2, end: 4, text: "You will plan a course step by step."),
        ])
        let course = try #require(try store.loadCourse(id: id))
        let results = try #require(TranscriptSearch.search("plan", course: course, cues: cues))
        // Course order, then cue order. The draft lecture "extra" is not shown.
        #expect(results.groups.map(\.lectureID) == ["welcome", "recap"])
        #expect(results.groups.map(\.sectionTitle) == ["Plan the course", "Plan the course"])
        #expect(results.hits.map(\.id) == ["welcome#1", "recap#0", "recap#1"])
        #expect(results.summary == "3 results in 2 lectures")
        #expect(results.hasTranscripts)
        for hit in results.hits {
            #expect(hit.snippet.localizedCaseInsensitiveContains("plan"))
            #expect(hit.matches.map { hit.snippet[$0].lowercased() } == ["plan"])
        }
        let hit = results.hits[2]
        #expect(hit.lectureID == "recap")
        #expect(hit.lectureTitle == "Recap the plan")
        #expect(hit.timeLabel == "1:05")
        #expect(hit.accessibilityLabel == "Recap the plan, 1:05, Keep the plan short.")
        #expect(hit.destination == .lecture(sectionID: "plan", lectureID: "recap"))
    }
}

@Test func republishReplacesTheIndexAndDeleteRemovesIt() async throws {
    try await withCourse { folder, root in
        let id = try CoursePublisher.publish(courseFolder: folder, root: root).id
        try "WEBVTT\n\n00:00.000 --> 00:01.000\nNew words.\n"
            .write(to: folder.appending(path: "content/recap.vtt"), atomically: true, encoding: .utf8)
        _ = try CoursePublisher.publish(courseFolder: folder, root: root)
        let store = try CourseStore(root: root)
        let cues = try #require(try store.allTranscriptCues()[id])
        #expect(cues.filter { $0.lectureID == "recap" }.map(\.text) == ["New words."])
        #expect(cues.filter { $0.lectureID == "welcome" }.count == 2)
        try store.deleteCourse(id: id)
        #expect(try store.allTranscriptCues().isEmpty)
    }
}

@Test func dataSavedBeforeTheTranscriptIndexStillLoadsAndRepublishIndexesIt() async throws {
    try await withCourse { folder, root in
        let id = try CoursePublisher.publish(courseFolder: folder, root: root).id
        let before = try #require(try CourseStore(root: root).loadCourse(id: id))
        try CourseStore(root: root).saveProgress(LectureProgress(completed: true, resumeSeconds: 2), courseID: id, lectureID: "welcome")
        // Make the store a schema version 8 store: no index table and no index flag.
        do {
            let database = try SQLiteDatabase(url: root.appending(path: "library.sqlite"))
            try database.execute("DROP TABLE qa_messages")
            try database.execute("DROP TABLE qa_threads")
            try database.execute("DROP TABLE transcript_cues")
            try database.execute("ALTER TABLE course_publications DROP COLUMN transcripts_indexed")
            try database.execute("ALTER TABLE lecture_progress DROP COLUMN auto_complete_off")
            try database.execute("UPDATE schema_version SET version = 8")
        }
        let upgraded = try CourseStore(root: root)
        #expect(try upgraded.schemaVersion == CourseStore.currentSchemaVersion)
        #expect(try upgraded.loadCourse(id: id) == before)
        #expect(try upgraded.allProgress()[id]?["welcome"] == LectureProgress(completed: true, resumeSeconds: 2))
        #expect(try upgraded.allTranscriptCues().isEmpty)
        #expect(try !upgraded.hasTranscriptIndex(courseID: id))
        // An unchanged republish writes the index from the installed snapshot.
        let result = try CoursePublisher.publish(courseFolder: folder, root: root)
        #expect(result.created == 0 && result.updated == 0)
        #expect(try upgraded.hasTranscriptIndex(courseID: id))
        #expect(try upgraded.allTranscriptCues()[id]?.count == 6)
    }
}

@Test func storeSavedBeforeSchemaVersion9MigratesWithAnEmptyIndex() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "SkillgardenSearchTests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let course = Course(id: "c", title: "Course", state: .published, sections: [
        CourseSection(id: "s", title: "Section", order: 0, state: .published, lectures: [
            Lecture(id: "v", title: "Video", type: .video, order: 0, state: .published),
        ]),
    ])
    let old = try CourseStore(root: root, migrations: Array(CourseStore.migrations.prefix(8)))
    #expect(try old.schemaVersion == 8)
    try old.saveCourse(course)
    let store = try CourseStore(root: root)
    #expect(try store.schemaVersion == CourseStore.currentSchemaVersion)
    #expect(try store.loadCourse(id: "c") == course)
    #expect(try store.allTranscriptCues().isEmpty)
}

// MARK: Search

/// In store order, as `CourseStore` reads it.
private let course = Course(id: "c", title: "Course", state: .published, sections: [
    CourseSection(id: "a", title: "First", order: 0, state: .published, lectures: [
        Lecture(id: "v1", title: "One", type: .video, order: 0, state: .published),
        Lecture(id: "hidden", title: "Hidden", type: .video, order: 1, state: .draft),
    ]),
    CourseSection(id: "b", title: "Second", order: 1, state: .published, lectures: [
        Lecture(id: "v2", title: "Two", type: .video, order: 0, state: .published),
    ]),
    CourseSection(id: "d", title: "Draft", order: 2, state: .draft, lectures: [
        Lecture(id: "v3", title: "Three", type: .video, order: 0, state: .published),
    ]),
])

private func cue(_ lecture: String, _ index: Int, _ text: String) -> TranscriptCue {
    TranscriptCue(lectureID: lecture, index: index, start: Double(index), end: Double(index + 1), text: text)
}

@Test func searchNeedsTwoCharactersAndTrimsTheQuery() {
    let cues = [cue("v1", 0, "Garden beds")]
    #expect(TranscriptSearch.search("", course: course, cues: cues) == nil)
    #expect(TranscriptSearch.search("g", course: course, cues: cues) == nil)
    #expect(TranscriptSearch.search("  g \n", course: course, cues: cues) == nil)
    let results = TranscriptSearch.search("  ga ", course: course, cues: cues)
    #expect(results?.query == "ga")
    #expect(results?.hits.map(\.id) == ["v1#0"])
}

@Test func searchIgnoresCaseAndDiacriticsAndMarksEveryMatch() throws {
    let cues = [cue("v1", 0, "Café, CAFE and cafe.")]
    let hit = try #require(TranscriptSearch.search("cafe", course: course, cues: cues)?.hits.first)
    #expect(hit.matches.map { String(hit.snippet[$0]) } == ["Café", "CAFE", "cafe"])
    #expect(TranscriptSearch.search("café", course: course, cues: cues)?.hitCount == 1)
}

@Test func searchUsesCourseOrderAndLeavesOutDraftAndUnknownLectures() throws {
    let cues = [cue("v2", 1, "seed b"), cue("v2", 0, "seed a"), cue("v1", 0, "seed c"), cue("hidden", 0, "seed"),
                cue("v3", 0, "seed"), cue("gone", 0, "seed")]
    let results = try #require(TranscriptSearch.search("seed", course: course, cues: cues))
    #expect(results.groups.map(\.lectureID) == ["v1", "v2"])
    #expect(results.groups.map(\.sectionTitle) == ["First", "Second"])
    #expect(results.hits.map(\.id) == ["v1#0", "v2#0", "v2#1"])
    #expect(results.summary == "3 results in 2 lectures")
    #expect(TranscriptSearch.search("seed", course: course, cues: [cue("v1", 0, "seed")])?.summary == "1 result in 1 lecture")
}

@Test func searchSeparatesNoResultsFromNoTranscripts() throws {
    let none = try #require(TranscriptSearch.search("zz", course: course, cues: [cue("v1", 0, "seed")]))
    #expect(none.groups.isEmpty && none.hasTranscripts)
    #expect(none.summary == "0 results in 0 lectures")
    // Cues of draft lectures do not count as transcripts of the course.
    let empty = try #require(TranscriptSearch.search("seed", course: course, cues: [cue("hidden", 0, "seed")]))
    #expect(empty.groups.isEmpty && !empty.hasTranscripts)
    #expect(TranscriptSearch.search("seed", course: course, cues: [])?.hasTranscripts == false)
}

@Test func aLongCueStartsNearTheFirstMatch() throws {
    let text = String(repeating: "alpha beta ", count: 12) + "the garden word here" + String(repeating: " gamma", count: 5)
    let hit = try #require(TranscriptSearch.search("garden", course: course, cues: [cue("v1", 0, text)])?.hits.first)
    #expect(hit.snippet.hasPrefix("…"))
    #expect(!hit.snippet.hasPrefix("… "))
    #expect(hit.snippet.hasSuffix("gamma"))
    #expect(hit.matches.map { String(hit.snippet[$0]) } == ["garden"])
    let before = hit.snippet.distance(from: hit.snippet.startIndex, to: hit.matches[0].lowerBound)
    #expect(before <= TranscriptSearch.snippetContext + 1)
    // A short cue, or a match near the start, keeps the whole text.
    let short = try #require(TranscriptSearch.search("beta", course: course, cues: [cue("v1", 0, text)])?.hits.first)
    #expect(short.snippet == text)
    #expect(short.matches.count == 12)
}

// MARK: Library model

@MainActor @Test func aSelectedResultOpensTheLectureAndRequestsAPausedSeek() async throws {
    try await withCourse { folder, root in
        let id = try CoursePublisher.publish(courseFolder: folder, root: root).id
        let library = LibraryModel(root: root)
        await library.reload()
        library.selectCourse(id)
        library.transcriptQuery = "p"
        library.searchTranscripts()
        #expect(library.transcriptResults == nil)
        library.transcriptQuery = "plan"
        library.searchTranscripts()
        let results = try #require(library.transcriptResults)
        #expect(results.summary == "3 results in 2 lectures")

        let hit = results.hits[2]
        library.openTranscriptHit(hit)
        #expect(library.destination == .lecture(sectionID: "plan", lectureID: "recap"))
        #expect(library.transcriptSeek?.lectureID == "recap")
        #expect(library.transcriptSeek?.seconds == 65)
        // The results stay, so the learner can select another result.
        #expect(library.transcriptResults == results)
        let first = try #require(library.transcriptSeek)
        library.openTranscriptHit(hit)
        #expect(library.transcriptSeek?.id != first.id)

        // Other navigation cancels a waiting seek.
        library.selectDestination(.overview)
        #expect(library.transcriptSeek == nil)
        #expect(library.transcriptResults == results)

        // A reload keeps the query and runs the search again.
        await library.reload()
        #expect(library.transcriptResults == results)

        library.clearTranscriptSearch()
        #expect(library.transcriptQuery.isEmpty)
        #expect(library.transcriptResults == nil)

        library.transcriptQuery = "plan"
        library.searchTranscripts()
        library.selectCourse(nil)
        #expect(library.transcriptQuery.isEmpty)
        #expect(library.transcriptResults == nil)
    }
}
