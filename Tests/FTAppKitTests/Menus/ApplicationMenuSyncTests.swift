// Ports apps/desktop/src/main/applicationMenuSync.test.ts
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
        var builds = 0
        /// The work queued for the end of the current task, run by `afterTask()`.
        var queued: [@MainActor () -> Void] = []

        init(built: Bool = true) {
            _ = NSApplication.shared
            sync = ApplicationMenuSync(
                .init(
                    windows: list, focusedWindow: { [unowned self] in focused }, menu: { [unowned self] in index },
                    build: { [unowned self] in
                        builds += 1
                        index = Self.index(router)
                        sync.menuBuilt()
                    }, afterCurrentTask: { [unowned self] work in queued.append(work) }))
            if built {
                index = Self.index(router)
                sync.menuBuilt()
            }
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

    // T-3c256a0b F-601 F-604
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

    // T-9dea35da F-641
    @Test func doesntHearWindowsThatArentExplorerWindows() {
        let f = Fixture()
        let a = f.open(1)
        f.focused = a.window
        f.sync.setWindowState(windowID: 1, .initial)
        f.sync.setWindowState(windowID: 99, oneTab)
        f.sync.setWindowState(windowID: nil, oneTab)
        #expect(f.item("moveTabToNewWindow").isEnabled)
    }

    // T-72c562dc F-599 F-600
    @Test func offersNewWindowAndTheGoMenusPlacesWithOnlySettingsOpen() {
        let f = Fixture()
        f.focused = makeOffscreenWindow()

        f.sync.sync()

        #expect(f.item("newWindow").isEnabled)
        #expect(f.item("goDesktop").isEnabled)
        #expect(!f.item("goBack").isEnabled)
        #expect(!f.item("emptyTrash").isEnabled)
    }

    // T-a6db3ae1 F-604
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

    // T-7bf0123d F-604
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
        f.sync.refresh()

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
        f.sync.refresh()
        #expect(f.sync.explorerFor(nil)?.handle === b)
        #expect(f.item("trashSelection").isEnabled)
    }

    // T-e19dcd55 F-604
    @Test func actsOnTheWindowInFrontOnceSettingsClosesAndLeavesNoWindowFocused() {
        let f = Fixture()
        _ = f.open(1)
        f.sync.setWindowState(windowID: 1, .initial)
        f.focused = makeOffscreenWindow()
        f.sync.sync()
        #expect(!f.item("trashSelection").isEnabled)

        f.focused = nil
        f.sync.refresh()

        #expect(f.item("trashSelection").isEnabled)
        #expect(!f.item("undo").isHidden)
    }

    // T-ee9cb945 F-598
    @Test func buildsTheMenuAgainOnlyWhenUndoOrRedoShouldSaySomethingElse() {
        let f = Fixture()
        f.focused = f.open(1).window

        f.sync.setUndoHistory(UndoHistoryMenu(undo: "Move of “a.txt”"))
        f.afterTask()
        #expect(f.builds == 1)
        #expect(f.sync.undoLabels().undo == "Undo Move of “a.txt”")
        f.sync.setUndoHistory(UndoHistoryMenu(undo: "Move of “a.txt”"))
        f.afterTask()
        #expect(f.builds == 1)
    }

    // T-679e824e F-605
    @Test func buildsTheMenuAfterTheTaskThatChangedTheHistoryOnceForAllItsChanges() {
        let f = Fixture()
        f.focused = f.open(1).window
        var order: [String] = []

        f.sync.setUndoHistory(UndoHistoryMenu(undo: "Move of “a.txt”"))
        f.sync.setUndoHistory(UndoHistoryMenu(undo: "Rename"))
        order.append("window told, \(f.builds) builds")
        f.afterTask()
        order.append("\(f.builds) builds")

        #expect(order == ["window told, 0 builds", "1 builds"])
        #expect(f.sync.undoLabels().undo == "Undo Rename")
    }

    // T-8a4dbd2c F-602
    // T-7b2fe094
    @Test func switchesToATextFieldsOwnUndoWithoutBuildingTheMenuAgain() {
        let f = Fixture()
        f.focused = f.open(1).window
        f.sync.setUndoHistory(UndoHistoryMenu(undo: "Move of “a.txt”", redo: "Rename"))
        f.afterTask()
        let built = f.builds

        f.sync.setWindowState(windowID: 1, ApplicationMenuState(textEditing: true))
        #expect(f.item("undo").isHidden)
        #expect(!f.item("undo:text").isHidden)
        #expect(!f.item("redo:text").isHidden)
        f.sync.setWindowState(windowID: 1, .initial)
        #expect(!f.item("undo").isHidden)
        #expect(f.item("undo:text").isHidden)

        #expect(f.builds == built)
    }

    // T-0e5abac8 F-602
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

    // T-151dc0d2 F-602
    @Test func stopsNamingTheLastOperationInUndoOnceTheLastWindowHasClosed() {
        let f = Fixture()
        let a = f.open(1)
        f.focused = a.window
        f.sync.setUndoHistory(UndoHistoryMenu(undo: "Move of “a.txt”"))
        f.afterTask()
        #expect(f.builds == 1)

        f.list.remove(a)
        f.focused = nil
        f.sync.windowsChanged()

        #expect(f.item("undo").isHidden)
        #expect(!f.item("undo:text").isHidden)
        #expect(!f.item("undo:text").isEnabled)
        #expect(!f.item("redo:text").isHidden)
        #expect(!f.item("redo:text").isEnabled)
    }

    // T-32be2fc0
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

    // T-0641022e
    @Test func doesNothingBeforeTheMenuIsBuilt() {
        let f = Fixture(built: false)
        f.sync.setUndoHistory(UndoHistoryMenu(undo: "Rename"))
        f.afterTask()
        f.sync.sync()
        #expect(f.builds == 0)
        #expect(f.sync.undoLabels().undo == "Undo Rename")
    }

    // F-603: radio items are only ever switched on, and switching one on switches the others of its menu off
    // B-VIEW-226 T-a1688568
    @Test func checksWhatTheWindowShowsAndSwitchesTheRadioGroupOver() {
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
        // F-575 F-586: one of each pair shows.
        #expect(!f.item("toggleFavorite:add").isHidden)
        #expect(f.item("toggleFavorite:remove").isHidden)
        #expect(!f.item("toggleFolderTree:hide").isHidden)
        #expect(f.item("toggleFolderTree:show").isHidden)
    }
}
