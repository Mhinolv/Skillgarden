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
        check(value, rule: Self.rootRule, path: "$")
        checkQuizzes(value)
        checkQuickChecks(value)
        checkRubrics(value)
        checkSources(value)
        checkOrders(value)
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

    /// The field rules as a JSON Schema outline with only `type`, `required`, `properties`, `items` and `enum`.
    /// An optional field also allows `null`. The schema drift test compares this outline with `ManifestSchema` (#112).
    static var schemaOutline: [String: Any] {
        func outline(_ rule: FieldRule, nullable: Bool = false) -> [String: Any] {
            if case .optional(let inner) = rule { return outline(inner, nullable: true) }
            var node: [String: Any] = ["type": nullable ? [rule.type, "null"] : [rule.type]]
            switch rule {
            case .optional: break
            case .choices(let choices): node["enum"] = choices
            case .object(let fields):
                node["properties"] = Dictionary(uniqueKeysWithValues: fields.map { ($0.0, outline($0.1)) })
                node["required"] = fields.compactMap { field -> String? in
                    if case .optional = field.1 { return nil }
                    return field.0
                }.sorted()
            case .array(let item): node["items"] = outline(item)
            case .string, .altText, .integer, .boolean: break
            }
            return node
        }
        return outline(rootRule)
    }

    private static var rootRule: FieldRule {
        let state = FieldRule.choices(["draft", "published"])
        let image = FieldRule.object([("path", .string), ("alt", .altText)])
        let choice = FieldRule.object([("id", .string), ("text", .string)])
        let question = FieldRule.object([
            ("id", .string), ("prompt", .string), ("image", .optional(image)), ("objective_tag", .string),
            ("choices", .array(choice)), ("correct_choice_id", .string), ("explanation", .string),
        ])
        let quickCheck = FieldRule.object([
            ("prompt", .string), ("choices", .array(choice)), ("correct_choice_id", .string), ("explanation", .optional(.string)),
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
                ("quick_checks", .optional(.array(quickCheck))),
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
            ("sources", .optional(.array(.object([
                ("title", .string), ("channel", .string), ("url", .optional(.string)),
                ("timestamp_start", .optional(.integer)), ("timestamp_end", .optional(.integer)),
            ])))),
        ])
        let section = FieldRule.object([
            ("id", .string), ("title", .string), ("objective", .string),
            ("state", state), ("order", .integer), ("header_image", image), ("lectures", .array(lecture)),
        ])
        return .object([
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
            // The app needs content in these lists. Other lists have their own rules below.
            let required = ["learning_outcomes", "requirements", "credits", "sections"].contains(path)
                || path.range(of: #"^sections\[\d+\]\.lectures$"#, options: .regularExpression) != nil
            if required, values.isEmpty { add(path, "must have at least one item") }
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
                guard checkPath(text, path: path) else { break }
                if path.hasSuffix(".video.path"), !text.lowercased().hasSuffix(".mp4") { add(path, "must be an .mp4 file") }
                if path.hasSuffix(".video.captions.path"), !text.lowercased().hasSuffix(".vtt") { add(path, "must be a .vtt file") }
            } else if path == "theme.accent_color", ThemeColor(hex: text) == nil {
                add(path, "must be a hex color such as \"#286644\"")
            }
            // Question, choice and rubric ids are unique inside their quiz, question, quick check or rubric only.
            // `checkQuizzes`, `checkQuickChecks` and `checkRubrics` check them.
            if key == "id", !path.contains(".quiz."), !path.contains(".assignment."), !path.contains(".quick_checks[") {
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
                    checkChoices(question, path: questionPath)
                }
            }
        }
    }

    /// Video quick checks: one or two checks, each with two or more unique choices and a correct choice that exists.
    private mutating func checkQuickChecks(_ root: ManifestValue) {
        guard case .object(let course) = root, case .array(let sections)? = course["sections"] else { return }
        for (sectionIndex, section) in sections.enumerated() {
            guard case .object(let section) = section, case .array(let lectures)? = section["lectures"] else { continue }
            for (lectureIndex, lecture) in lectures.enumerated() {
                guard case .object(let lecture) = lecture, case .object(let video)? = lecture["video"],
                      case .array(let checks)? = video["quick_checks"] else { continue }
                let path = "sections[\(sectionIndex)].lectures[\(lectureIndex)].video.quick_checks"
                if checks.isEmpty { add(path, "must have at least one check") }
                if checks.count > QuickCheck.maximumCount { add(path, "must have at most \(QuickCheck.maximumCount) checks") }
                for (checkIndex, check) in checks.enumerated() {
                    guard case .object(let check) = check else { continue }
                    checkChoices(check, path: "\(path)[\(checkIndex)]")
                }
            }
        }
    }

    /// A quiz question or a quick check has two or more choices with unique ids, and `correct_choice_id` names one.
    private mutating func checkChoices(_ question: [String: ManifestValue], path: String) {
        guard case .array(let choices)? = question["choices"] else { return }
        if choices.count < 2 { add(path + ".choices", "must have at least two choices") }
        var choiceIDs: [String: String] = [:]
        for (choiceIndex, choice) in choices.enumerated() {
            guard case .object(let choice) = choice, case .string(let id)? = choice["id"] else { continue }
            let choicePath = "\(path).choices[\(choiceIndex)].id"
            if let first = choiceIDs[id] { add(choicePath, "duplicate id \"\(id)\" (first used at \(first))") }
            else { choiceIDs[id] = choicePath }
        }
        if case .string(let correct)? = question["correct_choice_id"], choiceIDs[correct] == nil {
            add(path + ".correct_choice_id", "must refer to a choice id in this question")
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

    /// Each source `url` is an http or https URL. Timestamps are 0 or greater, and the end comes after the start.
    private mutating func checkSources(_ root: ManifestValue) {
        guard case .object(let course) = root, case .array(let sections)? = course["sections"] else { return }
        for (sectionIndex, section) in sections.enumerated() {
            guard case .object(let section) = section, case .array(let lectures)? = section["lectures"] else { continue }
            for (lectureIndex, lecture) in lectures.enumerated() {
                guard case .object(let lecture) = lecture, case .array(let sources)? = lecture["sources"] else { continue }
                for (sourceIndex, source) in sources.enumerated() {
                    guard case .object(let source) = source else { continue }
                    let path = "sections[\(sectionIndex)].lectures[\(lectureIndex)].sources[\(sourceIndex)]"
                    if case .string(let text)? = source["url"], !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        if LectureSource.webURL(text) == nil { add(path + ".url", "must be an http or https URL") }
                    }
                    var start: Int?
                    if case .integer(let seconds)? = source["timestamp_start"] {
                        if seconds < 0 { add(path + ".timestamp_start", "must be 0 or greater") } else { start = seconds }
                    }
                    if case .integer(let seconds)? = source["timestamp_end"] {
                        if seconds < 0 { add(path + ".timestamp_end", "must be 0 or greater") }
                        else if let start, seconds <= start { add(path + ".timestamp_end", "must be greater than timestamp_start") }
                    }
                }
            }
        }
    }

    /// Sections, and the lectures of each section, have unique `order` values. Siblings only.
    private mutating func checkOrders(_ root: ManifestValue) {
        func checkSiblings(_ values: [ManifestValue], path: String) {
            var first: [Int: String] = [:]
            for (index, value) in values.enumerated() {
                guard case .object(let object) = value, case .integer(let order)? = object["order"] else { continue }
                let orderPath = "\(path)[\(index)].order"
                if let firstPath = first[order] { add(orderPath, "duplicate order \(order) (first used at \(firstPath))") }
                else { first[order] = orderPath }
            }
        }
        guard case .object(let course) = root, case .array(let sections)? = course["sections"] else { return }
        checkSiblings(sections, path: "sections")
        for (sectionIndex, section) in sections.enumerated() {
            guard case .object(let section) = section, case .array(let lectures)? = section["lectures"] else { continue }
            checkSiblings(lectures, path: "sections[\(sectionIndex)].lectures")
        }
    }

    /// Returns false for a path that is not normalized. Then the caller skips the file type checks.
    private mutating func checkPath(_ text: String, path: String) -> Bool {
        // Treat both separators as boundaries so a manifest is safe across platforms.
        let normalized = text.replacingOccurrences(of: "\\", with: "/")
        let escapes = normalized.hasPrefix("/") || normalized.split(separator: "/").contains("..")
            || normalized.range(of: "^[A-Za-z]:", options: .regularExpression) != nil
            || URL(string: normalized)?.scheme != nil
        if escapes {
            add(path, path.hasPrefix("internal.") ? "path must stay inside internal/" : "path must stay inside the course folder")
            return true
        }
        let parts = normalized.split(separator: "/", omittingEmptySubsequences: false)
        let clean = parts.filter { !$0.isEmpty && $0 != "." }
        // Publish keeps internal/ out of the learner snapshot, so each path belongs to one side only.
        if path.hasPrefix("internal.") {
            if !(clean.first == "internal" && clean.count > 1) {
                add(path, "path must stay inside internal/")
                return true
            }
        } else if let first = clean.first, LectureArticle.isInternalFolder(first) {
            add(path, "path must not be inside internal/")
            return true
        }
        // Publish compares paths as text. So `./`, `//`, a `.` part or a trailing `/` gets this error, not `file does not exist`.
        // A path to the course folder itself, such as ".", keeps the error of its field.
        if !clean.isEmpty, clean.count != parts.count {
            add(path, "path must be normalized: use \"\(clean.joined(separator: "/"))\"")
            return false
        }
        return true
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
