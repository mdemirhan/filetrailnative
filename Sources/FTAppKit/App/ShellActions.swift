// Port of the app.on("activate") and open-file handling of apps/desktop/src/main/main.ts and ExplorerWindowController.activate
import AppKit
import FTFileSystem
import FTFoundation
import Foundation

/// What the shell does about a click on the Dock icon and an item from another app, apart from AppKit.
@MainActor
enum ShellActions {
    /// A click on the Dock icon. With no explorer window open one opens; with every window of the app minimized the one
    /// in front comes back.
    static func activate(hasVisibleWindows: Bool, shutdownInProgress: Bool, host: any ExplorerWindowHost) {
        if QuitWhileBusy.shouldOpenWindowOnActivate(
            shutdownInProgress: shutdownInProgress, explorerWindowCount: host.windows.count)
        {
            host.openDefaultWindow(initialCommand: nil)
            return
        }
        if !hasVisibleWindows, !shutdownInProgress {
            host.bringToFront()
        }
    }

    /// An item opened from another app goes to the window in front, which opens it. With no window open, a folder opens in
    /// a window of its own, and so does the folder another item is in, with the item selected. A disk image is mounted here
    /// and its disk opens in a window of its own; an error is shown on its own, with no window to show it in. Nothing opens
    /// while quitting.
    static func openFromOtherApp(
        _ request: OpenRequest, shutdownInProgress: Bool, host: any ExplorerWindowHost,
        mount: (String) async -> DiskImageOpenResponse, showFailure: (_ title: String, _ message: String) -> Void
    ) async {
        guard !shutdownInProgress, !host.openFromOtherApp(request) else { return }
        let path = request.path
        switch request.kind {
        case .folder:
            host.openWindowOnFolder(path, selecting: nil)
            return
        case .reveal, .select:
            host.openWindowOnFolder(NodePath.dirname(path), selecting: path)
            return
        case .diskImage:
            break
        }
        let response = await mount(path)
        if response.status == .opened, let volumePath = response.volumePath {
            host.openWindowOnFolder(volumePath, selecting: nil)
        } else if response.status == .failed {
            let notice = DiskImageNames.describeFailure(path: path, reason: response.reason)
            showFailure(notice.title, notice.message)
        }
    }

    /// The Dock menu has one item, New Window.
    static func makeDockMenu(target: AnyObject, action: Selector) -> NSMenu {
        let menu = NSMenu()
        let item = NSMenuItem(title: "New Window", action: action, keyEquivalent: "")
        item.target = target
        menu.addItem(item)
        return menu
    }
}
