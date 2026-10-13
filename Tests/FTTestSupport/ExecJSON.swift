// Any JSON value, for the parts of an execution outcome the engine shapes (events, results, undo
// logs, journals), and a comparison of two that names the first places they differ.
import Foundation

public indirect enum JSONValue: Sendable, Codable, CustomStringConvertible {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    /// Keys in no particular order: rendering and walking sort them.
    case object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let flag = try? container.decode(Bool.self) {
            self = .bool(flag)
        } else if let number = try? container.decode(Int.self) {
            self = .int(number)
        } else if let number = try? container.decode(Double.self) {
            self = .double(number)
        } else if let text = try? container.decode(String.self) {
            self = .string(text)
        } else if let items = try? container.decode([JSONValue].self) {
            self = .array(items)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let flag): try container.encode(flag)
        case .int(let number): try container.encode(number)
        case .double(let number): try container.encode(number)
        case .string(let text): try container.encode(text)
        case .array(let items): try container.encode(items)
        case .object(let members): try container.encode(members)
        }
    }

    /// Parses JSON text.
    public static func parse(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Any Encodable value as JSON.
    public static func of(_ value: some Encodable) throws -> JSONValue {
        try parse(JSONEncoder().encode(value))
    }

    /// Decodes this value as `type`.
    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: JSONEncoder().encode(self))
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let members) = self { members[key] } else { nil }
    }

    public var stringValue: String? {
        if case .string(let text) = self { text } else { nil }
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let items) = self { items } else { nil }
    }

    /// Compact JSON with keys sorted as JavaScript sorts strings.
    public var description: String {
        switch self {
        case .null: return "null"
        case .bool(let flag): return flag ? "true" : "false"
        case .int(let number): return String(number)
        case .double(let number):
            return number.rounded() == number && abs(number) < 1e15 ? String(Int(number)) : String(number)
        case .string(let text): return JSONText.quote(text)
        case .array(let items): return "[" + items.map(\.description).joined(separator: ",") + "]"
        case .object(let members):
            let body = JSONValue.sortedKeys(members).map { JSONText.quote($0) + ":" + (members[$0]?.description ?? "null") }
            return "{" + body.joined(separator: ",") + "}"
        }
    }

    /// Keys in JavaScript's default order (UTF-16 code units).
    public static func sortedKeys(_ members: [String: JSONValue]) -> [String] {
        members.keys.sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) }
    }
}

extension JSONValue: Equatable {
    /// Strings compare scalar for scalar: NFC and NFD names are different names on disk.
    public static func == (lhs: JSONValue, rhs: JSONValue) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): return true
        case (.bool(let a), .bool(let b)): return a == b
        case (.int(let a), .int(let b)): return a == b
        case (.double(let a), .double(let b)): return a == b
        case (.int(let a), .double(let b)), (.double(let b), .int(let a)): return Double(a) == b
        case (.string(let a), .string(let b)): return a.unicodeScalars.elementsEqual(b.unicodeScalars)
        case (.array(let a), .array(let b)): return a == b
        case (.object(let a), .object(let b)):
            return a.count == b.count && a.allSatisfy { key, value in b[key].map { $0 == value } ?? false }
        default: return false
        }
    }
}

/// Where two JSON values differ, compactly: one line per difference, as a path and both values.
public enum ExecDiff {
    public static func differences(expected: JSONValue, actual: JSONValue, limit: Int = 10) -> [String] {
        var lines: [String] = []
        walk(expected, actual, path: "", limit: limit, into: &lines)
        return lines
    }

    private static func walk(_ expected: JSONValue, _ actual: JSONValue, path: String, limit: Int, into lines: inout [String]) {
        guard lines.count < limit, expected != actual else { return }
        switch (expected, actual) {
        case (.array(let a), .array(let b)):
            for index in 0..<min(a.count, b.count) {
                walk(a[index], b[index], path: "\(path)[\(index)]", limit: limit, into: &lines)
            }
            if a.count != b.count && lines.count < limit {
                let extra = a.count > b.count ? "missing \(short(a[b.count]))" : "extra \(short(b[a.count]))"
                lines.append("\(path): expected \(a.count) items, got \(b.count); first \(extra)")
            }
        case (.object(let a), .object(let b)):
            let keys = Set(a.keys).union(b.keys).sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) }
            for key in keys {
                let child = path.isEmpty ? key : "\(path).\(key)"
                switch (a[key], b[key]) {
                case (let x?, let y?): walk(x, y, path: child, limit: limit, into: &lines)
                case (let x?, nil) where lines.count < limit: lines.append("\(child): expected \(short(x)), missing")
                case (nil, let y?) where lines.count < limit: lines.append("\(child): unexpected \(short(y))")
                default: break
                }
            }
        default:
            lines.append("\(path.isEmpty ? "(root)" : path): expected \(short(expected)), got \(short(actual))")
        }
    }

    private static func short(_ value: JSONValue) -> String {
        let text = value.description
        return text.count > 160 ? String(text.prefix(157)) + "..." : text
    }
}
