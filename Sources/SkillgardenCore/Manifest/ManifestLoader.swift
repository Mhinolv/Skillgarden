import Foundation
import Yams

public struct ManifestDiagnostic: Equatable, Sendable, CustomStringConvertible {
    public let file: String
    public let fieldPath: String
    public let message: String
    public var description: String { "\(file): \(fieldPath): \(message)" }
}

public struct ManifestValidationError: Error, Sendable, CustomStringConvertible {
    public let diagnostics: [ManifestDiagnostic]
    public var description: String { diagnostics.map(\.description).joined(separator: "\n") }
}

/// Decode into a neutral tree first so validation can report all field errors.
indirect enum ManifestValue: Codable {
    case object([String: ManifestValue]), array([ManifestValue]), string(String)
    case integer(Int), number(Double), bool(Bool), null

    init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int.self) { self = .integer(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([ManifestValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: ManifestValue].self)) }
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .integer(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }

    var type: String {
        switch self {
        case .object: "object"
        case .array: "array"
        case .string: "string"
        case .integer: "integer"
        case .number: "number"
        case .bool: "boolean"
        case .null: "null"
        }
    }
}

public enum ManifestLoader {
    public static func load(courseFolder: URL) throws -> CourseManifest {
        let files = ["skillgarden.yaml", "skillgarden.json"].map { courseFolder.appendingPathComponent($0) }
        let present = files.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard present.count == 1 else {
            let message = present.isEmpty ? "no skillgarden.yaml or skillgarden.json found"
                : "found skillgarden.yaml and skillgarden.json, keep only one"
            throw ManifestValidationError(diagnostics: [ManifestDiagnostic(file: courseFolder.path, fieldPath: "$", message: message)])
        }
        return try load(file: present[0])
    }

    public static func load(file: URL) throws -> CourseManifest {
        let tree: ManifestValue
        let source: String
        do {
            let data = try Data(contentsOf: file)
            source = String(decoding: data, as: UTF8.self)
            if file.pathExtension.lowercased() == "json" {
                tree = try JSONDecoder().decode(ManifestValue.self, from: data)
            } else {
                tree = try YAMLDecoder().decode(ManifestValue.self, from: source)
            }
        } catch {
            throw ManifestValidationError(diagnostics: [ManifestDiagnostic(file: file.path, fieldPath: "$", message: "cannot read or parse manifest")])
        }
        var orders: [String: [String]] = [:]
        if let node = try? compose(yaml: source) { collectOrder(node, path: "$", into: &orders) }
        var validator = ManifestValidator(file: file.path, fieldOrders: orders)
        validator.validate(tree)
        guard validator.errors.isEmpty else { throw ManifestValidationError(diagnostics: validator.errors) }
        return try JSONDecoder().decode(CourseManifest.self, from: JSONEncoder().encode(tree))
    }

    private static func collectOrder(_ node: Node, path: String, into orders: inout [String: [String]]) {
        switch node {
        case .mapping(let mapping):
            orders[path] = mapping.compactMap { $0.key.string }
            for pair in mapping {
                guard let key = pair.key.string else { continue }
                collectOrder(pair.value, path: path == "$" ? key : "\(path).\(key)", into: &orders)
            }
        case .sequence(let sequence):
            for (index, child) in sequence.enumerated() {
                collectOrder(child, path: "\(path)[\(index)]", into: &orders)
            }
        default: break
        }
    }

}
