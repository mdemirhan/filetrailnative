import Foundation
import Testing

@testable import FTFoundation

/// The startup disk renamed "Data": every place that names `/` says so, and other folders keep their names.
@Suite("startup disk name")
struct StartupDiskNameTests {
    static let name = "Data"

    @Test func untoldItIsMacintoshHD() {
        #expect(VolumePaths.defaultStartupDiskName == "Macintosh HD")
        #expect(TabText.folderDisplayName("/") == "Macintosh HD")
    }

    @Test func tabsAndTheirSearches() {
        #expect(TabText.folderDisplayName("/", startupDiskName: Self.name) == "Data")
        #expect(TabText.folderDisplayName("/Users", startupDiskName: Self.name) == "Users")
        let folder = TabText.describe(
            currentPath: "/", searchVisible: false, searchQuery: "", searchRootPath: "", searchRunning: false,
            startupDiskName: Self.name)
        #expect(folder.label == "Data")
        let search = TabText.describe(
            currentPath: "/Users", searchVisible: true, searchQuery: "notes", searchRootPath: "/", searchRunning: true,
            startupDiskName: Self.name)
        #expect(search.label == "“notes” in Data")
    }

    @Test func pathBar() {
        #expect(PathBarModel.label("/", startupDiskName: Self.name) == "Data")
        #expect(PathBarModel.segments("/", startupDiskName: Self.name).map(\.label) == ["Data"])
        #expect(
            PathBarModel.segments("/Users/demo", homePath: "/Users/demo", startupDiskName: Self.name).map(\.label)
                == ["Data", "Users", "demo"])
        #expect(
            PathBarModel.segments("/Volumes/Photos/2026", startupDiskName: Self.name).map(\.label)
                == ["Photos", "2026"])
    }

    @Test func infoPanel() {
        #expect(InfoPreview.folderEntry("/", startupDiskName: Self.name).name == "Data")
        #expect(InfoPreview.folderEntry("/Users", startupDiskName: Self.name).name == "Users")
        let resolved = InfoPreview.resolve(
            path: "/", currentPath: "/", entries: [], metadataByPath: [:], properties: nil,
            startupDiskName: Self.name)
        #expect(resolved?.item.name == "Data")

        let item = InfoItem(path: "/Users", name: "Users", kind: .directory, kindLabel: "Folder")
        let content = InfoPanelModel.itemContent(
            item: item, pending: false, volume: nil, isVolumeRoot: false, hasFolderSize: false, folderSize: nil,
            opensWith: .hidden, startupDiskName: Self.name)
        #expect(content.rows.first { $0.label == "Where" }?.value == .whereLink(label: "Data", path: "/"))

        let selection = InfoSelection(count: 2, folderCount: 0, fileCount: 2, totalBytes: 2, parentPath: "/")
        let rows = InfoPanelModel.selectionRows(
            selection, hasFolderSize: false, folderSize: nil, startupDiskName: Self.name)
        #expect(rows.first { $0.label == "Where" }?.value == .whereLink(label: "Data", path: "/"))
    }

    @Test func sidebarLocationsAndTree() {
        let locations = Favorites.locations(volumes: [], homePath: "/Users/demo", startupDiskName: Self.name)
        #expect(locations.map(\.label) == ["demo", "Data", "Trash"])

        var nodes = TreeNodes([TreeNodeState(path: "/", expanded: false)])
        nodes["/Users"] = TreeNodeState(path: "/Users", expanded: false)
        let presentation = Favorites.presentation(
            .init(
                favorites: [FavoritePreference(path: "/", icon: .drive)], favoritesExpanded: true,
                homePath: "/Users/demo", rootPath: "/", nodes: nodes, startupDiskName: Self.name))
        #expect(presentation.items[.filesystem("/")]?.label == "Data")
        #expect(presentation.items[.favorite("/")]?.label == "Data")
    }

    @Test func placesGoToAndHistory() {
        #expect(FavoriteLabel.label(for: "/", homePath: "/Users/demo", startupDiskName: Self.name) == "Data")
        #expect(FavoriteLabel.label(for: "/Users/demo", homePath: "/Users/demo", startupDiskName: Self.name) == "Home")
        let places = Places.build(
            visitedFolders: [VisitedFolder(path: "/", visits: [FolderVisit(at: 1, kind: .stay)])], favoritePaths: [],
            currentPath: "/Users/demo", homePath: "/Users/demo", now: 2, startupDiskName: Self.name)
        #expect(places.map(\.name) == ["Data"])
        let back = HistoryMenu.backEntries(
            historyPaths: ["/", "/Users"], historyIndex: 1, homePath: "/Users/demo", startupDiskName: Self.name)
        #expect(back.map(\.label) == ["Data"])
        let forward = HistoryMenu.forwardEntries(
            historyPaths: ["/Users", "/"], historyIndex: 0, homePath: "/Users/demo", startupDiskName: Self.name)
        #expect(forward.map(\.label) == ["Data"])
    }

    @Test func searchScopes() {
        let atRoot = SearchBarText.scopeOptions(currentPath: "/", homePath: "/Users/demo", startupDiskName: Self.name)
        #expect(atRoot.map(\.label) == ["“Data”", "Home"])
        let inHome = SearchBarText.scopeOptions(
            currentPath: "/Users/demo/Projects", homePath: "/Users/demo", startupDiskName: Self.name)
        #expect(inHome.map(\.label) == ["“Projects”", "Home", "Data"])
    }
}
