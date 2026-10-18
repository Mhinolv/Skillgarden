import Foundation
import Testing
@testable import SkillgardenCore

private let fixture = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Fixtures/sample-course")

/// Gives each test a writable copy of the sample course outside the library, and a library root that does not exist yet.
/// The body runs on the actor of the test, so a `@MainActor` test can use its `LibraryModel`.
private func withImport(isolation: isolated (any Actor)? = #isolation, _ body: (URL, URL) async throws -> Void) async throws {
    let base = FileManager.default.temporaryDirectory.appending(path: "SkillgardenImportTests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: base) }
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let folder = base.appending(path: "course")
    try FileManager.default.copyItem(at: fixture, to: folder)
    try FileManager.default.removeItem(at: folder.appending(path: "equivalent.json"))
    try await body(folder, base.appending(path: "library"))
}

private func edit(_ folder: URL, _ old: String, _ new: String) throws {
    let file = folder.appending(path: "skillgarden.yaml")
    let text = try String(contentsOf: file, encoding: .utf8)
    #expect(text.contains(old))
    try text.replacingOccurrences(of: old, with: new).write(to: file, atomically: true, encoding: .utf8)
}

private func diagnostics(_ count: Int) -> [ManifestDiagnostic] {
    (0..<count).map { ManifestDiagnostic(file: "/c", fieldPath: "f\($0)", message: "m") }
}

@Test func importCheckOfANewCourseIsNew() async throws {
    try await withImport { folder, root in
        let check = try CourseImport.check(folder: folder, root: root)
        guard case let .new(result) = check else { Issue.record("expected new, got \(check)"); return }
        #expect(result.id == "sample-course")
        #expect(result.title == "Local Course Basics")
        #expect(result.state == .published)
    }
}

@Test func importCheckOfAnInvalidFolderReturnsTheCLIErrorsAndDoesNotTouchTheLibrary() async throws {
    try await withImport { folder, root in
        try FileManager.default.removeItem(at: folder.appending(path: "media/course.svg"))
        let check = try CourseImport.check(folder: folder, root: root)
        guard case let .invalid(problems) = check else { Issue.record("expected invalid, got \(check)"); return }
        #expect(problems.contains(ManifestDiagnostic(file: folder.path, fieldPath: "course_image.path", message: "file does not exist")))
        // The alert lines are the CLI error lines without the "error: " prefix.
        let cli = SkillgardenCommand.run(arguments: ["validate", folder.path], root: root)
        #expect(cli.stderr == problems.map { "error: \($0)\n" }.joined())
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }
}

@Test func importCheckOfAFolderWithNoManifestIsInvalid() async throws {
    try await withImport { folder, root in
        let empty = folder.deletingLastPathComponent().appending(path: "empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let check = try CourseImport.check(folder: empty, root: root)
        guard case let .invalid(problems) = check else { Issue.record("expected invalid, got \(check)"); return }
        #expect(problems.count == 1)
        #expect(problems.first?.file == empty.path)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }
}

@Test func importCheckRejectsALibraryInsideTheCourseFolder() async throws {
    try await withImport { folder, _ in
        let check = try CourseImport.check(folder: folder, root: folder.appending(path: "library"))
        #expect(check == .invalid([ManifestDiagnostic(file: folder.path, fieldPath: "$",
                                                      message: "library must be outside the course folder")]))
    }
}

@Test func importCheckOfAnExistingIDNamesTheOldTitleAlsoForADraft() async throws {
    try await withImport { folder, root in
        try edit(folder, "title: Local Course Basics", "title: Old Draft")
        try edit(folder, "state: published\ntheme:", "state: draft\ntheme:")
        try CoursePublisher.publish(courseFolder: folder, root: root)
        try edit(folder, "title: Old Draft", "title: New Title")
        let check = try CourseImport.check(folder: folder, root: root)
        guard case let .replaces(result, oldTitle) = check else { Issue.record("expected replaces, got \(check)"); return }
        #expect(oldTitle == "Old Draft")
        #expect(result.title == "New Title")
        #expect(CourseImport.replaceMessage(oldTitle: oldTitle) == "Replace \"Old Draft\"?")
        #expect(CourseImport.replaceInformation(id: result.id, newTitle: result.title)
            == "The library already has a course with the ID \"sample-course\". Import replaces it with \"New Title\".")
    }
}

@Test(arguments: [0, 1, 10, 11, 25])
func importErrorAlertShowsTenLinesThenACount(count: Int) {
    let problems = diagnostics(count)
    let shown = CourseImport.shownErrors(problems).split(separator: "\n").map(String.init)
    #expect(Array(shown.prefix(10)) == problems.prefix(10).map(\.description))
    #expect(shown.count == min(count, 11))
    if count > 10 { #expect(shown.last == "and \(count - 10) more") }
    #expect(CourseImport.allErrors(problems) == problems.map(\.description).joined(separator: "\n"))
}

@MainActor @Test func importPublishesReloadsAndOpensTheLandingPage() async throws {
    try await withImport { folder, root in
        let library = LibraryModel(root: root)
        await library.reload()
        #expect(library.courses.isEmpty)
        #expect(library.canImport)
        let check = try await library.checkImport(folder: folder)
        guard case .new = check else { Issue.record("expected new, got \(check)"); return }
        #expect(!library.isImporting)
        let result = try await library.importCourse(folder: folder, title: "Local Course Basics")
        #expect(result.created == 7)
        #expect(library.courses.map(\.id) == ["sample-course"])
        #expect(library.selectedCourseID == "sample-course")
        #expect(library.destination == .overview)
        #expect(library.selectedLanding != nil)
        #expect(!library.isImporting)
        #expect(library.importingTitle == nil)
        #expect(library.canImport)
    }
}

@MainActor @Test func importReplaceOfTheOpenCourseShowsTheNewTitleAtTheLandingPage() async throws {
    try await withImport { folder, root in
        try CoursePublisher.publish(courseFolder: folder, root: root)
        let library = LibraryModel(root: root)
        await library.reload()
        library.selectCourse("sample-course")
        library.selectDestination(.lecture(sectionID: "plan", lectureID: "read"))
        try edit(folder, "title: Local Course Basics", "title: Renamed Course")
        let check = try await library.checkImport(folder: folder)
        guard case let .replaces(_, oldTitle) = check else { Issue.record("expected replaces, got \(check)"); return }
        #expect(oldTitle == "Local Course Basics")
        try await library.importCourse(folder: folder, title: "Renamed Course")
        #expect(library.courses.map(\.title) == ["Renamed Course"])
        #expect(library.selectedCourseID == "sample-course")
        #expect(library.destination == .overview)
    }
}

@MainActor @Test func importOfADraftPublishesItButOpensNothing() async throws {
    try await withImport { folder, root in
        try edit(folder, "state: published\ntheme:", "state: draft\ntheme:")
        let library = LibraryModel(root: root)
        await library.reload()
        let result = try await library.importCourse(folder: folder, title: "Local Course Basics")
        #expect(result.state == .draft)
        #expect(library.courses.isEmpty)
        #expect(library.selectedCourseID == nil)
        #expect(try CourseStore(root: root).loadCourse(id: "sample-course", includeDrafts: true)?.state == .draft)
        #expect(CourseImport.draftMessage(title: result.title) == "\"Local Course Basics\" is a draft.")
    }
}

@MainActor @Test func importOfAFolderThatTurnsInvalidThrowsAndKeepsTheLibrary() async throws {
    try await withImport { folder, root in
        try CoursePublisher.publish(courseFolder: folder, root: root)
        let library = LibraryModel(root: root)
        await library.reload()
        try edit(folder, "title: Local Course Basics", "title: \"\"")
        await #expect(throws: ManifestValidationError.self) {
            try await library.importCourse(folder: folder, title: "Local Course Basics")
        }
        #expect(library.courses.map(\.title) == ["Local Course Basics"])
        #expect(!library.isImporting)
        #expect(library.importingTitle == nil)
    }
}

@MainActor @Test func importIsOffWithABadDataFolderSetting() {
    let library = LibraryModel(root: URL(fileURLWithPath: "/nonexistent"), rootError: "bad folder")
    #expect(!library.canImport)
}
