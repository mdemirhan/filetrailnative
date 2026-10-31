// Port of the state and the key rules of apps/desktop/src/renderer/components/GoToFolderDialog.tsx
import Foundation

/// One row of the Go To list: a folder to go to, however it was found (`GoToRow`).
public struct GoToRow: Equatable, Sendable {
    public var path: String
    public var name: String
    /// Where it is, beside the name: a place's folder, a completion's whole path.
    public var detail: String
    /// UTF-16 ranges of the name the typed letters matched.
    public var nameRanges: [Range<Int>]
    public var isFavorite: Bool
    /// Whether ⌘⌫ can take it out of the list of opened folders.
    public var canForget: Bool

    public init(
        path: String, name: String, detail: String, nameRanges: [Range<Int>], isFavorite: Bool, canForget: Bool
    ) {
        self.path = path
        self.name = name
        self.detail = detail
        self.nameRanges = nameRanges
        self.isFavorite = isFavorite
        self.canForget = canForget
    }
}

/// A folder the disk offers to complete a typed path with.
public struct GoToCompletion: Equatable, Sendable {
    public var path: String
    public var name: String

    public init(path: String, name: String) {
        self.path = path
        self.name = name
    }
}

/// What the box asks of its owner after a key or a click.
public enum GoToEffect: Equatable, Sendable {
    case none
    /// The field holds new text, and completions are asked for it.
    case requestCompletions(String)
    /// The folder to go to (or move into).
    case submit(String)
    /// The opened folder to forget.
    case forget(String)
}

/// The Go To box (⌘K, ⇧⌘G) and the Move To box: what is typed, what is listed and selected, and what the keys do. A
/// few letters find a folder that has been opened before, or a favorite; text starting with "/" or "~" is a path and
/// is completed folder by folder.
public struct GoToBoxState: Equatable, Sendable {
    /// The opened folders and favorites to find by name, as the box opened.
    public private(set) var places: [Place]
    /// Whether the top place is selected before anything is typed (Go To), so Return goes there at once. Off for Move
    /// To, where Return must never act on a folder nobody chose.
    public let selectFirstPlace: Bool
    /// Whether ⌘⌫ forgets a folder (`onForgetPlace`).
    public let canForgetPlaces: Bool
    public private(set) var text = ""
    public private(set) var completions: [GoToCompletion] = []
    public private(set) var rows: [GoToRow] = []
    /// The selected row; -1 for none.
    public private(set) var selectedIndex = -1
    public var submitting = false
    public var error: String?
    /// The pointer's last place over the list (`lastPointerRef`): a row is selected only once it really moved.
    public var lastPointer: CGPoint?

    public init(places: [Place], selectFirstPlace: Bool = true, canForgetPlaces: Bool = true) {
        self.places = places
        self.selectFirstPlace = selectFirstPlace
        self.canForgetPlaces = canForgetPlaces
        rebuild(reselect: true)
    }

    public var isPathMode: Bool { Places.isPathQuery(text) }
    public var trimmedText: String { JSString.trimmed(text) }
    /// `trim()`, as the box trims what it submits.
    public static func trim(_ text: String) -> String { JSString.trimmed(text) }
    public var hasQuery: Bool { !trimmedText.isEmpty }
    public var selectedRow: GoToRow? { rows.indices.contains(selectedIndex) ? rows[selectedIndex] : nil }

    /// A name needs a folder picked from the list; a path can be opened as typed.
    public var canSubmit: Bool {
        !submitting && (isPathMode ? hasQuery : selectedRow != nil)
    }

    /// What Open (or Move) goes to: the trimmed path, or the selected place.
    public var submitValue: String? {
        guard canSubmit else { return nil }
        return isPathMode ? JSString.trimmed(text) : selectedRow?.path
    }

    /// The list's heading, while it lists something.
    public var label: String {
        guard isPathMode || hasQuery else { return "Recent and favorite folders" }
        return "\(rows.count) match\(rows.count == 1 ? "" : "es")"
    }

    /// The keys easy to miss: Tab completes a path, ⌘⌫ forgets a folder.
    public var hint: String? {
        if isPathMode { return "⇥ Completes" }
        return canForgetPlaces && selectedRow?.canForget == true ? "⌘⌫ Removes from List" : nil
    }

    /// What shows instead of the list when it is empty.
    public var emptyText: String {
        if isPathMode { return "No folders match this path" }
        return hasQuery
            ? "No folder you have opened has that name. Start with / or ~ to type a path."
            : "Folders you open are listed here. Start with / or ~ to type a path."
    }

    /// Whether the field shows its ✕.
    public var showsClear: Bool { !text.isEmpty }

    // MARK: Changes

    /// What is typed changed (`setValue`): the completions go at once; a path asks for new ones.
    public mutating func setText(_ value: String) -> GoToEffect {
        text = value
        completions = []
        rebuild(reselect: true)
        return Places.isPathQuery(value) ? .requestCompletions(value) : .none
    }

    /// The ✕: the field empties and the completions go, and nothing is asked.
    public mutating func clear() {
        text = ""
        completions = []
        rebuild(reselect: true)
    }

    /// The disk answered for the text in the field.
    public mutating func setCompletions(_ completions: [GoToCompletion]) {
        self.completions = completions
        rebuild(reselect: false)
    }

    /// A folder was forgotten: it leaves the list at once.
    public mutating func forgetPlace(_ path: String) {
        places.removeAll { $0.path == path }
        rebuild(reselect: false)
    }

    /// The places read again (a folder forgotten from the store): the list follows at once.
    public mutating func setPlaces(_ places: [Place]) {
        self.places = places
        rebuild(reselect: false)
    }

    private mutating func rebuild(reselect: Bool) {
        let before = rows.count
        if isPathMode {
            rows = completions.map {
                GoToRow(
                    path: $0.path, name: $0.name, detail: $0.path, nameRanges: [], isFavorite: false, canForget: false)
            }
        } else {
            rows = Places.rank(places, query: text).map { match in
                GoToRow(
                    path: match.place.path, name: match.place.name,
                    detail: Places.describeLocation(name: match.place.name, displayPath: match.place.displayPath),
                    nameRanges: match.nameRanges, isFavorite: match.place.isFavorite,
                    canForget: match.place.isVisited)
            }
        }
        // What is typed decides what is selected: the best place while a name is typed (and before, for Go To),
        // nothing while a path is typed until ↓ picks a completion. Re-evaluated when the text, the mode or the
        // number of rows changes, not on every selection move.
        guard reselect || rows.count != before else { return }
        if rows.isEmpty || isPathMode {
            selectedIndex = -1
        } else {
            selectedIndex = hasQuery || selectFirstPlace ? 0 : -1
        }
    }

    // MARK: Keys

    /// ↓ (`step` 1) and ↑ (-1): from no selection to the first or the last row; otherwise one row, stopping at the
    /// ends.
    public mutating func moveSelection(_ step: Int) {
        guard !rows.isEmpty else { return }
        if selectedIndex < 0 {
            selectedIndex = step == 1 ? 0 : rows.count - 1
        } else {
            selectedIndex = max(0, min(rows.count - 1, selectedIndex + step))
        }
    }

    /// Tab: in path mode with a row, completes with the selected row (or the first) and descends into it. Nil when
    /// Tab is left to move the focus.
    public mutating func tab() -> GoToEffect? {
        guard isPathMode, let row = selectedRow ?? rows.first else { return nil }
        return acceptCompletion(row, descend: true)
    }

    /// Return: in path mode a selected completion goes into the field first; otherwise what can be submitted is.
    public mutating func pressReturn() -> GoToEffect {
        if isPathMode, let row = selectedRow, row.path != JSString.trimmed(text) {
            return acceptCompletion(row, descend: false)
        }
        return submitValue.map(GoToEffect.submit) ?? .none
    }

    /// ⌘⌫: the selected opened folder is forgotten. Nil when the key is left to the field.
    public func forgetKey() -> GoToEffect? {
        guard !isPathMode, canForgetPlaces, let row = selectedRow, row.canForget else { return nil }
        return .forget(row.path)
    }

    /// A click on a row: a completion goes into the field, a place is gone to at once.
    public mutating func click(_ index: Int) -> GoToEffect {
        guard rows.indices.contains(index) else { return .none }
        let row = rows[index]
        guard isPathMode else { return .submit(row.path) }
        let effect = acceptCompletion(row, descend: false)
        // `setSelectedIndex(index)` follows, but the text changed in path mode, so the selection is none again.
        return effect
    }

    /// The pointer moved over row `index`: it selects the row only when it really moved since the last time.
    public mutating func pointerMoved(over index: Int, at point: CGPoint) {
        let last = lastPointer
        lastPointer = point
        if let last, last != point, rows.indices.contains(index) {
            selectedIndex = index
        }
    }

    /// Puts a completion into the field. With `descend` the path ends in a slash, so the list moves on to the folders
    /// inside it (Tab); without, the folder itself stays listed.
    private mutating func acceptCompletion(_ row: GoToRow, descend: Bool) -> GoToEffect {
        let value = descend && !row.path.hasSuffix("/") ? row.path + "/" : row.path
        _ = setText(value)
        return .requestCompletions(value)
    }
}
