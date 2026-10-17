import Foundation

private indirect enum FieldRule {
    case string, integer, choices([String]), object([(String, FieldRule)]), array(FieldRule), optional(FieldRule)

    var type: String {
        switch self {
        case .string, .choices: "string"
        case .integer: "integer"
        case .object: "object"
        case .array: "array"
        case .optional(let rule): rule.type
        }
    }
}

struct ManifestValidator {
    let file: String
    let fieldOrders: [String: [String]]
    var errors: [ManifestDiagnostic] = []
    private var ids: [String: String] = [:]
    private var lectureIDs: Set<String> = []
    private var recommendations: [(String, String)] = []

    init(file: String, fieldOrders: [String: [String]]) {
        self.file = file
        self.fieldOrders = fieldOrders
    }

    mutating func validate(_ value: ManifestValue) {
        let state = FieldRule.choices(["draft", "published"])
        let image = FieldRule.object([("path", .string), ("alt", .string)])
        let lecture = FieldRule.object([
            ("id", .string), ("title", .string),
            ("type", .choices(["video", "article", "quiz", "assignment"])),
            ("objective", .string), ("state", state), ("order", .integer),
            ("recommended_next", .optional(.string)),
        ])
        let section = FieldRule.object([
            ("id", .string), ("title", .string), ("objective", .string),
            ("state", state), ("order", .integer), ("header_image", image), ("lectures", .array(lecture)),
        ])
        let root = FieldRule.object([
            ("schema_version", .integer), ("id", .string), ("title", .string),
            ("subtitle", .string), ("description", .string), ("learning_outcomes", .array(.string)),
            ("requirements", .array(.string)), ("target_audience", .string), ("state", state),
            ("theme", .object([("accent_color", .string), ("appearance", .choices(["light", "dark"]))])),
            ("course_image", image),
            ("credits", .array(.object([("name", .string), ("role", .optional(.string)), ("url", .optional(.string))]))),
            ("sections", .array(section)),
        ])
        check(value, rule: root, path: "$")
        for (id, path) in recommendations where !lectureIDs.contains(id) {
            add(path, "must refer to a lecture id in this course")
        }
        // Keep reference errors beside their fields, even though targets require a complete scan.
        var ranks: [String: Int] = [:]
        var ends: [String: Int] = [:]
        var cursor = 0
        func visit(_ value: ManifestValue, path: String) {
            ranks[path] = cursor
            cursor += 1
            switch value {
            case .object(let object):
                for key in fieldOrders[path] ?? object.keys.sorted() {
                    if let child = object[key] {
                        visit(child, path: path == "$" ? key : "\(path).\(key)")
                    }
                }
            case .array(let values):
                for (index, child) in values.enumerated() { visit(child, path: "\(path)[\(index)]") }
            default: break
            }
            ends[path] = cursor
        }
        visit(value, path: "$")
        func rank(_ path: String) -> Int {
            if let rank = ranks[path] { return rank }
            if let dot = path.lastIndex(of: ".") { return ends[String(path[..<dot])] ?? cursor }
            return cursor
        }
        errors = errors.enumerated().sorted {
            let left = rank($0.element.fieldPath), right = rank($1.element.fieldPath)
            return left == right ? $0.offset < $1.offset : left < right
        }.map(\.element)
    }

    private mutating func add(_ path: String, _ message: String) {
        errors.append(ManifestDiagnostic(file: file, fieldPath: path, message: message))
    }

    private mutating func check(_ value: ManifestValue?, rule: FieldRule, path: String) {
        if case .optional(let inner) = rule {
            if let value, case .null = value { return }
            if let value { check(value, rule: inner, path: path) }
            return
        }
        guard let value else { add(path, "required field is missing"); return }
        guard value.type == rule.type else {
            add(path, "expected \(rule.type), found \(value.type)")
            return
        }
        switch (value, rule) {
        case (.object(let object), .object(let fields)):
            let rules = Dictionary(uniqueKeysWithValues: fields)
            let sourceKeys = fieldOrders[path] ?? object.keys.sorted()
            let keys = sourceKeys + fields.map(\.0).filter { !sourceKeys.contains($0) }
            for key in keys {
                let childPath = path == "$" ? key : "\(path).\(key)"
                if let childRule = rules[key] {
                    check(object[key], rule: childRule, path: childPath)
                } else if let child = object[key] {
                    checkExtensionPaths(child, path: childPath, key: key)
                }
            }
        case (.array(let values), .array(let childRule)):
            for (index, child) in values.enumerated() {
                check(child, rule: childRule, path: "\(path)[\(index)]")
            }
        case (.string(let text), .choices(let choices)):
            if !choices.contains(text) { add(path, "must be one of: \(choices.joined(separator: ", "))") }
        case (.integer(let version), .integer) where path == "schema_version":
            if version != 1 { add(path, "must be 1") }
        case (.string(let text), .string):
            let key = path.components(separatedBy: ".").last ?? path
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                add(path, "must not be empty")
            }
            if key == "path" { checkPath(text, path: path) }
            if key == "id" {
                if let first = ids[text] { add(path, "duplicate id \"\(text)\" (first used at \(first))") }
                else { ids[text] = path }
                if path.contains(".lectures[") { lectureIDs.insert(text) }
            }
            if key == "recommended_next" { recommendations.append((text, path)) }
        default: break
        }
    }

    private mutating func checkPath(_ text: String, path: String) {
        // Treat both separators as boundaries so a manifest is safe across platforms.
        let normalized = text.replacingOccurrences(of: "\\", with: "/")
        if normalized.hasPrefix("/") || normalized.split(separator: "/").contains("..")
            || normalized.range(of: "^[A-Za-z]:", options: .regularExpression) != nil
            || URL(string: normalized)?.scheme != nil {
            add(path, "path must stay inside the course folder")
        }
    }

    private mutating func checkExtensionPaths(_ value: ManifestValue, path: String, key: String) {
        if key == "path" {
            check(value, rule: .string, path: path)
            return
        }
        switch value {
        case .object(let object):
            for key in object.keys.sorted() {
                checkExtensionPaths(object[key]!, path: "\(path).\(key)", key: key)
            }
        case .array(let values):
            for (index, child) in values.enumerated() {
                checkExtensionPaths(child, path: "\(path)[\(index)]", key: "")
            }
        default: break
        }
    }
}
