// Port of the explorer window's frame in apps/desktop/src/main/main.ts (titleBarStyle "hiddenInset")
import AppKit
import FTFoundation

/// The window's frame, as Finder's: no title, a unified system toolbar (`ExplorerToolbar`), the content under the title
/// bar, and the system tab bar (D-001) under the toolbar. The window's content is a sidebar split (`WorkspaceView`), so
/// the system places the toolbar's items and the tab bar over the content column only, and the traffic lights over the
/// sidebar, where it puts them. The system draws the tabs; the band is the content's color with no separator at rest,
/// and `WorkspaceBandLine` is its line under the pointer, as Finder's (D-015).
@MainActor
enum WindowChrome {
    static func configure(_ window: NSWindow, toolbar: NSToolbar) {
        window.styleMask.insert(.fullSizeContentView)
        window.titleVisibility = .hidden
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .none
    }

    /// How far below the window's top the panes of the content column start: the title bar, with the system tab bar
    /// while it shows.
    static func panesTop(_ window: NSWindow) -> Double {
        max(0, window.frame.height - window.contentLayoutRect.maxY)
    }
}
