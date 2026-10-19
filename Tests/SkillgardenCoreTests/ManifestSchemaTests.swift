import Foundation
import Testing
@testable import SkillgardenCore

private let repository = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let unusedRoot = FileManager.default.temporaryDirectory.appending(path: "SkillgardenUnused-\(UUID())")

private func schema() throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: Data(ManifestSchema.json.utf8)) as? [String: Any])
}

/// Follows `properties` and `items` keys from the root, for example `["sections", "lectures", "type"]`.
private func property(_ schema: [String: Any], _ names: [String]) -> [String: Any]? {
    var node = schema
    for name in names {
        if let items = node["items"] as? [String: Any] { node = items }
        guard let next = (node["properties"] as? [String: Any])?[name] as? [String: Any] else { return nil }
        node = next
    }
    return node
}

/// Reduces a schema node to the keys of `ManifestValidator.schemaOutline`. It resolves `$ref` and an `anyOf` with `null`.
private func outline(_ node: [String: Any], defs: [String: Any]) -> [String: Any] {
    if let ref = node["$ref"] as? String {
        let name = String(ref.dropFirst("#/$defs/".count))
        return outline(defs[name] as? [String: Any] ?? [:], defs: defs)
    }
    if let anyOf = node["anyOf"] as? [[String: Any]], anyOf.count == 2,
       let nonNull = anyOf.first(where: { $0["type"] as? String != "null" }) {
        var result = outline(nonNull, defs: defs)
        result["type"] = (result["type"] as? [String] ?? []) + ["null"]
        return result
    }
    var result: [String: Any] = [:]
    if let type = node["type"] as? String { result["type"] = [type] }
    if let types = node["type"] as? [String] { result["type"] = types }
    if let values = node["enum"] { result["enum"] = values }
    if let required = node["required"] as? [String] { result["required"] = required.sorted() }
    if let properties = node["properties"] as? [String: Any] {
        result["properties"] = properties.mapValues { outline($0 as? [String: Any] ?? [:], defs: defs) }
    }
    if let items = node["items"] as? [String: Any] { result["items"] = outline(items, defs: defs) }
    return result
}

/// One line for each difference between two outlines.
private func differences(_ schema: [String: Any], _ rules: [String: Any], path: String = "$") -> [String] {
    var lines: [String] = []
    for key in ["type", "enum", "required"] where !NSDictionary(dictionary: [key: schema[key] ?? NSNull()])
        .isEqual(to: [key: rules[key] ?? NSNull()]) {
        lines.append("\(path) \(key): schema \(schema[key] ?? "none"), validator \(rules[key] ?? "none")")
    }
    let schemaProperties = schema["properties"] as? [String: [String: Any]] ?? [:]
    let ruleProperties = rules["properties"] as? [String: [String: Any]] ?? [:]
    for name in Set(schemaProperties.keys).union(ruleProperties.keys).sorted() {
        guard let left = schemaProperties[name], let right = ruleProperties[name] else {
            lines.append("\(path).\(name): only in the \(schemaProperties[name] == nil ? "validator" : "schema")")
            continue
        }
        lines += differences(left, right, path: "\(path).\(name)")
    }
    if let left = schema["items"] as? [String: Any], let right = rules["items"] as? [String: Any] {
        lines += differences(left, right, path: path + "[]")
    } else if (schema["items"] == nil) != (rules["items"] == nil) {
        lines.append("\(path) items: only in the \(schema["items"] == nil ? "validator" : "schema")")
    }
    return lines
}

/// The text of `json.dumps(value, indent=2, sort_keys=True)`.
private func canonical(_ value: Any, indent: String = "") -> String {
    let inner = indent + "  "
    func quoted(_ text: String) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed, .withoutEscapingSlashes])) ?? Data(),
               as: UTF8.self)
    }
    switch value {
    case let object as [String: Any]:
        let lines = object.keys.sorted().map { inner + quoted($0) + ": " + canonical(object[$0]!, indent: inner) }
        return "{\n" + lines.joined(separator: ",\n") + "\n" + indent + "}"
    case let array as [Any]:
        return "[\n" + array.map { inner + canonical($0, indent: inner) }.joined(separator: ",\n") + "\n" + indent + "]"
    case let text as String:
        return quoted(text)
    case let number as NSNumber:
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
        return number.stringValue
    default:
        return "null"
    }
}

private func containsKey(_ key: String, in value: Any) -> Bool {
    if let object = value as? [String: Any] { return object[key] != nil || object.values.contains { containsKey(key, in: $0) } }
    if let array = value as? [Any] { return array.contains { containsKey(key, in: $0) } }
    return false
}

@Test func schemaIdentifiesManifestVersionOne() throws {
    let schema = try schema()
    #expect(schema["$schema"] as? String == "https://json-schema.org/draft/2020-12/schema")
    #expect(schema["$id"] as? String == "urn:skillgarden:manifest:1")
    #expect(schema["title"] as? String == "Skillgarden course manifest")
    #expect(property(schema, ["schema_version"])?["const"] as? Int == ManifestSchema.version)
    // The validator accepts unknown keys, so the schema must too.
    #expect(!containsKey("additionalProperties", in: schema))
}

@Test func schemaEnumsMatchManifestModel() throws {
    let schema = try schema()
    let states = ManifestState.allCases.map(\.rawValue)
    #expect(property(schema, ["state"])?["enum"] as? [String] == states)
    #expect(property(schema, ["sections", "state"])?["enum"] as? [String] == states)
    #expect(property(schema, ["sections", "lectures", "state"])?["enum"] as? [String] == states)
    #expect(property(schema, ["theme", "appearance"])?["enum"] as? [String] == ManifestAppearance.allCases.map(\.rawValue))
    #expect(property(schema, ["sections", "lectures", "type"])?["enum"] as? [String] == ManifestLectureType.allCases.map(\.rawValue))
}

@Test func schemaRequiredFieldsMatchValidator() throws {
    let schema = try schema()
    let rules = ManifestValidator.schemaOutline
    #expect((schema["required"] as? [String])?.sorted() == rules["required"] as? [String])
    #expect(schema["required"] as? [String] == ["schema_version", "id", "title", "subtitle", "description", "learning_outcomes",
                                                "requirements", "target_audience", "state", "theme", "course_image", "credits", "sections"])
    // Every level: field names, types, nullable optional fields, required lists and enums.
    let lines = differences(outline(schema, defs: schema["$defs"] as? [String: Any] ?? [:]), rules)
    #expect(lines.isEmpty, "\(lines.joined(separator: "\n"))")
}

@Test func schemaHasOneVariantForEachLectureType() throws {
    let lecture = try #require(property(try schema(), ["sections", "lectures"])?["items"] as? [String: Any])
    let variants = try #require(lecture["allOf"] as? [[String: Any]])
    var types: [String] = []
    for variant in variants {
        let type = try #require(((variant["if"] as? [String: Any])?["properties"] as? [String: Any])?["type"] as? [String: Any])
        let name = try #require(type["const"] as? String)
        types.append(name)
        let then = try #require(variant["then"] as? [String: Any])
        #expect(then["required"] as? [String] == [name])
        #expect(((then["properties"] as? [String: Any])?[name] as? [String: Any])?["type"] as? String == "object")
        // Validate rejects the field for other types and accepts null.
        let otherwise = try #require(variant["else"] as? [String: Any])
        #expect(((otherwise["properties"] as? [String: Any])?[name] as? [String: Any])?["type"] as? String == "null")
        #expect((lecture["properties"] as? [String: Any])?[name] != nil)
    }
    #expect(types == ManifestLectureType.allCases.map(\.rawValue))
}

@Test func schemaUsesTwoSpaceIndentAndSortedKeys() throws {
    #expect(canonical(try schema()) == ManifestSchema.json)
}

@Test func docsCopyMatchesSchemaConstant() throws {
    let copy = try String(contentsOf: repository.appending(path: "docs/skillgarden-manifest.schema.json"), encoding: .utf8)
    #expect(copy == ManifestSchema.json + "\n", "Run skillgarden schema --output docs/skillgarden-manifest.schema.json")
    let guide = try String(contentsOf: repository.appending(path: "docs/agent-publishing.md"), encoding: .utf8)
    #expect(guide.contains("## 8. Manifest schema"))
}

@Test func schemaCommandPrintsSchema() {
    let expected = CommandResult(exitCode: 0, stdout: ManifestSchema.json + "\n", stderr: "")
    #expect(SkillgardenCommand.run(arguments: ["schema"], root: unusedRoot) == expected)
    #expect(SkillgardenCommand.run(arguments: ["schema", "--json"], root: unusedRoot) == expected)
}

@Test func schemaCommandWritesFile() throws {
    let base = FileManager.default.temporaryDirectory.appending(path: "SkillgardenSchemaTests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: base) }
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let file = base.appending(path: "manifest.schema.json")
    try Data("old".utf8).write(to: file)

    let result = SkillgardenCommand.run(arguments: ["schema", "--output", file.path], root: unusedRoot)
    #expect(result == CommandResult(exitCode: 0, stdout: "Wrote manifest schema 1 to \(file.path)\n", stderr: ""))
    #expect(try String(contentsOf: file, encoding: .utf8) == ManifestSchema.json + "\n")

    // The path is absolute in the message, also when the argument has `..` parts.
    let indirect = base.path + "/sub/../manifest.schema.json"
    try FileManager.default.createDirectory(at: base.appending(path: "sub"), withIntermediateDirectories: true)
    #expect(SkillgardenCommand.run(arguments: ["schema", "--output", indirect], root: unusedRoot).stdout
            == "Wrote manifest schema 1 to \(file.path)\n")

    let json = SkillgardenCommand.run(arguments: ["schema", "--json", "--output", file.path], root: unusedRoot)
    #expect(json.exitCode == 0 && json.stderr.isEmpty)
    let object = try #require(JSONSerialization.jsonObject(with: Data(json.stdout.utf8)) as? [String: Any])
    #expect(object["command"] as? String == "schema")
    #expect(object["ok"] as? Bool == true)
    let resultObject = try #require(object["result"] as? [String: Any])
    #expect(resultObject["path"] as? String == file.path)
    #expect(resultObject["schema_version"] as? Int == 1)
}

@Test func schemaCommandWriteFailureExits3() throws {
    let base = FileManager.default.temporaryDirectory.appending(path: "SkillgardenSchemaTests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: base) }
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    for target in [base.appending(path: "missing/schema.json").path, base.path] {
        let result = SkillgardenCommand.run(arguments: ["schema", "--output", target], root: unusedRoot)
        #expect(result.exitCode == 3)
        #expect(result.stdout.isEmpty)
        #expect(result.stderr.hasPrefix("error: ") && result.stderr.hasSuffix("\n") && !result.stderr.contains("usage:"))
    }
}

@Test func schemaCommandUsage() throws {
    let usage = SkillgardenCommand.usage + SkillgardenCommand.usageMore
    #expect(usage.contains("       skillgarden doctor [--json]\n       skillgarden schema [--output <file>]\n"))
    #expect(SkillgardenCommand.run(arguments: ["schema", "--help"], root: unusedRoot)
            == CommandResult(exitCode: 0, stdout: SkillgardenCommand.help, stderr: ""))
    for arguments in [["schema", "extra"], ["schema", "--bogus"], ["schema", "--output"], ["schema", "--output", ""],
                      ["schema", "--output", "-x"], ["schema", "--output", "a", "b"], ["schema", "a", "--output"]] {
        #expect(SkillgardenCommand.run(arguments: arguments, root: unusedRoot) == CommandResult(
            exitCode: 2, stdout: "", stderr: "error: expected schema [--output <file>]\n" + usage), "\(arguments)")
    }
    let json = SkillgardenCommand.run(arguments: ["schema", "--bogus", "--json"], root: unusedRoot)
    #expect(json.exitCode == 2 && json.stderr.isEmpty)
    let object = try #require(JSONSerialization.jsonObject(with: Data(json.stdout.utf8)) as? [String: Any])
    #expect(object["command"] as? String == "schema")
    #expect(object["ok"] as? Bool == false)
}
