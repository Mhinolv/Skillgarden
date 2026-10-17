import Foundation

private indirect enum FieldRule {
    case string, altText, integer, boolean, choices([String]), object([(String, FieldRule)]), array(FieldRule), optional(FieldRule)

    var type: String {
        switch self {
        case .string, .altText, .choices: "string"
        case .integer: "integer"
        case .boolean: "boolean"
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
        let image = FieldRule.object([("path", .string), ("alt", .altText)])
        let question = FieldRule.object([
            ("id", .string), ("prompt", .string), ("image", .optional(image)), ("objective_tag", .string),
            ("choices", .array(.object([("id", .string), ("text", .string)]))),
            ("correct_choice_id", .string), ("explanation", .string),
        ])
        let article = FieldRule.object([("path", .string), ("images", .optional(.array(image)))])
        let lecture = FieldRule.object([
            ("id", .string), ("title", .string),
            ("type", .choices(["video", "article", "quiz", "assignment", "interactive"])),
            ("objective", .string), ("state", state), ("order", .integer),
            ("recommended_next", .optional(.string)),
            ("article", .optional(article)),
            ("video", .optional(.object([
                ("path", .string), ("duration_seconds", .integer),
                ("captions", .optional(.object([("path", .string)]))),
                ("poster", .optional(image)), ("free_preview", .optional(.boolean)),
            ]))),
            ("quiz", .optional(.object([("questions", .array(question))]))),
            ("interactive", .optional(.object([("bundle_path", .string)]))),
            ("assignment", .optional(.object([
                ("brief", article),
                ("rubric", .array(.object([("id", .string), ("criterion", .string), ("guidance", .string)]))),
            ]))),
            ("downloads", .optional(.array(.object([
                ("path", .string), ("title", .string), ("description", .optional(.string)),
            ])))),
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
            ("internal", .optional(.object([("files", .array(.object([
                ("path", .string), ("title", .string), ("description", .optional(.string)),
            ])))]))),
        ])
        check(value, rule: root, path: "$")
        checkQuizzes(value)
        checkRubrics(value)
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
        if case .altText = rule {
            // A missing, null or blank alt gets one stable message.
            switch value {
            case nil, .null?: add(path, "alt text is required")
            case .string(let text)?:
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { add(path, "alt text is required") }
            case let value?: add(path, "expected string, found \(value.type)")
            }
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
            // Only lectures have `article`, `video`, `interactive` and `assignment` rules. Each field must match the lecture type.
            if rules["article"] != nil, case .string(let type)? = object["type"] {
                for field in ["article", "video", "interactive", "assignment"] {
                    let present: Bool = if case .null? = object[field] { false } else { object[field] != nil }
                    if type == field, !present { add("\(path).\(field)", "required field is missing") }
                    if type != field, present { add("\(path).\(field)", "allowed only when type is \(field)") }
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
        case (.integer(let seconds), .integer) where path.hasSuffix(".video.duration_seconds"):
            if seconds < 1 { add(path, "must be greater than 0") }
        case (.string(let text), .string):
            let key = path.components(separatedBy: ".").last ?? path
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                add(path, "must not be empty")
            } else if key == "path" || key == "bundle_path" {
                checkPath(text, path: path)
                if path.hasSuffix(".video.path"), !text.lowercased().hasSuffix(".mp4") { add(path, "must be an .mp4 file") }
                if path.hasSuffix(".video.captions.path"), !text.lowercased().hasSuffix(".vtt") { add(path, "must be a .vtt file") }
            }
            // Question, choice and rubric ids are unique inside their quiz, question or rubric only.
            // `checkQuizzes` and `checkRubrics` check them.
            if key == "id", !path.contains(".quiz."), !path.contains(".assignment.") {
                if let first = ids[text] { add(path, "duplicate id \"\(text)\" (first used at \(first))") }
                else { ids[text] = path }
                if path.contains(".lectures[") { lectureIDs.insert(text) }
            }
            if key == "recommended_next" { recommendations.append((text, path)) }
        default: break
        }
    }

    /// Rules that span fields: `quiz` goes with `type: quiz`, ids are unique, and the correct choice exists.
    private mutating func checkQuizzes(_ root: ManifestValue) {
        func object(_ value: ManifestValue?) -> [String: ManifestValue]? {
            if case .object(let object)? = value { return object }
            return nil
        }
        func array(_ value: ManifestValue?) -> [ManifestValue] {
            if case .array(let values)? = value { return values }
            return []
        }
        func string(_ value: ManifestValue?) -> String? {
            if case .string(let text)? = value { return text }
            return nil
        }
        for (sectionIndex, section) in array(object(root)?["sections"]).enumerated() {
            for (lectureIndex, lecture) in array(object(section)?["lectures"]).enumerated() {
                guard let lecture = object(lecture) else { continue }
                let path = "sections[\(sectionIndex)].lectures[\(lectureIndex)].quiz"
                var quiz = lecture["quiz"]
                if case .null? = quiz { quiz = nil }
                let isQuiz = string(lecture["type"]) == "quiz"
                if isQuiz, quiz == nil { add(path, "required when type is quiz") }
                if !isQuiz, quiz != nil, string(lecture["type"]) != nil { add(path, "allowed only when type is quiz") }
                guard case .array(let questions)? = object(quiz)?["questions"] else { continue }
                if questions.isEmpty { add(path + ".questions", "must have at least one question") }
                var questionIDs: [String: String] = [:]
                for (questionIndex, question) in questions.enumerated() {
                    guard let question = object(question) else { continue }
                    let questionPath = "\(path).questions[\(questionIndex)]"
                    if let id = string(question["id"]) {
                        if let first = questionIDs[id] { add(questionPath + ".id", "duplicate id \"\(id)\" (first used at \(first))") }
                        else { questionIDs[id] = questionPath + ".id" }
                    }
                    guard case .array(let choices)? = question["choices"] else { continue }
                    if choices.count < 2 { add(questionPath + ".choices", "must have at least two choices") }
                    var choiceIDs: [String: String] = [:]
                    for (choiceIndex, choice) in choices.enumerated() {
                        guard let id = string(object(choice)?["id"]) else { continue }
                        let choicePath = "\(questionPath).choices[\(choiceIndex)].id"
                        if let first = choiceIDs[id] { add(choicePath, "duplicate id \"\(id)\" (first used at \(first))") }
                        else { choiceIDs[id] = choicePath }
                    }
                    if let correct = string(question["correct_choice_id"]), choiceIDs[correct] == nil {
                        add(questionPath + ".correct_choice_id", "must refer to a choice id in this question")
                    }
                }
            }
        }
    }

    /// Each assignment rubric has at least one row, and its row ids are unique inside the rubric.
    private mutating func checkRubrics(_ root: ManifestValue) {
        guard case .object(let course) = root, case .array(let sections)? = course["sections"] else { return }
        for (sectionIndex, section) in sections.enumerated() {
            guard case .object(let section) = section, case .array(let lectures)? = section["lectures"] else { continue }
            for (lectureIndex, lecture) in lectures.enumerated() {
                guard case .object(let lecture) = lecture, case .object(let assignment)? = lecture["assignment"],
                      case .array(let rows)? = assignment["rubric"] else { continue }
                let path = "sections[\(sectionIndex)].lectures[\(lectureIndex)].assignment.rubric"
                if rows.isEmpty { add(path, "must have at least one row") }
                var rowIDs: [String: String] = [:]
                for (rowIndex, row) in rows.enumerated() {
                    guard case .object(let row) = row, case .string(let id)? = row["id"] else { continue }
                    let rowPath = "\(path)[\(rowIndex)].id"
                    if let first = rowIDs[id] { add(rowPath, "duplicate id \"\(id)\" (first used at \(first))") }
                    else { rowIDs[id] = rowPath }
                }
            }
        }
    }

    private mutating func checkPath(_ text: String, path: String) {
        // Treat both separators as boundaries so a manifest is safe across platforms.
        let normalized = text.replacingOccurrences(of: "\\", with: "/")
        let escapes = normalized.hasPrefix("/") || normalized.split(separator: "/").contains("..")
            || normalized.range(of: "^[A-Za-z]:", options: .regularExpression) != nil
            || URL(string: normalized)?.scheme != nil
        // Publish keeps internal/ out of the learner snapshot, so each path belongs to one side only.
        let inside = normalized.hasPrefix("internal/") && normalized.count > "internal/".count
        if path.hasPrefix("internal.") {
            if escapes || !inside { add(path, "path must stay inside internal/") }
        } else if escapes {
            add(path, "path must stay inside the course folder")
        } else if normalized.hasPrefix("internal/") {
            add(path, "path must not be inside internal/")
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
