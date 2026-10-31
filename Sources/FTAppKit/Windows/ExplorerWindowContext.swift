// Port of the props apps/desktop/src/renderer/components/ExplorerWorkspace.tsx hands its panes (folder, history,
// selection, view, preferences and the commands), as one seam the native panes share
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

/// The search a tab shows (P5-07): where it runs from, what it looks for, and whether it is still running. The toolbar's
/// title ("Searching “X”") and the sidebar's search mode follow it.
struct ExplorerSearchState: Equatable, Sendable {
    var rootPath: String
    var query: String
    var isRunning: Bool
    /// The results found and narrowed to the query, before the filter.
    var resultCount: Int
}

/// What changed in a window, for the panes that show it.
enum ExplorerWindowChange: Equatable, Sendable {
    case folder
    case history
    case selection
    case focusedPane
    case treeRoot
    case view
    case panels
    case preferences
    case clipboard
    /// A search started or ended (`searchRootPath`), or how it stands changed (`searchState`).
    case search
    /// Something else the commands read changed (a file operation started or ended, the Trash).
    case commands
}

/// What the panes of an explorer window use of the services the app runs.
@MainActor
struct ExplorerServices {
    var directoryService: DirectoryService
    var folderWatches: FolderWatches?
    var iconStore: FileIconStore?
    var volumeWatcher: VolumeWatcher?
    /// What Copy and Cut put on the app's clipboard.
    var clipboard: SharedClipboard
    /// Preference changes, as every window sees them (P4-03 makes the app's one).
    var preferences: WindowPreferenceChannel?

    /// The services the app delegate runs; what it doesn't have yet is made here once.
    static var current: ExplorerServices {
        if let installed { return installed }
        let app = NSApp.delegate as? AppDelegate
        return ExplorerServices(
            directoryService: app?.directoryService ?? fallbackDirectoryService, folderWatches: app?.folderWatches,
            iconStore: nil, volumeWatcher: nil,
            clipboard: app?.explorerWindowsIfStarted?.clipboard ?? fallbackClipboard,
            preferences: fallbackChannel(app))
    }

    /// Set once by the app (sharedFileRequest to P4-03: `ExplorerServices.installed = …` in `startServices`).
    static var installed: ExplorerServices?

    private static let fallbackDirectoryService = DirectoryService()
    private static let fallbackClipboard = SharedClipboard()
    private static var madeChannel: WindowPreferenceChannel?

    /// A preference channel over the app's store until the app makes its own: a change reaches every explorer
    /// window, and the theme is applied.
    private static func fallbackChannel(_ app: AppDelegate?) -> WindowPreferenceChannel? {
        if let madeChannel { return madeChannel }
        guard let app, let store = app.store else { return nil }
        let channel = WindowPreferenceChannel(
            store: store,
            explorerWindowID: { senderID in
                senderID.flatMap { app.explorerWindowsIfStarted?.tab(windowID: $0)?.group?.recordID }
            },
            onPreferencesChanged: { preferences, change in
                if change.patch["theme"] != nil { app.applyAppearance(preferences.theme) }
                for tab in app.explorerWindowsIfStarted?.allTabs ?? [] { tab.preferencesChanged(change) }
            })
        madeChannel = channel
        return channel
    }
}

extension AppDelegate {
    /// The explorer windows, once the services have started.
    var explorerWindowsIfStarted: ExplorerWindows? {
        let windows: ExplorerWindows? = explorerWindows
        return windows
    }
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
/// window's panels and preferences, the app's services, and the commands. `MainWindowController` is it. Members
/// stay as they are; later work packages add to it.
@MainActor
protocol ExplorerWindowContext: AnyObject {
    /// The window the panes are in.
    var window: NSWindow? { get }

    // MARK: Folder and history

    var currentFolder: URL { get }
    /// The folder on screen; empty once the tab has let go of it (`currentPath` of the original is then empty).
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
    /// Whether the command can run now (`canRunRendererCommand`).
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
    /// nil otherwise. P5-07 starts and ends searches.
    var searchRootPath: String? { get }
    /// The search on screen while the tab shows results; nil otherwise.
    var searchState: ExplorerSearchState? { get }

    /// Tells `handler` of every change until the token goes.
    func observe(_ handler: @escaping @MainActor (ExplorerWindowChange) -> Void) -> ExplorerWindowObservation
}
