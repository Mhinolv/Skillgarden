import Foundation
import Testing
@testable import SkillgardenCore

/// Gives each test a temporary base folder. Init must not open the library, so `root` is a path that does not exist.
private func withBase(_ body: (URL) throws -> Void) throws {
    let base = FileManager.default.temporaryDirectory.appending(path: "SkillgardenScaffoldTests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: base) }
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    try body(base)
}

private func run(_ arguments: [String]) -> CommandResult {
    SkillgardenCommand.run(arguments: arguments, root: URL(fileURLWithPath: "/unused-library"))
}

private func entries(_ folder: URL) throws -> [String] {
    try FileManager.default.subpathsOfDirectory(atPath: folder.path).sorted()
}

private let usage = SkillgardenCommand.usage + SkillgardenCommand.usageMore
private let scaffoldFiles = ["content", "content/welcome.md", "media", "media/course.svg", "media/section.svg", "skillgarden.yaml"]

@Test func initCreatesAMissingFolderThatPassesValidateAndPublish() throws {
    try withBase { base in
        let folder = base.appending(path: "courses/new-course")
        #expect(run(["init", folder.path, "--id", "new-course", "--title", "New Course"]) == CommandResult(exitCode: 0, stdout: """
            Created "New Course" (new-course, draft): 4 files in \(folder.path)
            Draft: learners do not see this course.
            Next: edit skillgarden.yaml, then run: skillgarden validate \(folder.path)

            """, stderr: ""))
        #expect(try entries(folder) == scaffoldFiles)

        let result = try CoursePublisher.validate(courseFolder: folder)
        #expect(result == ValidationResult(title: "New Course", id: "new-course", state: .draft, sections: 1, lectures: 1))
        #expect(run(["validate", folder.path]).exitCode == 0)

        let manifest = try ManifestLoader.load(courseFolder: folder)
        #expect(manifest.sections.map(\.state) == [.published])
        #expect(manifest.sections[0].lectures.map(\.state) == [.published])
        #expect(manifest.sections[0].lectures.map(\.type) == [.article])
        #expect(manifest.courseImage.alt == "Course image for New Course")
        // No network: the manifest and the article name no URL, and the SVGs link to no file.
        for path in scaffoldFiles where path.contains(".") {
            let text = try String(contentsOf: folder.appending(path: path), encoding: .utf8)
            #expect(!(path.hasSuffix(".svg") ? text.contains("href") : text.contains("http")), "\(path)")
        }

        let library = base.appending(path: "library")
        let published = try CoursePublisher.publish(courseFolder: folder, root: library)
        #expect(published.state == .draft)
    }
}

@Test func initWritesTheFixtureFieldsAndComments() throws {
    let scaffold = CourseScaffold(id: "c", title: "T")
    let manifest = scaffold.manifest
    let keys = manifest.split(separator: "\n").filter { !$0.hasPrefix(" ") && !$0.hasPrefix("#") }.map { $0.split(separator: ":")[0] }
    #expect(keys == ["schema_version", "id", "title", "subtitle", "description", "learning_outcomes", "requirements", "target_audience",
                     "state", "theme", "course_image", "credits", "sections"])
    #expect(manifest.contains("# Learners do not see a draft course. Change state to published when the course is ready.\nstate: draft\n"))
    #expect(manifest.contains("# Replace media/course.svg with your course image before you publish. Then update the alt text.\ncourse_image:\n"))
    #expect(manifest.contains("  accent_color: '#286644'\n  appearance: light\n"))
    #expect(scaffold.article == "# T\n\nWelcome to the course. Replace this paragraph with the first lesson, then add more lectures to skillgarden.yaml.\n")
    let course = scaffold.files[2].contents
    #expect(course.hasPrefix("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"1600\" height=\"900\" viewBox=\"0 0 1600 900\">"))
    #expect(course.contains("<rect width=\"1600\" height=\"900\" fill=\"#286644\"/>") && course.contains("fill=\"#fff\""))
    #expect(scaffold.files[3].contents.contains("width=\"1600\" height=\"400\""))
}

@Test func initKeepsSpecialCharactersInTheTitleAndID() throws {
    try withBase { base in
        let folder = base.appending(path: "special")
        let title = "Café: \"Quotes\" & <tags> # not a comment \\ 'single'"
        #expect(run(["init", "--title", title, "--id", "123", folder.path]).exitCode == 0)
        let result = try CoursePublisher.validate(courseFolder: folder)
        #expect(result.title == title && result.id == "123")
        let svg = try String(contentsOf: folder.appending(path: "media/course.svg"), encoding: .utf8)
        #expect(svg.contains(">Café: &quot;Quotes&quot; &amp; &lt;tags&gt; # not a comment \\ 'single'</text>"))
        #expect(try XMLDocument(data: Data(svg.utf8)).rootElement()?.name == "svg")
        #expect(try String(contentsOf: folder.appending(path: "content/welcome.md"), encoding: .utf8).hasPrefix("# \(title)\n"))
    }
}

@Test func initUsesAnEmptyFolderOrAFolderWithOnlyDSStore() throws {
    try withBase { base in
        let empty = base.appending(path: "empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        #expect(run(["init", empty.path, "--id", "a", "--title", "A"]).exitCode == 0)
        #expect(try entries(empty) == scaffoldFiles)

        let finder = base.appending(path: "finder")
        try FileManager.default.createDirectory(at: finder, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: finder.appending(path: ".DS_Store"))
        #expect(run(["init", finder.path, "--id", "b", "--title", "B"]).exitCode == 0)
        #expect(try entries(finder) == [".DS_Store"] + scaffoldFiles)
        #expect(try CoursePublisher.validate(courseFolder: finder).id == "b")
    }
}

@Test func initRefusesANonemptyFolderAndWritesNothing() throws {
    try withBase { base in
        for entry in ["notes.txt", ".hidden", "skillgarden.yaml"] {
            let folder = base.appending(path: "full-\(entry)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("keep".utf8).write(to: folder.appending(path: entry))
            #expect(run(["init", folder.path, "--id", "a", "--title", "A"]) == CommandResult(
                exitCode: 1, stdout: "", stderr: "error: folder is not empty: \(folder.path)\n"))
            #expect(try entries(folder) == [entry])
            #expect(try String(contentsOf: folder.appending(path: entry), encoding: .utf8) == "keep")
        }
        // A folder that holds only an empty subfolder is not empty.
        let nested = base.appending(path: "nested")
        try FileManager.default.createDirectory(at: nested.appending(path: "media"), withIntermediateDirectories: true)
        #expect(run(["init", nested.path, "--id", "a", "--title", "A"]).exitCode == 1)
        #expect(try entries(nested) == ["media"])
    }
}

@Test func initRefusesAFile() throws {
    try withBase { base in
        let file = base.appending(path: "course.txt")
        try Data("keep".utf8).write(to: file)
        #expect(run(["init", file.path, "--id", "a", "--title", "A"]) == CommandResult(
            exitCode: 1, stdout: "", stderr: "error: not a folder: \(file.path)\n"))
        #expect(try String(contentsOf: file, encoding: .utf8) == "keep")
    }
}

@Test func initNeedsTheFolderTheIDAndTheTitle() throws {
    try withBase { base in
        let folder = base.appending(path: "course").path
        let error = "error: expected init <folder> --id <id> --title <title>\n" + usage
        for arguments in [["init"], ["init", folder], ["init", folder, "--id", "a"], ["init", folder, "--title", "A"],
                          ["init", "--id", "a", "--title", "A"], ["init", folder, "--id", "", "--title", "A"],
                          ["init", folder, "--id", "a", "--title", "  "], ["init", folder, "--id", "a", "--title"],
                          ["init", folder, "--id", "--title", "A"], ["init", folder, "--id", "a", "--id", "b", "--title", "A"],
                          ["init", folder, "other", "--id", "a", "--title", "A"], ["init", folder, "--id", "a", "--title", "A", "--force"],
                          ["init", folder, "--id", "a", "--title", "Line one\nLine two"]] {
            #expect(run(arguments) == CommandResult(exitCode: 2, stdout: "", stderr: error), "\(arguments)")
        }
        for id in CourseScaffold.reservedIDs {
            #expect(run(["init", folder, "--id", id, "--title", "A"]) == CommandResult(exitCode: 2, stdout: "", stderr:
                "error: --id must not be \"start\" or \"welcome\", because the starter section and lecture use these ids\n" + usage))
        }
        #expect(!FileManager.default.fileExists(atPath: folder))
        #expect(run(["init", "--help"]) == CommandResult(exitCode: 0, stdout: SkillgardenCommand.help, stderr: ""))
        #expect(usage.contains("       skillgarden internal list <course-id> [--json]\n       skillgarden inspect <course-id> [--json]\n"
            + "       skillgarden remove <course-id> --yes [--json]\n"
            + "       skillgarden init <folder> --id <id> --title <title> [--json]\n       skillgarden media inspect <file> [--json]\n"
            + "       skillgarden skill install <folder> [--json]\n       skillgarden doctor [--json]\n"))
    }
}

@Test func initDeletesItsFilesWhenAWriteFails() throws {
    struct DiskFull: Error {}
    try withBase { base in
        var writes = 0
        func failThird(_ data: Data, _ url: URL) throws {
            writes += 1
            if writes == 3 { throw DiskFull() }
            try data.write(to: url)
        }
        let folder = base.appending(path: "a/b/course")
        #expect(throws: CourseScaffoldError.self) {
            try CourseScaffold(id: "c", title: "C").create(at: folder, write: failThird)
        }
        #expect(try entries(base) == [])

        writes = 0
        let existing = base.appending(path: "existing")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        try Data().write(to: existing.appending(path: ".DS_Store"))
        #expect(throws: CourseScaffoldError.self) {
            try CourseScaffold(id: "c", title: "C").create(at: existing, write: failThird)
        }
        #expect(try entries(base) == ["existing", "existing/.DS_Store"])
    }
}

@Test func initWriteFailureExitsThree() throws {
    try withBase { base in
        let locked = base.appending(path: "locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        let result = run(["init", locked.appending(path: "course").path, "--id", "a", "--title", "A"])
        #expect(result.exitCode == 3 && result.stdout.isEmpty && result.stderr.hasPrefix("error: "))
        #expect(try entries(locked) == [])
    }
}

@Test func initJSONHoldsTheResult() throws {
    try withBase { base in
        let folder = base.appending(path: "json course")
        let result = run(["init", "--json", folder.path, "--id", "j", "--title", "J"])
        #expect(result.exitCode == 0 && result.stderr.isEmpty)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        #expect(object["command"] as? String == "init" && object["ok"] as? Bool == true)
        let value = try #require(object["result"] as? [String: Any])
        #expect(value["id"] as? String == "j" && value["title"] as? String == "J" && value["state"] as? String == "draft")
        #expect(value["draft"] as? Bool == true && value["path"] as? String == folder.path)
        #expect(value["files"] as? [String] == ["skillgarden.yaml", "content/welcome.md", "media/course.svg", "media/section.svg"])

        let full = run(["init", folder.path, "--id", "j", "--title", "J", "--json"])
        let failure = try #require(try JSONSerialization.jsonObject(with: Data(full.stdout.utf8)) as? [String: Any])
        let diagnostic = try #require((failure["diagnostics"] as? [[String: Any]])?.first)
        #expect(full.exitCode == 1 && diagnostic["code"] as? String == "course_folder.not_empty")
        #expect(diagnostic["file"] as? String == folder.path)
    }
}

@Test func initQuotesAFolderWithSpacesInTheNextLine() throws {
    try withBase { base in
        let folder = base.appending(path: "my course's")
        let stdout = run(["init", folder.path, "--id", "q", "--title", "Q"]).stdout
        #expect(stdout.hasSuffix("then run: skillgarden validate '\(base.path)/my course'\\''s'\n"))
    }
}
