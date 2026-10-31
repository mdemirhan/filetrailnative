// Port of the props apps/desktop/src/renderer/components/ContentPane.tsx hands its views (entries, metadata, selection,
// columns, sort and the gestures they report), as one seam the views of the folder share
import AppKit
import FTFileSystem
import FTFoundation

/// The List's columns as it draws them: which are shown (Name first), how wide each is as saved, and the density; with
/// the densities of the Icons view and of the Compact List, which Settings sets apart.
struct ListColumnState: Equatable {
    var columns: [DetailColumn]
    var widths: [DetailColumn: Double]
    var density: Density
    var iconDensity: Density
    var flowDensity: Density

    /// A folder's columns, from Settings and the window's saved widths.
    init(preferences: AppPreferences) {
        columns = DetailsColumns.visible(
            visibility: preferences.detailColumns, order: preferences.detailColumnOrder)
        widths = DetailsColumns.widths(preferences.detailColumnWidths)
        density = preferences.compactDetailsView ? .compact : .comfortable
        iconDensity = preferences.compactIconView ? .compact : .comfortable
        flowDensity = preferences.compactListView ? .compact : .comfortable
    }

    init(
        columns: [DetailColumn], widths: [DetailColumn: Double], density: Density,
        iconDensity: Density = .comfortable, flowDensity: Density = .comfortable
    ) {
        self.columns = columns
        self.widths = widths
        self.density = density
        self.iconDensity = iconDensity
        self.flowDensity = flowDensity
    }

    static let standard = ListColumnState(preferences: .defaults())
}

/// Where the drag and drop package (P5-08) plugs in: rows and the pane's background adopt the automation seams and
/// call these.
struct ContentDragHooks {
    /// The files a drag of these entries carries (nil: the entries' own).
    var itemsToDrag: (([DirectoryEntry]) -> [URL])?
    /// Takes a drop of files on the folder under the pointer, or on the folder on screen (nil entry); answers whether
    /// it was taken.
    var acceptDrop: (([URL], DirectoryEntry?, NSDragOperation) -> Bool)?
    /// Starts a drag of the entries from a press on one of them, once the pointer has moved; answers whether a drag
    /// session began (a press that began one is not a click). The view hands the press, and the view it was in.
    var beginDrag: (([DirectoryEntry], NSEvent, NSView) -> Bool)?
    /// A drag of files is over the entry (nil: the folder on screen) at a point in window coordinates: what a drop
    /// would do (none: not taken).
    var dragUpdated: ((any NSDraggingInfo, DirectoryEntry?) -> NSDragOperation)?
    /// The drag was let go over the entry (nil: the folder on screen); whether it was taken.
    var performDrop: ((any NSDraggingInfo, DirectoryEntry?) -> Bool)?
    /// The drag left the view.
    var dragExited: (() -> Void)?
}

/// What a view of the folder (List, Icons, Compact List) takes from the content pane and reports to it.
@MainActor
protocol ContentPaneHost: AnyObject {
    var theme: Theme { get }
    var folderPath: String { get }
    /// The entries shown, in order.
    var entries: [DirectoryEntry] { get }
    var selection: ContentSelection { get }
    /// The paths of the entries shown, in order, and where one stands (the selection model works on these).
    var entryPaths: [String] { get }
    func position(of path: String?) -> Int?
    var sortBy: SortByPreference { get }
    var sortDirection: SortDirectionPreference { get }
    var columnState: ListColumnState { get }
    var iconStore: FileIconStore? { get }

    /// Whether the view of the pane has the keyboard, and whether the window is the one in front (selections turn
    /// grey otherwise).
    var paneHasKeyboard: Bool { get }
    var windowIsActive: Bool { get }

    func metadata(for path: String) -> EntryMetadata?
    /// Asks for the details of rows that came into view.
    func requestMetadata(for paths: [String])
    func folderSizeEntry(_ path: String) -> FolderSizeEntry
    /// The largest size among the folder's entries, while the folder is sorted by size and not searched; nil when the
    /// list draws no bars.
    var sizeBarScale: Int64? { get }
    /// A folder's size as the Size column and the bars use it: the text, once known.
    func sizeBytes(of entry: DirectoryEntry) -> Int64?

    // MARK: Keys

    /// The keys of the commands, as Settings has them.
    var shortcuts: ResolvedShortcuts { get }
    /// The text typed to narrow the list.
    var listFilter: ListFilterTyping { get }
    /// Typing, Backspace or Esc in the list.
    func applyFilterKey(_ key: ListFilterKey)
    /// Return with an item selected: Open or Rename, as the Return key setting says.
    func pressedReturn()
    /// Tab: the keyboard goes to the other pane.
    func switchPane()
    /// A command the window runs for a key the menu does not listen for; whether it took the key.
    func runCommand(_ command: ShortcutCommandID) -> Bool
    /// ⌘A in the list.
    func selectAllEntries()

    // MARK: Rename

    /// The rename going on, if one is.
    var inlineRename: InlineRenameState? { get }
    /// The field's name was handed over, or the rename was given up.
    func renameSubmitted(_ name: String)
    func renameCancelled()

    // MARK: Reports

    func selectionChanged(_ selection: ContentSelection)
    /// Open the entries (double-click, Return, ⌘O); `newTab` for ⌘-double-click on a folder.
    func activate(_ entries: [DirectoryEntry], newTab: Bool)
    /// A header asked for the folder to be ordered by this column.
    func requestSort(_ sortBy: SortByPreference)
    /// The view's sort descriptor was set directly (the capture's sort step): the folder is put in exactly this order.
    func sortSetFromOutside(_ sortBy: SortByPreference, ascending: Bool)
    /// A column was resized (drag, arrow keys or double-click): the widths to keep.
    func columnWidthsChanged(_ widths: [DetailColumn: Double])
    /// The menu for a right-click on the entries, or on the background (nil entries).
    func contextMenu(for entries: [DirectoryEntry]?) -> NSMenu?
    var dragHooks: ContentDragHooks { get }

    // MARK: The clipboard and drops (P5-08)

    /// The items on the clipboard, while Settings marks them; nil for no marks.
    var clipboardMarks: ClipboardMarks? { get }
    /// What the clipboard holds of an item, for its mark (the Icons view's badge); nil while the clipboard does not
    /// hold it or marks are off.
    func clipboardMark(for path: String) -> ContentClipboardMark?
    /// What a drop on the row of `path` would do, while a drag is over it.
    func dropState(for path: String) -> DropTargetState?
    /// While search results show: the Folder column, the marks in names and the results' order (P5-07); nil for a
    /// folder.
    var search: ContentSearchContext? { get }
}

extension ContentPaneHost {
    var clipboardMarks: ClipboardMarks? { nil }
    func dropState(for path: String) -> DropTargetState? { nil }
    var search: ContentSearchContext? { nil }
}

/// A pane's root view, whose rows start below the card of a state (a folder left on screen under its error).
@MainActor
protocol RowsBelowCard: AnyObject {
    var roomAboveRows: CGFloat { get set }
}

/// A view of the folder in one mode (Icons, List, Compact List), as the content pane swaps them.
@MainActor
protocol FolderPane: NSViewController {
    var host: (any ContentPaneHost)? { get set }
    /// The view that takes the keyboard.
    var focusView: NSView { get }
    /// Whether it has the keyboard now.
    var hasKeyboard: Bool { get }
    /// Room the view keeps above its items (the List's column header), which the states below it start under.
    var contentTopInset: Double { get }
    /// The entries changed: shown again, from the top when asked.
    func reload(scrollToTop: Bool)
    /// The details of these paths changed (nil: of all).
    func refresh(paths: Set<String>?)
    /// The entries at these paths changed, and no row moved: only their rows are drawn again.
    func reloadRows(paths: Set<String>)
    /// The selection model changed.
    func syncSelection()
    /// The look changed: the theme, the accent, which pane or window has the focus.
    func refreshLook()
    /// The columns or the density changed.
    func columnsChanged()
    /// Where the view is scrolled (a folder left remembers it, Back puts it back).
    var scrollPosition: (top: Double, left: Double) { get set }
    /// The rename the host is told of began, changed or ended.
    func syncRename()
    /// A filter nothing matches is said in place of the view: what the view draws besides its items (the List's
    /// column header) goes meanwhile.
    func showNothingMatches(_ shown: Bool)
    /// The items on the clipboard changed, or marks were switched on or off: their rows are drawn again (P5-08).
    func clipboardMarksChanged()
    /// The items on the clipboard were just copied or cut: their rows flash (P5-08).
    func flashClipboardMarks()
    /// Where the rows of `paths` are drawn, in `dragView`'s coordinates, for the drag's images (P5-08).
    func dragPlacements(for paths: [String]) -> [String: FileDragPlacement]
    /// The view a drag of items starts from.
    var dragView: NSView { get }
}

extension FolderPane {
    var contentTopInset: Double { 0 }
    var hasKeyboard: Bool { focusView.window?.firstResponder === focusView }
    func refresh(paths: Set<String>?) { reload(scrollToTop: false) }
    func reloadRows(paths: Set<String>) { reload(scrollToTop: false) }
    func syncSelection() {}
    func refreshLook() {}
    func columnsChanged() {}
    var scrollPosition: (top: Double, left: Double) {
        get { (0, 0) }
        set {}
    }
    func syncRename() {}
    func showNothingMatches(_ shown: Bool) {}
    func clipboardMarksChanged() { refresh(paths: nil) }
    func flashClipboardMarks() {}
    func dragPlacements(for paths: [String]) -> [String: FileDragPlacement] { [:] }
    var dragView: NSView { focusView }
}

/// The views of the content pane by mode: Icons, List and Compact List.
@MainActor
enum ContentViewRegistry {
    typealias Factory = @MainActor () -> any FolderPane

    private static var factories: [ExplorerViewMode: Factory] = [
        .details: { ListViewController() },
        .icons: { IconViewController() },
        .list: { CompactListViewController() },
    ]

    static func register(_ mode: ExplorerViewMode, _ factory: @escaping Factory) {
        factories[mode] = factory
    }

    /// A view for the mode; a mode with none registered shows the List.
    static func make(_ mode: ExplorerViewMode) -> any FolderPane {
        (factories[mode] ?? factories[.details]!)()
    }
}
