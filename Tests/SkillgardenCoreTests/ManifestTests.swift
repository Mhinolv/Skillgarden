import Foundation
import Testing
import Yams
@testable import SkillgardenCore

private let fixture = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Fixtures/sample-course")

private func withFolder(_ body: (URL) throws -> Void) throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    try body(folder)
}

private func fixtureObject() throws -> [String: Any] {
    let manifest = try ManifestLoader.load(courseFolder: fixture)
    return try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(manifest)) as? [String: Any])
}

private func diagnostics(_ object: Any) throws -> [ManifestDiagnostic] {
    var result: [ManifestDiagnostic] = []
    try withFolder { folder in
        let file = folder.appendingPathComponent("skillgarden.json")
        try JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed, .sortedKeys]).write(to: file)
        do {
            _ = try ManifestLoader.load(file: file)
            Issue.record("Expected validation to fail")
        } catch let error as ManifestValidationError {
            result = error.diagnostics
            #expect(result.allSatisfy { $0.file == file.path })
            #expect(error.description == result.map(\.description).joined(separator: "\n"))
        }
    }
    return result
}

@Test func manifestFixtureAndJSONRoundTrip() throws {
    let yaml = try ManifestLoader.load(courseFolder: fixture)
    #expect(try ManifestLoader.load(file: fixture.appendingPathComponent("equivalent.json")) == yaml)
    #expect(yaml.schemaVersion == 1)
    #expect(yaml.sections.count == 2)
    let lectures = yaml.sections.flatMap(\.lectures)
    #expect(Set(lectures.map(\.type)) == Set([.video, .article, .quiz, .assignment]))
    #expect(lectures.allSatisfy { !$0.objective.isEmpty })
    #expect(lectures[0].recommendedNext == "read")
    #expect(Set(yaml.sections.map(\.state)) == Set([.draft, .published]))
    try withFolder { folder in
        let file = folder.appendingPathComponent("skillgarden.json")
        try JSONEncoder().encode(yaml).write(to: file)
        #expect(try ManifestLoader.load(courseFolder: folder) == yaml)
        let yamlFile = folder.appendingPathComponent("roundtrip.yaml")
        try YAMLEncoder().encode(yaml).write(to: yamlFile, atomically: true, encoding: .utf8)
        #expect(try ManifestLoader.load(file: yamlFile) == yaml)
    }
}

@Test func manifestCollectsStableErrors() throws {
    var object = try fixtureObject()
    object.removeValue(forKey: "title")
    object["subtitle"] = 12
    object["state"] = "hidden"
    let errors = try diagnostics(object)
    #expect(errors.count == 3)
    #expect(errors.contains { $0.fieldPath == "title" && $0.message == "required field is missing" })
    #expect(errors.contains { $0.fieldPath == "subtitle" && $0.message == "expected string, found integer" })
    #expect(errors.contains { $0.fieldPath == "state" && $0.message == "must be one of: draft, published" })
}

@Test(arguments: ["../secret", "media/../secret", "/tmp/secret", "media/..\\secret", "C:\\secret", "file:///tmp/secret"])
func manifestRejectsPaths(path: String) throws {
    var object = try fixtureObject()
    object["course_image"] = ["path": path, "alt": "Cover"]
    object["extension"] = ["downloads": [["path": path]]]
    var sections = try #require(object["sections"] as? [[String: Any]])
    sections[0]["header_image"] = ["path": path, "alt": "Header"]
    object["sections"] = sections
    let errors = try diagnostics(object)
    #expect(errors.count == 3)
    #expect(errors.allSatisfy { $0.message == "path must stay inside the course folder" })
}

@Test func manifestDuplicateIDsAndReference() throws {
    var object = try fixtureObject()
    var sections = try #require(object["sections"] as? [[String: Any]])
    var lectures = try #require(sections[0]["lectures"] as? [[String: Any]])
    lectures[1]["id"] = "welcome"
    lectures[0]["recommended_next"] = "missing"
    lectures[1].removeValue(forKey: "objective")
    sections[0]["lectures"] = lectures
    object["sections"] = sections
    let errors = try diagnostics(object)
    #expect(errors.contains { $0.fieldPath == "sections[0].lectures[1].id" && $0.message == "duplicate id \"welcome\" (first used at sections[0].lectures[0].id)" })
    #expect(errors.contains { $0.fieldPath == "sections[0].lectures[1].objective" && $0.message == "required field is missing" })
    #expect(errors.contains { $0.fieldPath == "sections[0].lectures[0].recommended_next" })
}

@Test func manifestDiscoveryAndSyntaxErrors() throws {
    try withFolder { folder in
        do { _ = try ManifestLoader.load(courseFolder: folder); Issue.record("Expected no manifest error") }
        catch let error as ManifestValidationError {
            #expect(error.diagnostics[0].message == "no skillgarden.yaml or skillgarden.json found")
        }
        for name in ["skillgarden.yaml", "skillgarden.json"] {
            try Data("{bad".utf8).write(to: folder.appendingPathComponent(name))
        }
        do { _ = try ManifestLoader.load(courseFolder: folder); Issue.record("Expected both files error") }
        catch let error as ManifestValidationError {
            #expect(error.diagnostics[0].message == "found skillgarden.yaml and skillgarden.json, keep only one")
        }
        for name in ["skillgarden.yaml", "skillgarden.json"] {
            do { _ = try ManifestLoader.load(file: folder.appendingPathComponent(name)); Issue.record("Expected syntax error") }
            catch let error as ManifestValidationError {
                #expect(error.diagnostics[0].fieldPath == "$")
                #expect(error.diagnostics[0].message == "cannot read or parse manifest")
            }
        }
    }
}

@Test func manifestReportsSourceOrder() throws {
    try withFolder { folder in
        for name in ["skillgarden.yaml", "skillgarden.json"] {
            let source = name.hasSuffix("json") ? "{\"state\":\"bad\",\"title\":3,\"schema_version\":2}" : "state: bad\ntitle: 3\nschema_version: 2\n"
            let file = folder.appendingPathComponent(name)
            try source.write(to: file, atomically: true, encoding: .utf8)
            do { _ = try ManifestLoader.load(file: file); Issue.record("Expected field errors") }
            catch let error as ManifestValidationError {
                #expect(Array(error.diagnostics.prefix(3).map(\.fieldPath)) == ["state", "title", "schema_version"])
            }
        }
    }
}

@Test func manifestEveryRequiredField() throws {
    let object = try fixtureObject()
    func checkFields(_ fields: [String: Any], prefix: String, wrap: ([String: Any]) -> [String: Any]) throws {
        for key in fields.keys.sorted() where !["recommended_next", "role", "url", "internal"].contains(key) {
            let path = prefix.isEmpty ? key : "\(prefix).\(key)"
            var missing = fields
            missing.removeValue(forKey: key)
            // Image alt text has its own stable message for a missing or null value.
            let required = key == "alt" ? "alt text is required" : "required field is missing"
            #expect(try diagnostics(wrap(missing)).contains { $0.fieldPath == path && $0.message == required })
            var wrong = fields
            wrong[key] = NSNull()
            #expect(try diagnostics(wrap(wrong)).contains {
                $0.fieldPath == path && (key == "alt" ? $0.message == required : $0.message.hasPrefix("expected "))
            })
        }
    }
    try checkFields(object, prefix: "", wrap: { $0 })
    for key in ["theme", "course_image"] {
        try checkFields(try #require(object[key] as? [String: Any]), prefix: key) { child in
            var copy = object; copy[key] = child; return copy
        }
    }
    let sections = try #require(object["sections"] as? [[String: Any]])
    let section = sections[0]
    try checkFields(section, prefix: "sections[0]") { child in
        var copy = object; var items = sections; items[0] = child; copy["sections"] = items; return copy
    }
    let lectures = try #require(section["lectures"] as? [[String: Any]])
    try checkFields(lectures[0], prefix: "sections[0].lectures[0]") { child in
        var copy = object; var items = sections; var first = section; var lessons = lectures
        lessons[0] = child; first["lectures"] = lessons; items[0] = first; copy["sections"] = items; return copy
    }
}

@Test func manifestMinimalArraysAndOptionalFields() throws {
    var object = try fixtureObject()
    object["sections"] = []
    object["credits"] = [["name": "Author", "role": NSNull(), "url": NSNull()]]
    object["learning_outcomes"] = []
    object["requirements"] = []
    object["theme"] = ["accent_color": "#000000", "appearance": "dark"]
    try withFolder { folder in
        let file = folder.appendingPathComponent("skillgarden.json")
        try JSONSerialization.data(withJSONObject: object).write(to: file)
        let manifest = try ManifestLoader.load(file: file)
        #expect(manifest.sections.isEmpty)
        #expect(manifest.theme.appearance == .dark)
        #expect(manifest.credits[0].role == nil)
    }
}

@Test func manifestYAMLQuotedScalarsAndSafePaths() throws {
    var manifest = try ManifestLoader.load(courseFolder: fixture)
    manifest.id = "123"
    manifest.title = "true"
    manifest.subtitle = "null"
    manifest.courseImage.path = "media/cover..svg"
    manifest.sections[0].lectures[0].order = Int.max
    manifest.sections[0].lectures[0].recommendedNext = nil
    manifest.credits[0].url = nil
    manifest.credits[0].role = nil
    try withFolder { folder in
        let file = folder.appendingPathComponent("skillgarden.yaml")
        try YAMLEncoder().encode(manifest).write(to: file, atomically: true, encoding: .utf8)
        #expect(try ManifestLoader.load(file: file) == manifest)
    }
}

@Test(arguments: ["[]", "\"text\"", "true", "null", "1", "1.5"])
func manifestRejectsNonObjectRoots(source: String) throws {
    try withFolder { folder in
        for name in ["skillgarden.yaml", "skillgarden.json"] {
            let file = folder.appendingPathComponent(name)
            try source.write(to: file, atomically: true, encoding: .utf8)
            do { _ = try ManifestLoader.load(file: file); Issue.record("Expected object error") }
            catch let error as ManifestValidationError {
                #expect(error.diagnostics.count == 1)
                #expect(error.diagnostics[0].fieldPath == "$")
                #expect(error.diagnostics[0].message.hasPrefix("expected object, found "))
            }
        }
    }
}
