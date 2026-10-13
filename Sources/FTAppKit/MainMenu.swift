import AppKit

/// The menu bar, built in code. Actions travel the responder chain to the
/// front window's `MainWindowController` (or the app delegate).
@MainActor
enum MainMenu {
    static func make() -> NSMenu {
        let main = NSMenu()

        let appMenu = submenu(in: main, title: "File Trail")
        appMenu.addItem(
            withTitle: "About File Trail",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let services = appMenu.addItem(withTitle: "Services", action: nil, keyEquivalent: "")
        services.submenu = NSMenu()
        NSApp.servicesMenu = services.submenu
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide File Trail", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        appMenu.addItem(
            withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Quit File Trail", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let file = submenu(in: main, title: "File")
        file.addItem(withTitle: "New Window", action: #selector(AppDelegate.newWindow(_:)), keyEquivalent: "n")
        file.addItem(withTitle: "New Tab", action: #selector(NSResponder.newWindowForTab(_:)), keyEquivalent: "t")
        file.addItem(withTitle: "Open", action: #selector(MainWindowController.openSelection(_:)), keyEquivalent: "o")
        file.addItem(.separator())
        file.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        let edit = submenu(in: main, title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let view = submenu(in: main, title: "View")
        view.addItem(withTitle: "as Icons", action: #selector(MainWindowController.showAsIcons(_:)), keyEquivalent: "1")
        view.addItem(withTitle: "as List", action: #selector(MainWindowController.showAsList(_:)), keyEquivalent: "2")
        view.addItem(.separator())
        view.addItem(
            item("Show Sidebar", #selector(NSSplitViewController.toggleSidebar(_:)), "s", [.command, .control]))

        let go = submenu(in: main, title: "Go")
        go.addItem(withTitle: "Back", action: #selector(MainWindowController.goBack(_:)), keyEquivalent: "[")
        go.addItem(withTitle: "Forward", action: #selector(MainWindowController.goForward(_:)), keyEquivalent: "]")
        go.addItem(
            withTitle: "Enclosing Folder", action: #selector(MainWindowController.goToEnclosingFolder(_:)),
            keyEquivalent: arrow(NSUpArrowFunctionKey))
        go.addItem(.separator())
        let fm = FileManager.default
        let places: [(String, URL?, String, NSEvent.ModifierFlags)] = [
            ("Documents", fm.urls(for: .documentDirectory, in: .userDomainMask).first, "o", [.command, .shift]),
            ("Desktop", fm.urls(for: .desktopDirectory, in: .userDomainMask).first, "d", [.command, .shift]),
            ("Downloads", fm.urls(for: .downloadsDirectory, in: .userDomainMask).first, "l", [.command, .option]),
            ("Home", fm.homeDirectoryForCurrentUser, "h", [.command, .shift]),
            ("Applications", fm.urls(for: .applicationDirectory, in: .localDomainMask).first, "a", [.command, .shift]),
        ]
        for (title, url, key, modifiers) in places {
            guard let url else { continue }
            let placeItem = item(title, #selector(MainWindowController.goToPlace(_:)), key, modifiers)
            placeItem.representedObject = url
            go.addItem(placeItem)
        }
        go.addItem(.separator())
        go.addItem(
            withTitle: "Open Selection", action: #selector(MainWindowController.openSelection(_:)),
            keyEquivalent: arrow(NSDownArrowFunctionKey))

        let window = submenu(in: main, title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(.separator())
        window.addItem(
            withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.windowsMenu = window

        NSApp.helpMenu = submenu(in: main, title: "Help")
        return main
    }

    private static func submenu(in menu: NSMenu, title: String) -> NSMenu {
        let submenu = NSMenu(title: title)
        menu.addItem(withTitle: title, action: nil, keyEquivalent: "").submenu = submenu
        return submenu
    }

    private static func item(
        _ title: String, _ action: Selector, _ key: String, _ modifiers: NSEvent.ModifierFlags
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    private static func arrow(_ key: Int) -> String {
        String(Character(UnicodeScalar(UInt16(key))!))
    }
}
