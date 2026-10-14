// Port of `JSON.stringify(state, null, 2)` as appStateStore.ts writes app-state.json (key order of its object literals)
import FTFoundation
import Foundation

/// The text of `app-state.json`: two-space indent, `"key": value`, a newline at the end, keys in the order the original
/// writes them where that order is known (everything else is sorted).
enum AppStateJSON {
    static func serialize(_ state: AppState) throws -> String {
        stringify(try JSONNode.of(state), context: "", indent: "") + "\n"
    }

    // MARK: Key order

    private static let tabKeys = [
        "path", "treeRootPath", "favoritePath", "viewMode", "searchViewMode", "sortBy", "sortDirection",
        "includeHidden", "foldersFirst", "favoritesExpanded", "locationsExpanded",
    ]
    private static let windowKeys = ["id", "bounds", "session"]
    private static let columnKeys = ["modified", "size", "kind", "created", "permissions"]

    /// `sanitizePreferences`' object literal.
    private static let preferenceKeys = [
        "theme", "accent", "zoomPercent", "viewMode", "searchViewMode", "sortBy", "sortDirection", "foldersFirst",
        "compactListView", "compactDetailsView", "compactIconView", "compactTreeView", "detailColumns",
        "detailColumnOrder", "detailColumnWidths", "searchColumns", "searchColumnOrder", "searchColumnWidths",
        "notificationsEnabled", "markClipboardItems", "autoCalculateFolderSizes", "folderTreeOpen", "propertiesOpen",
        "detailRowOpen", "topToolbarItems", "terminalApp", "defaultTextEditor", "openWithApplications",
        "fileActivationAction", "diskImageOpensIn", "returnKeyAction", "shortcutOverrides", "openItemLimit",
        "includeHidden", "searchPatternMode", "searchMatchScope", "searchRecursive", "searchSkipGitFolders",
        "searchSkipGitIgnored", "searchResultsSortBy", "searchResultsSortDirection", "treeWidth", "inspectorWidth",
        "restoreSessionOnStartup", "openTabs", "activeTabIndex", "treeRootPath", "lastVisitedPath",
        "lastVisitedFavoritePath", "favorites", "favoritesPlacement", "favoritesExpanded", "locationsExpanded",
        "favoritesInitialized", "singleClickExpandTreeItems", "batchRenameSettings", "batchRenamePresets",
    ]

    private static let orders: [String: [String]] = [
        "": ["preferences", "windows", "lastClosedWindow"],
        "preferences": preferenceKeys,
        "windows": windowKeys,
        "lastClosedWindow": windowKeys,
        "bounds": ["width", "height", "maximized", "x", "y"],
        "session": WindowSessionKeys.all,
        "openTabs": tabKeys,
        "detailColumns": columnKeys,
        "searchColumns": ["folder"] + columnKeys,
        "detailColumnWidths": ["name"] + columnKeys,
        "searchColumnWidths": ["name", "folder"] + columnKeys,
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

    /// A number as JavaScript writes it: whole numbers without a fraction, `-0` as `0`.
    private static func number(_ value: Double) -> String {
        guard value.isFinite else { return "null" }
        if value == value.rounded(), abs(value) < 1e21 {
            return value == 0 ? "0" : String(format: "%.0f", value)
        }
        return "\(value)"
    }

    /// A string as `JSON.stringify` quotes it.
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
