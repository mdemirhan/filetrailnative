// Checks opening a workspace in a window, on stand-in windows: where it opens, and the window it takes the place of
import AppKit
import FTFileSystem
import FTFoundation
import Testing

@testable import FTAppKit

@MainActor
struct WorkspaceWindowTests {
    static func workspace(_ id: String = "workspace-a", maximized: Bool = false) -> Workspace {
        var session = AppPreferences.defaults().windowSession
        session.openTabs = [tab("/Users/demo/a"), tab("/Users/demo/b")]
        session.activeTabIndex = 1
        session.treeWidth = 333
        return Workspace(
            id: id, name: "Work", bounds: StoredWindowState(width: 1000, height: 700, maximized: maximized),
            session: session)
    }

    @Test func opensAStepDownFromTheWindowInFrontAtItsOwnSize() async throws {
        let setup = try WindowSetup.withWindows(1)
        let front = try #require(setup.windows.first)
        var shown = 0

        let opened = try #require(setup.controller.openWorkspace(Self.workspace()) { shown += 1 })

        let record = try #require(setup.store.explorerWindows().first)
        #expect(record.id == opened.recordID)
        let offset = ExplorerWindowPlacement.newWindowOffset
        #expect(
            record.bounds
                == StoredWindowState(x: 100 + offset, y: 80 + offset, width: 1000, height: 700, maximized: false))
        #expect(record.session.openTabs.map(\.path) == ["/Users/demo/a", "/Users/demo/b"])
        #expect(record.session.activeTabIndex == 1)
        #expect(record.session.treeWidth == 333)
        #expect(setup.launches[opened.recordID]?.restoreTabs == true)

        opened.events.readyToShow()
        #expect(setup.log.last == "show \(opened.recordID)")
        #expect(shown == 1)
        // The window it opened beside stays.
        #expect(!front.destroyed)
    }

    @Test func opensCenteredWithNoWindowOpenAndZoomedWhenItWasSavedSo() throws {
        let setup = try WindowSetup()

        let opened = try #require(setup.controller.openWorkspace(Self.workspace(maximized: true)))

        let record = try #require(setup.store.explorerWindows().first)
        #expect(record.bounds == StoredWindowState(width: 1000, height: 700, maximized: true))
        opened.events.readyToShow()
        #expect(setup.log.suffix(2) == ["maximize \(opened.recordID)", "show \(opened.recordID)"])
    }

    @Test func opensAsSavedInANewWindowAlsoWhileAWindowFromItIsOpen() throws {
        let setup = try WindowSetup()
        let first = try #require(setup.controller.openWorkspace(Self.workspace()))
        // The window from it may have changed since: it isn't what the key brings.
        setup.store.updateWindow(first.recordID) { $0.openTabs = [tab("/Users/demo/elsewhere")] }

        let second = try #require(setup.controller.openWorkspace(Self.workspace()))

        #expect(second !== first)
        #expect(first.focused == 0)
        #expect(
            setup.store.windowPreferences(second.recordID).openTabs.map(\.path) == ["/Users/demo/a", "/Users/demo/b"])
    }

    @Test func inPlaceOfAWindowItTakesItsPlaceAndSizeAndTheWindowClosesOnceItIsShown() async throws {
        let setup = try WindowSetup.withWindows(1)
        let old = try #require(setup.windows.first)
        old.bounds = WindowBounds(x: 300, y: 200, width: 1100, height: 800)
        let closedBefore = setup.store.lastClosedWindow()

        let opened = try #require(setup.controller.openWorkspace(Self.workspace(), replacing: old.windowID))

        let record = try #require(setup.store.explorerWindows().first { $0.id == opened.recordID })
        #expect(record.bounds == StoredWindowState(x: 300, y: 200, width: 1100, height: 800, maximized: false))
        // It waits for the new window to be on screen.
        #expect(!old.destroyed)
        opened.events.readyToShow()
        await settle()
        #expect(old.destroyed)
        #expect(setup.store.explorerWindows().map(\.id) == [opened.recordID])
        // Not remembered as the window closed last: it was replaced.
        #expect(setup.store.lastClosedWindow() == closedBefore)
    }

    @Test func aWindowOpenedFromTheWorkspaceIsReplacedTooSoItOpensAsSaved() async throws {
        let setup = try WindowSetup()
        let first = try #require(setup.controller.openWorkspace(Self.workspace()))
        first.events.readyToShow()

        let again = try #require(setup.controller.openWorkspace(Self.workspace(), replacing: first.windowID))

        #expect(again !== first)
        again.events.readyToShow()
        await settle()
        #expect(first.destroyed)
    }

    @Test func aWindowClosedOrNotKnownIsntReplacedAndNothingOpensWhileQuitting() async throws {
        let setup = try WindowSetup.withWindows(1)
        #expect(setup.controller.openWorkspace(Self.workspace(), replacing: 99_999) == nil)
        _ = await setup.quit.quit()
        #expect(setup.controller.openWorkspace(Self.workspace("workspace-b")) == nil)
    }

    @Test func aWindowSavedAsAWorkspaceKeepsItsSizeAndSession() throws {
        let setup = try WindowSetup.withWindows(1)
        let window = try #require(setup.windows.first)
        window.bounds = WindowBounds(x: 10, y: 20, width: 950, height: 640)

        let snapshot = try #require(setup.controller.workspaceSnapshot(of: window.windowID))
        #expect(snapshot.id == window.recordID)
        #expect(snapshot.bounds == StoredWindowState(x: 10, y: 20, width: 950, height: 640, maximized: false))
        #expect(snapshot.session == setup.store.windowPreferences(window.recordID).windowSession)
        #expect(setup.controller.workspaceSnapshot(of: 99_999) == nil)
    }
}
