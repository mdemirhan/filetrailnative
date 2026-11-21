// A saved model is a folder's by its path's bytes: equal, kept apart and written as its path is spelled
import FTFoundation
import Foundation
import Testing

struct SavedPathsTests {
    /// "café" with its "é" as one scalar, as a disk may keep it, and with the accent apart, as a `URL` spells it.
    static let composed = "/Users/demo/caf\u{E9}"
    static let decomposed = "/Users/demo/cafe\u{301}"

    private func bytes(_ paths: [String?]) -> [[UInt8]?] { paths.map { $0.map { Array($0.utf8) } } }

    static func tab(_ path: String?, second: String? = nil) -> OpenTabPreference {
        OpenTabPreference(
            path: path, treeRootPath: nil, favoritePath: nil, viewMode: .list, searchViewMode: .details,
            sortBy: .name, sortDirection: .asc, includeHidden: false, foldersFirst: true, favoritesExpanded: true,
            locationsExpanded: true,
            secondPane: second.map {
                OpenPanePreference(
                    path: $0, viewMode: .list, searchViewMode: .details, sortBy: .name, sortDirection: .asc,
                    includeHidden: false, foldersFirst: true)
            })
    }

    static func workspace(_ tabs: [OpenTabPreference]) -> Workspace {
        var preferences = AppPreferences.defaults()
        preferences.openTabs = tabs
        return Workspace(
            id: "workspace-1", name: "Work", bounds: StoredWindowState(width: 900, height: 600, maximized: false),
            session: preferences.windowSession)
    }

    // MARK: Equal by bytes

    // Swift's `==` on text takes the two spellings for one path: a saved model is another when its path is.
    @Test func savedModelsWhosePathsDifferOnlyInAnAccentsEncodingAreTwo() {
        #expect(Self.composed == Self.decomposed)
        #expect(
            FavoritePreference(path: Self.composed, icon: .folder)
                != FavoritePreference(path: Self.decomposed, icon: .folder))
        #expect(
            VisitedFolder(path: Self.composed, visits: []) != VisitedFolder(path: Self.decomposed, visits: []))
        #expect(
            FolderView(path: Self.composed, subfolders: true) != FolderView(path: Self.decomposed, subfolders: true))
        #expect(Self.tab(Self.composed) != Self.tab(Self.decomposed))
        #expect(Self.tab("/a", second: Self.composed) != Self.tab("/a", second: Self.decomposed))
        var favorite = Self.tab("/a")
        var other = favorite
        favorite.favoritePath = Self.composed
        other.favoritePath = Self.decomposed
        #expect(favorite != other)
        #expect(Self.workspace([Self.tab(Self.composed)]) != Self.workspace([Self.tab(Self.decomposed)]))
        #expect(FavoritePreference(path: "/a", icon: .folder) == FavoritePreference(path: "/a", icon: .folder))
        #expect(Self.tab("/a", second: nil) == Self.tab("/a", second: nil))
    }

    // A path respelled is a change of its preference, so the store writes it and the windows hear of it.
    @Test func aPathRespelledIsAChangeOfThePreferences() {
        var saved = AppPreferences.defaults()
        saved.favorites = [FavoritePreference(path: Self.decomposed, icon: .folder)]
        saved.openTabs = [Self.tab(Self.decomposed)]
        saved.lastVisitedPath = Self.decomposed
        saved.workspaces = [Self.workspace([Self.tab(Self.decomposed)])]
        var respelled = saved
        respelled.favorites[0].path = Self.composed
        respelled.openTabs[0].path = Self.composed
        respelled.lastVisitedPath = Self.composed
        respelled.workspaces[0].session.openTabs[0].path = Self.composed

        #expect(respelled.keys(differingFrom: saved) == [.openTabs, .lastVisitedPath, .favorites, .workspaces])
        #expect(saved.keys(differingFrom: saved).isEmpty)
    }

    // The JSON of a saved model is what it was while its paths were plain text.
    @Test func aSavedPathIsTheBareStringInJSON() throws {
        func json(_ value: some Encodable) throws -> String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return String(decoding: try encoder.encode(value), as: UTF8.self)
        }
        #expect(try json(FavoritePreference(path: "/a/b", icon: .star)) == #"{"icon":"star","path":"/a/b"}"#)
        #expect(
            try json(VisitedFolder(path: "/a/b", visits: [])) == #"{"path":"/a/b","visits":[]}"#)
        #expect(
            try json(FolderView(path: "/a/b", subfolders: true))
                == #"{"keeps":{},"path":"/a/b","subfolders":true}"#)
        // A tab with no folder writes `null`, and a second pane with none leaves the key out.
        let noFolder = try json(Self.tab(nil, second: nil))
        #expect(noFolder.contains(#""path":null"#))
        #expect(noFolder.contains(#""favoritePath":null"#))
        #expect(noFolder.contains(#""treeRootPath":null"#))
        var pane = OpenPanePreference(
            path: nil, viewMode: .list, searchViewMode: .details, sortBy: .name, sortDirection: .asc,
            includeHidden: false, foldersFirst: true)
        #expect(try !json(pane).contains("path"))
        pane.path = "/a/b"
        #expect(try json(pane).contains(#""path":"/a/b""#))

        // Read back, the paths are the bytes written, and a pane saved with no folder has none.
        let both = Self.tab(Self.decomposed, second: Self.composed)
        let read = try JSONDecoder().decode(OpenTabPreference.self, from: JSONEncoder().encode(both))
        #expect(read == both)
        #expect(bytes([read.path, read.secondPane?.path]) == bytes([Self.decomposed, Self.composed]))
        pane.path = nil
        #expect(try JSONDecoder().decode(OpenPanePreference.self, from: JSONEncoder().encode(pane)).path == nil)
    }

    // Two favorites whose paths differ only in an accent's encoding are two folders' until the disk says otherwise.
    @Test func twoFavoritesThatDifferOnlyInEncodingAreTwo() throws {
        var favorites: [FavoritePreference] = []
        favorites = try #require(Favorites.adding(Self.decomposed, to: favorites, homePath: "/Users/demo"))
        favorites = try #require(Favorites.adding(Self.composed, to: favorites, homePath: "/Users/demo"))
        #expect(bytes(favorites.map(\.path)) == bytes([Self.decomposed, Self.composed]))
        #expect(Favorites.adding(Self.composed, to: favorites, homePath: "/Users/demo") == nil)

        let left = try #require(Favorites.removing(Self.composed, from: favorites))
        #expect(bytes(left.map(\.path)) == bytes([Self.decomposed]))
        #expect(Favorites.contains(left, path: Self.decomposed))
        #expect(!Favorites.contains(left, path: Self.composed))
    }
    // A workspace's folders are told apart by their bytes, and only the one that is gone gives way.
    @Test func aWorkspacesFoldersThatDifferOnlyInEncodingAreTwo() {
        let session = Self.workspace([Self.tab(Self.decomposed), Self.tab(Self.composed, second: Self.decomposed)])
            .session
        #expect(bytes(Workspaces.folders(of: session)) == bytes([Self.decomposed, Self.composed]))

        let replaced = Workspaces.replacingGoneFolders(session, gone: [DiskPath(Self.composed)]) { _ in "/Users/demo" }

        #expect(replaced.tabs == 1)
        #expect(
            bytes(replaced.session.openTabs.map(\.path) + [replaced.session.openTabs[1].secondPane?.path])
                == bytes([Self.decomposed, "/Users/demo", Self.decomposed]))
    }

    // How a folder was left is kept for each spelling.
    @Test func twoFoldersThatDifferOnlyInEncodingAreEachRememberedAsTheyWereLeft() {
        let first = FolderViewMemory(selection: .empty, scrollTop: 10)
        let second = FolderViewMemory(selection: .empty, scrollTop: 20)
        var memories: FolderViewMemories = [:]
        memories = memories.remembering(first, at: Self.decomposed, historyPaths: [Self.decomposed, Self.composed])
        memories = memories.remembering(second, at: Self.composed, historyPaths: [Self.decomposed, Self.composed])

        #expect(memories.count == 2)
        #expect(memories[Self.decomposed] == first)
        #expect(memories[Self.composed] == second)
        // Only the folders of the history are kept, by their bytes.
        #expect(memories.remembering(second, at: Self.composed, historyPaths: [Self.composed]).count == 1)
    }
}
