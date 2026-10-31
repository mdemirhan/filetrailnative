// The history and the opening of items (hooks/useExplorerNavigationController.ts :315-335 and :735-768,
// hooks/useExplorerActions.ts :3229-3343)
import Testing

@testable import FTFoundation

struct NavigationHistoryTests {
    // T-d8fbdd46 B-NAV-001 B-NAV-004: the first load is a replace on an empty list, which creates it.
    @Test func aTabThatStartsAtAFolderHasThatFolderAtIndexZero() {
        var history = NavigationHistory()
        #expect(history.index == -1 && history.paths.isEmpty && !history.canGoBack && !history.canGoForward)
        history.record("/home", mode: .replace)
        #expect(history.paths == ["/home"] && history.index == 0)
        #expect(NavigationHistory(startingAt: "/home") == history)
    }

    // T-578cd148 F-832 B-NAV-002 B-NAV-017 B-NAV-018
    @Test func pushCutsOffTheEntriesAheadAndAppends() {
        var history = NavigationHistory(paths: ["/a", "/b", "/c"], index: 1)
        #expect(history.canGoBack && history.canGoForward)
        history.record("/d", mode: .push)
        #expect(history.paths == ["/a", "/b", "/d"] && history.index == 2)
        #expect(!history.canGoForward)
    }

    // B-NAV-003: push does not de-duplicate.
    @Test func pushingTheFolderOnScreenAppendsASecondEntry() {
        var history = NavigationHistory(startingAt: "/a")
        history.record("/a", mode: .push)
        #expect(history.paths == ["/a", "/a"] && history.index == 1)
        #expect(history.backTarget == "/a")
    }

    // T-1e882d85 F-832 B-NAV-004: replace overwrites the current entry and leaves the index alone.
    @Test func replaceOverwritesTheCurrentEntry() {
        var history = NavigationHistory(paths: ["/a", "/b", "/c"], index: 1)
        history.record("/x", mode: .replace)
        #expect(history.paths == ["/a", "/x", "/c"] && history.index == 1)
    }

    // T-6d636796 F-832 B-NAV-005 B-NAV-009 B-NAV-014 B-NAV-015 B-NAV-016
    @Test func backAndForwardMoveTheIndexAtOnceAndStopAtTheEnds() {
        var history = NavigationHistory(paths: ["/a", "/b", "/c"], index: 1)
        #expect(history.goBack() == "/a" && history.index == 0)
        #expect(history.goBack() == nil && history.index == 0)
        #expect(history.goForward() == "/b" && history.goForward() == "/c")
        #expect(history.goForward() == nil && history.index == 2)
        // Skip touches nothing.
        history.record("/zzz", mode: .skip)
        #expect(history.paths == ["/a", "/b", "/c"])
    }

    // T-5b67fbc3 B-NAV-034 B-NAV-035: a jump adds nothing and leaves the passed folders in the other direction.
    @Test func aJumpMovesWithinTheHistory() {
        var history = NavigationHistory(paths: ["/a", "/b", "/c", "/d"], index: 3)
        #expect(history.jump(to: 1) == "/b")
        #expect(history.paths.count == 4 && history.canGoForward)
        #expect(history.jump(to: 1) == nil)
        #expect(history.jump(to: 9) == nil)
    }
}

struct NavigationHistoryPlaceTests {
    // A place holds while the same folder is at the same position; a new step can put another folder there.
    @Test func aPlaceHoldsWhileItsFolderIsThere() {
        var history = NavigationHistory(paths: ["/a", "/b", "/c"], index: 1)
        let place = NavigationHistory.Place(index: 2, path: "/c")
        #expect(history.holds(place))
        #expect(!history.holds(.init(index: 2, path: "/b")))
        #expect(!history.holds(.init(index: 3, path: "/c")))
        history.record("/d", mode: .push)
        #expect(!history.holds(place))
    }
}

struct OpenItemsTests {
    private let folder = CommandEntry(path: "/f/folder", kind: .directory)
    private let file = CommandEntry(path: "/f/a.txt", kind: .file)
    private let app = CommandEntry(path: "/f/App.app", kind: .bundle)
    private let folderAlias = CommandEntry(path: "/f/link", kind: .symlinkDirectory)
    private let fileAlias = CommandEntry(path: "/f/alias.txt", kind: .symlinkFile)

    // T-ce3a4ee4 T-329e368a T-6d8a0ef5 T-c4e8b2e2 B-SEL-110 B-NAV-064 B-NAV-067 B-NAV-068 B-NAV-070
    @Test func oneItemIsOpenedAccordingToWhatItIs() {
        func steps(_ item: CommandEntry) -> OpenItems.Plan {
            OpenItems.activation([item], fileActivation: .open, limit: 5)
        }
        #expect(steps(folder) == .steps([.navigate("/f/folder")]))
        #expect(steps(app) == .steps([.openExternally("/f/App.app")]))
        #expect(steps(file) == .steps([.openExternally("/f/a.txt")]))
        #expect(steps(folderAlias) == .steps([.resolveThenNavigate("/f/link")]))
        #expect(steps(fileAlias) == .steps([.resolveThenOpen("/f/alias.txt")]))
        #expect(OpenItems.activation([], fileActivation: .open, limit: 5) == .nothing)
    }

    // T-113332f0 B-NAV-065: several items go to the system one after another, folders included.
    @Test func severalItemsAreEachHandedToTheSystem() {
        #expect(
            OpenItems.activation([folder, file], fileActivation: .open, limit: 5)
                == .steps([.openExternally("/f/folder"), .openExternally("/f/a.txt")]))
    }

    // B-SEL-109 B-NAV-066: more than the limit shows a notice and opens none.
    // B-DLG-192
    @Test func moreThanTheLimitOpensNone() {
        let many = (0..<6).map { CommandEntry(path: "/f/\($0)", kind: .file) }
        #expect(
            OpenItems.activation(many, fileActivation: .open, limit: 5)
                == .tooMany(action: .open, selected: 6, limit: 5))
        #expect(OpenItems.limitTitle(action: .open) == "Too Many Items to Open")
        #expect(
            OpenItems.limitMessage(action: .open, selected: 6, limit: 5)
                == "File Trail opens up to 5 items at a time, and 6 are selected. You can change this in Settings.")
        #expect(
            OpenItems.limitMessage(action: .edit, selected: 3, limit: 1)
                == "File Trail edits up to 1 item at a time, and 3 are selected. You can change this in Settings.")
    }

    // B-SEL-111: files are edited when Settings says so and every selected item is an editable file.
    // T-33d23be1
    @Test func filesAreEditedWhenSettingsSaysSoAndEveryItemIsEditable() {
        #expect(
            OpenItems.activation([file, fileAlias], fileActivation: .edit, limit: 5)
                == .edit(["/f/a.txt", "/f/alias.txt"]))
        // Folders and mixed selections are opened.
        #expect(OpenItems.activation([folder], fileActivation: .edit, limit: 5) == .steps([.navigate("/f/folder")]))
        #expect(
            OpenItems.activation([file, folder], fileActivation: .edit, limit: 5)
                == .steps([.openExternally("/f/a.txt"), .openExternally("/f/folder")]))
        #expect(
            OpenItems.activation([file, fileAlias], fileActivation: .edit, limit: 1)
                == .tooMany(action: .edit, selected: 2, limit: 1))
    }
}
