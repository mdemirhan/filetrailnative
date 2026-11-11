import AppKit
import FTFileSystem
import FTFoundation

/// Where a folder opens.
enum NavigationTarget: Equatable, Sendable {
    /// In this tab, as a new step of its history.
    case push
    case newTab
    case newWindow
}

/// The pane that has the keyboard (`focusedPane`).
enum ExplorerPane: Equatable, Sendable {
    case tree, content
}

/// How the tab shows its folder: the view, the sort, hidden files and folders first.
struct ExplorerViewState: Equatable, Sendable {
    var viewMode: ExplorerViewMode
    var searchViewMode: ExplorerViewMode
    var sortBy: SortByPreference
    var sortDirection: SortDirectionPreference
    var includeHidden: Bool
    var foldersFirst: Bool
}

/// What changed in a window, for the panes that show it.
enum ExplorerWindowChange: Equatable, Sendable {
    case folder
    case history
    case selection
    case focusedPane
    case view
    case panels
    case preferences
    case clipboard
    /// A search started or ended (`searchRootPath`), or how it stands changed.
    case search
    /// Something else the commands read changed (a file operation started or ended, the Trash).
    case commands
}

/// What the panes of an explorer window use of the services the app runs.
@MainActor
struct ExplorerServices {
    var directoryService: DirectoryService
    var iconStore: FileIconStore?
    /// What Copy and Cut put on the app's clipboard.
    var clipboard: SharedClipboard
    /// Preference changes, as every window sees them.
    var preferences: WindowPreferenceChannel?

    /// The services the app runs, which it installs before any window opens.
    static var current: ExplorerServices {
        guard let installed else {
            preconditionFailure("ExplorerServices.installed is set when the app starts, before any window opens")
        }
        return installed
    }

    /// Set once by the app (`ExplorerServices.installed = …` in `startServices`).
    static var installed: ExplorerServices?
}

/// A reference that doesn't keep its object.
struct Weak<Object: AnyObject> {
    weak var value: Object?

    init(_ value: Object) {
        self.value = value
    }
}

/// Keeps an observation going for as long as it is held; `invalidate` (or letting it go) stops it.
@MainActor
final class ExplorerWindowObservation {
    private(set) var isValid = true

    init() {}

    func invalidate() {
        isValid = false
    }
}

/// What every pane of an explorer window (sidebar, content, path bar, Info Row, Info panel, toolbar) gets of the
/// window: its folder and history, the selection and which pane has the keyboard, how the tab shows its folder, the
/// window's panels and preferences, the app's services, and the commands. `MainWindowController` is it.
@MainActor
protocol ExplorerWindowContext: AnyObject {
    /// The window the panes are in.
    var window: NSWindow? { get }

    // MARK: Folder and history

    var currentFolder: URL { get }
    /// The folder on screen; empty once the tab has let go of it.
    var shownFolderPath: String { get }
    /// Opens the folder above the one on screen, as the toolbar's Enclosing Folder does.
    func goToParentFolder()
    func navigate(to url: URL, target: NavigationTarget)
    var historyPaths: [String] { get }
    var historyIndex: Int { get }
    var canGoBack: Bool { get }
    var canGoForward: Bool { get }
    /// Jumps within the history without adding to it (the Back and Forward hold menus).
    func goToHistoryIndex(_ index: Int)

    // MARK: Commands

    /// Carries out a command, as the menu bar, a key or a toolbar button sends it.
    func perform(_ command: RendererCommand)
    /// Whether the command can run now.
    func canPerform(_ command: RendererCommand) -> Bool

    // MARK: Selection and focus

    var selectedPaths: [String] { get }
    var focusedPane: ExplorerPane? { get }
    var treeRootPath: String { get }

    // MARK: View, panels, preferences

    var viewState: ExplorerViewState { get }
    /// The panels and widths every tab of the window shares.
    var panels: TabGroupSession.Panels { get }
    func updatePanels(_ change: (inout TabGroupSession.Panels) -> Void)
    /// The preferences as this window sees them.
    var preferences: AppPreferences { get }
    /// Changes preferences through the app's channel; the keys the whole app shares reach every window.
    func updatePreferences(_ patch: [String: JSONNode])

    var services: ExplorerServices { get }

    // MARK: Search

    /// While the tab shows search results, the folder the search runs from (`searchRootPath` in search mode);
    /// nil otherwise.
    var searchRootPath: String? { get }

    /// Tells `handler` of every change until the token goes.
    func observe(_ handler: @escaping @MainActor (ExplorerWindowChange) -> Void) -> ExplorerWindowObservation
}
