import FTFoundation
import Foundation

/// The text of `app-state.json`: two-space indent, `"key": value`, a newline at the end, keys in a fixed order
/// where one is set (everything else is sorted).
enum AppStateJSON {
    static func serialize(_ state: AppState) throws -> String {
        stringify(try JSONNode.of(state), context: "", indent: "") + "\n"
    }

    // MARK: Key order

    private static let tabKeys = [
        "path", "treeRootPath", "favoritePath", "viewMode", "searchViewMode", "sortBy", "sortDirection",
        "includeHidden", "foldersFirst", "favoritesExpanded", "locationsExpanded", "secondPane", "activePane",
        "paneSplit",
    ]
    private static let windowKeys = ["id", "bounds", "session"]
    private static let columnKeys = ["modified", "size", "kind", "created", "permissions"]

    private static let orders: [String: [String]] = [
        "": ["preferences", "windows", "lastClosedWindow"],
        "preferences": PreferenceKey.allCases.map(\.rawValue),
        "windows": windowKeys,
        "lastClosedWindow": windowKeys,
        "bounds": ["width", "height", "maximized", "x", "y"],
        "session": WindowSession.keys.map(\.rawValue),
        "openTabs": tabKeys,
        "secondPane": [
            "path", "viewMode", "searchViewMode", "sortBy", "sortDirection", "includeHidden", "foldersFirst",
        ],
        "detailColumns": columnKeys,
        "searchColumns": ["folder"] + columnKeys,
        "detailColumnWidths": ["name"] + columnKeys,
        "searchColumnWidths": ["name", "folder"] + columnKeys,
        "compactListWidths": Density.allCases.map(\.rawValue),
        "iconSizes": Density.allCases.map(\.rawValue),
        "previewCounts": Density.allCases.map(\.rawValue),
        "favorites": ["path", "icon"],
        "openWithApplications": ["id", "appPath", "appName"],
        "terminalApp": ["appPath", "appName"],
        "defaultTextEditor": ["appPath", "appName"],
        "batchRenamePresets": ["name", "settings"],
    ]

    // MARK: Writer

    // `context` is the key the value sits under (an array's items have their array's key).
    private static func stringify(_ node: JSONNode, context: String, indent: String) -> String {
        let inner = indent + "  "
        switch node {
        case .null: return "null"
        case .bool(let flag): return flag ? "true" : "false"
        case .number(let value): return number(value)
        case .string(let text): return quoted(text)
        case .array(let items):
            if items.isEmpty { return "[]" }
            let lines = items.map { inner + stringify($0, context: context, indent: inner) }
            return "[\n" + lines.joined(separator: ",\n") + "\n" + indent + "]"
        case .object(let members):
            if members.isEmpty { return "{}" }
            let known = orders[context] ?? []
            let keys = known.filter { members[$0] != nil } + members.keys.filter { !known.contains($0) }.sorted()
            let lines = keys.compactMap { key -> String? in
                guard let value = members[key] else { return nil }
                return inner + quoted(key) + ": " + stringify(value, context: key, indent: inner)
            }
            return "{\n" + lines.joined(separator: ",\n") + "\n" + indent + "}"
        }
    }

    /// A number in the file: whole numbers without a fraction, `-0` as `0`.
    private static func number(_ value: Double) -> String {
        guard value.isFinite else { return "null" }
        if value == value.rounded(), abs(value) < 1e21 {
            return value == 0 ? "0" : String(format: "%.0f", value)
        }
        return "\(value)"
    }

    /// A string as a JSON string literal: in quotes, with quotes, backslashes and control characters escaped.
    private static func quoted(_ text: String) -> String {
        var result = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            case "\u{08}": result += "\\b"
            case "\u{0C}": result += "\\f"
            default:
                if scalar.value < 0x20 {
                    result += String(format: "\\u%04x", scalar.value)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result + "\""
    }
}
