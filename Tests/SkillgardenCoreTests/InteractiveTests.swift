import Foundation
import JavaScriptCore
import SQLite3
import Testing
@testable import SkillgardenCore

private let fixture = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Fixtures/interactive-course")

private let objective = "Order the steps of a course plan"
private let bundleField = "sections[0].lectures[0].interactive.bundle_path"

private func temporaryFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appending(path: "InteractiveTests-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

/// Gives the body a writable copy of the interactive fixture and an empty library root.
private func withCourse(_ body: (URL, URL) throws -> Void) throws {
    let base = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: base) }
    let folder = base.appending(path: "course")
    try FileManager.default.copyItem(at: fixture, to: folder)
    try body(folder, base.appending(path: "library"))
}

private func edit(_ folder: URL, _ old: String, _ new: String) throws {
    let file = folder.appending(path: "skillgarden.yaml")
    let text = try String(contentsOf: file, encoding: .utf8)
    #expect(text.contains(old))
    try text.replacingOccurrences(of: old, with: new).write(to: file, atomically: true, encoding: .utf8)
}

private func publishDiagnostics(_ folder: URL, root: URL) throws -> [ManifestDiagnostic] {
    do {
        _ = try CoursePublisher.publish(courseFolder: folder, root: root)
        return []
    } catch let error as ManifestValidationError {
        return error.diagnostics
    }
}

// MARK: Manifest and publish

@Test func manifestLoadsAnInteractiveLecture() throws {
    let manifest = try ManifestLoader.load(courseFolder: fixture)
    let lecture = try #require(manifest.sections.first?.lectures.first)
    #expect(lecture.type == .interactive)
    #expect(lecture.interactive == ManifestInteractive(bundlePath: "modules/order"))
    #expect(lecture.article == nil && lecture.quiz == nil)
}

@Test func manifestRequiresTheInteractiveFieldOnlyForInteractiveLectures() throws {
    try withCourse { folder, root in
        try edit(folder, "        interactive:\n          bundle_path: modules/order\n", "")
        #expect(try publishDiagnostics(folder, root: root).map(\.description) == [
            "\(folder.appending(path: "skillgarden.yaml").path): sections[0].lectures[0].interactive: required field is missing",
        ])
    }
    try withCourse { folder, root in
        // Every other type needs its own field. An assignment adds only its own "required" error.
        try edit(folder, "type: interactive", "type: assignment")
        #expect(try publishDiagnostics(folder, root: root).map(\.message) == ["allowed only when type is interactive",
                                                                              "required field is missing"])
    }
    for (path, message) in [("../outside", "path must stay inside the course folder"),
                            ("internal/module", "path must not be inside internal/"),
                            ("/tmp/module", "path must stay inside the course folder"),
                            ("''", "must not be empty")] {
        try withCourse { folder, root in
            try edit(folder, "bundle_path: modules/order", "bundle_path: \(path)")
            let diagnostics = try publishDiagnostics(folder, root: root)
            #expect(diagnostics.map(\.fieldPath) == [bundleField], "\(path)")
            #expect(diagnostics.map(\.message) == [message], "\(path)")
        }
    }
}

@Test func publishFailsWhenTheBundleHasNoIndexFile() throws {
    try withCourse { folder, root in
        try FileManager.default.removeItem(at: folder.appending(path: "modules/order/index.html"))
        let diagnostics = try publishDiagnostics(folder, root: root)
        #expect(diagnostics.map(\.fieldPath) == [bundleField])
        #expect(diagnostics.map(\.message) == ["folder must contain index.html"])
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "library.sqlite").path))
    }
    // A missing folder, a file path and the course root are not bundles.
    for path in ["modules/missing", "modules/order/app.js", "."] {
        try withCourse { folder, root in
            try edit(folder, "bundle_path: modules/order", "bundle_path: \(path)")
            #expect(try publishDiagnostics(folder, root: root).map(\.message) == ["folder must contain index.html"], "\(path)")
        }
    }
}

@Test func publishCopiesTheBundleIntoTheSnapshot() throws {
    try withCourse { folder, root in
        let result = try CoursePublisher.publish(courseFolder: folder, root: root)
        #expect(result.created == 2)
        let snapshot = try #require(try CoursePublisher.assetDirectory(courseID: "interactive-course", root: root))
        for file in ["index.html", "app.js", "style.css"] {
            #expect(FileManager.default.contentsEqual(atPath: folder.appending(path: "modules/order/\(file)").path,
                                                      andPath: snapshot.appending(path: "modules/order/\(file)").path))
        }
        let course = try #require(try CourseStore(root: root).loadCourse(id: "interactive-course"))
        #expect(course.sections.first?.lectures.map(\.type) == [.interactive])
        // A trailing slash and `./` give the same bundle.
        let module = try #require(InteractiveModule(snapshot: snapshot, bundlePath: "./modules/order/"))
        #expect(module.entryExists())
        #expect(module.entryURL == snapshot.appending(path: "modules/order/index.html").standardizedFileURL)
        #expect(InteractiveModule(snapshot: snapshot, bundlePath: "../modules") == nil)
        #expect(InteractiveModule(snapshot: snapshot, bundlePath: "internal/module") == nil)
    }
}

// MARK: Web view policy

@Test func navigationPolicyDeniesOffBundleFilesAndHTTP() throws {
    let bundle = URL(fileURLWithPath: "/Library/Skillgarden/courses/A/modules/order", isDirectory: true)
    let allowed = [
        "file:///Library/Skillgarden/courses/A/modules/order/index.html",
        "file:///Library/Skillgarden/courses/A/modules/order/index.html#step-2",
        "file:///Library/Skillgarden/courses/A/modules/order/index.html?level=1",
        "file:///Library/Skillgarden/courses/A/modules/order/pages/two.html",
        "file:///Library/Skillgarden/courses/A/modules/order/pages/../index.html",
        "about:blank",
        "about:srcdoc",
    ]
    let denied = [
        "file:///Library/Skillgarden/courses/A/skillgarden.yaml",
        "file:///Library/Skillgarden/courses/A/modules/order/../other/index.html",
        "file:///Library/Skillgarden/courses/A/modules/order%2F..%2F..%2Fskillgarden.yaml",
        "file:///Library/Skillgarden/courses/A/modules/order-copy/index.html",
        "file:///Library/Skillgarden/courses/A/modules/order",
        "file:///etc/passwd",
        "http://example.com/",
        "https://example.com/modules/order/index.html",
        "http://localhost:8080/index.html",
        "ws://example.com/socket",
        "data:text/html,<p>Hi</p>",
        "blob:file:///0000",
        "javascript:alert(1)",
        "about:config",
        "mailto:learner@example.com",
    ]
    for text in allowed {
        #expect(InteractiveNavigationPolicy.allows(try #require(URL(string: text)), bundle: bundle), "\(text)")
    }
    for text in denied {
        #expect(!InteractiveNavigationPolicy.allows(try #require(URL(string: text)), bundle: bundle), "\(text)")
    }
}

@Test func navigationPolicyResolvesSymbolicLinksOfTheLibraryFolder() throws {
    // The temporary folder is under /var, which is a link to /private/var.
    let root = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let bundle = root.appending(path: "modules/order", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
    try Data("<p>Hi</p>".utf8).write(to: bundle.appending(path: "index.html"))
    let resolved = bundle.resolvingSymlinksInPath().appending(path: "index.html")
    #expect(InteractiveNavigationPolicy.allows(resolved, bundle: bundle))
    #expect(InteractiveNavigationPolicy.allows(bundle.appending(path: "index.html"), bundle: bundle.resolvingSymlinksInPath()))
    #expect(!InteractiveNavigationPolicy.allows(root.appending(path: "modules/other.html"), bundle: bundle))
}

@Test func contentRulesBlockEveryNetworkLoad() throws {
    let rules = try #require(JSONSerialization.jsonObject(with: Data(InteractiveNavigationPolicy.contentRules.utf8)) as? [[String: [String: String]]])
    #expect(rules.map { $0["action"]?["type"] } == ["block"] + Array(repeating: "ignore-previous-rules", count: 4))
    // WebKit rejects a filter with a disjunction or a group, so the rule list must not use them.
    #expect(rules.allSatisfy { rule in !(rule["trigger"]?["url-filter"] ?? "|").contains(where: { "|()".contains($0) }) })
    // WebKit applies the rules in order, so a later "ignore-previous-rules" match unblocks the load.
    func blocks(_ url: String) throws -> Bool {
        var blocked = false
        for rule in rules {
            let filter = try NSRegularExpression(pattern: try #require(rule["trigger"]?["url-filter"]))
            guard filter.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil else { continue }
            blocked = rule["action"]?["type"] == "block"
        }
        return blocked
    }
    for url in ["http://example.com/a.js", "https://example.com/a.png", "ws://example.com", "wss://example.com", "ftp://example.com"] {
        #expect(try blocks(url), "\(url)")
    }
    for url in ["file:///Library/Skillgarden/courses/A/modules/order/app.js", "about:blank", "data:image/png;base64,AA==", "blob:file:///1"] {
        #expect(try !blocks(url), "\(url)")
    }
}

// MARK: Bridge

@Test func bridgeMessagesParseCompleteAndScore() {
    #expect(InteractiveBridgeMessage(body: ["type": "complete"]) == .complete)
    #expect(InteractiveBridgeMessage(body: ["type": "score", "score": 80]) == .score(80))
    #expect(InteractiveBridgeMessage(body: ["type": "score", "score": NSNumber(value: 79.6)]) == .score(80))
    #expect(InteractiveBridgeMessage(body: ["type": "score", "score": 0]) == .score(0))
    #expect(InteractiveBridgeMessage(body: ["type": "score", "score": 100]) == .score(100))
    #expect(InteractiveBridgeMessage(body: ["type": "score", "score": 150]) == .score(100))
    #expect(InteractiveBridgeMessage(body: ["type": "score", "score": -5]) == .score(0))
    for body: Any in [
        ["type": "score", "score": "80"], ["type": "score", "score": NSNumber(value: true)],
        ["type": "score", "score": Double.nan], ["type": "score", "score": Double.infinity], ["type": "score"],
        ["type": "reload"], ["score": 80], "complete", 80, NSNull(),
    ] {
        #expect(InteractiveBridgeMessage(body: body) == nil, "\(body)")
    }
}

@Test func bridgeScriptPostsMessagesThatParse() throws {
    let context = try #require(JSContext())
    var posted: [Any] = []
    let post: @convention(block) (JSValue) -> Void = { posted.append($0.toObject() as Any) }
    context.evaluateScript("var window = this; window.webkit = { messageHandlers: { skillgarden: {} } };")
    context.objectForKeyedSubscript("webkit").objectForKeyedSubscript("messageHandlers")
        .objectForKeyedSubscript(InteractiveBridgeMessage.handlerName).setObject(post, forKeyedSubscript: "postMessage" as NSString)
    context.evaluateScript(InteractiveBridgeMessage.bridgeScript)
    #expect(context.exception == nil)
    context.evaluateScript("Skillgarden.submitScore(40); Skillgarden.complete(); Skillgarden.submitScore(true);")
    #expect(context.exception == nil)
    #expect(posted.map { InteractiveBridgeMessage(body: $0) } == [.score(40), .complete, nil])
    // A module cannot replace the bridge.
    context.evaluateScript("Skillgarden.complete = null; window.Skillgarden = null; Skillgarden.complete();")
    #expect(posted.count == 4)
}

@Test func lowScoreMakesTheLectureObjectiveWeak() {
    #expect(InteractiveResult(score: 40, objective: objective) == InteractiveResult(score: 40, weakSkills: [objective]))
    #expect(InteractiveResult(score: 99, objective: " \(objective) ").weakSkills == [objective])
    #expect(InteractiveResult(score: 100, objective: objective).weakSkills == [])
    #expect(InteractiveResult(score: 0, objective: "  ").weakSkills == [])
    #expect(InteractiveResult(score: 140, objective: objective).score == 100)
    #expect(InteractiveResult(score: -1, objective: objective).score == 0)
}

// MARK: Store and library

@Test func storeMigratesFromSchemaVersion6AndKeepsOldCourses() throws {
    let root = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let old = try CourseStore(root: root, migrations: Array(CourseStore.migrations.prefix(6)))
    let course = Course(id: "c", title: "Old course", state: .published, sections: [
        CourseSection(id: "s", title: "Section", order: 0, state: .published, lectures: [
            Lecture(id: "v", title: "Video", type: .video, objective: "Watch", order: 0, state: .published, recommendedNext: "q"),
            Lecture(id: "q", title: "Quiz", type: .quiz, order: 1, state: .published),
        ]),
    ])
    try old.saveCourse(course)
    try old.setCompleted(true, courseID: "c", lectureID: "v")
    try old.saveQuizResult(QuizResult(correct: 1, total: 2, weakSkills: ["A"]), courseID: "c", lectureID: "q")
    // The version 6 CHECK does not allow the new type.
    var withModule = course
    withModule.sections[0].lectures.append(Lecture(id: "m", title: "Module", type: .interactive, order: 2, state: .published))
    #expect(throws: CourseStoreError.databaseFailure) { try old.saveCourse(withModule) }

    let store = try CourseStore(root: root)
    #expect(try store.schemaVersion == 7)
    #expect(try store.loadCourse(id: "c") == course)
    #expect(try store.allProgress() == ["c": ["v": LectureProgress(completed: true)]])
    #expect(try store.allQuizResults() == ["c": ["q": QuizResult(correct: 1, total: 2, weakSkills: ["A"])]])
    #expect(try store.allInteractiveResults().isEmpty)
    try store.saveCourse(withModule)
    #expect(try store.loadCourse(id: "c") == withModule)
    // The index and the cascade from sections still work on the new table.
    let database = try SQLiteDatabase(url: root.appending(path: "library.sqlite"))
    #expect(try database.query("SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'lectures' AND name = 'lectures_outline'") {
        SQLiteDatabase.text($0, 0)
    } == ["lectures_outline"])
    try store.deleteCourse(id: "c")
    #expect(try database.query("SELECT COUNT(*) FROM lectures") { sqlite3_column_int64($0, 0) } == [0])
}

@Test func interactiveResultsSaveAndReplace() throws {
    let root = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try CourseStore(root: root)
    try store.saveInteractiveResult(InteractiveResult(score: 40, objective: objective), courseID: "c", lectureID: "m")
    try store.saveInteractiveResult(InteractiveResult(score: 100, objective: objective), courseID: "c", lectureID: "m")
    try store.saveInteractiveResult(InteractiveResult(score: 0, objective: "It's \"quoted\""), courseID: "d", lectureID: "m")
    #expect(try store.allInteractiveResults() == [
        "c": ["m": InteractiveResult(score: 100, weakSkills: [])],
        "d": ["m": InteractiveResult(score: 0, weakSkills: ["It's \"quoted\""])],
    ])
    #expect(throws: CourseStoreError.databaseFailure) {
        try store.saveInteractiveResult(InteractiveResult(score: 101, weakSkills: []), courseID: "c", lectureID: "m")
    }
}

@MainActor @Test func libraryAppliesBridgeMessagesToProgressAndResults() async throws {
    let root = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try CoursePublisher.publish(courseFolder: fixture, root: root)
    let library = LibraryModel(root: root)
    await library.reload()
    library.selectCourse("interactive-course")
    #expect(library.selectedInteractive == nil)
    library.selectDestination(.lecture(sectionID: "practice", lectureID: "order-steps"))
    let module = try #require(library.selectedInteractive)
    #expect(module.entryURL.path.hasSuffix("/modules/order/index.html"))
    #expect(library.selectedInteractiveResult == nil)
    #expect(!library.isSelectedLectureComplete)

    // A message from another lecture does nothing.
    library.receiveInteractiveMessage(.complete, lectureID: "other")
    library.receiveInteractiveMessage(.score(10), lectureID: "other")
    #expect(!library.isSelectedLectureComplete && library.selectedInteractiveResult == nil)

    library.receiveInteractiveMessage(.complete, lectureID: "order-steps")
    #expect(library.isSelectedLectureComplete)
    library.receiveInteractiveMessage(.score(25), lectureID: "order-steps")
    #expect(library.selectedInteractiveResult == InteractiveResult(score: 25, weakSkills: [objective]))
    await library.waitForWrites()
    let store = try CourseStore(root: root)
    #expect(try store.progress(courseID: "interactive-course", lectureID: "order-steps")?.completed == true)
    #expect(try store.allInteractiveResults() == ["interactive-course": ["order-steps": InteractiveResult(score: 25, weakSkills: [objective])]])

    // The learner can still undo, and a second complete() marks the lecture complete again.
    await library.toggleSelectedLectureComplete()
    #expect(!library.isSelectedLectureComplete)
    library.receiveInteractiveMessage(.complete, lectureID: "order-steps")
    // A new score replaces the old one and survives a reload.
    library.receiveInteractiveMessage(.score(100), lectureID: "order-steps")
    await library.reload()
    #expect(library.isSelectedLectureComplete)
    #expect(library.selectedInteractiveResult == InteractiveResult(score: 100, weakSkills: []))
}
