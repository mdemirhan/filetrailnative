import Foundation

/// What opening the items of the file list comes to.
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
        /// Archives: File Trail takes them apart, all in one run, rather than handing them to Archive Utility.
        case extract([String])
    }

    public enum Plan: Equatable, Sendable {
        case nothing
        /// More items than "open at most N items" allows: a notice, and nothing opens.
        case tooMany(action: Action, selected: Int, limit: Int)
        /// Edit (⇧⌘E): the files open in the text editor.
        case edit([String])
        /// The items, one after another in list order.
        case steps([Step])
    }

    public static func limitMessage(action: Action, selected: Int, limit: Int) -> String {
        let verb = action == .open ? "opens" : "edits"
        return
            "File Trail \(verb) up to \(limit) item\(limit == 1 ? "" : "s") at a time, and \(selected) are selected. You can change this in Settings."
    }

    /// The notice's title.
    public static func limitTitle(action: Action) -> String { "Too Many Items to \(action.rawValue)" }

    /// The files open in the text editor, unless there are more than `limit`.
    public static func editPlan(_ paths: [String], limit: Int) -> Plan {
        guard !paths.isEmpty else { return .nothing }
        if paths.count > limit { return .tooMany(action: .edit, selected: paths.count, limit: limit) }
        return .edit(paths)
    }

    /// Double-click, Return (set to Open), ⌘↓ and Open, on the selected items in list order. Only a single selected
    /// item is opened by what it is; of several, the archives are extracted together and the rest are each handed to
    /// the system, folders included.
    public static func openPlan(_ items: [CommandEntry], limit: Int) -> Plan {
        guard !items.isEmpty else { return .nothing }
        if items.count > limit { return .tooMany(action: .open, selected: items.count, limit: limit) }
        if items.count == 1 { return .steps([step(for: items[0])]) }
        let archives = items.filter(isArchive).map(\.path)
        let others: [Step] = items.filter { !isArchive($0) }.map { .openExternally($0.path) }
        return .steps(others + (archives.isEmpty ? [] : [.extract(archives)]))
    }

    /// What opening one item does: a folder opens in place, a link is followed first, an archive is extracted,
    /// anything else the system opens.
    public static func step(for item: CommandEntry) -> Step {
        if isArchive(item) { return .extract([item.path]) }
        switch item.kind {
        case .directory: return .navigate(item.path)
        case .symlinkDirectory: return .resolveThenNavigate(item.path)
        case .symlinkFile: return .resolveThenOpen(item.path)
        case .bundle, .file, .other: return .openExternally(item.path)
        }
    }

    /// A file whose name is an archive's Extract takes apart. A link to one is followed first, and its target
    /// extracted then.
    static func isArchive(_ item: CommandEntry) -> Bool {
        item.kind == .file && ArchiveNames.isArchive(NodePath.basename(item.path))
    }
}
