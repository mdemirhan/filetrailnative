// The state files of a launch that spelled paths as a `URL` does: left byte for byte while nothing is respelled, and
// written when a path is
import FTFoundation
import Foundation
import Testing

@testable import FTFileSystem

struct SavedPathsStateTests {
    typealias Kit = StateTestKit

    /// "café" with its "é" as one scalar, as its disk keeps it, and with the accent apart, as an earlier launch saved
    /// it.
    static let composed = "/Users/demo/caf\u{E9}"
    static let decomposed = "/Users/demo/cafe\u{301}"
    static let fileNames = ["app-state.json", "visited-folders.json", "destination-folders.json", "folder-views.json"]

    /// Each file's bytes: compared as text, a file with a path respelled would be the file it was.
    static func texts(_ folder: String) throws -> [[UInt8]] {
        try fileNames.map { Array(try #require(FileManager.default.contents(atPath: folder + "/" + $0))) }
    }

    static func holds(_ text: [UInt8], _ path: String) -> Bool {
        text.split(separator: UInt8(ascii: "\"")).contains { $0.elementsEqual(path.utf8) }
    }

    /// Every file with something saved under `path`: a favorite, a tab, a workspace's tab, a folder's view (among
    /// others), a visit and a folder chosen in Move To.
    static func save(under path: String, in folder: String) {
        let store = Kit.store(Kit.statePath(folder))
        let tabs = Kit.openTabs([path, "/Users/demo/Documents"])
        var session = AppPreferences.defaults().windowSession
        session.openTabs = tabs
        store.update {
            $0.favorites = [
                FavoritePreference(path: "/Applications", icon: .applications),
                FavoritePreference(path: path, icon: .star),
            ]
            $0.favoritesInitialized = true
            $0.openTabs = tabs
            $0.lastVisitedPath = path
            $0.workspaces = [Workspace(id: "workspace-1", name: "Work", bounds: Kit.bounds, session: session)]
        }
        store.addExplorerWindow(id: "window-1", bounds: Kit.bounds, session: session)
        store.updateFolderViews {
            for viewed in ["/Users/demo/Pictures", path, "/Users/demo/apple", "/Users/demo/Zebra", path + "/2019"] {
                $0.set(FolderView(path: viewed, subfolders: true, keeps: FolderViewKeeps(view: .previews)))
            }
        }
        store.recordFolderVisit("/Users/demo/Documents", kind: .stay, now: 1_000)
        store.recordFolderVisit(path, kind: .goTo, now: 2_000)
        store.recordDestination(path, now: 3_000)
        store.flush()
    }

    // Loaded and saved again with nothing respelled, each file is what it was: the paths it holds are written as
    // they were read, and the folders' views in the order they were in.
    @Test func filesWithNothingToRespellAreWrittenBackByteForByte() throws {
        try Kit.withFolder { folder in
            Self.save(under: Self.decomposed, in: folder)
            let saved = try Self.texts(folder)
            #expect(saved.allSatisfy { Self.holds($0, Self.decomposed) })

            let files = RecordingFileSystem()
            let store = Kit.store(Kit.statePath(folder), fileSystem: files)
            // Each file is changed and put back, so each is written: a file is written when it has been changed.
            store.update { $0.notificationsEnabled = false }
            store.update { $0.notificationsEnabled = true }
            store.updateFolderViews { $0.set(FolderView(path: "/tmp/x", keeps: FolderViewKeeps(view: .list))) }
            store.updateFolderViews { $0.remove("/tmp/x") }
            store.recordFolderVisit("/tmp/x", kind: .stay, now: 9_000)
            store.recordDestination("/tmp/x", now: 9_000)
            store.forgetVisitedFolder("/tmp/x")
            store.flush()

            #expect(Set(files.written) == Set(Self.fileNames))
            #expect(try Self.texts(folder) == saved)
        }
    }

    // A favorite respelled is a change, though Swift's `==` takes the two spellings for one text: it is written.
    @Test func aPathRespelledIsWritten() throws {
        try Kit.withFolder { folder in
            Self.save(under: Self.decomposed, in: folder)
            let timer = ManualTimer()
            let files = RecordingFileSystem()
            let store = Kit.store(Kit.statePath(folder), fileSystem: files, timer: timer)

            store.update { $0.favorites[1].path = Self.composed }

            #expect(timer.pendingDelays == [1000])
            timer.run()
            #expect(files.written == ["app-state.json"])
            let favorites = Kit.readFile(Kit.statePath(folder))["preferences"]?["favorites"]?.array ?? []
            #expect(favorites.last?["path"]?.string.map { Array($0.utf8) } == Array(Self.composed.utf8))
        }
    }
}
