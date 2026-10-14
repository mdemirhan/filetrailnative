// Port of the props apps/desktop/src/renderer/components/ContentPane.tsx hands its views (entries, metadata, selection,
// columns, sort and the gestures they report), as one seam the views of the folder share
import AppKit
import FTFileSystem
import FTFoundation

/// The List's columns as it draws them: which are shown (Name first), how wide each is as saved, and the density.
struct ListColumnState: Equatable {
    var columns: [DetailColumn]
    var widths: [DetailColumn: Double]
    var density: Density

    /// A folder's columns, from Settings and the window's saved widths.
    init(preferences: AppPreferences) {
        columns = DetailsColumns.visible(
            visibility: preferences.detailColumns, order: preferences.detailColumnOrder)
        widths = DetailsColumns.widths(preferences.detailColumnWidths)
        density = preferences.compactDetailsView ? .compact : .comfortable
    }

    init(columns: [DetailColumn], widths: [DetailColumn: Double], density: Density) {
        self.columns = columns
        self.widths = widths
        self.density = density
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
}

/// What a view of the folder (List, Icons, Compact List) takes from the content pane and reports to it.
@MainActor
protocol ContentPaneHost: AnyObject {
    var theme: Theme { get }
    var folderPath: String { get }
    /// The entries shown, in order.
    var entries: [DirectoryEntry] { get }
    var selection: ContentSelection { get }
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
    /// The selection model changed.
    func syncSelection()
    /// The look changed: the theme, the accent, which pane or window has the focus.
    func refreshLook()
    /// The columns or the density changed.
    func columnsChanged()
    /// Brings the entries into view.
    func reveal(paths: [String])
}

extension FolderPane {
    var contentTopInset: Double { 0 }
    var hasKeyboard: Bool { focusView.window?.firstResponder === focusView }
    func refresh(paths: Set<String>?) { reload(scrollToTop: false) }
    func syncSelection() {}
    func refreshLook() {}
    func columnsChanged() {}
    func reveal(paths: [String]) {}
}

/// The views of the content pane by mode: the List is registered here; the Icons view (and Compact List) of P5-04
/// register theirs the same way.
@MainActor
enum ContentViewRegistry {
    typealias Factory = @MainActor () -> any FolderPane

    private static var factories: [ExplorerViewMode: Factory] = [
        .details: { ListViewController() },
        .icons: { IconViewController() },
    ]

    static func register(_ mode: ExplorerViewMode, _ factory: @escaping Factory) {
        factories[mode] = factory
    }

    /// A view for the mode; a mode with none (Compact List until its package registers) shows the List.
    static func make(_ mode: ExplorerViewMode) -> any FolderPane {
        (factories[mode] ?? factories[.details]!)()
    }
}
