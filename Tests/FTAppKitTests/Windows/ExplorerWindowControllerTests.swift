import FTFileSystem
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

@MainActor
@Suite struct ExplorerWindowControllerStartupTests {
    @Test func bringsBackEveryWindowShownBackToFrontOnceAllAreReadyTheFrontOneFocused() async throws {
        let store = try makeStore()
        add(store, storedWindow(store, "window-b", ["/Users/demo/b"], maximized: true))
        add(store, storedWindow(store, "window-a", ["/Users/demo/a"]))
        let setup = try WindowSetup(store: store)

        setup.controller.openStartupWindows(folder: "/Users/demo/launched")
        setup.window("window-a")?.events.readyToShow()
        await settle()
        #expect(setup.log.isEmpty)
        setup.window("window-b")?.events.readyToShow()
        await settle()

        #expect(setup.log == ["maximize window-b", "showInactive window-b", "show window-a"])
        #expect(setup.controller.windows.all.map(\.id) == ["window-a", "window-b"])
        // The folder File Trail was launched with goes to the window in front.
        #expect(
            setup.controller.launchContext(for: setup.window("window-a")?.windowID)
                == ExplorerLaunchContext(startupFolderPath: "/Users/demo/launched"))
        #expect(setup.controller.launchContext(for: setup.window("window-b")?.windowID) == ExplorerLaunchContext())
    }

    @Test func showsTheWindowsAnywayWhenAFirstFolderNeverComes() throws {
        let store = try makeStore()
        add(store, storedWindow(store, "window-a", ["/Users/demo/a"]))
        let setup = try WindowSetup(store: store)

        setup.controller.openStartupWindows(folder: nil)
        setup.scheduler.advance(ExplorerWindowController<FakeWindow>.startupShowTimeoutMilliseconds)

        #expect(setup.log == ["show window-a"])
        // Ready late, it isn't shown again.
        setup.window("window-a")?.events.readyToShow()
        #expect(setup.log == ["show window-a"])
    }

    @Test func opensOnlyTheFrontWindowWhenTheLastFoldersArentReopenedAndForgetsTheRest() throws {
        let store = try makeStore(#"{"preferences":{"restoreSessionOnStartup":false},"windows":[]}"#)
        add(store, storedWindow(store, "window-b", ["/Users/demo/b"]))
        add(store, storedWindow(store, "window-a", ["/Users/demo/a"]))
        let setup = try WindowSetup(store: store)

        setup.controller.openStartupWindows(folder: nil)

        #expect(setup.windows.map(\.recordID) == ["window-a"])
        #expect(store.explorerWindows().map(\.id) == ["window-a"])
    }

    @Test func opensOneWindowAsTheWindowClosedLastEndedWhenNoneWasOpenAtQuit() throws {
        let store = try makeStore()
        add(store, storedWindow(store, "window-old", ["/Users/demo/a", "/Users/demo/b"], x: 40, y: 50))
        store.rememberClosedWindow("window-old")
        store.removeExplorerWindow("window-old")
        let setup = try WindowSetup(store: store)

        setup.controller.openStartupWindows(folder: nil)

        #expect(setup.windows.count == 1)
        let record = store.explorerWindows().first
        #expect(record?.id == "window-new-1")
        #expect(record?.bounds.x == 40)
        #expect(record?.bounds.y == 50)
        #expect(record?.session.openTabs.map(\.path) == ["/Users/demo/a"])
    }
}

@MainActor
@Suite struct ExplorerWindowControllerOpeningTests {
    @Test func opensAWindowFromAnotherWithItsTabsAndPanelsAStepDownAndToTheRight() throws {
        let setup = try WindowSetup.withWindows(1)
        let first = try #require(setup.windows.first)
        setup.store.updateWindowPreferences(first.recordID, ["propertiesOpen": .bool(true), "treeWidth": .number(333)])

        #expect(
            setup.controller.openWindowFrom(
                first.windowID, tabs: [tab("/Users/demo/x"), tab("/Users/demo/y")], activeTabIndex: 5))

        let opened = try #require(setup.windows.last)
        let record = try #require(setup.store.explorerWindows().first)
        #expect(record.id == opened.recordID)
        #expect(
            record.bounds
                == StoredWindowState(
                    x: 100 + ExplorerWindowPlacement.newWindowOffset, y: 80 + ExplorerWindowPlacement.newWindowOffset,
                    width: 900, height: 600, maximized: false))
        #expect(record.session.activeTabIndex == 1)
        #expect(record.session.lastVisitedPath == "/Users/demo/y")
        #expect(record.session.propertiesOpen)
        #expect(record.session.treeWidth == 333)
        #expect(setup.controller.launchContext(for: opened.windowID).restoreTabs)
        // Shown once its first folder is drawn.
        opened.events.readyToShow()
        #expect(setup.log.last == "show \(opened.recordID)")
        #expect(!setup.controller.openWindowFrom(first.windowID, tabs: [], activeTabIndex: 0))
    }

    @Test func opensAWindowFromNoWindowAtTheDefaultSizeWithTheAppsLatestPanels() throws {
        let setup = try WindowSetup()
        setup.store.updatePreferences(["propertiesOpen": .bool(true)])

        #expect(setup.controller.openWindowFrom(nil, tabs: [tab("/Users/demo/x")], activeTabIndex: 0))

        let record = try #require(setup.store.explorerWindows().first)
        #expect(record.bounds == .default)
        #expect(record.session.propertiesOpen)
    }

    @Test func opensAWindowWhereTheLastOneClosedToRunACommandChosenWithNoneOpen() throws {
        let setup = try WindowSetup()

        setup.controller.openDefaultWindow(initialCommand: .goDesktop)

        let window = try #require(setup.windows.first)
        let expected = ExplorerLaunchContext(initialCommand: .goDesktop)
        #expect(setup.controller.launchContext(for: window.windowID) == expected)
        // The window is made with it: it runs the command once, as it opens.
        #expect(setup.launches[window.recordID] == expected)
    }

    @Test func givesTheLaunchFolderToTheWindowAsItIsMade() throws {
        let store = try makeStore()
        add(store, storedWindow(store, "window-a", ["/Users/demo/a"]))
        let setup = try WindowSetup(store: store)

        setup.controller.openStartupWindows(folder: "/Users/demo/launched")

        #expect(setup.launches["window-a"] == ExplorerLaunchContext(startupFolderPath: "/Users/demo/launched"))
    }

    @Test func opensNewWindowFromTheDockOnTheFrontWindowsTabOrOneWhereTheLastClosed() throws {
        let setup = try WindowSetup()

        setup.controller.openNewWindowFromFront()
        #expect(setup.windows.count == 1)
        let front = try #require(setup.windows.first)
        setup.store.updateWindowPreferences(
            front.recordID,
            [
                "openTabs": node([tab("/Users/demo/a"), tab("/Users/demo/b")]), "activeTabIndex": .number(1),
                "propertiesOpen": .bool(true),
            ])

        // Opened here, not by the window in front, which can't while a sheet is open in it.
        setup.controller.openNewWindowFromFront()

        #expect(setup.windows.count == 2)
        #expect(front.told.isEmpty)
        let opened = setup.store.windowPreferences(setup.windows[1].recordID)
        #expect(opened.openTabs == [tab("/Users/demo/b")])
        #expect(opened.propertiesOpen)
    }

    @Test func bringsTheWindowInFrontForwardForASecondLaunchOrOpensOne() throws {
        let setup = try WindowSetup()
        setup.controller.bringToFront()
        #expect(setup.windows.count == 1)
        let window = try #require(setup.windows.first)
        window.minimized = true

        setup.controller.bringToFront()

        #expect(!window.minimized)
        #expect(window.focused == 1)
        #expect(setup.windows.count == 1)
    }

    @Test func opensAWindowZoomedWithNoneOpenWhenTheWindowClosedLastWas() throws {
        let store = try makeStore()
        add(store, storedWindow(store, "window-old", ["/Users/demo"], maximized: true))
        store.rememberClosedWindow("window-old")
        store.removeExplorerWindow("window-old")
        let setup = try WindowSetup(store: store)

        setup.controller.openDefaultWindow()
        setup.windows.first?.events.readyToShow()

        #expect(setup.log == ["maximize window-new-1", "show window-new-1"])
    }

    @Test func tellsTheMenuWhenAWindowIsMinimizedOrComesBack() throws {
        let setup = try WindowSetup.withWindows(1)
        setup.windowsChanged = 0

        setup.windows.first?.events.visibilityChanged()
        setup.windows.first?.events.visibilityChanged()

        #expect(setup.windowsChanged == 2)
    }
}

@MainActor
@Suite struct ExplorerWindowControllerOpenFileTests {
    let image = OpenRequest(path: "/Users/demo/Install.dmg", kind: .diskImage)

    @Test func givesThemToTheWindowInFrontOnceAndTellsItTheyAreWaiting() throws {
        let setup = try WindowSetup.withWindows(2)
        let back = setup.windows[0]
        let front = setup.windows[1]

        let projects = OpenRequest(path: "/Users/demo/Projects", kind: .folder)
        #expect(setup.controller.openFromOtherApp(image))
        #expect(setup.controller.openFromOtherApp(projects))

        #expect(front.told == [.openRequestsWaiting, .openRequestsWaiting])
        #expect(back.told.isEmpty)
        #expect(setup.controller.takeOpenRequests(back.windowID).isEmpty)
        #expect(setup.controller.takeOpenRequests(front.windowID) == [image, projects])
        #expect(setup.controller.takeOpenRequests(front.windowID).isEmpty)
    }

    @Test func saysSoWithNoWindowOpenToTakeThemAndBringsBackAMinimizedOne() throws {
        let setup = try WindowSetup()

        #expect(!setup.controller.openFromOtherApp(image))
        #expect(setup.windows.isEmpty)

        setup.controller.openStartupWindows(folder: nil)
        let window = try #require(setup.windows.first)
        window.visible = true
        window.minimized = true
        #expect(setup.controller.openFromOtherApp(image))
        #expect(setup.windows.count == 1)
        #expect(!window.minimized)
        #expect(window.focused == 1)
    }

    @Test func opensAWindowOnADiskAloneWhereTheWindowClosedLastWas() async throws {
        let setup = try WindowSetup.withWindows(1)
        setup.windows[0].close()
        await settle()

        setup.controller.openWindowOnFolder("/Volumes/Install")

        let opened = try #require(setup.windows.last)
        #expect(setup.windows.count == 2)
        #expect(
            setup.controller.launchContext(for: opened.windowID)
                == ExplorerLaunchContext(startupFolderPath: "/Volumes/Install"))
        #expect(setup.store.windowPreferences(opened.recordID).openTabs.isEmpty)
        #expect(setup.controller.takeOpenRequests(opened.windowID).isEmpty)
    }

    @Test func opensAWindowOnAnItemsFolderWhichThenSelectsTheItem() throws {
        let setup = try WindowSetup()

        setup.controller.openWindowOnFolder("/Users/demo/Notes", selecting: "/Users/demo/Notes/todo.txt")

        let opened = try #require(setup.windows.first)
        #expect(
            setup.controller.launchContext(for: opened.windowID)
                == ExplorerLaunchContext(startupFolderPath: "/Users/demo/Notes"))
        #expect(opened.told == [.openRequestsWaiting])
        #expect(
            setup.controller.takeOpenRequests(opened.windowID) == [
                OpenRequest(path: "/Users/demo/Notes/todo.txt", kind: .select)
            ])
    }

    @Test func opensNothingWhileQuitting() async throws {
        let setup = try WindowSetup.withWindows(1)
        await setup.quit.quit()

        #expect(setup.controller.openFromOtherApp(image))
        setup.controller.openWindowOnFolder("/Volumes/Install")

        #expect(setup.windows.count == 1)
        #expect(setup.controller.takeOpenRequests(setup.windows[0].windowID).isEmpty)
    }
}

@MainActor
@Suite struct ExplorerWindowControllerOrderAndBoundsTests {
    @Test func keepsTheWindowFocusedLastInFrontInTheStoreToo() throws {
        let setup = try WindowSetup.withWindows(3)
        func ids() -> [String] { setup.store.explorerWindows().map(\.id) }
        #expect(ids() == setup.controller.windows.all.map(\.id))

        setup.windows[0].focus()

        #expect(setup.controller.windows.front?.window === setup.windows[0])
        #expect(ids() == setup.controller.windows.all.map(\.id))
        #expect(ids().first == setup.windows[0].recordID)
    }

    @Test func recordsAFullScreenWindowsPlaceAndSizeOutOfFullScreen() throws {
        let setup = try WindowSetup.withWindows(2)
        let window = setup.windows[0]
        window.fullScreen = true
        window.bounds = WindowBounds(x: 0, y: 0, width: 1600, height: 1000)

        // A window opened from it is the size it is out of full screen.
        setup.controller.openWindowFrom(window.windowID, tabs: [tab("/Users/demo/x")], activeTabIndex: 0)
        #expect(setup.store.explorerWindows().first?.bounds.width == 900)
        #expect(setup.store.explorerWindows().first?.bounds.height == 600)
        _ = window.events.shouldClose()

        #expect(
            setup.store.explorerWindows().first { $0.id == window.recordID }?.bounds
                == StoredWindowState(x: 100, y: 80, width: 900, height: 600, maximized: false))
    }

    @Test func recordsWhereAWindowIsOnceItStopsMovingAndAsItCloses() throws {
        let setup = try WindowSetup.withWindows(2)
        let window = setup.windows[0]
        func recorded() -> StoredWindowState? {
            setup.store.explorerWindows().first { $0.id == window.recordID }?.bounds
        }

        window.bounds = WindowBounds(x: 300, y: 200, width: 1000, height: 700)
        window.events.boundsChanged()
        #expect(recorded()?.x != 300)
        setup.scheduler.advance(ExplorerWindowController<FakeWindow>.boundsSaveDelayMilliseconds)
        #expect(recorded() == StoredWindowState(x: 300, y: 200, width: 1000, height: 700, maximized: false))

        window.maximized = true
        window.bounds = WindowBounds(x: 0, y: 0, width: 1600, height: 1000)
        _ = window.events.shouldClose()
        #expect(recorded() == StoredWindowState(x: 100, y: 80, width: 900, height: 600, maximized: true))
    }
}

@MainActor
@Suite struct ExplorerWindowControllerClosingTests {
    @Test func forgetsAWindowClosedByHandAndRemembersItAsTheWindowClosedLast() async throws {
        let setup = try WindowSetup.withWindows(2)
        let window = setup.windows[0]
        setup.windowsChanged = 0

        window.close()
        await settle()

        #expect(setup.controller.windows.count == 1)
        #expect(!setup.store.explorerWindows().map(\.id).contains(window.recordID))
        #expect(setup.store.lastClosedWindow()?.id == window.recordID)
        #expect(setup.windowsChanged > 0)
    }

    @Test func keepsAWindowClosedWhileQuittingToBringItBackAtTheNextLaunch() async throws {
        let setup = try WindowSetup.withWindows(2)
        await setup.quit.quit()

        setup.windows[1].close()
        await settle()

        #expect(setup.store.explorerWindows().count == 2)
        #expect(setup.store.lastClosedWindow() == nil)
    }

    @Test func asksBeforeClosingTheLastWindowStopsACopyAndKeepsWorkingWhenToldTo() async throws {
        let setup = try WindowSetup.withWindows(1)
        setup.runOperation(.copy)
        let window = setup.windows[0]

        window.close()
        await settle()

        #expect(setup.questions.count == 1)
        #expect(setup.questions.first?.question.buttons == ["Keep Working", "Stop and Close"])
        #expect(setup.controller.stopQuestionParent === window)
        // ⌘W again while the question is up does nothing more.
        window.close()
        #expect(setup.questions.count == 1)
        setup.questions[0].answer(QuitWhileBusy.keepWorkingButtonIndex)
        await settle()
        #expect(!window.destroyed)
        #expect(setup.controller.windows.count == 1)

        window.close()
        await settle()
        setup.questions[1].answer(QuitWhileBusy.stopButtonIndex)
        await settle()
        #expect(window.destroyed)
        #expect(setup.controller.windows.count == 0)
    }

    @Test func bringsTheQuestionForwardWhenQuitOrAnotherCloseComesWhileItIsOpen() async throws {
        let setup = try WindowSetup.withWindows(1)
        setup.runOperation(.copy)
        let window = setup.windows[0]
        window.close()
        await settle()
        window.minimized = true

        #expect(await setup.quit.quit() == .questionBroughtForward)

        #expect(setup.questions.count == 1)
        #expect(!window.minimized)
        #expect(window.focused == 1)
        #expect(setup.exits == 0)
        // A window opened meanwhile isn't closed either while the question waits.
        setup.controller.openWindowFrom(window.windowID, tabs: [tab("/Users/demo/x")], activeTabIndex: 0)
        setup.windows[1].close()
        #expect(!setup.windows[1].destroyed)
        #expect(window.focused == 2)
        setup.questions[0].answer(QuitWhileBusy.keepWorkingButtonIndex)
        await settle()
    }

    @Test func stopsTheOperationWithStopAndCloseEvenWithAWindowOpenedWhileItAsked() async throws {
        let setup = try WindowSetup.withWindows(1)
        setup.runOperation(.copy)
        let first = setup.windows[0]
        first.close()
        await settle()

        setup.controller.openWindowFrom(first.windowID, tabs: [tab("/Users/demo/x")], activeTabIndex: 0)
        setup.questions[0].answer(QuitWhileBusy.stopButtonIndex)
        await settle()

        #expect(first.destroyed)
        #expect(!setup.windows[1].destroyed)
        // Not handed to the new window: it is stopped.
        #expect(setup.controller.successor(of: first.windowID) == nil)
    }

    @Test func asksTheSameWhenCommandWClosesTheLastTabOfTheLastWindow() async throws {
        let setup = try WindowSetup.withWindows(1)
        setup.runOperation(.copy)
        let window = setup.windows[0]
        // Moved just before ⌘W, before the place was recorded.
        window.bounds = WindowBounds(x: 321, y: 123, width: 1000, height: 700)
        window.events.boundsChanged()

        #expect(setup.controller.closeWindow(of: window.windowID))
        await settle()

        #expect(setup.store.explorerWindows().first?.bounds.x == 321)
        #expect(setup.store.explorerWindows().first?.bounds.y == 123)
        #expect(setup.questions.map(\.question.buttons) == [["Keep Working", "Stop and Close"]])
        setup.questions[0].answer(QuitWhileBusy.keepWorkingButtonIndex)
        await settle()
        // The window stays, and so the copy keeps running in it.
        #expect(!window.destroyed)
        #expect(!setup.controller.closeWindow(of: 12_345))
    }

    @Test func asksOnceWhenTheLastTwoWindowsCloseTogetherWhileOneOfThemCopies() async throws {
        let setup = try WindowSetup.withWindows(2)
        setup.runOperation(.copy)
        let first = setup.windows[0]
        let second = setup.windows[1]

        // Close All, or ⌥-click on a close button: both in the same moment.
        first.close()
        second.close()
        await settle()

        #expect(setup.questions.count == 1)
        #expect(first.destroyed)
        // The copy is handed to the window still open, which asks before it goes too.
        #expect(setup.controller.successor(of: first.windowID) === second)
        setup.questions[0].answer(QuitWhileBusy.keepWorkingButtonIndex)
        await settle()
        #expect(!second.destroyed)
    }

    @Test func doesntHandACopyToAWindowThatIsClosingToo() async throws {
        let setup = try WindowSetup.withWindows(3)
        let first = setup.windows[0]

        setup.windows[2].close()
        #expect(setup.controller.successor(of: first.windowID) === setup.windows[1])
        setup.windows[1].close()
        #expect(setup.controller.successor(of: first.windowID) == nil)
        await settle()
    }

    @Test func closesTheLastWindowWithoutAskingWhenNothingWorthAskingAboutRuns() async throws {
        let setup = try WindowSetup.withWindows(1)
        setup.runOperation(.rename)
        setup.windows[0].close()
        await settle()
        #expect(setup.questions.isEmpty)
        #expect(setup.windows[0].destroyed)
    }

    @Test func closesOneOfSeveralWindowsWithoutAskingAndHandsItsCopyToAnother() async throws {
        let setup = try WindowSetup.withWindows(2)
        setup.runOperation(.copy)
        let first = setup.windows[0]
        let second = setup.windows[1]

        #expect(setup.controller.successor(of: second.windowID) === first)
        second.close()
        await settle()

        #expect(setup.questions.isEmpty)
        #expect(second.destroyed)
        #expect(setup.controller.successor(of: first.windowID) == nil)
    }
}

@MainActor
@Suite struct ExplorerWindowControllerMergeTests {
    @Test func handsOverTheOtherWindowsTabsAsTheyAreNowFrontToBackAndClosesThem() async throws {
        let setup = try WindowSetup.withWindows(3)
        let first = setup.windows[0]
        // Gone somewhere else a moment ago, not saved yet.
        setup.answerTabs(setup.windows[2], WindowTabsAnswer(tabs: [tab("/Users/demo/2/Sub")], busy: false))

        let tabs = setup.controller.mergeInto(first.windowID, tabCount: 1)
        await settle()

        #expect(tabs.map(\.path) == ["/Users/demo/2/Sub", "/Users/demo/1"])
        #expect(setup.windows[1].destroyed)
        #expect(setup.windows[2].destroyed)
        // Merged windows weren't closed by hand.
        #expect(setup.store.lastClosedWindow() == nil)
        #expect(setup.controller.windows.count == 1)
        #expect(setup.controller.mergeInto(12_345, tabCount: 1).isEmpty)
    }

    @Test func leavesOpenABusyWindowAndOneWhoseTabsDontFit() async throws {
        let setup = try WindowSetup.withWindows(4)
        // In front of the first window, front to back: inFront, leftOut, renaming.
        let first = setup.windows[0]
        let renaming = setup.windows[1]
        let leftOut = setup.windows[2]
        let inFront = setup.windows[3]
        setup.answerTabs(renaming, WindowTabsAnswer(tabs: [tab("/Users/demo/renaming")], busy: true))
        setup.answerTabs(leftOut, WindowTabsAnswer(tabs: [tab("/Users/demo/a"), tab("/Users/demo/b")], busy: false))
        setup.answerTabs(inFront, WindowTabsAnswer(tabs: [tab("/Users/demo/c"), tab("/Users/demo/d")], busy: false))

        // Room for three more tabs.
        let tabs = setup.controller.mergeInto(first.windowID, tabCount: AppPreferenceLimits.openTabsLimit - 3)
        await settle()

        #expect(tabs.map(\.path) == ["/Users/demo/c", "/Users/demo/d"])
        #expect(setup.windows.filter(\.destroyed).map(\.windowID) == [inFront.windowID])
        #expect(setup.controller.windows.count == 3)
    }

    @Test func mergesNothingWhileQuitting() async throws {
        let setup = try WindowSetup.withWindows(2)
        setup.shutDownHeld = true
        let first = setup.windows[0]

        Task { await setup.quit.quit() }
        await settle()

        #expect(setup.controller.mergeInto(first.windowID, tabCount: 1).isEmpty)
        await settle()
        #expect(!setup.windows[1].destroyed)
    }
}

@MainActor
@Suite struct ExplorerWindowControllerQuittingTests {
    @Test func opensNoWindowWhileQuitting() async throws {
        let setup = try WindowSetup.withWindows(1)
        setup.shutDownHeld = true
        Task { await setup.quit.quit() }
        await settle()
        setup.windows[0].close()
        await settle()

        setup.controller.openDefaultWindow()
        setup.controller.openNewWindowFromFront()
        setup.controller.openWindowOnFolder("/Volumes/Install")

        #expect(!setup.controller.openWindowFrom(nil, tabs: [tab("/Users/demo")], activeTabIndex: 0))
        #expect(setup.windows.count == 1)
    }

    @Test func asksOnceWithOnlySettingsOpenAndHasNoWindowToBringForwardForQuitAgain() async throws {
        let setup = try WindowSetup()
        setup.runOperation(.copy)
        setup.quit.hooks.anyWindowOpen = { true }
        var forward = 0
        setup.quit.hooks.bringStopQuestionForward = {
            if !setup.controller.bringStopQuestionForward() { forward += 1 }
        }

        let quitting = Task { await setup.quit.quit() }
        await settle()
        #expect(await setup.quit.quit() == .questionBroughtForward)

        #expect(setup.questions.count == 1)
        #expect(setup.controller.stopQuestionParent == nil)
        #expect(forward == 1)
        setup.questions[0].answer(QuitWhileBusy.keepWorkingButtonIndex)
        #expect(await quitting.value == .keptWorking)
        #expect(setup.exits == 0)
    }

    @Test func recordsTheWindowsBoundsBeforeExiting() async throws {
        let setup = try WindowSetup.withWindows(1)
        setup.runOperation(.copy)
        setup.windows[0].bounds = WindowBounds(x: 5, y: 6, width: 1000, height: 700)

        let quitting = Task { await setup.quit.quit() }
        await settle()
        setup.questions[0].answer(QuitWhileBusy.stopButtonIndex)
        #expect(await quitting.value == .exited)

        #expect(setup.store.explorerWindows().first?.bounds.x == 5)
        #expect(setup.store.explorerWindows().first?.bounds.y == 6)
        #expect(setup.exits == 1)
    }
}
