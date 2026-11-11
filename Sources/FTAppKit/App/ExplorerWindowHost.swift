import AppKit
import FTFileSystem
import FTFoundation

/// One explorer window as the app shell and the menu see it. The window controller conforms to it.
@MainActor
public protocol ExplorerWindowHandle: AnyObject {
    /// The id the window's folder watch and menu state are filed under.
    var windowID: Int { get }
    var window: NSWindow? { get }
    /// Visible and not minimized: a menu command may act on it unseen only when it is not.
    var isOnScreen: Bool { get }
    /// Carries out a menu command.
    func perform(_ command: RendererCommand)
    /// What the application menu should show of it now; nil when it doesn't say.
    var currentMenuState: ApplicationMenuState? { get }
}

extension ExplorerWindowHandle {
    public var currentMenuState: ApplicationMenuState? { nil }

    public var isOnScreen: Bool {
        guard let window else { return false }
        return window.isVisible && !window.isMiniaturized
    }
}

/// The open explorer windows, front to back.
@MainActor
public protocol ExplorerWindowListing: AnyObject {
    var front: (any ExplorerWindowHandle)? { get }
    var count: Int { get }
    /// The explorer window a window belongs to (a sheet of it too); nil for Settings and the other windows.
    func handle(for window: NSWindow) -> (any ExplorerWindowHandle)?
    func handle(windowID: Int) -> (any ExplorerWindowHandle)?
}

/// What the app shell needs of the explorer windows it does not open itself. The window controller provides it;
/// the shell keeps one reference so the two plug together.
@MainActor
public protocol ExplorerWindowHost: AnyObject {
    var windows: any ExplorerWindowListing { get }
    /// The windows the app opens with; the folder the app was launched with goes to the one in front.
    func openStartupWindows(folder: String?)
    /// A window opened with none open (the Dock icon, New Window, a place of the Go menu): it starts where the
    /// window closed last was, and runs `initialCommand` once opened.
    func openDefaultWindow(initialCommand: RendererCommand?)
    /// New Window from the Dock menu, or while another window (Settings) has the keyboard.
    func openNewWindowFromFront()
    /// A second launch, or the Dock icon with every window minimized.
    func bringToFront()
    /// An item opened with File Trail from another app: the window in front takes it. False with no window to take it.
    func openFromOtherApp(_ request: OpenRequest) -> Bool
    /// A window on one folder (a disk image's disk, or a folder or an item's folder from another app, opened with no window
    /// open). `selectPath`, an item in the folder, is selected once it has opened.
    func openWindowOnFolder(_ path: String, selecting selectPath: String?)
}
