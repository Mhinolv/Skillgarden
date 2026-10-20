import Foundation
import Testing
@testable import SkillgardenCore

// #181: learner notes on lectures. These tests cover the store, the migration from the prior schema, the library model,
// the Notes page groups, the note seek, the shared panel slot, and that Q&A and the lecture context never read notes.

private let fixture = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Fixtures/sample-course")

private func course() -> Course {
    Course(id: "c", title: "Garden", state: .published, sections: [
        CourseSection(id: "s", title: "Start", order: 0, state: .published, lectures: [
            Lecture(id: "v", title: "Video", type: .video, order: 0, state: .published),
            Lecture(id: "a", title: "Article", type: .article, order: 1, state: .published),
        ]),
    ])
}

private func withRoot(_ body: (URL) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "LectureNotesTests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    try body(root)
}

/// A library with the published sample course and its practice section, so two sections have lectures.
@MainActor
private func withLibrary(_ body: (LibraryModel, URL) async throws -> Void) async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "LectureNotesTests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let courseID = try #require(try SnapshotPlan.seedStore(for: .assignment, root: root, fixture: fixture))
    let library = LibraryModel(root: root)
    await library.reload()
    library.selectCourse(courseID)
    try await body(library, root)
}

@Test func storeSavesEditsAndDeletesNotesAndKeepsThemAfterReopen() throws {
    try withRoot { root in
        let store = try CourseStore(root: root)
        try store.saveCourse(course())
        let first = try store.addNote(text: "  Watch the bed depth.  ", videoSeconds: 221.4, courseID: "c", lectureID: "v",
                                      createdAt: Date(timeIntervalSince1970: 10))
        #expect(first.text == "Watch the bed depth.")
        #expect(first.videoSeconds == 221.4)
        #expect(first.timeLabel == "3:41")
        let second = try store.addNote(text: "Read again.", videoSeconds: nil, courseID: "c", lectureID: "a")
        #expect(second.videoSeconds == nil)
        #expect(second.timeLabel == nil)
        let third = try store.addNote(text: "Before the first.", videoSeconds: 12, courseID: "c", lectureID: "v")
        // A time that is not finite or below 0 saves as no time or as 0.
        #expect(try store.addNote(text: "Bad time", videoSeconds: .nan, courseID: "c", lectureID: "a").videoSeconds == nil)
        #expect(try store.addNote(text: "Negative", videoSeconds: -3, courseID: "c", lectureID: "v").videoSeconds == 0)
        #expect(throws: CourseStoreError.invalidData) { try store.addNote(text: " \n ", videoSeconds: 1, courseID: "c", lectureID: "v") }

        try store.updateNote(id: first.id, text: "Watch the depth.", courseID: "c")
        #expect(throws: CourseStoreError.invalidData) { try store.updateNote(id: first.id, text: "", courseID: "c") }
        #expect(throws: CourseStoreError.databaseFailure) { try store.updateNote(id: first.id, text: "x", courseID: "other") }
        try store.deleteNote(id: second.id, courseID: "c")

        // A new store on the same file is a relaunch.
        let reopened = try CourseStore(root: root)
        let notes = try #require(try reopened.allNotes()["c"])
        #expect(notes["v"]?.map(\.text) == ["Watch the depth.", "Before the first.", "Negative"])
        #expect(notes["v"]?.first?.videoSeconds == 221.4)
        #expect(notes["v"]?.first?.createdAt == Date(timeIntervalSince1970: 10))
        #expect(notes["a"]?.map(\.text) == ["Bad time"])
        // The panel order is the video time, then the creation order.
        #expect(LectureNote.panelOrder(notes["v"] ?? []).map(\.id) == [notes["v"]![2].id, third.id, first.id])
    }
}

@Test func notesLoadAfterTheMigrationFromThePriorSchema() throws {
    try withRoot { root in
        let old = try CourseStore(root: root, migrations: Array(CourseStore.migrations.prefix(13)))
        #expect(try old.schemaVersion == 13)
        try old.saveCourse(course())
        try old.saveProgress(LectureProgress(completed: true, resumeSeconds: 30), courseID: "c", lectureID: "v")
        _ = try old.startQATurn(question: "Why?", sourceRevision: "r", origin: .legacy, courseID: "c", lectureID: "v")
        #expect(throws: CourseStoreError.databaseFailure) { try old.allNotes() }

        let store = try CourseStore(root: root)
        #expect(try store.schemaVersion == 14)
        #expect(CourseStore.currentSchemaVersion == 14)
        #expect(try store.loadCourse(id: "c") == course())
        #expect(try store.allProgress() == ["c": ["v": LectureProgress(completed: true, resumeSeconds: 30)]])
        #expect(try store.qaTurns(courseID: "c", lectureID: "v").map(\.question) == ["Why?"])
        #expect(try store.allNotes().isEmpty)
        let note = try store.addNote(text: "New", videoSeconds: 5, courseID: "c", lectureID: "v")
        #expect(try store.allNotes() == ["c": ["v": [note]]])
    }
}

@Test func republishAndCourseRemovalKeepNotes() throws {
    try withRoot { root in
        let id = try CoursePublisher.publish(courseFolder: fixture, root: root).id
        let store = try CourseStore(root: root)
        let note = try store.addNote(text: "Keep me", videoSeconds: 2, courseID: id, lectureID: "welcome")
        _ = try CoursePublisher.publish(courseFolder: fixture, root: root)
        #expect(try CourseStore(root: root).allNotes() == [id: ["welcome": [note]]])
        _ = try store.removeCourse(id: id)
        #expect(try CourseStore(root: root).allNotes() == [id: ["welcome": [note]]])
    }
}

@MainActor
@Test func libraryAddsEditsAndDeletesNotesAndReloadKeepsThem() async throws {
    try await withLibrary { library, root in
        #expect(await library.addNote("At the start", videoSeconds: 3, lectureID: "welcome"))
        #expect(await library.addNote("Earlier", videoSeconds: 1, lectureID: "welcome"))
        #expect(await library.addNote("Article note", videoSeconds: nil, lectureID: "read"))
        // Empty text and a lecture that is not in the learner outline save nothing.
        #expect(!(await library.addNote("   ", videoSeconds: 1, lectureID: "welcome")))
        #expect(!(await library.addNote("Ghost", videoSeconds: nil, lectureID: "missing")))
        #expect(library.notes(forLecture: "welcome").map(\.text) == ["Earlier", "At the start"])

        let earlier = library.notes(forLecture: "welcome")[0]
        #expect(await library.updateNote(earlier, text: " Changed "))
        #expect(!(await library.updateNote(earlier, text: "")))
        let article = library.notes(forLecture: "read")[0]
        #expect(await library.deleteNote(article))
        #expect(library.notes(forLecture: "read").isEmpty)

        let reloaded = LibraryModel(root: root)
        await reloaded.reload()
        reloaded.selectCourse(library.selectedCourseID)
        #expect(reloaded.notes(forLecture: "welcome").map(\.text) == ["Changed", "At the start"])
        #expect(reloaded.notes(forLecture: "welcome").map(\.videoSeconds) == [1, 3])
        #expect(reloaded.notes(forLecture: "read").isEmpty)
    }
}

@MainActor
@Test func notesPageGroupsNotesInCourseOrderAndOpensTheLecture() async throws {
    try await withLibrary { library, _ in
        library.selectDestination(.notes)
        #expect(library.destination == .notes)
        #expect(library.selectedNoteGroups.isEmpty)
        #expect(await library.addNote("Rubric first", videoSeconds: nil, lectureID: "apply"))
        #expect(await library.addNote("Second", videoSeconds: 4, lectureID: "welcome"))
        #expect(await library.addNote("First", videoSeconds: 2, lectureID: "welcome"))
        #expect(await library.addNote("Plan", videoSeconds: nil, lectureID: "read"))
        let groups = library.selectedNoteGroups
        #expect(groups.map(\.title) == ["Plan the course · Welcome", "Plan the course · Read the plan",
                                        "Check your work · Write a plan"])
        #expect(groups.map(\.lecture.id) == ["welcome", "read", "apply"])
        #expect(groups.map(\.sectionID) == ["plan", "plan", "practice"])
        #expect(groups[0].notes.map(\.text) == ["First", "Second"])

        // A row click opens the lecture and does not seek.
        library.openNote(groups[1].notes[0])
        #expect(library.destination == .lecture(sectionID: "plan", lectureID: "read"))
        #expect(library.transcriptSeek == nil)
        // A time click opens the video lecture and seeks to the note, then plays. The transcript does not open.
        library.openNote(groups[0].notes[1], seeks: true)
        #expect(library.destination == .lecture(sectionID: "plan", lectureID: "welcome"))
        let seek = try #require(library.transcriptSeek)
        #expect(seek.lectureID == "welcome" && seek.seconds == 4 && seek.plays && !seek.showsTranscript)
    }
}

@MainActor
@Test func noteSeekWorksOnlyOnTheOpenVideoLecture() async throws {
    try await withLibrary { library, _ in
        #expect(await library.addNote("Video", videoSeconds: 2.5, lectureID: "welcome"))
        #expect(await library.addNote("Article", videoSeconds: nil, lectureID: "read"))
        let video = library.notes(forLecture: "welcome")[0]
        library.selectDestination(.lecture(sectionID: "plan", lectureID: "read"))
        library.seekNote(video)
        #expect(library.transcriptSeek == nil)
        library.seekNote(library.notes(forLecture: "read")[0])
        #expect(library.transcriptSeek == nil)
        library.selectDestination(.lecture(sectionID: "plan", lectureID: "welcome"))
        library.seekNote(video)
        #expect(library.transcriptSeek?.seconds == 2.5)
        #expect(library.transcriptSeek?.plays == true)
        let first = try #require(library.transcriptSeek?.id)
        // A second click on the same time seeks again.
        library.seekNote(video)
        #expect(library.transcriptSeek?.id == first + 1)
        // A Q&A source seek stays paused.
        library.seekCitation(lectureID: "welcome", seconds: 1)
        #expect(library.transcriptSeek?.plays == false)
    }
}

@MainActor
@Test func lectureContextNeverIncludesNoteText() async throws {
    try await withLibrary { library, _ in
        let secret = "Zebra-note-181"
        #expect(await library.addNote(secret, videoSeconds: 1, lectureID: "welcome"))
        #expect(await library.addNote(secret, videoSeconds: nil, lectureID: "read"))
        for lectureID in ["welcome", "read"] {
            guard case .ready(let context) = await library.lectureContext(forLecture: lectureID) else {
                Issue.record("No context for \(lectureID)")
                continue
            }
            #expect(!context.passages.contains { $0.text.contains(secret) || $0.label.contains(secret) })
            #expect(!context.lectureTitle.contains(secret) && !context.courseTitle.contains(secret))
        }
    }
}

@Test func notesQAAndTranscriptShareOneSlot() {
    // One of Q&A and Notes is open at a time. On closes the other. Off closes only its own panel.
    #expect(LecturePanelSlot.set(.notes, true, open: nil) == .notes)
    #expect(LecturePanelSlot.set(.notes, true, open: .qa) == .notes)
    #expect(LecturePanelSlot.set(.qa, true, open: .notes) == .qa)
    #expect(LecturePanelSlot.set(.notes, false, open: .notes) == nil)
    #expect(LecturePanelSlot.set(.notes, false, open: .qa) == .qa)
    #expect(LecturePanelSlot.set(.qa, false, open: .notes) == .notes)
    // Notes hides the transcript and keeps the saved choice. The Transcript pill on closes Notes.
    #expect(!LecturePanelSlot.showsTranscript(saved: true, open: .notes))
    #expect(LecturePanelSlot.setTranscript(true, open: .notes) == (saved: true, open: nil))
    #expect(LecturePanelSlot.setTranscript(false, open: .notes) == (saved: false, open: .notes))
}

@Test func noteAccessibilityLabelSpeaksTheTime() {
    let locale = Locale(identifier: "en_US")
    let timed = LectureNote(id: 1, lectureID: "v", text: "Check depth", videoSeconds: 221.9, createdAt: Date())
    #expect(timed.accessibilityLabel(locale: locale) == "Note at 3 minutes 41 seconds: Check depth")
    #expect(timed.timeLabel == "3:41")
    let plain = LectureNote(id: 2, lectureID: "a", text: "Read again", videoSeconds: nil, createdAt: Date())
    #expect(plain.accessibilityLabel(locale: locale) == "Note: Read again")
    #expect(LectureNote(id: 3, lectureID: "v", text: "Long", videoSeconds: 3_725, createdAt: Date()).timeLabel == "1:02:05")
}
