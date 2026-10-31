// Port of apps/desktop/src/renderer/lib/{places,goMenuPlaces,historyMenu}.test.ts, with the
// visited-ranking golden recorded from the reference (tools/parity/golden/visited-ranking.ts).
import FTTestSupport
import Testing

@testable import FTFoundation

struct PlacesTests {
    static let now = 1_800_000_000_000.0
    static let hour = 60.0 * 60 * 1000
    static let home = "/Users/demo"

    // A folder opened `count` times an hour ago.
    private func visited(_ path: String, _ count: Int) -> VisitedFolder {
        VisitedFolder(path: path, visits: (0..<count).map { _ in FolderVisit(at: Self.now - Self.hour, kind: .stay) })
    }

    private func places(currentPath: String = "/somewhere/else") -> [Place] {
        Places.build(
            visitedFolders: [
                visited("/Users/demo/src/filetrail/apps/desktop", 1),
                visited("/Users/demo/src/filetrail", 9),
                visited("/Users/demo/Downloads", 4),
                visited("/Users/demo/Music/Old Downloads", 10),
                visited("/Users/demo/src/render-farm", 2),
            ],
            favoritePaths: [Self.home, "/Users/demo/Desktop", "/Users/demo/Downloads", "/Users/demo/.Trash"],
            currentPath: currentPath, homePath: Self.home, now: Self.now)
    }

    private func names(_ query: String, currentPath: String = "/somewhere/else") -> [String] {
        Places.rank(places(currentPath: currentPath), query: query).map(\.place.name)
    }

    // T-03dac36f F-096 F-097
    // B-DLG-018 B-DLG-019 B-DLG-020 B-TREE-032 B-TREE-196
    @Test func listsOpenedFoldersAndFavoritesOnceEachNamedAsTheSidebarNamesThem() {
        let all = places()
        #expect(
            all.map(\.path) == [
                "/Users/demo/src/filetrail/apps/desktop",
                "/Users/demo/src/filetrail",
                "/Users/demo/Downloads",
                "/Users/demo/Music/Old Downloads",
                "/Users/demo/src/render-farm",
                Self.home,
                "/Users/demo/Desktop",
                "/Users/demo/.Trash",
            ])
        func byPath(_ path: String) -> Place? { all.first { $0.path == path } }
        #expect(byPath(Self.home)?.name == "Home")
        #expect(byPath(Self.home)?.isFavorite == true)
        #expect(byPath(Self.home)?.isVisited == false)
        #expect(byPath("/Users/demo/.Trash")?.name == "Trash")
        #expect(byPath("/Users/demo/Downloads")?.isFavorite == true)
        #expect(byPath("/Users/demo/Downloads")?.isVisited == true)
        // The folder on screen is not somewhere to go.
        #expect(!places(currentPath: "/Users/demo/Downloads").contains { $0.path.hasSuffix("/Downloads") })
    }

    // T-17c86615 F-096
    // B-TREE-198
    @Test func listsTheMostUsedPlacesFirstWhenNothingIsTyped() {
        #expect(Array(names("").prefix(3)) == ["Old Downloads", "filetrail", "Downloads"])
        // Favorites never opened come last, in their own order.
        #expect(Array(names("").suffix(3)) == ["Home", "Desktop", "Trash"])
    }

    // T-35f7d93b F-096
    // B-DLG-024 B-TREE-199
    @Test func ranksByHowTheTextMatchesFirstAndByUseSecond() {
        // Both start with "desk"; the one that has been opened comes first.
        #expect(names("desk") == ["desktop", "Desktop"])
        // A name starting with the text beats one that only contains it, however much used.
        #expect(names("down") == ["Downloads", "Old Downloads"])
        // Letters in order with others between them still find a name that starts with them.
        #expect(names("dwn") == ["Downloads"])
        #expect(names("ownloads") == ["Old Downloads", "Downloads"])
        #expect(names("zzz") == [])
    }

    // T-182825e8 F-096
    // B-TREE-199
    @Test func matchesEveryWordTypedInTheNameOrInThePath() {
        // "apps" is only in the path of one "desktop".
        #expect(names("apps desk") == ["desktop"])
        #expect(names("render") == ["render-farm"])
        // A word found only in the path ranks below a name match.
        #expect(names("src") == ["filetrail", "render-farm", "desktop"])
        #expect(names("farm") == ["render-farm"])
    }

    // T-93e5444b
    // B-TREE-200
    @Test func reportsWhichLettersOfTheNameMatched() {
        func match(_ query: String) -> PlaceMatch? { Places.rank(places(), query: query).first }
        #expect(match("down")?.nameRanges == [0..<4])
        // Neighbouring letters are reported as one range.
        #expect(match("dwn")?.nameRanges == [0..<1, 2..<4])
        #expect(match("farm")?.nameRanges == [7..<11])
        #expect(match("apps desk")?.nameRanges == [0..<4])
    }

    // T-415c212b F-097
    // B-TREE-201
    @Test func saysWhereAPlaceIs() {
        #expect(Places.describeLocation(name: "filetrail", displayPath: "~/src/filetrail") == "~/src")
        #expect(Places.describeLocation(name: "Desktop", displayPath: "~/Desktop") == "~")
        #expect(Places.describeLocation(name: "Volumes", displayPath: "/Volumes") == "/")
        #expect(Places.describeLocation(name: "Home", displayPath: "~") == "~")
        #expect(Places.describeLocation(name: "Trash", displayPath: "~/.Trash") == "~/.Trash")
    }

    // T-07d278a9 F-097
    // B-DLG-017 B-TREE-197
    @Test func tellsAPathFromANameAndShortensTheHomeFolder() {
        #expect(Places.isPathQuery("/usr"))
        #expect(Places.isPathQuery("~/Doc"))
        #expect(Places.isPathQuery(" ~"))
        #expect(!Places.isPathQuery("docs"))
        #expect(!Places.isPathQuery(""))
        #expect(Places.abbreviate("/Users/demo/src", homePath: Self.home) == "~/src")
        #expect(Places.abbreviate(Self.home, homePath: Self.home) == "~")
        #expect(Places.abbreviate("/Users/demolition", homePath: Self.home) == "/Users/demolition")
        #expect(Places.abbreviate("/Applications", homePath: Self.home) == "/Applications")
    }

    // B-DLG-025 B-TREE-199
    @Test func cutsTheListAtFiftyResults() {
        let many = (0..<80).map { VisitedFolder(path: "/many/folder \($0)", visits: []) }
        let all = Places.build(
            visitedFolders: many, favoritePaths: [], currentPath: "/", homePath: Self.home, now: Self.now)
        #expect(Places.rank(all, query: "fold").count == Places.maxResults)
    }

    // MARK: Golden

    struct VisitedInput: Codable, Sendable {
        let visited: [VisitedFolder]
        let favorites: [String]
        let currentPath: String
        let homePath: String
        let now: Double
        let query: String
    }

    struct RankedOutput: Codable, Equatable, Sendable {
        struct Ranked: Codable, Equatable, Sendable {
            let path: String
            let nameRanges: [[Int]]
        }

        let places: [Place]
        let ranked: [Ranked]
        let locations: [String]
    }

    // F-096 F-095
    @Test func placesAndRankingMatchTheReference() throws {
        let cases: [GoldenCase<VisitedInput, RankedOutput>] = try Golden.load(suite: "visited-ranking")
        #expect(cases.count >= 200)
        Golden.expectMatches(cases) { input in
            let places = Places.build(
                visitedFolders: input.visited, favoritePaths: input.favorites, currentPath: input.currentPath,
                homePath: input.homePath, now: input.now)
            let ranked = Places.rank(places, query: input.query)
            return RankedOutput(
                places: places,
                ranked: ranked.map {
                    .init(path: $0.place.path, nameRanges: $0.nameRanges.map { [$0.lowerBound, $0.upperBound] })
                },
                locations: ranked.map {
                    Places.describeLocation(name: $0.place.name, displayPath: $0.place.displayPath)
                })
        }
    }

    // MARK: Go menu

    // T-108c669a
    // B-NAV-103 B-NAV-104 B-NAV-105 B-TREE-083
    @Test func findsTheFoldersInHomeAndThePlacesOutsideIt() {
        #expect(
            GoMenuPlaceCommand.goDocuments.place(homePath: Self.home)
                == GoMenuPlace(path: "/Users/demo/Documents", asLocation: false))
        #expect(GoMenuPlaceCommand.goLibrary.place(homePath: Self.home)?.path == "/Users/demo/Library")
        #expect(
            GoMenuPlaceCommand.goApplications.place(homePath: Self.home)
                == GoMenuPlace(path: "/Applications", asLocation: false))
        // Rows of the sidebar's Locations.
        #expect(GoMenuPlaceCommand.goMacintoshHD.place(homePath: Self.home) == GoMenuPlace(path: "/", asLocation: true))
        #expect(
            GoMenuPlaceCommand.goTrash.place(homePath: Self.home)
                == GoMenuPlace(path: "/Users/demo/.Trash", asLocation: true))
    }

    // T-e67aa010
    @Test func hasNoPlaceInHomeUntilHomeIsKnown() {
        #expect(GoMenuPlaceCommand.goDownloads.place(homePath: "") == nil)
        #expect(GoMenuPlaceCommand.goTrash.place(homePath: "") == nil)
        #expect(GoMenuPlaceCommand.goMacintoshHD.place(homePath: "")?.path == "/")
    }

    // T-9e77156e
    @Test func tellsThePlaceCommandsFromTheOthers() {
        #expect(GoMenuPlaceCommand.isPlaceCommand("goDesktop"))
        #expect(GoMenuPlaceCommand.isPlaceCommand("goTrash"))
        #expect(!GoMenuPlaceCommand.isPlaceCommand("goHomeRootTree"))
        #expect(!GoMenuPlaceCommand.isPlaceCommand("emptyTrash"))
    }

    // MARK: History menu

    private let history = ["/", Self.home, "/Users/demo/src", "/Users/demo/src/app", "/Applications"]

    // T-8f3fa1a7
    @Test func listsWhereBackLeadsNearestFirst() {
        #expect(
            HistoryMenu.backEntries(historyPaths: history, historyIndex: 3, homePath: Self.home) == [
                HistoryMenuEntry(index: 2, path: "/Users/demo/src", label: "src", detail: "~"),
                HistoryMenuEntry(index: 1, path: Self.home, label: "Home", detail: "/Users"),
                HistoryMenuEntry(index: 0, path: "/", label: "Macintosh HD", detail: ""),
            ])
        #expect(HistoryMenu.backEntries(historyPaths: history, historyIndex: 0, homePath: Self.home).isEmpty)
        #expect(HistoryMenu.backEntries(historyPaths: [], historyIndex: -1, homePath: Self.home).isEmpty)
    }

    // T-87426be6
    @Test func listsWhereForwardLeadsNearestFirst() {
        #expect(
            HistoryMenu.forwardEntries(historyPaths: history, historyIndex: 2, homePath: Self.home) == [
                HistoryMenuEntry(index: 3, path: "/Users/demo/src/app", label: "app", detail: "~/src"),
                HistoryMenuEntry(index: 4, path: "/Applications", label: "Applications", detail: "/"),
            ])
        #expect(HistoryMenu.forwardEntries(historyPaths: history, historyIndex: 4, homePath: Self.home).isEmpty)
    }

    // T-389442af
    // B-NAV-008
    @Test func stopsAtADozenFoldersInEitherDirection() {
        let long = (0..<40).map { "/folders/\($0)" }
        let back = HistoryMenu.backEntries(historyPaths: long, historyIndex: 30, homePath: Self.home)
        #expect(back.count == HistoryMenu.limit)
        #expect(back.first?.index == 29)
        #expect(back.last?.index == 30 - HistoryMenu.limit)
        let forward = HistoryMenu.forwardEntries(historyPaths: long, historyIndex: 5, homePath: Self.home)
        #expect(forward.count == HistoryMenu.limit)
        #expect(forward.first?.index == 6)
    }
}
