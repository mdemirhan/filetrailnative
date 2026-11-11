import AppKit
import FTFoundation
import Testing

@testable import FTAppKit

@MainActor
@Suite struct ApplicationMenuSyncTests {
    @MainActor
    private final class Fixture {
        let list = ExplorerWindowList()
        let router = MenuCommandRouter()
        var sync: ApplicationMenuSync!
        var index: MenuItemIndex?
        var focused: NSWindow?
        /// The work queued for the end of the current task, run by `afterTask()`.
        var queued: [@MainActor () -> Void] = []

        init(built: Bool = true) {
            _ = NSApplication.shared
            sync = ApplicationMenuSync(
                .init(
                    windows: list, focusedWindow: { [unowned self] in focused }, menu: { [unowned self] in index },
                    afterCurrentTask: { [unowned self] work in queued.append(work) }))
            if built { build() }
        }

        /// Builds the menu, as the host does at launch and when the shortcuts or the text editor change.
        func build() {
            index = Self.index(router)
            sync.menuBuilt()
        }

        static func index(_ router: MenuCommandRouter) -> MenuItemIndex {
            MenuItemIndex(ApplicationMenuBuilder.build(target: router), router: router)
        }

        func open(_ id: Int) -> FakeExplorerWindow {
            let window = FakeExplorerWindow(id: id)
            list.add(window)
            return window
        }

        func afterTask() {
            let work = queued
            queued = []
            for item in work { item() }
        }

        func item(_ id: String) -> NSMenuItem {
            guard let found = index?.item(id) else { preconditionFailure("no item \(id)") }
            return found
        }
    }

    private let oneTab = ApplicationMenuState(disabledCommands: [.moveTabToNewWindow])

    @Test func showsTheStateOfTheFocusedExplorerWindowFollowingTheFocus() {
        let f = Fixture()
        let a = f.open(1)
        let b = f.open(2)
        f.sync.setWindowState(windowID: 1, oneTab)
        f.sync.setWindowState(windowID: 2, .initial)

        f.focused = a.window
        f.sync.sync()
        #expect(!f.item("moveTabToNewWindow").isEnabled)
        f.focused = b.window
        f.sync.sync()
        #expect(f.item("moveTabToNewWindow").isEnabled)
        #expect(f.item("mergeAllWindows").isEnabled)
    }

    @Test func doesntHearWindowsThatArentExplorerWindows() {
        let f = Fixture()
        let a = f.open(1)
        f.focused = a.window
        f.sync.setWindowState(windowID: 1, .initial)
        f.sync.setWindowState(windowID: 99, oneTab)
        f.sync.setWindowState(windowID: nil, oneTab)
        #expect(f.item("moveTabToNewWindow").isEnabled)
    }

    @Test func offersNewWindowAndTheGoMenusPlacesWithOnlySettingsOpen() {
        let f = Fixture()
        f.focused = makeOffscreenWindow()

        f.sync.sync()

        #expect(f.item("newWindow").isEnabled)
        #expect(f.item("goDesktop").isEnabled)
        #expect(!f.item("goBack").isEnabled)
        #expect(!f.item("emptyTrash").isEnabled)
    }

    @Test func sendsCommandsToTheFocusedExplorerWindowOrTheFrontOneFromAnotherWindow() {
        let f = Fixture()
        #expect(f.sync.explorerFor(nil) == nil)
        let a = f.open(1)
        let b = f.open(2)

        #expect(f.sync.explorerFor(a.window)?.handle === a)
        #expect(f.sync.explorerFor(a.window)?.focused == true)
        let fromSettings = f.sync.explorerFor(makeOffscreenWindow())
        #expect(fromSettings?.handle === b)
        #expect(fromSettings?.focused == false)
        let fromNone = f.sync.explorerFor(nil)
        #expect(fromNone?.handle === b)
        #expect(fromNone?.focused == true)
    }

    /// A sheet on `parent`, as AppKit reports one, without putting it on a window.
    private final class SheetWindow: NSWindow {
        weak var sheetOwner: NSWindow?
        override var sheetParent: NSWindow? { sheetOwner }
    }

    // A sheet hanging from an explorer window is that window.
    @Test func countsASheetAsItsExplorerWindow() {
        let f = Fixture()
        let a = f.open(1)
        let sheet = SheetWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.borderless], backing: .buffered,
            defer: true)
        sheet.sheetOwner = a.window

        #expect(f.sync.explorerFor(sheet)?.handle === a)
    }

    @Test func actsOnNoWindowAndOffersOnlyWhatOpensOneWhileEveryWindowIsMinimized() {
        let f = Fixture()
        let a = f.open(1)
        let b = f.open(2)
        f.list.bringToFront(b)
        f.sync.setWindowState(windowID: 2, .initial)
        f.focused = b.window
        f.sync.sync()
        #expect(f.item("trashSelection").isEnabled)

        a.isOnScreen = false
        b.isOnScreen = false
        f.focused = nil
        f.sync.sync()

        // ⌘⌫ or ⌘W would act on a window that can't be seen.
        #expect(f.sync.explorerFor(nil) == nil)
        #expect(!f.item("trashSelection").isEnabled)
        #expect(!f.item("closeTab").isEnabled)
        #expect(!f.item("renameSelection").isEnabled)
        #expect(!f.item("undo:text").isEnabled)
        #expect(f.item("newWindow").isEnabled)
        #expect(f.item("goDesktop").isEnabled)

        // One comes back on screen, and the menu acts on it again.
        b.isOnScreen = true
        f.sync.sync()
        #expect(f.sync.explorerFor(nil)?.handle === b)
        #expect(f.item("trashSelection").isEnabled)
    }

    @Test func actsOnTheWindowInFrontOnceSettingsClosesAndLeavesNoWindowFocused() {
        let f = Fixture()
        _ = f.open(1)
        f.sync.setWindowState(windowID: 1, .initial)
        f.focused = makeOffscreenWindow()
        f.sync.sync()
        #expect(!f.item("trashSelection").isEnabled)

        f.focused = nil
        f.sync.sync()

        #expect(f.item("trashSelection").isEnabled)
        #expect(!f.item("undo").isHidden)
    }

    // The same items, renamed: the menu is not built again.
    @Test func namesWhatUndoAndRedoWouldDoOnTheItemsTheMenuHas() {
        let f = Fixture()
        f.focused = f.open(1).window
        let undo = f.item("undo")
        let redo = f.item("redo")

        f.sync.setUndoHistory(UndoHistoryMenu(undo: "Move of “a.txt”", redo: "Rename"))
        f.afterTask()
        #expect(f.item("undo") === undo && f.item("redo") === redo)
        #expect(undo.title == "Undo Move of “a.txt”")
        #expect(redo.title == "Redo Rename")
        f.sync.setUndoHistory(UndoHistoryMenu(cantUndo: true))
        f.afterTask()
        #expect(undo.title == "Can’t Undo")
        #expect(redo.title == "Redo")
        #expect(f.item("undo") === undo)
    }

    @Test func namesUndoAfterTheTaskThatChangedTheHistoryOnceForAllItsChanges() {
        let f = Fixture()
        f.focused = f.open(1).window
        var order: [String] = []

        f.sync.setUndoHistory(UndoHistoryMenu(undo: "Move of “a.txt”"))
        f.sync.setUndoHistory(UndoHistoryMenu(undo: "Rename"))
        order.append("window told, \(f.item("undo").title)")
        f.afterTask()
        order.append(f.item("undo").title)

        #expect(order == ["window told, Undo", "Undo Rename"])
    }

    @Test func switchesToATextFieldsOwnUndoOnTheItemsTheMenuHas() {
        let f = Fixture()
        f.focused = f.open(1).window
        f.sync.setUndoHistory(UndoHistoryMenu(undo: "Move of “a.txt”", redo: "Rename"))
        f.afterTask()
        let items = ["undo", "undo:text", "redo", "redo:text"].map { f.item($0) }

        f.sync.setWindowState(windowID: 1, ApplicationMenuState(textEditing: true))
        #expect(f.item("undo").isHidden)
        #expect(!f.item("undo:text").isHidden)
        #expect(!f.item("redo:text").isHidden)
        f.sync.setWindowState(windowID: 1, .initial)
        #expect(!f.item("undo").isHidden)
        #expect(f.item("undo:text").isHidden)

        #expect(["undo", "undo:text", "redo", "redo:text"].map { f.item($0) } == items)
    }

    @Test func usesTheTextFieldsOwnUndoWhileSettingsHasTheKeyboardAndNoExplorerWindowIsOpen() {
        let f = Fixture()
        f.sync.setUndoHistory(UndoHistoryMenu(undo: "Move of “a.txt”"))
        f.afterTask()
        f.focused = makeOffscreenWindow()

        f.sync.sync()

        #expect(f.item("undo").isHidden)
        #expect(!f.item("undo:text").isHidden)
        #expect(f.item("undo:text").isEnabled)
        #expect(f.item("newWindow").isEnabled)
    }

    @Test func stopsNamingTheLastOperationInUndoOnceTheLastWindowHasClosed() {
        let f = Fixture()
        let a = f.open(1)
        f.focused = a.window
        f.sync.setUndoHistory(UndoHistoryMenu(undo: "Move of “a.txt”"))
        f.afterTask()
        #expect(f.item("undo").title == "Undo Move of “a.txt”")

        f.list.remove(a)
        f.focused = nil
        f.sync.windowsChanged()

        #expect(f.item("undo").isHidden)
        #expect(!f.item("undo:text").isHidden)
        #expect(!f.item("undo:text").isEnabled)
        #expect(!f.item("redo:text").isHidden)
        #expect(!f.item("redo:text").isEnabled)
    }

    @Test func letsGoOfAClosedWindowsState() {
        let f = Fixture()
        let a = f.open(1)
        f.focused = a.window
        f.sync.setWindowState(windowID: 1, oneTab)
        f.list.remove(a)
        f.sync.windowsChanged()
        f.list.add(a)
        f.sync.sync()
        #expect(f.item("moveTabToNewWindow").isEnabled)
    }

    // What the history said before the menu was built is what it shows once built.
    @Test func doesNothingBeforeTheMenuIsBuilt() {
        let f = Fixture(built: false)
        f.focused = f.open(1).window
        f.sync.setUndoHistory(UndoHistoryMenu(undo: "Rename"))
        f.afterTask()
        f.sync.sync()
        #expect(f.index == nil)
        f.build()
        #expect(f.item("undo").title == "Undo Rename")
    }

    // Each mark is set from what the window says: the view and the order it has on, the others off.
    @Test func checksWhatTheWindowShowsAndUnchecksTheRest() {
        let f = Fixture()
        f.focused = f.open(1).window

        f.sync.setWindowState(windowID: 1, ApplicationMenuState(viewMode: .icons, foldersFirst: false))
        #expect(f.item("viewAsIcons").state == .on)
        #expect(f.item("viewAsDetails").state == .off)
        #expect(f.item("toggleFoldersFirst").state == .off)
        f.sync.setWindowState(windowID: 1, ApplicationMenuState(viewMode: .details, sortBy: .size))
        #expect(f.item("viewAsIcons").state == .off)
        #expect(f.item("viewAsDetails").state == .on)
        #expect(f.item("sortBySize").state == .on)
        #expect(f.item("sortByName").state == .off)
        #expect(f.item("toggleFoldersFirst").state == .on)
        // One of each pair shows.
        #expect(!f.item("toggleFavorite:add").isHidden)
        #expect(f.item("toggleFavorite:remove").isHidden)
        #expect(!f.item("toggleFolderTree:hide").isHidden)
        #expect(f.item("toggleFolderTree:show").isHidden)
    }
}
