// No TypeScript source: the stand-in for P4-02's window controller, over the window the app has today
import AppKit
import FTFoundation

/// Opens and tracks `MainWindowController`s until P4-02's explorer window controller replaces them. It keeps the
/// shell's seam (`ExplorerWindowHost`) honest: nothing else of the shell knows what a window is.
@MainActor
final class MainWindowHost: ExplorerWindowHost {
    let list = ExplorerWindowList()
    private(set) var controllers: [MainWindowController] = []

    private var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    var windows: any ExplorerWindowListing { list }

    func openStartupWindows(folder: String?) {
        openWindow(at: folder.map { URL(fileURLWithPath: $0) } ?? home)
    }

    func openDefaultWindow(initialCommand: RendererCommand?) {
        let controller = openWindow(at: home)
        if let initialCommand { controller.perform(initialCommand) }
    }

    func openNewWindowFromFront() {
        openWindow(at: controllers.last?.folder ?? home)
    }

    func bringToFront() {
        guard let window = controllers.last?.window else {
            openDefaultWindow(initialCommand: nil)
            return
        }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }

    func openFromOtherApp(_ path: String) -> Bool { false }

    func openWindowOnFolder(_ path: String) {
        openWindow(at: URL(fileURLWithPath: path))
    }

    @discardableResult
    func openWindow(at url: URL) -> MainWindowController {
        let controller = makeController(at: url)
        controller.showWindow(nil)
        return controller
    }

    func openTab(at url: URL, nextTo existing: MainWindowController) {
        let controller = makeController(at: url)
        guard let window = controller.window else { return }
        existing.window?.addTabbedWindow(window, ordered: .above)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeController(at url: URL) -> MainWindowController {
        let controller = MainWindowController(folder: url)
        controller.onClose = { [weak self, weak controller] in
            guard let self, let controller else { return }
            controllers.removeAll { $0 === controller }
            list.remove(controller)
            onWindowsChanged?()
        }
        controllers.append(controller)
        list.add(controller)
        onWindowsChanged?()
        return controller
    }

    /// Called as a window opens or closes.
    var onWindowsChanged: (() -> Void)?
}

extension MainWindowController: ExplorerWindowHandle {
    var windowID: Int { ObjectIdentifier(self).hashValue }

    /// The menu commands this window can take today; P4-02's controller takes all of them.
    func perform(_ command: RendererCommand) {
        let fileManager = FileManager.default
        func place(_ url: URL?) {
            if let url { go(to: url) }
        }
        switch command {
        case .goBack: goBack(nil)
        case .goForward: goForward(nil)
        case .goEnclosingFolder: goToEnclosingFolder(nil)
        case .openSelection: openSelection(nil)
        case .viewAsIcons: showAsIcons(nil)
        case .viewAsDetails, .viewAsList: showAsList(nil)
        case .newTab: newWindowForTab(nil)
        case .closeTab: window?.performClose(nil)
        case .goDocuments: place(fileManager.urls(for: .documentDirectory, in: .userDomainMask).first)
        case .goDesktop: place(fileManager.urls(for: .desktopDirectory, in: .userDomainMask).first)
        case .goDownloads: place(fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first)
        case .goHomeRootTree: place(fileManager.homeDirectoryForCurrentUser)
        case .goLibrary: place(fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first)
        case .goMacintoshHD: place(URL(fileURLWithPath: "/"))
        case .goApplications: place(fileManager.urls(for: .applicationDirectory, in: .localDomainMask).first)
        case .goTrash: place(fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".Trash"))
        case .newWindow: (NSApp.delegate as? AppDelegate)?.newWindow(nil)
        default:
            if let selector = MenuCommandRouter.nativeEditSelector(command) {
                NSApp.sendAction(selector, to: nil, from: nil)
            }
        }
    }
}
