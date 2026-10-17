import Foundation
import Testing
@testable import SkillgardenCore

private let fixture = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Fixtures/sample-course")

private func temporaryFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appending(path: "AssignmentTests-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

private func fixtureObject() throws -> [String: Any] {
    let manifest = try ManifestLoader.load(courseFolder: fixture)
    return try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(manifest)) as? [String: Any])
}

/// Changes the lecture at `sections[section].lectures[lecture]` of the fixture manifest. The default is the assignment.
private func editLecture(_ object: inout [String: Any], section: Int = 1, lecture: Int = 1,
                         _ change: (inout [String: Any]) throws -> Void) throws {
    var sections = try #require(object["sections"] as? [[String: Any]])
    var lectures = try #require(sections[section]["lectures"] as? [[String: Any]])
    try change(&lectures[lecture])
    sections[section]["lectures"] = lectures
    object["sections"] = sections
}

/// Changes the `assignment` object of the fixture assignment.
private func editAssignment(_ object: inout [String: Any], _ change: (inout [String: Any]) throws -> Void) throws {
    try editLecture(&object) { lecture in
        var assignment = try #require(lecture["assignment"] as? [String: Any])
        try change(&assignment)
        lecture["assignment"] = assignment
    }
}

/// Changes the rubric rows of the fixture assignment.
private func editRubric(_ object: inout [String: Any], _ change: (inout [[String: Any]]) throws -> Void) throws {
    try editAssignment(&object) { assignment in
        var rows = try #require(assignment["rubric"] as? [[String: Any]])
        try change(&rows)
        assignment["rubric"] = rows
    }
}

/// Loads the manifest object and returns its diagnostics as `fieldPath: message`. Empty means valid.
private func errors(_ object: Any) throws -> [String] {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appending(path: "skillgarden.json")
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: file)
    do {
        _ = try ManifestLoader.load(file: file)
        return []
    } catch let error as ManifestValidationError {
        return error.diagnostics.map { "\($0.fieldPath): \($0.message)" }
    }
}

private let assignmentPath = "sections[1].lectures[1].assignment"

private let rubric = [
    RubricCriterion(id: "a", criterion: "First", guidance: "Guide A"),
    RubricCriterion(id: "b", criterion: "Second", guidance: "Guide B"),
    RubricCriterion(id: "c", criterion: "Third", guidance: "Guide C"),
]

// MARK: Manifest

@Test func manifestParsesTheAssignmentBriefAndRubricInOrder() throws {
    let manifest = try ManifestLoader.load(courseFolder: fixture)
    let lecture = manifest.sections[1].lectures[1]
    #expect(lecture.type == .assignment)
    let assignment = try #require(lecture.assignment)
    #expect(assignment.brief == ManifestArticle(path: "content/brief.md", images: nil))
    #expect(assignment.rubric.map(\.id) == ["goal", "sections", "order", "length"])
    #expect(assignment.rubric[0] == ManifestRubricItem(id: "goal", criterion: "The plan states one course goal",
                                                        guidance: "Write the goal in one sentence that names the skill."))
    #expect(manifest.sections[0].lectures.allSatisfy { $0.assignment == nil })
    #expect(try errors(try fixtureObject()) == [])
}

@Test func manifestRequiresTheAssignmentFieldOnlyForAssignmentLectures() throws {
    var object = try fixtureObject()
    try editLecture(&object) { $0["assignment"] = nil }
    #expect(try errors(object) == ["\(assignmentPath): required field is missing"])

    object = try fixtureObject()
    try editLecture(&object) { $0["assignment"] = NSNull() }
    #expect(try errors(object) == ["\(assignmentPath): required field is missing"])

    // An article lecture with an assignment field is rejected.
    object = try fixtureObject()
    let assignment = try #require(try editLectureValue(object))
    try editLecture(&object, section: 0, lecture: 1) { $0["assignment"] = assignment }
    #expect(try errors(object) == ["sections[0].lectures[1].assignment: allowed only when type is assignment"])
}

private func editLectureValue(_ object: [String: Any]) throws -> Any? {
    let sections = try #require(object["sections"] as? [[String: Any]])
    let lectures = try #require(sections[1]["lectures"] as? [[String: Any]])
    return lectures[1]["assignment"]
}

@Test func manifestRequiresTheBriefPath() throws {
    var object = try fixtureObject()
    try editAssignment(&object) { $0["brief"] = nil }
    #expect(try errors(object) == ["\(assignmentPath).brief: required field is missing"])

    object = try fixtureObject()
    try editAssignment(&object) { $0["brief"] = [String: Any]() }
    #expect(try errors(object) == ["\(assignmentPath).brief.path: required field is missing"])

    for (path, message) in [("", "must not be empty"), ("../brief.md", "path must stay inside the course folder"),
                            ("/tmp/brief.md", "path must stay inside the course folder"),
                            ("internal/research.md", "path must not be inside internal/")] {
        object = try fixtureObject()
        try editAssignment(&object) { $0["brief"] = ["path": path] }
        #expect(try errors(object) == ["\(assignmentPath).brief.path: \(message)"], "\(path)")
    }
}

@Test func manifestRequiresAtLeastOneRubricRowWithAllFields() throws {
    var object = try fixtureObject()
    try editAssignment(&object) { $0["rubric"] = nil }
    #expect(try errors(object) == ["\(assignmentPath).rubric: required field is missing"])

    object = try fixtureObject()
    try editRubric(&object) { $0 = [] }
    #expect(try errors(object) == ["\(assignmentPath).rubric: must have at least one row"])

    for field in ["id", "criterion", "guidance"] {
        object = try fixtureObject()
        try editRubric(&object) { $0[2][field] = nil }
        #expect(try errors(object) == ["\(assignmentPath).rubric[2].\(field): required field is missing"])
        object = try fixtureObject()
        try editRubric(&object) { $0[2][field] = " " }
        #expect(try errors(object) == ["\(assignmentPath).rubric[2].\(field): must not be empty"])
    }

    // One row is enough.
    object = try fixtureObject()
    try editRubric(&object) { $0 = [$0[0]] }
    #expect(try errors(object) == [])
}

@Test func rubricIDsAreUniqueInsideTheirRubricOnly() throws {
    var object = try fixtureObject()
    try editRubric(&object) { $0[3]["id"] = "goal" }
    #expect(try errors(object) == [
        "\(assignmentPath).rubric[3].id: duplicate id \"goal\" (first used at \(assignmentPath).rubric[0].id)",
    ])
    // A rubric id can match a lecture or section id. The fixture has a section id "plan" and a lecture id "check".
    object = try fixtureObject()
    try editRubric(&object) { $0[0]["id"] = "plan"; $0[1]["id"] = "check" }
    #expect(try errors(object) == [])
}

@Test func publishRequiresTheBriefFileWithArticleRules() throws {
    let base = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: base) }
    let folder = base.appending(path: "course")
    try FileManager.default.copyItem(at: fixture, to: folder)
    try FileManager.default.removeItem(at: folder.appending(path: "equivalent.json"))
    let root = base.appending(path: "library")
    func publishErrors() throws -> [String] {
        do {
            _ = try CoursePublisher.publish(courseFolder: folder, root: root)
            return []
        } catch let error as ManifestValidationError {
            return error.diagnostics.map { "\($0.fieldPath): \($0.message)" }
        }
    }
    let brief = folder.appending(path: "content/brief.md")
    let text = try String(contentsOf: brief, encoding: .utf8)
    try FileManager.default.removeItem(at: brief)
    #expect(try publishErrors() == ["\(assignmentPath).brief.path: file does not exist"])
    // A brief image needs an alt text entry in `brief.images`, like an article image.
    try (text + "\n![Plan](../media/section.svg)\n").write(to: brief, atomically: true, encoding: .utf8)
    #expect(try publishErrors() == ["\(assignmentPath).brief.images: image \"media/section.svg\" needs an entry with alt text"])
    try Data([0xFF, 0xFE, 0x00]).write(to: brief)
    #expect(try publishErrors() == ["\(assignmentPath).brief.path: cannot read the Markdown file as UTF-8 text"])
    try text.write(to: brief, atomically: true, encoding: .utf8)
    #expect(try publishErrors() == [])
}

// MARK: Model

@Test func assignmentResolvesTheBriefInsideTheSnapshot() throws {
    let folder = URL(fileURLWithPath: "/tmp/snapshot")
    let manifest = ManifestAssignment(brief: ManifestArticle(path: "content/./brief.md", images: nil),
                                      rubric: [ManifestRubricItem(id: "a", criterion: "First", guidance: "Guide A")])
    let assignment = LectureAssignment(manifest: manifest, folder: folder)
    #expect(assignment.brief?.path == "content/brief.md")
    #expect(assignment.brief?.url.path == "/tmp/snapshot/content/brief.md")
    #expect(assignment.rubric == [RubricCriterion(id: "a", criterion: "First", guidance: "Guide A")])
    #expect(assignment.meta == "Assignment · 1 criterion")
    #expect(LectureAssignment(brief: nil, rubric: rubric).meta == "Assignment · 3 criteria")
    for path in ["../brief.md", "internal/brief.md"] {
        var outside = manifest
        outside.brief.path = path
        #expect(LectureAssignment(manifest: outside, folder: folder).brief == nil, "\(path)")
    }
}

@Test func rubricChecklistTogglesEachRowIndependently() {
    var checklist = RubricChecklist(rubric: rubric)
    #expect(checklist.checked.isEmpty)
    #expect(checklist.summary == "0 of 3 criteria met")
    #expect(!checklist.allMet)
    checklist.toggle("b")
    #expect(checklist.isChecked("b") && !checklist.isChecked("a") && !checklist.isChecked("c"))
    #expect(checklist.summary == "1 of 3 criteria met")
    checklist.toggle("a")
    checklist.toggle("c")
    #expect(checklist.allMet)
    #expect(checklist.summary == "3 of 3 criteria met")
    // A second toggle unchecks only that row.
    checklist.toggle("a")
    #expect(checklist.checked == ["b", "c"])
    // An unknown id does nothing.
    checklist.toggle("x")
    #expect(checklist.checked == ["b", "c"])
    checklist.reset()
    #expect(checklist.checked.isEmpty)
    #expect(checklist.metCount == 0)
}

@Test func rubricChecklistEdgeCases() {
    // Checked ids that are not in the rubric are dropped.
    #expect(RubricChecklist(rubric: rubric, checked: ["a", "gone"]).checked == ["a"])
    let one = [RubricCriterion(id: "only", criterion: "Only", guidance: "")]
    var single = RubricChecklist(rubric: one)
    #expect(single.summary == "0 of 1 criterion met")
    single.toggle("only")
    #expect(single.allMet)
    #expect(single.summary == "1 of 1 criterion met")
    // An empty rubric is never met.
    #expect(!RubricChecklist(rubric: []).allMet)
}

// MARK: Library

@MainActor @Test func libraryKeepsRubricChecksForTheSessionOnly() async throws {
    let root = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let courseID = try #require(try SnapshotPlan.seedStore(for: .assignment, root: root, fixture: fixture))
    let library = LibraryModel(root: root)
    await library.reload()
    library.selectCourse(courseID)
    let destination = CourseDestination.lecture(sectionID: "practice", lectureID: "apply")
    library.selectDestination(destination)
    let assignment = try #require(library.selectedAssignment)
    #expect(assignment.rubric.map(\.criterion) == [
        "The plan states one course goal", "The plan has two sections with objectives",
        "The lectures are in a clear order", "The plan fits on one page",
    ])
    let brief = try #require(assignment.brief)
    #expect(try brief.load().blocks.first == .heading(level: 1, text: "Write a course plan"))
    // Default: all rows unchecked.
    #expect(library.selectedRubricChecklist?.checked == [])
    library.toggleRubricCriterion("goal")
    library.toggleRubricCriterion("order")
    #expect(library.selectedRubricChecklist?.summary == "2 of 4 criteria met")

    // The checks stay when the learner opens another lecture and comes back, and after a reload.
    library.selectDestination(.lecture(sectionID: "practice", lectureID: "check"))
    #expect(library.selectedAssignment == nil)
    #expect(library.selectedRubricChecklist == nil)
    library.toggleRubricCriterion("sections")
    library.selectDestination(destination)
    #expect(library.selectedRubricChecklist?.checked == ["goal", "order"])
    await library.reload()
    #expect(library.selectedRubricChecklist?.checked == ["goal", "order"])

    // Reset clears all checks.
    library.resetRubric()
    #expect(library.selectedRubricChecklist?.checked == [])
    library.toggleRubricCriterion("length")

    // The checks are not saved: a new app session starts unchecked.
    await library.waitForWrites()
    let next = LibraryModel(root: root)
    await next.reload()
    next.selectCourse(courseID)
    next.selectDestination(destination)
    #expect(next.selectedRubricChecklist?.checked == [])
}
