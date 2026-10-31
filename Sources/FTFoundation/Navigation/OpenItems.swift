// Port of activateContentPaths, openPaths, editPaths and openEntry of apps/desktop/src/renderer/hooks/useExplorerActions.ts
// (:3229-3343, 4340-4358) and createOpenItemLimitMessage of lib/explorerAppUtils.ts
import Foundation

/// What opening the items of the file list comes to (B-SEL-106 to B-SEL-111, B-NAV-064 to B-NAV-073).
public enum OpenItems {
    public enum Action: String, Sendable {
        case open = "Open"
        case edit = "Edit"
    }

    /// One thing done to an item.
    public enum Step: Equatable, Sendable {
        /// A folder: opened in place (a push of the tab's history).
        case navigate(String)
        /// A link to a folder: its target is looked up, and opened in place unless another tab came to the front.
        case resolveThenNavigate(String)
        /// A link to a file: its target opens in its app.
        case resolveThenOpen(String)
        /// An app or package, a file, or anything else: the system opens it.
        case openExternally(String)
    }

    public enum Plan: Equatable, Sendable {
        case nothing
        /// More items than "open at most N items" allows: a notice, and nothing opens.
        case tooMany(action: Action, selected: Int, limit: Int)
        /// Every item is an editable file and Settings says files are edited: they open in the text editor.
        case edit([String])
        /// The items, one after another in list order.
        case steps([Step])
    }

    /// `createOpenItemLimitMessage`.
    public static func limitMessage(action: Action, selected: Int, limit: Int) -> String {
        let verb = action == .open ? "opens" : "edits"
        return
            "File Trail \(verb) up to \(limit) item\(limit == 1 ? "" : "s") at a time, and \(selected) are selected. You can change this in Settings."
    }

    /// The notice's title (`showOpenItemLimitNotice`).
    public static func limitTitle(action: Action) -> String { "Too Many Items to \(action.rawValue)" }

    /// `activateContentPaths`: double-click, Return (set to Open) and ⌘↓ on the selected items, in list order.
    public static func activation(
        _ items: [CommandEntry], fileActivation: FileActivationAction, limit: Int
    ) -> Plan {
        guard !items.isEmpty else { return .nothing }
        if fileActivation == .edit, items.allSatisfy({ $0.kind.isEditableFile }) {
            return editPlan(items.map(\.path), limit: limit)
        }
        return openPlan(items, limit: limit)
    }

    /// `editPaths`.
    public static func editPlan(_ paths: [String], limit: Int) -> Plan {
        guard !paths.isEmpty else { return .nothing }
        if paths.count > limit { return .tooMany(action: .edit, selected: paths.count, limit: limit) }
        return .edit(paths)
    }

    /// `openPaths`: only a single selected item goes through the logic of what it is; several are each handed to the
    /// system, folders included.
    public static func openPlan(_ items: [CommandEntry], limit: Int) -> Plan {
        guard !items.isEmpty else { return .nothing }
        if items.count > limit { return .tooMany(action: .open, selected: items.count, limit: limit) }
        if items.count == 1 { return .steps([step(for: items[0])]) }
        return .steps(items.map { .openExternally($0.path) })
    }

    /// `openEntry`.
    public static func step(for item: CommandEntry) -> Step {
        switch item.kind {
        case .directory: .navigate(item.path)
        case .symlinkDirectory: .resolveThenNavigate(item.path)
        case .symlinkFile: .resolveThenOpen(item.path)
        case .bundle, .file, .other: .openExternally(item.path)
        }
    }
}
