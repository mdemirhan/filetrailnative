import AppKit
import FTFoundation
import Testing

@testable import FTAppKit

@MainActor
@Suite struct MenuCommandRouterTests {
    /// Records the question "may this window close", which is what ⌘W on a window asks.
    private final class CloseWatcher: NSObject, NSWindowDelegate {
        var asked = 0
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            asked += 1
            return false
        }
    }

    @MainActor
    private final class NativeLog { var calls: [String] = [] }

    // Scenarios 246, 247: ⌘A takes the whole text of the field of the window it is meant for, whether or not the system
    // calls that window key at this moment (the app coming to the front, a run started from a terminal).
    @Test func anEditCommandReachesTheFieldOfItsWindowUnkeyed() throws {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered,
            defer: true)
        window.isReleasedWhenClosed = false
        let field = NSTextField(string: "File")
        field.frame = NSRect(x: 10, y: 10, width: 100, height: 22)
        window.contentView?.addSubview(field)
        #expect(window.makeFirstResponder(field))
        let editor = try #require(window.firstResponder as? NSTextView)
        editor.setSelectedRange(NSRange(location: 4, length: 0))
        #expect(!window.isKeyWindow)
        MenuCommandRouter().performNativeEdit(#selector(NSResponder.selectAll(_:)), window)
        #expect(editor.selectedRange() == NSRange(location: 0, length: 4))
    }

    private func make(options: ApplicationMenuOptions = .init()) -> (BuiltApplicationMenu, MenuCommandRouter, NativeLog)
    {
        _ = NSApplication.shared
        let router = MenuCommandRouter()
        let log = NativeLog()
        router.performNativeEdit = { selector, _ in log.calls.append(NSStringFromSelector(selector)) }
        return (ApplicationMenuBuilder.build(target: router, options: options), router, log)
    }

    private func menuItem(_ built: BuiltApplicationMenu, _ menu: String, _ title: String) -> NSMenuItem {
        item(submenu(built.menu, menu), title)
    }

    /// An explorer that takes every command, and the window that has the keyboard.
    private func routeTo(_ router: MenuCommandRouter, _ explorer: FakeExplorerWindow, focused: Bool = true) {
        router.explorerFor = { _ in ExplorerCommandTarget(handle: explorer, focused: focused) }
    }

    private func commandKey(_ characters: String, code: UInt16, isRepeat: Bool) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: isRepeat, keyCode: code)
    }

    // A held ⌘V reaches the Edit menu's Paste again and again: the files are pasted once for the press.
    @Test func aHeldCommandVPastesOnce() {
        let (built, router, _) = make()
        let explorer = FakeExplorerWindow(id: 1)
        routeTo(router, explorer)
        router.focusedWindow = { nil }
        let paste = menuItem(built, "Edit", "Paste")
        let press = commandKey("v", code: 9, isRepeat: false)
        let held = commandKey("v", code: 9, isRepeat: true)
        router.currentEvent = { press }
        choose(paste, router)
        #expect(explorer.performed == [.editPaste])
        router.currentEvent = { held }
        choose(paste, router)
        choose(paste, router)
        #expect(explorer.performed == [.editPaste])
        // The next press is a press of its own, and a click on the item always runs.
        router.currentEvent = { press }
        choose(paste, router)
        router.currentEvent = { nil }
        choose(paste, router)
        #expect(explorer.performed == [.editPaste, .editPaste, .editPaste])
    }

    // In a text field the held key goes on pasting into the text, there and in another window, as the system's does.
    @Test func aHeldCommandVKeepsPastingIntoAField() {
        let (built, router, log) = make()
        let explorer = FakeExplorerWindow(id: 1)
        routeTo(router, explorer)
        router.focusedWindow = { explorer.window }
        router.isTextEditing = { _ in true }
        let held = commandKey("v", code: 9, isRepeat: true)
        router.currentEvent = { held }
        let paste = menuItem(built, "Edit", "Paste")
        choose(paste, router)
        #expect(log.calls == ["paste:"])
        routeTo(router, explorer, focused: false)
        router.isTextEditing = { _ in false }
        choose(paste, router)
        #expect(log.calls == ["paste:", "paste:"])
        #expect(explorer.performed.isEmpty)
    }

    // ⌘C, ⌘X and ⌘A are not among the write-starting keys: a held one repeats, and it starts nothing on disk.
    @Test func theOtherEditItemsRepeat() {
        let (built, router, _) = make()
        let explorer = FakeExplorerWindow(id: 1)
        routeTo(router, explorer)
        router.focusedWindow = { nil }
        let held = commandKey("c", code: 8, isRepeat: true)
        router.currentEvent = { held }
        for title in ["Cut", "Copy", "Select All"] { choose(menuItem(built, "Edit", title), router) }
        #expect(explorer.performed == [.editCut, .editCopy, .editSelectAll])
    }

    @Test func sendsEachItemsCommandToTheExplorerWindow() {
        let (built, router, _) = make()
        let explorer = FakeExplorerWindow(id: 1)
        routeTo(router, explorer)
        router.focusedWindow = { nil }

        var sent = 0
        for found in flatten(built.menu) {
            guard let id = found.identifier?.rawValue,
                let command = RendererCommand(rawValue: id.split(separator: ":").first.map(String.init) ?? id)
            else {
                continue
            }
            if command == .openSettings { continue }
            let before = explorer.performed.count
            choose(found, router)
            sent += 1
            #expect(explorer.performed.count == before + 1, "\(found.title)")
            #expect(explorer.performed.last == command, "\(found.title)")
        }
        #expect(sent > 50)
    }

    @Test func dispatchesTheEditCommandsToTheResponderChainWhileATextFieldHasTheKeyboard() {
        let (built, router, log) = make()
        let explorer = FakeExplorerWindow(id: 1)
        routeTo(router, explorer)
        router.focusedWindow = { explorer.window }
        router.isTextEditing = { _ in true }

        for title in ["Cut", "Copy", "Paste", "Select All"] {
            choose(menuItem(built, "Edit", title), router)
        }
        choose(built.itemsByID["undo:text"]!, router)
        choose(built.itemsByID["redo:text"]!, router)

        #expect(
            log.calls == [
                NSStringFromSelector(#selector(NSText.cut(_:))), NSStringFromSelector(#selector(NSText.copy(_:))),
                NSStringFromSelector(#selector(NSText.paste(_:))),
                NSStringFromSelector(#selector(NSResponder.selectAll(_:))), "undo:", "redo:",
            ])
        #expect(explorer.performed.isEmpty)
    }

    @Test func appliesEditCommandsNativelyInAnotherFocusedWindowInsteadOfTheExplorer() {
        let (built, router, log) = make()
        let explorer = FakeExplorerWindow(id: 1)
        let settings = makeOffscreenWindow()
        routeTo(router, explorer, focused: false)
        router.focusedWindow = { settings }

        choose(menuItem(built, "Edit", "Copy"), router)

        #expect(log.calls == [NSStringFromSelector(#selector(NSText.copy(_:)))])
        #expect(explorer.performed.isEmpty)
    }

    @Test func undoesAndRedoesTheTypingOfAnotherFocusedWindowNeverTheFiles() {
        let (built, router, log) = make(options: .init(undoLabels: (undo: "Undo Move of “a.txt”", redo: "Redo")))
        let explorer = FakeExplorerWindow(id: 1)
        let settings = makeOffscreenWindow()
        routeTo(router, explorer, focused: false)
        router.focusedWindow = { settings }
        let edit = submenu(built.menu, "Edit")
        let undo = item(edit, "Undo Move of “a.txt”")

        #expect(accelerator(undo) == "Command+Z")
        #expect(accelerator(item(edit, "Redo")) == "Command+Shift+Z")
        choose(undo, router)
        choose(item(edit, "Redo"), router)

        #expect(log.calls == ["undo:", "redo:"])
        #expect(explorer.performed.isEmpty)

        // With the explorer focused the same item sends the command to it.
        routeTo(router, explorer)
        router.focusedWindow = { explorer.window }
        choose(undo, router)
        #expect(explorer.performed == [.undo])
    }

    @Test func closesAnotherFocusedWindowWithCommandWInsteadOfATabOfTheExplorer() {
        let (built, router, _) = make()
        let explorer = FakeExplorerWindow(id: 1)
        let settings = makeOffscreenWindow()
        let watcher = CloseWatcher()
        settings.delegate = watcher
        routeTo(router, explorer, focused: false)
        router.focusedWindow = { settings }

        choose(menuItem(built, "File", "Close Tab"), router)

        #expect(watcher.asked == 1)
        #expect(explorer.performed.isEmpty)
    }

    @Test func sendsACommandToTheExplorerWindowThatHasTheKeyboard() {
        let (built, router, _) = make()
        let front = FakeExplorerWindow(id: 1)
        let focused = FakeExplorerWindow(id: 2)
        router.explorerFor = { window in
            window === focused.window
                ? ExplorerCommandTarget(handle: focused, focused: true)
                : ExplorerCommandTarget(handle: front, focused: window == nil)
        }

        router.focusedWindow = { focused.window }
        choose(menuItem(built, "Go", "Back"), router)
        router.focusedWindow = { nil }
        choose(menuItem(built, "Go", "Forward"), router)

        #expect(focused.performed == [.goBack])
        #expect(front.performed == [.goForward])
    }

    @Test func hasTheHostOpenANewWindowWhileAnotherWindowIsFocused() {
        let (built, router, _) = make()
        let front = FakeExplorerWindow(id: 1)
        let settings = makeOffscreenWindow()
        var opened = 0
        router.onNewWindowFromOtherWindow = { opened += 1 }
        routeTo(router, front, focused: false)
        router.focusedWindow = { settings }

        choose(menuItem(built, "File", "New Window"), router)
        choose(menuItem(built, "Go", "Back"), router)

        // Not through the front window, which may not be able to take it (a sheet is open).
        #expect(opened == 1)
        #expect(front.performed.isEmpty)
    }

    @Test func doesNothingWithNoExplorerWindowToSendTo() {
        let (built, router, _) = make()
        router.explorerFor = { _ in nil }
        router.focusedWindow = { nil }

        choose(menuItem(built, "Go", "Back"), router)
    }

    @Test func withNoExplorerWindowOpensOneForNewWindowAndTheGoMenusPlaces() {
        let (built, router, log) = make()
        let settings = makeOffscreenWindow()
        var opened: [RendererCommand] = []
        router.onCommandWithoutExplorerWindow = { opened.append($0) }
        router.explorerFor = { _ in nil }

        router.focusedWindow = { nil }
        choose(menuItem(built, "File", "New Window"), router)
        router.focusedWindow = { settings }
        choose(menuItem(built, "Go", "Documents"), router)
        router.focusedWindow = { nil }
        choose(menuItem(built, "Go", "Go to Folder…"), router)
        choose(menuItem(built, "Go", "Back"), router)
        router.focusedWindow = { settings }
        choose(menuItem(built, "Edit", "Copy"), router)

        #expect(opened == [.newWindow, .goDocuments, .openLocationSheet])
        // Settings' own copy still works.
        #expect(log.calls == [NSStringFromSelector(#selector(NSText.copy(_:)))])
    }

    @Test func leavesTheExplorerAloneWhenAnotherWindowIsFocused() {
        let (built, router, _) = make()
        let explorer = FakeExplorerWindow(id: 1)
        routeTo(router, explorer, focused: false)
        router.focusedWindow = { makeOffscreenWindow() }

        choose(menuItem(built, "Go", "Back"), router)

        #expect(explorer.performed.isEmpty)
    }

    @Test func opensTheSettingsWindowDirectlyWhenTheHostProvidesIt() {
        let (built, router, _) = make()
        let explorer = FakeExplorerWindow(id: 1)
        routeTo(router, explorer)
        var opened = 0
        router.onOpenSettings = { opened += 1 }

        choose(menuItem(built, "File Trail", "Settings…"), router)

        #expect(opened == 1)
        #expect(explorer.performed.isEmpty)
    }

    @Test func opensTheAppsOwnAboutWindowInPlaceOfTheStandardPanel() {
        let (built, router, _) = make()
        var opened = 0
        router.onOpenAbout = { opened += 1 }

        choose(menuItem(built, "File Trail", "About File Trail"), router)

        #expect(opened == 1)
    }

    @Test func opensHelpsWindowFromAnyWindowOnTheKeyboardShortcutsPageForThatItem() {
        let (built, router, _) = make()
        let explorer = FakeExplorerWindow(id: 1)
        routeTo(router, explorer)
        var topics: [HelpTopicID?] = []
        router.onOpenHelp = { topics.append($0) }
        let help = submenu(built.menu, "Help")
        router.focusedWindow = { makeOffscreenWindow() }

        choose(item(help, "File Trail Help"), router)
        router.focusedWindow = { nil }
        choose(item(help, "Keyboard Shortcuts"), router)

        #expect(topics == [nil, .shortcuts])
        #expect(explorer.performed.isEmpty)
    }

    @Test func tellsTheHostAfterEachCommandSoItCanPutTheCheckmarksBack() {
        let (built, router, _) = make()
        let explorer = FakeExplorerWindow(id: 1)
        routeTo(router, explorer)
        var told = 0
        router.onCommandSent = { told += 1 }

        choose(menuItem(built, "View", "Hidden Files"), router)

        #expect(told == 1)
        #expect(explorer.performed == [.toggleHiddenFiles])
    }

    // The menu validates an item by the state the explorer window reported
    @Test func validatesAnItemByWhatTheStateSays() {
        let (built, router, _) = make()
        let goBack = menuItem(built, "Go", "Back")

        #expect(router.validateMenuItem(goBack))
        router.setItem("goBack", enabled: false)
        #expect(!router.validateMenuItem(goBack))
        router.resetEnabled()
        #expect(router.validateMenuItem(goBack))
    }
}
