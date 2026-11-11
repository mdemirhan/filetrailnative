import FTFileSystem
import FTFoundation
import Testing

@testable import FTAppKit

@MainActor
@Suite struct ExplorerWindowOrderTests {
    private final class Window {}

    private func entry(_ id: String, _ windowID: Int) -> ExplorerWindowEntry<Window> {
        ExplorerWindowEntry(id: id, window: Window(), windowID: windowID)
    }

    @Test func keepsTheWindowsFrontToBackTheOneFocusedLastInFront() {
        let list = ExplorerWindowOrder<Window>()
        list.add(entry("a", 1), .back)
        list.add(entry("b", 2), .back)
        list.add(entry("c", 3))

        #expect(list.all.map(\.id) == ["c", "a", "b"])
        #expect(list.moveToFront("b"))
        #expect(!list.moveToFront("b"))
        #expect(list.front?.id == "b")
        list.remove("b")
        #expect(list.front?.id == "c")
        #expect(list.count == 2)
    }

    @Test func findsAWindowByItsIDAndItsNumber() {
        let list = ExplorerWindowOrder<Window>()
        let a = entry("a", 7)
        list.add(a)

        #expect(list.byID("a") === a)
        #expect(list.byWindowID(7) === a)
        #expect(list.byWindowID(8) == nil)
        #expect(list.byWindowID(nil) == nil)
    }
}

@Suite struct PlaceNewWindowTests {
    private let screen = WindowBounds(x: 0, y: 25, width: 1440, height: 875)

    @Test func putsANewWindowAStepDownAndToTheRightTheSameSize() {
        let offset = ExplorerWindowPlacement.newWindowOffset
        #expect(
            ExplorerWindowPlacement.placeNewWindow(
                from: WindowBounds(x: 100, y: 120, width: 900, height: 600), workArea: screen)
                == WindowBounds(x: 100 + offset, y: 120 + offset, width: 900, height: 600))
    }

    @Test func startsAgainAtTheTopLeftWhenTheStepWouldLeaveTheScreen() {
        #expect(
            ExplorerWindowPlacement.placeNewWindow(
                from: WindowBounds(x: 530, y: 290, width: 900, height: 600), workArea: screen)
                == WindowBounds(x: 0, y: 25, width: 900, height: 600))
    }

    @Test func isNeverBiggerThanTheScreen() {
        #expect(
            ExplorerWindowPlacement.placeNewWindow(
                from: WindowBounds(x: 0, y: 25, width: 3000, height: 2000), workArea: screen)
                == WindowBounds(x: 0, y: 25, width: 1440, height: 875))
    }
}

@MainActor
@Suite struct WindowChannelsTests {
    private struct Changed {
        var preferences: AppPreferences
        var change: PreferencesChange
    }

    // Window 1 is window A; 2 is Settings.
    private func channel(_ changes: @escaping (Changed) -> Void = { _ in }) throws -> (
        AppStateStore, WindowPreferenceChannel
    ) {
        let store = try makeStore()
        store.addExplorerWindow(
            id: "window-a", bounds: StoredWindowState(width: 900, height: 600, maximized: false),
            session: store.createWindowSession(overrides: [:]))
        let channel = WindowPreferenceChannel(
            store: store, explorerWindowID: { $0 == 1 ? "window-a" : nil },
            onPreferencesChanged: { changes(Changed(preferences: $0, change: $1)) })
        return (store, channel)
    }

    @Test func showsAnExplorerWindowTheAppsPreferencesWithItsOwnSession() throws {
        let (store, channel) = try channel()
        store.updateWindowPreferences("window-a", ["treeWidth": .number(333)])
        store.updatePreferences(["treeWidth": .number(280)])

        #expect(channel.preferences(for: 1).treeWidth == 333)
        #expect(channel.preferences(for: 2).treeWidth == 280)
    }

    @Test func keepsAWindowsOwnKeysToItAndTellsTheOtherWindowsOnlyTheSharedOnes() throws {
        var changes: [Changed] = []
        let (store, channel) = try channel { changes.append($0) }

        let preferences = channel.update(from: 1) {
            $0.treeWidth = 345
            $0.notificationsEnabled = false
        }

        #expect(preferences.treeWidth == 345)
        #expect(store.windowPreferences("window-a").treeWidth == 345)
        #expect(changes.last?.preferences == store.preferences())
        #expect(changes.last?.change == PreferencesChange(keys: [.notificationsEnabled], senderID: 1))

        // From Settings: the app's preferences only.
        channel.update(from: 2) { $0.theme = .light }
        #expect(store.preferences().theme == .light)
        #expect(changes.last?.change == PreferencesChange(keys: [.theme], senderID: 2))
    }

    @Test func asksTheControllerAboutTheWindowAsking() async throws {
        let setup = try WindowSetup.withWindows(2)
        let back = setup.windows[0]
        let front = setup.windows[1]

        #expect(setup.controller.recordID(of: front.windowID) == front.recordID)
        #expect(setup.controller.recordID(of: nil) == nil)
        #expect(setup.controller.windows.count == 2)
        #expect(setup.controller.openWindowFrom(front.windowID, tabs: [tab("/Users/demo/x")], activeTabIndex: 0))
        #expect(setup.controller.windows.count == 3)
        #expect(setup.controller.closeWindow(of: back.windowID))
        await settle()
        #expect(back.destroyed)
    }

    private func copied(_ path: String, _ capturedAt: String) -> CopyPasteClipboard {
        .ready(mode: .copy, sourcePaths: [path], sourceEntries: [:], capturedAt: capturedAt)
    }

    @Test func keepsOneClipboardForEveryWindowAndTellsTheOthersOfAChange() {
        var told: [(Int?, CopyPasteClipboard)] = []
        let clipboard = SharedClipboard { told.append(($0, $1)) }
        #expect(clipboard.contents == .empty)
        let contents = CopyPasteClipboard.ready(
            mode: .copy, sourcePaths: ["/Users/demo/a.txt"],
            sourceEntries: ["/Users/demo/a.txt": ClipboardSourceEntry(kind: .file, isSymlink: false)],
            capturedAt: "2026-10-08T10:00:00.000Z")

        #expect(clipboard.set(contents, from: 1))

        #expect(clipboard.contents == contents)
        #expect(told.count == 1)
        #expect(told.first?.0 == 1)
        #expect(told.first?.1 == contents)
    }

    @Test func followsWhatItHolds() {
        var told: [(Int?, CopyPasteClipboard)] = []
        let clipboard = SharedClipboard { told.append(($0, $1)) }
        let before = copied("/Users/demo/a.txt", "2026-10-08T10:00:00.000Z")
        clipboard.set(before, from: 1)
        let moved = copied("/Users/demo/Folder/a.txt", "2026-10-08T10:00:00.000Z")

        #expect(clipboard.set(moved, follows: "2026-10-08T10:00:00.000Z", from: 1))
        #expect(clipboard.contents == moved)
        #expect(told.last?.1 == moved)
    }

    @Test func doesntTakeACopyMadeSinceInAnotherWindowOff() {
        var told: [(Int?, CopyPasteClipboard)] = []
        let clipboard = SharedClipboard { told.append(($0, $1)) }
        clipboard.set(copied("/Users/demo/a.txt", "2026-10-08T10:00:00.000Z"), from: 1)
        let since = copied("/Users/demo/b.txt", "2026-10-08T10:00:05.000Z")
        clipboard.set(since, from: 2)
        told.removeAll()

        #expect(
            !clipboard.set(
                copied("/Users/demo/Folder/a.txt", "2026-10-08T10:00:00.000Z"), follows: "2026-10-08T10:00:00.000Z",
                from: 1))
        #expect(!clipboard.set(.empty, follows: "x", from: 1))
        #expect(clipboard.contents == since)
        #expect(told.isEmpty)
    }
}
