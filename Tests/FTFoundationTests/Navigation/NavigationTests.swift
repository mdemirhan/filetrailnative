// The history and the opening of items
import Testing

@testable import FTFoundation

struct NavigationHistoryTests {
    // The first load is a replace on an empty list, which creates it.
    @Test func aTabThatStartsAtAFolderHasThatFolderAtIndexZero() {
        var history = NavigationHistory()
        #expect(history.index == -1 && history.paths.isEmpty && !history.canGoBack && !history.canGoForward)
        history.record("/home", mode: .replace)
        #expect(history.paths == ["/home"] && history.index == 0)
        #expect(NavigationHistory(startingAt: "/home") == history)
    }

    @Test func pushCutsOffTheEntriesAheadAndAppends() {
        var history = NavigationHistory(paths: ["/a", "/b", "/c"], index: 1)
        #expect(history.canGoBack && history.canGoForward)
        history.record("/d", mode: .push)
        #expect(history.paths == ["/a", "/b", "/d"] && history.index == 2)
        #expect(!history.canGoForward)
    }

    // Push does not de-duplicate.
    @Test func pushingTheFolderOnScreenAppendsASecondEntry() {
        var history = NavigationHistory(startingAt: "/a")
        history.record("/a", mode: .push)
        #expect(history.paths == ["/a", "/a"] && history.index == 1)
        #expect(history.backTarget == "/a")
    }

    // Replace overwrites the current entry and leaves the index alone.
    @Test func replaceOverwritesTheCurrentEntry() {
        var history = NavigationHistory(paths: ["/a", "/b", "/c"], index: 1)
        history.record("/x", mode: .replace)
        #expect(history.paths == ["/a", "/x", "/c"] && history.index == 1)
    }

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

    // A jump adds nothing and leaves the passed folders in the other direction.
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

    // Several items go to the system one after another, folders included.
    @Test func severalItemsAreEachHandedToTheSystem() {
        #expect(
            OpenItems.activation([folder, file], fileActivation: .open, limit: 5)
                == .steps([.openExternally("/f/folder"), .openExternally("/f/a.txt")]))
    }

    // More than the limit shows a notice and opens none.
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

    // Files are edited when Settings says so and every selected item is an editable file.
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
