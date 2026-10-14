// Port of formatArgs of apps/desktop/src/main/appLog.ts (strings raw, errors, `util.inspect` of the rest)
import FTFoundation
import Foundation

/// One argument of a log line.
public enum LogArg: Sendable, ExpressibleByStringLiteral {
    case text(String)
    case error(any Error)
    /// Any other value, written as `util.inspect` writes it.
    case value(JSONNode)

    public init(stringLiteral value: String) {
        self = .text(value)
    }

    /// A dictionary of values, as an object.
    public static func context(_ members: [String: JSONNode]) -> LogArg {
        .value(.object(members))
    }
}

public enum LogFormat {
    /// `toISOString`: `2026-10-14T09:30:00.123Z`.
    public static func timestamp(_ date: Date) -> String {
        let milliseconds = Int((date.timeIntervalSince1970 * 1000).rounded(.down))
        let seconds = Int(floor(Double(milliseconds) / 1000))
        let fraction = milliseconds - seconds * 1000
        var time = time_t(seconds)
        var parts = tm()
        gmtime_r(&time, &parts)
        return String(
            format: "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ", Int(parts.tm_year) + 1900, Int(parts.tm_mon) + 1,
            Int(parts.tm_mday), Int(parts.tm_hour), Int(parts.tm_min), Int(parts.tm_sec), fraction)
    }

    /// `<ISO time> <LEVEL> <args…>`, without the newline.
    public static func line(_ level: LogLevel, _ args: [LogArg], at date: Date) -> String {
        "\(timestamp(date)) \(level.rawValue.uppercased()) \(arguments(args))"
    }

    /// `formatArgs`: the arguments joined by a space.
    public static func arguments(_ args: [LogArg]) -> String {
        args.map(format).joined(separator: " ")
    }

    private static func format(_ arg: LogArg) -> String {
        switch arg {
        case .text(let text): return text
        case .error(let error): return describe(error)
        case .value(.string(let text)): return text
        case .value(let node): return inspect(node, depth: 0)
        }
    }

    /// An error as `Name: message` (the original writes its stack, which has no counterpart here).
    static func describe(_ error: any Error) -> String {
        let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        return "\(String(describing: type(of: error))): \(message)"
    }

    // MARK: util.inspect

    // `util.inspect(value, { depth: 8, breakLength: Infinity, compact: true, sorted: true })`.
    private static let maxDepth = 8

    static func inspect(_ node: JSONNode, depth: Int) -> String {
        switch node {
        case .null: return "null"
        case .bool(let flag): return flag ? "true" : "false"
        case .number(let number): return inspectNumber(number)
        case .string(let text): return quote(text)
        case .array(let items):
            if items.isEmpty { return "[]" }
            if depth > maxDepth { return "[Array]" }
            return "[ " + items.map { inspect($0, depth: depth + 1) }.joined(separator: ", ") + " ]"
        case .object(let members):
            if members.isEmpty { return "{}" }
            if depth > maxDepth { return "[Object]" }
            // Node sorts the rendered `key: value` strings by UTF-16 code unit, not the raw keys.
            let entries = members.map { "\(inspectKey($0.key)): \(inspect($0.value, depth: depth + 1))" }
                .sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) }
            return "{ " + entries.joined(separator: ", ") + " }"
        }
    }

    private static func inspectNumber(_ value: Double) -> String {
        if value.isNaN { return "NaN" }
        if value.isInfinite { return value < 0 ? "-Infinity" : "Infinity" }
        if value == 0 { return value.sign == .minus ? "-0" : "0" }
        if value == value.rounded(), abs(value) < 1e21 { return String(format: "%.0f", value) }
        return "\(value)"
    }

    // Bare only when it matches /^[a-zA-Z_][a-zA-Z_0-9]*$/.
    private static func inspectKey(_ key: String) -> String {
        let bytes = Array(key.utf8)
        func isLetter(_ byte: UInt8) -> Bool {
            (65...90).contains(byte) || (97...122).contains(byte) || byte == 95
        }
        let identifier =
            bytes.first.map(isLetter) ?? false
            && bytes.allSatisfy { isLetter($0) || (48...57).contains($0) }
        return identifier ? key : quote(key)
    }

    // Single quotes, unless the text holds one and no double quote (then double), or both (then backticks).
    private static func quote(_ text: String) -> String {
        var mark: Character = "'"
        if text.contains("'") {
            if !text.contains("\"") {
                mark = "\""
            } else if !text.contains("`") && !text.contains("${") {
                mark = "`"
            }
        }
        var result = String(mark)
        for character in text {
            switch character {
            case mark: result += "\\\(mark)"
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\t": result += "\\t"
            case "\r": result += "\\r"
            default: result.append(character)
            }
        }
        result.append(mark)
        return result
    }
}
