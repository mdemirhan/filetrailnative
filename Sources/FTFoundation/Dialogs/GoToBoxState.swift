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

/// What a Go To box is for.
public enum GoToPurpose: Equatable, Sendable {
    /// Go To (⌘K, ⇧⌘G): going to a folder is quick and Back undoes it, so the best place is selected before anything
    /// is typed and a click goes at once.
    case goTo
    /// Move To and Extract To: a folder for items to go into. Nothing is chosen for the user, and a click only puts a
    /// folder in the field; a double click, or Return, sends the items there.
    case chooseFolder
}

/// The Go To box (⌘K, ⇧⌘G), the Move To box and the Extract To box: what is typed, what is listed and selected, and
/// what the keys do. A few letters find a folder that has been opened before, or a favorite; text starting with "/",
/// "~", "./" or "../" is a path and is completed folder by folder. ↑ and ↓ show the selected folder's path in the
/// field, and typing goes on from it.
public struct GoToBoxState: Equatable, Sendable {
    /// The opened folders and favorites to find by name, as the box opened.
    public private(set) var places: [Place]
    public let purpose: GoToPurpose
    /// Whether ⌘⌫ forgets a folder.
    public let canForgetPlaces: Bool
    /// The home folder, written "~" in a path the field takes from a row.
    public let homePath: String
    /// What the field shows.
    public private(set) var text = ""
    /// What the list was made for: what was typed. It differs from `text` while a row is shown in the field.
    public private(set) var listText = ""
    /// Whether the field shows the selected row's path, put there by ↑ or ↓ (or a click, when choosing a folder),
    /// rather than what was typed. The list stays as it was until something is typed.
    public private(set) var isShowingRow = false
    public private(set) var completions: [GoToCompletion] = []
    public private(set) var rows: [GoToRow] = []
    /// The selected row; -1 for none.
    public private(set) var selectedIndex = -1
    public var submitting = false
    public var error: String?
    /// The folder that doesn't exist yet and is made before the items go into it, once asked (`offerToCreate`):
    /// the text it was asked for, and what is said under the field.
    public private(set) var folderToCreate: (text: String, notice: String)?
    /// The pointer's last place over the list: a row is selected only once it really moved.
    public var lastPointer: CGPoint?

    public init(
        places: [Place], purpose: GoToPurpose = .goTo, canForgetPlaces: Bool = true, homePath: String = "",
        text: String = ""
    ) {
        self.places = places
        self.purpose = purpose
        self.canForgetPlaces = canForgetPlaces
        self.homePath = homePath
        self.text = text
        listText = text
        rebuild(reselect: true)
    }

    public static func == (lhs: GoToBoxState, rhs: GoToBoxState) -> Bool {
        lhs.places == rhs.places && lhs.purpose == rhs.purpose && lhs.canForgetPlaces == rhs.canForgetPlaces
            && lhs.homePath == rhs.homePath && lhs.text == rhs.text && lhs.listText == rhs.listText
            && lhs.isShowingRow == rhs.isShowingRow && lhs.completions == rhs.completions && lhs.rows == rhs.rows
            && lhs.selectedIndex == rhs.selectedIndex && lhs.submitting == rhs.submitting && lhs.error == rhs.error
            && lhs.folderToCreate?.text == rhs.folderToCreate?.text
            && lhs.folderToCreate?.notice == rhs.folderToCreate?.notice && lhs.lastPointer == rhs.lastPointer
    }

    /// Whether the list holds a path's completions rather than places found by name.
    public var isPathMode: Bool { Places.isPathQuery(listText) }
    public var trimmedText: String { JSString.trimmed(text) }
    /// The text without white space at either end, as the box submits it.
    public static func trim(_ text: String) -> String { JSString.trimmed(text) }
    public var hasQuery: Bool { !JSString.trimmed(listText).isEmpty }
    public var selectedRow: GoToRow? { rows.indices.contains(selectedIndex) ? rows[selectedIndex] : nil }

    /// What Open (or Move, or Extract) goes to: the folder shown in the field, the selected place, or the typed path.
    public var submitValue: String? {
        guard !submitting else { return nil }
        if isShowingRow { return selectedRow?.path ?? JSString.trimmed(text) }
        if let row = selectedRow { return row.path }
        return isPathMode && hasQuery ? JSString.trimmed(text) : nil
    }

    /// A name needs a folder picked from the list; a path can be opened as typed.
    public var canSubmit: Bool { submitValue != nil }

    /// The list's heading, while it lists something.
    public var label: String {
        guard isPathMode || hasQuery else { return "Recent and favorite folders" }
        return "\(FormatLocale.count(rows.count)) match\(rows.count == 1 ? "" : "es")"
    }

    /// The keys easy to miss: Tab completes, ⌘⌫ forgets a folder.
    public var hint: String? {
        if isPathMode { return "⇥ Completes" }
        return canForgetPlaces && selectedRow?.canForget == true ? "⌘⌫ Removes from List" : nil
    }

    /// What shows instead of the list when it is empty.
    public var emptyText: String {
        if isPathMode {
            return JSString.trimmed(listText).hasSuffix("/")
                ? "No folders in this folder" : "No folders match this path"
        }
        return hasQuery
            ? "No folder you have opened has that name. Start with / or ~ to type a path."
            : "Folders you open are listed here. Start with / or ~ to type a path."
    }

    /// Whether the field shows its ✕.
    public var showsClear: Bool { !text.isEmpty }

    /// The path a row puts in the field, ending in "/" so what is typed next goes inside it: from the home folder
    /// as "~", unless a path from "/" was typed.
    public func fieldPath(for row: GoToRow) -> String {
        let fromRoot = isPathMode && JSString.hasPrefix(JSString.trimmedStart(listText), "/")
        let path = fromRoot ? row.path : Places.abbreviate(row.path, homePath: homePath)
        return path.hasSuffix("/") ? path : path + "/"
    }

    // MARK: Changes

    /// What is typed changed (`setValue`): the completions go at once, and so does an error about the text before; a
    /// path asks for new ones.
    public mutating func setText(_ value: String) -> GoToEffect {
        text = value
        listText = value
        isShowingRow = false
        folderToCreate = nil
        error = nil
        completions = []
        rebuild(reselect: true)
        return Places.isPathQuery(value) ? .requestCompletions(value) : .none
    }

    /// The ✕: the field empties and the completions go, and nothing is asked.
    public mutating func clear() {
        text = ""
        listText = ""
        isShowingRow = false
        folderToCreate = nil
        completions = []
        rebuild(reselect: true)
    }

    /// The disk answered for the text in the field.
    public mutating func setCompletions(_ completions: [GoToCompletion]) {
        self.completions = completions
        rebuild(reselect: false)
    }

    /// A folder was forgotten: it leaves the list at once, and the row that takes its place is the one selected (the
    /// last row when it was the last), so that ⌘⌫ again forgets the next folder down rather than the one at the top.
    public mutating func forgetPlace(_ path: String) {
        let at = selectedIndex
        places.removeAll { $0.path == path }
        letGoOfRow()
        rebuild(reselect: false)
        if at >= 0, !rows.isEmpty { selectedIndex = min(at, rows.count - 1) }
    }

    /// The places read again (a folder forgotten from the store): the list follows at once.
    /// A row shown in the field stays the one selected while it is still listed; once it is gone (it was the folder
    /// forgotten) the field gives back what was typed, so Return never goes to a place the field doesn't show.
    public mutating func setPlaces(_ places: [Place]) {
        let shown = isShowingRow ? selectedRow?.path : nil
        self.places = places
        rebuild(reselect: false)
        guard let shown else { return }
        if let index = rows.firstIndex(where: { $0.path == shown }) {
            selectedIndex = index
        } else {
            letGoOfRow()
        }
    }

    /// The folder typed as `submitted` doesn't exist: the next submit of the same text makes it first, and `notice`
    /// says so. The disk may answer after the field has changed: the offer is for what was submitted, not for what
    /// the field holds by then, which was never looked for.
    public mutating func offerToCreate(notice: String, for submitted: String) {
        folderToCreate = (submitted, notice)
        if submitted == text { error = nil }
    }

    /// Whether the next submit makes the typed folder first.
    public var createsFolder: Bool { folderToCreate?.text == text }

    private mutating func rebuild(reselect: Bool) {
        let before = rows.count
        if isPathMode {
            rows = completions.map {
                GoToRow(
                    path: $0.path, name: $0.name, detail: $0.path, nameRanges: [], isFavorite: false, canForget: false)
            }
        } else {
            rows = Places.rank(places, query: listText).map { match in
                let location = Places.describeLocation(
                    name: match.place.name, displayPath: match.place.displayPath)
                return GoToRow(
                    path: match.place.path, name: match.place.name,
                    detail: match.place.isOtherPane ? "Other pane \u{00B7} \(location)" : location,
                    nameRanges: match.nameRanges, isFavorite: match.place.isFavorite,
                    canForget: match.place.canForget)
            }
        }
        // What is typed decides what is selected: the best place while a name is typed (and before, for Go To),
        // nothing while a path is typed until ↓ picks a completion. Re-evaluated when the text, the mode or the
        // number of rows changes, not on every selection move.
        guard reselect || rows.count != before else { return }
        selectedIndex = defaultSelection
    }

    private var defaultSelection: Int {
        if rows.isEmpty || isPathMode { return -1 }
        return hasQuery || purpose == .goTo ? 0 : -1
    }

    /// The field shows row `index`'s path; the list stays as typed.
    private mutating func showRow(_ index: Int) {
        selectedIndex = index
        text = fieldPath(for: rows[index])
        isShowingRow = true
        folderToCreate = nil
    }

    /// The field shows what was typed again, and the selection is what the typing chose.
    private mutating func letGoOfRow() {
        guard isShowingRow else { return }
        text = listText
        isShowingRow = false
        selectedIndex = defaultSelection
    }

    // MARK: Keys

    /// ↓ (`step` 1) and ↑ (-1): from no selection to the first or the last row, otherwise one row, stopping at the
    /// ends; the field shows the row's path. ↑ from the first row gives the field what was typed back.
    public mutating func moveSelection(_ step: Int) {
        guard !rows.isEmpty else { return }
        if isShowingRow, selectedIndex == 0, step == -1 {
            letGoOfRow()
            return
        }
        if selectedIndex < 0 {
            showRow(step == 1 ? 0 : rows.count - 1)
        } else {
            showRow(max(0, min(rows.count - 1, selectedIndex + step)))
        }
    }

    /// Escape: a row shown in the field gives way to what was typed. False when there was none, and Escape closes the
    /// box.
    public mutating func escape() -> Bool {
        guard isShowingRow else { return false }
        letGoOfRow()
        return true
    }

    /// Tab: the selected row (or in a path, the first) goes into the field ending in "/", and the list moves on to
    /// the folders inside it. Nil when Tab is left to move the focus.
    public mutating func tab() -> GoToEffect? {
        guard let row = selectedRow ?? (isPathMode ? rows.first : nil) else { return nil }
        return acceptRow(row)
    }

    /// Return: what can be submitted is. Nothing while a submit is under way.
    public mutating func pressReturn() -> GoToEffect {
        submitValue.map(GoToEffect.submit) ?? .none
    }

    /// ⌘⌫: the selected opened folder is forgotten. Nil when the key is left to the field.
    public func forgetKey() -> GoToEffect? {
        guard !isPathMode, canForgetPlaces, let row = selectedRow, row.canForget else { return nil }
        return .forget(row.path)
    }

    /// A click on a row: Go To goes there at once; when a folder is chosen for items, the field shows it, as ↓ would.
    /// Nothing while a submit is under way, so a double click goes to a place once.
    public mutating func click(_ index: Int) -> GoToEffect {
        guard !submitting, rows.indices.contains(index) else { return .none }
        switch purpose {
        case .goTo:
            return .submit(rows[index].path)
        case .chooseFolder:
            showRow(index)
            return .none
        }
    }

    /// A double click on a row: the items go into it.
    public mutating func doubleClick(_ index: Int) -> GoToEffect {
        guard !submitting, rows.indices.contains(index) else { return .none }
        if purpose == .chooseFolder { showRow(index) }
        return .submit(rows[index].path)
    }

    /// The pointer moved over row `index`: it selects the row only when it really moved since the last time, and
    /// not while the field shows a row, which stays the one chosen. Where a folder is chosen for items it selects
    /// nothing: only a click puts a folder in the field, so Return sends the items where the field says, never to a
    /// row the pointer happens to be over.
    public mutating func pointerMoved(over index: Int, at point: CGPoint) {
        let last = lastPointer
        lastPointer = point
        if let last, last != point, !isShowingRow, purpose == .goTo, rows.indices.contains(index) {
            selectedIndex = index
        }
    }

    /// Puts a row into the field ending in "/", so the list moves on to the folders inside it.
    private mutating func acceptRow(_ row: GoToRow) -> GoToEffect {
        setText(fieldPath(for: row))
    }

    // MARK: Paths

    /// What a typed path names: trimmed, "~" expanded, "." and ".." followed, and a path starting with "./" or "../"
    /// taken from `currentPath`. A path ending in "/" still does, so its completions are the folders inside it. A
    /// name is left as it is.
    public static func resolve(_ text: String, homePath: String, currentPath: String) -> String {
        let expanded = PathText2.expandHome(JSString.trimmed(text), homePath: homePath)
        guard Places.isPathQuery(expanded) else { return expanded }
        var joined = expanded
        if !JSString.hasPrefix(expanded, "/") {
            guard !currentPath.isEmpty else { return expanded }
            joined = currentPath + "/" + expanded
        }
        var parts: [Substring] = []
        for part in joined.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." {
                _ = parts.popLast()
                continue
            }
            parts.append(part)
        }
        let path = "/" + parts.joined(separator: "/")
        return joined.hasSuffix("/") && path != "/" ? path + "/" : path
    }

    /// The folder a submitted text names, as `resolve` reads it, without a "/" at its end.
    public static func folderPath(_ text: String, homePath: String, currentPath: String) -> String {
        let path = resolve(text, homePath: homePath, currentPath: currentPath)
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}
