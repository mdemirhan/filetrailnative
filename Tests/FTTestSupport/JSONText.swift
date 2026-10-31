// JSON text exactly as JavaScript's `JSON.stringify(value, null, 2)` writes it, so a Swift tool and a
// Bun tool can produce byte-identical files (Foundation's JSONEncoder spaces and escapes differently).

public enum JSONText: Sendable {
    /// A JSON value; an object keeps its keys in the order given, as a JavaScript object does.
    public indirect enum Value: Sendable, Equatable {
        case null
        case bool(Bool)
        case int(Int)
        case string(String)
        case array([Value])
        case object([Member])
    }

    public struct Member: Sendable, Equatable {
        public let key: String
        public let value: Value

        public init(_ key: String, _ value: Value) {
            self.key = key
            self.value = value
        }
    }

    public static func stringify(_ value: Value, indent: String = "") -> String {
        let inner = indent + "  "
        switch value {
        case .null:
            return "null"
        case .bool(let flag):
            return flag ? "true" : "false"
        case .int(let number):
            return String(number)
        case .string(let text):
            return quote(text)
        case .array(let items):
            if items.isEmpty {
                return "[]"
            }
            let body = items.map { inner + stringify($0, indent: inner) }.joined(separator: ",\n")
            return "[\n\(body)\n\(indent)]"
        case .object(let members):
            if members.isEmpty {
                return "{}"
            }
            let body = members.map { inner + quote($0.key) + ": " + stringify($0.value, indent: inner) }
                .joined(separator: ",\n")
            return "{\n\(body)\n\(indent)}"
        }
    }

    /// JSON.stringify's escaping: quote, backslash and control characters only; the rest is written as is.
    public static func quote(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case let control where control.value < 0x20:
                let hex = String(control.value, radix: 16)
                out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }
}
