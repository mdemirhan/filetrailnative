// Holds what the original's `unknown` holds: a value read from JSON whose shape the sanitizers check.
import Foundation

/// Any JSON value. The sanitizers of the saved state and of the shortcut overrides take one, as the
/// original's take `unknown`, and decide field by field what they keep.
public indirect enum JSONNode: Sendable, Equatable, Codable {
    case null
    case bool(Bool)
    /// JavaScript's only number type; an integer is a number with no fraction.
    case number(Double)
    case string(String)
    case array([JSONNode])
    case object([String: JSONNode])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let flag = try? container.decode(Bool.self) {
            self = .bool(flag)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let text = try? container.decode(String.self) {
            self = .string(text)
        } else if let items = try? container.decode([JSONNode].self) {
            self = .array(items)
        } else {
            self = .object(try container.decode([String: JSONNode].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let flag): try container.encode(flag)
        case .number(let number): try container.encode(number)
        case .string(let text): try container.encode(text)
        case .array(let items): try container.encode(items)
        case .object(let members): try container.encode(members)
        }
    }

    /// `JSON.parse`.
    public static func parse(_ data: Data) throws -> JSONNode {
        try JSONDecoder().decode(JSONNode.self, from: data)
    }

    /// Any Encodable value, as the JSON it writes.
    public static func of(_ value: some Encodable) throws -> JSONNode {
        try parse(JSONEncoder().encode(value))
    }

    /// Decodes this value as `type`.
    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: JSONEncoder().encode(self))
    }

    // MARK: JavaScript's checks

    /// `isPlainObject`: an object that is not an array, and not null.
    public var object: [String: JSONNode]? {
        if case .object(let members) = self { members } else { nil }
    }

    /// `Array.isArray`.
    public var array: [JSONNode]? {
        if case .array(let items) = self { items } else { nil }
    }

    /// `typeof value === "string"`.
    public var string: String? {
        if case .string(let text) = self { text } else { nil }
    }

    /// `typeof value === "number"`.
    public var number: Double? {
        if case .number(let number) = self { number } else { nil }
    }

    /// `typeof value === "boolean"`.
    public var bool: Bool? {
        if case .bool(let flag) = self { flag } else { nil }
    }

    /// `Number.isInteger(value)` for a number.
    public var integer: Double? {
        if case .number(let number) = self, number.isFinite, number == number.rounded(.towardZero) {
            number
        } else {
            nil
        }
    }

    public var isNull: Bool {
        if case .null = self { true } else { false }
    }

    public subscript(key: String) -> JSONNode? {
        object?[key]
    }
}

/// `Math.round`: halves go up.
func jsRound(_ value: Double) -> Double {
    guard value.isFinite else { return value }
    // Exact for every value in the ranges the preferences use; larger ones are whole numbers already.
    if abs(value) >= 4_503_599_627_370_496 { return value }
    return (value + 0.5).rounded(.down)
}

/// `Math.round(Math.max(min, Math.min(max, value)))`.
func clampRounded(_ value: Double, _ lower: Double, _ upper: Double) -> Int {
    Int(jsRound(max(lower, min(upper, value))))
}
