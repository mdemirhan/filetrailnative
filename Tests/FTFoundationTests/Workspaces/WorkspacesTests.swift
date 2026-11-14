// Checks the workspaces' rules: what is read back of them, their names, what they say, and the menu's items
import Foundation
import Testing

@testable import FTFoundation

struct WorkspacesTests {
    static func tab(_ path: String, second: String? = nil) -> OpenTabPreference {
        OpenTabPreference(
            path: path, treeRootPath: "/Users/demo", favoritePath: nil, viewMode: .list, searchViewMode: .details,
            sortBy: .name, sortDirection: .asc, includeHidden: false, foldersFirst: true, favoritesExpanded: true,
            locationsExpanded: true,
            secondPane: second.map {
                OpenPanePreference(
                    path: $0, viewMode: .list, searchViewMode: .details, sortBy: .name, sortDirection: .asc,
                    includeHidden: false, foldersFirst: true)
            }, activePane: nil, paneSplit: second == nil ? nil : 0.5)
    }

    static func session(_ tabs: [OpenTabPreference], active: Int = 0) -> WindowSession {
        var session = AppPreferences.defaults().windowSession
        session.openTabs = tabs
        session.activeTabIndex = active
        return session
    }

    static func workspace(_ id: String, _ name: String, _ paths: [String] = ["/Users/demo"]) -> Workspace {
        Workspace(
            id: id, name: name, bounds: StoredWindowState(width: 900, height: 600, maximized: false),
            session: session(paths.map { tab($0) }))
    }

    static func read(_ json: String) throws -> [Workspace] {
        let parsed = try JSONNode.parse(Data(json.utf8))
        return PreferencesSanitizer.sanitize(parsed, defaults: .defaults()).workspaces
    }

    // MARK: Reading

    @Test func aFileFromBeforeWorkspacesHasNone() throws {
        #expect(try Self.read(#"{"theme": "dark"}"#).isEmpty)
        #expect(AppPreferences.defaults().workspaces.isEmpty)
    }

    @Test func keepsWhatMakesSenseAndDropsTheRest() throws {
        let read = try Self.read(
            """
            {"workspaces": [
              {"id": "a", "name": "  Photos  ", "bounds": {"x": 40, "y": 50, "width": 1000, "height": 700},
               "session": {"openTabs": [{"path": "/Users/demo/Pictures"}], "treeWidth": 300}},
              {"id": "a", "name": "Same id", "session": {"openTabs": [{"path": "/x"}]}},
              {"id": "b", "name": "photos", "session": {"openTabs": [{"path": "/x"}]}},
              {"id": "c", "name": "   ", "session": {"openTabs": [{"path": "/x"}]}},
              {"id": "d", "name": "No tabs", "session": {"openTabs": []}},
              {"name": "No id", "session": {"openTabs": [{"path": "/x"}]}},
              "not an object",
              {"id": "e", "name": "Clients", "bounds": {"width": 10, "maximized": true},
               "session": {"openTabs": [{"path": "/a"}, {"path": "/b"}], "activeTabIndex": 9}}
            ]}
            """)
        #expect(read.map(\.id) == ["a", "e"])
        #expect(read.map(\.name) == ["Photos", "Clients"])
        // Its size, never its place.
        #expect(read[0].bounds == StoredWindowState(width: 1000, height: 700, maximized: false))
        #expect(read[1].bounds == StoredWindowState(width: 1200, height: 760, maximized: true))
        #expect(read[0].session.openTabs.map(\.path) == ["/Users/demo/Pictures"])
        #expect(read[0].session.treeWidth == 300)
        // A value it doesn't hold is the app's.
        #expect(read[0].session.inspectorWidth == AppPreferences.defaults().inspectorWidth)
        #expect(read[1].session.activeTabIndex == 1)
    }

    @Test func cutsALongNameAndKeepsAtMostFifty() throws {
        let long = String(repeating: "n", count: 200)
        let entries = (0..<60).map { index in
            #"{"id": "w\#(index)", "name": "\#(index == 0 ? long : "W\(index)")", "session": {"openTabs": [{"path": "/x"}]}}"#
        }
        let read = try Self.read(#"{"workspaces": [\#(entries.joined(separator: ","))]}"#)
        #expect(read.count == Workspaces.limit)
        #expect(read[0].name.utf16.count == Workspaces.nameLimit)
    }

    @Test func aWorkspaceIsWrittenAndReadBackAsItWas() throws {
        var preferences = AppPreferences.defaults()
        preferences.workspaces = [
            Self.workspace("w1", "Photos", ["/Users/demo/Pictures", "/Users/demo/Desktop"]),
            Workspace(
                id: "w2", name: "Clients",
                bounds: StoredWindowState(x: 10, y: 20, width: 800, height: 500, maximized: true),
                session: Self.session([Self.tab("/a", second: "/b")])),
        ]
        let written = try JSONNode.of(preferences)
        let read = PreferencesSanitizer.sanitize(written, defaults: .defaults()).workspaces
        #expect(read == preferences.workspaces)
        // The place was never kept.
        #expect(read[1].bounds.x == nil)
    }

    // MARK: Names

    @Test func namesAreTrimmedAndCompareIgnoringCase() {
        let kept = [Self.workspace("a", "Photos"), Self.workspace("b", "Clients")]
        #expect(Workspaces.cleanName("  Taxes 2026 \n") == "Taxes 2026")
        #expect(Workspaces.index(named: "PHOTOS", in: kept) == 0)
        #expect(Workspaces.index(named: "Releases", in: kept) == nil)
        #expect(
            Workspaces.renameRefusal("clients", id: "a", in: kept) == "There’s already a workspace called “Clients”.")
        // Its own name, in another case, is no clash.
        #expect(Workspaces.renameRefusal("photos", id: "a", in: kept) == nil)
        #expect(Workspaces.renameRefusal("Releases", id: "a", in: kept) == nil)
    }

    @Test func savingUnderANameTakenReplacesThatWorkspaceInItsPlace() {
        let kept = [Self.workspace("a", "Photos"), Self.workspace("b", "Clients")]
        let replacing = Self.workspace("b", "clients", ["/new"])
        #expect(Workspaces.saving(replacing, in: kept).map(\.name) == ["Photos", "clients"])
        #expect(Workspaces.saving(replacing, in: kept)[1].session.openTabs.map(\.path) == ["/new"])
        let added = Self.workspace("c", "Releases")
        #expect(Workspaces.saving(added, in: kept).map(\.id) == ["a", "b", "c"])
        let full = (0..<Workspaces.limit).map { Self.workspace("w\($0)", "W\($0)") }
        #expect(Workspaces.saving(added, in: full).count == Workspaces.limit)
        #expect(Workspaces.saving(added, in: full).last?.id == "w49")
    }

    @Test func sayWhatTheyHold() {
        #expect(Workspaces.summary(Self.session([Self.tab("/a")])) == "1 tab")
        #expect(Workspaces.summary(Self.session([Self.tab("/a", second: "/b")])) == "1 tab with two panes")
        #expect(Workspaces.summary(Self.session([Self.tab("/a"), Self.tab("/b")])) == "2 tabs")
        #expect(
            Workspaces.summary(
                Self.session([
                    Self.tab("/a", second: "/b"), Self.tab("/c"), Self.tab("/d", second: "/e"), Self.tab("/f"),
                ])) == "4 tabs, 2 with two panes")
    }

    @Test func theFirstFiveHaveTheirKeysInOrder() {
        #expect(Workspaces.slot(of: .openWorkspace1) == 0)
        #expect(Workspaces.slot(of: .openWorkspace5) == 4)
        #expect(Workspaces.slot(of: .openWorkspace1InThisWindow) == nil)
        #expect(Workspaces.inThisWindowSlot(of: .openWorkspace3InThisWindow) == 2)
        #expect(Workspaces.inThisWindowSlot(of: .openWorkspace3) == nil)
        #expect(
            Workspaces.inThisWindowSlotCommands.map { ShortcutCommands.defaultBindings[$0] ?? [] }
                == (1...5).map { ["Ctrl+Cmd+Option+\($0)"] })
        #expect(Workspaces.slot(of: .newTab) == nil)
        let defaults = ShortcutCommands.defaultBindings
        #expect(Workspaces.slotCommands.map { defaults[$0] ?? [] } == (1...5).map { ["Ctrl+Cmd+\($0)"] })
        #expect(defaults[.saveWorkspace] == [])
        #expect(defaults[.updateWorkspace] == [])
    }

    // MARK: Opening

    @Test func aGoneFolderGivesWayToTheNearestOneAbove() {
        var favorite = Self.tab("/Users/demo/Gone")
        favorite.favoritePath = "/Users/demo/Gone"
        let session = Self.session(
            [favorite, Self.tab("/Users/demo/Here", second: "/Volumes/Away/Work"), Self.tab("/Users/demo/Here")])
        #expect(
            Workspaces.folders(of: session) == ["/Users/demo/Gone", "/Users/demo/Here", "/Volumes/Away/Work"])

        let gone: Set<String> = ["/Users/demo/Gone", "/Volumes/Away/Work"]
        let replaced = Workspaces.replacingGoneFolders(session, gone: gone) { path in
            path == "/Users/demo/Gone" ? "/Users/demo" : "/Volumes"
        }
        #expect(replaced.tabs == 2)
        #expect(replaced.session.openTabs.map(\.path) == ["/Users/demo", "/Users/demo/Here", "/Users/demo/Here"])
        #expect(replaced.session.openTabs[0].favoritePath == nil)
        #expect(replaced.session.openTabs[1].secondPane?.path == "/Volumes")
        #expect(replaced.session.lastVisitedPath == "/Users/demo")

        let none = Workspaces.replacingGoneFolders(session, gone: []) { _ in "/" }
        #expect(none.tabs == 0)
        #expect(none.session == session)
    }

    // MARK: The menu

    @Test func theMenuItemsNameTheWorkspaceTheyOpen() {
        let id = ApplicationMenu.workspaceItemID("workspace-1")
        let here = ApplicationMenu.workspaceItemID("workspace-1", inThisWindow: true)
        #expect(ApplicationMenu.workspaceItem(id)?.workspaceID == "workspace-1")
        #expect(ApplicationMenu.workspaceItem(id)?.inThisWindow == false)
        #expect(ApplicationMenu.workspaceItem(here)?.workspaceID == "workspace-1")
        #expect(ApplicationMenu.workspaceItem(here)?.inThisWindow == true)
        #expect(ApplicationMenu.workspaceItem("newTab") == nil)
        #expect(ApplicationMenu.workspaceItem("workspace:") == nil)
        #expect(ApplicationMenu.workspaceItem(ApplicationMenu.manageWorkspacesItemID) == nil)
    }

    @Test func theMenuChecksTheWorkspaceTheWindowCameFromAndUpdateNamesIt() {
        let state = ApplicationMenuState(workspaceID: "b", workspaceName: "Clients")
        let focused = ApplicationMenu.WindowFacts(explorerFocused: true)
        let states = ApplicationMenu.workspaceItemStates(state, window: focused, workspaceIDs: ["a", "b"])
        let checked = Dictionary(uniqueKeysWithValues: states.compactMap { item in item.checked.map { (item.id, $0) } })
        #expect(checked["workspace:a"] == false)
        #expect(checked["workspace:b"] == true)
        #expect(checked["workspaceHere:b"] == true)
        #expect(states.first { $0.id == "updateWorkspace" }?.title == "Update “Clients”")

        // Settings has the keyboard: no window is the menu's, and nothing is checked.
        let other = ApplicationMenu.workspaceItemStates(
            state, window: .init(explorerFocused: false), workspaceIDs: ["a", "b"])
        #expect(other.allSatisfy { $0.checked != true })
        #expect(other.first { $0.id == "updateWorkspace" }?.title == "Update Workspace")
    }

    @Test func updateIsDimmedForAWindowThatCameFromNoWorkspace() {
        #expect(!CommandAvailability.canRun(.updateWorkspace, CommandAvailabilityContext(hasWorkspace: false)))
        #expect(CommandAvailability.canRun(.updateWorkspace, CommandAvailabilityContext(hasWorkspace: true)))
        #expect(CommandAvailability.canRun(.saveWorkspace, CommandAvailabilityContext(hasWorkspace: false)))
    }
}
