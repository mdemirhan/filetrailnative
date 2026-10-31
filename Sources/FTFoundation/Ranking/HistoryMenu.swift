// Port of apps/desktop/src/renderer/lib/historyMenu.ts
import Foundation

public struct HistoryMenuEntry: Equatable, Sendable {
    /// Position in the history list, to jump to.
    public var index: Int
    public var path: String
    /// The folder's name, as the sidebar would show it.
    public var label: String
    /// The folder that contains it, with the home folder as "~".
    public var detail: String
}

/// The folders offered when Back or Forward is held: where each step in that direction leads, nearest
/// first.
public enum HistoryMenu {
    public static let limit = 12

    public static func backEntries(historyPaths: [String], historyIndex: Int, homePath: String) -> [HistoryMenuEntry] {
        var entries: [HistoryMenuEntry] = []
        var index = historyIndex - 1
        while index >= 0, entries.count < limit {
            entries.append(entry(path: path(in: historyPaths, at: index), index: index, homePath: homePath))
            index -= 1
        }
        return entries
    }

    public static func forwardEntries(historyPaths: [String], historyIndex: Int, homePath: String) -> [HistoryMenuEntry]
    {
        var entries: [HistoryMenuEntry] = []
        var index = max(0, historyIndex + 1)
        while index < historyPaths.count, entries.count < limit {
            entries.append(entry(path: path(in: historyPaths, at: index), index: index, homePath: homePath))
            index += 1
        }
        return entries
    }

    private static func path(in paths: [String], at index: Int) -> String {
        index < paths.count ? paths[index] : ""
    }

    private static func entry(path: String, index: Int, homePath: String) -> HistoryMenuEntry {
        let units = Array(path.utf16)
        let parentPath = JSString.string(units[..<min(units.count, max(1, units.lastIndex(of: 0x2F) ?? -1))])
        return HistoryMenuEntry(
            index: index,
            path: path,
            label: FavoriteLabel.label(for: path, homePath: homePath),
            detail: JSString.equals(path, "/") ? "" : Places.abbreviate(parentPath, homePath: homePath))
    }
}
