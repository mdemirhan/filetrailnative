// What an earlier launch saved under another spelling of a folder's path goes to the spelling a listing gives
import FTFoundation
import Foundation
import Testing

struct SavedSpellingsTests {
    static let composed = SavedPathsTests.composed
    static let decomposed = SavedPathsTests.decomposed
    static let noOtherHome = SavedSpellings.Home(system: "/Users/demo", real: "/Users/demo")

    private func bytes(_ paths: [String?]) -> [[UInt8]?] { paths.map { $0.map { Array($0.utf8) } } }

    private static func tab(_ path: String?, second: String? = nil) -> OpenTabPreference {
        SavedPathsTests.tab(path, second: second)
    }

    private static func tabView(_ left: String, _ right: String? = nil, id: String = "tab-view-1") -> TabView {
        SavedPathsTests.tabView(left, right, id: id)
    }

    // MARK: The spellings an earlier launch may have saved

    @Test func aPathWithNoAccentHasNoOtherSpelling() {
        #expect(SavedSpellings.earlier(of: "/Users/demo/Documents/Work", home: Self.noOtherHome).isEmpty)
        #expect(SavedSpellings.earlier(of: "/", home: Self.noOtherHome).isEmpty)
        #expect(DiskPath("/Users/demo/Documents").asAURLSpells() == nil)
    }

    @Test func aFolderMayHaveBeenSavedAsAURLSpellsItAndSoMayTheFoldersAboveIt() {
        let inside = Self.composed + "/2019"
        let earlier = SavedSpellings.earlier(of: DiskPath(inside), home: Self.noOtherHome)

        #expect(
            earlier == [
                SavedSpellings.Earlier(old: DiskPath(Self.decomposed + "/2019"), path: DiskPath(inside)),
                SavedSpellings.Earlier(old: DiskPath(Self.decomposed), path: DiskPath(Self.composed)),
            ])
        // A path a `URL` spells as the disk does has no other spelling.
        #expect(SavedSpellings.earlier(of: DiskPath(Self.decomposed), home: Self.noOtherHome).isEmpty)
    }

    // A home folder the system names by a link was saved by that name.
    @Test func aFolderInAHomeTheSystemNamesOtherwiseMayHaveBeenSavedByThatName() {
        let home = SavedSpellings.Home(system: "/Users/demo", real: "/Volumes/Data/demo")
        #expect(
            SavedSpellings.earlier(of: "/Volumes/Data/demo/Desktop", home: home) == [
                SavedSpellings.Earlier(old: "/Users/demo/Desktop", path: "/Volumes/Data/demo/Desktop"),
                SavedSpellings.Earlier(old: "/Users/demo", path: "/Volumes/Data/demo"),
            ])
        #expect(SavedSpellings.earlier(of: "/Volumes/Data/demolition", home: home).isEmpty)
        #expect(SavedSpellings.earlier(of: "/Volumes/Data", home: home).isEmpty)
        // With an accent as well, by that name as a `URL` spells it too.
        let accented = SavedSpellings.earlier(of: DiskPath("/Volumes/Data/demo/caf\u{E9}"), home: home)
        #expect(
            accented.map(\.old) == [
                DiskPath("/Volumes/Data/demo/cafe\u{301}"), DiskPath("/Users/demo/caf\u{E9}"),
                DiskPath("/Users/demo/cafe\u{301}"), "/Users/demo",
            ])
    }

    // MARK: Taking over

    @Test func aFavoriteSavedUnderTheOldSpellingKeepsItsPlaceAndIcon() throws {
        let favorites = [
            FavoritePreference(path: "/Applications", icon: .applications),
            FavoritePreference(path: Self.decomposed, icon: .star),
            FavoritePreference(path: "/Users/demo/Documents", icon: .documents),
        ]
        let (old, path) = (DiskPath(Self.decomposed), DiskPath(Self.composed))

        let taken = try #require(SavedSpellings.favorites(favorites, from: old, to: path))

        #expect(bytes(taken.map(\.path)) == bytes(["/Applications", Self.composed, "/Users/demo/Documents"]))
        #expect(taken.map(\.icon) == [.applications, .star, .documents])
        // Once: nothing is left under the old spelling.
        #expect(SavedSpellings.favorites(taken, from: old, to: path) == nil)
        #expect(SavedSpellings.favorites(favorites, from: path, to: path) == nil)
        // A folder that is a favorite under both is listed once, as its listing spells it.
        let both = favorites + [FavoritePreference(path: Self.composed, icon: .folder)]
        let once = try #require(SavedSpellings.favorites(both, from: old, to: path))
        #expect(bytes(once.map(\.path)) == bytes(["/Applications", "/Users/demo/Documents", Self.composed]))
    }
    @Test func aTabViewsFoldersSavedUnderTheOldSpellingGoToTheListings() throws {
        let views = [
            Self.tabView(Self.decomposed, Self.decomposed), Self.tabView("/tmp", "/Users/demo", id: "tab-view-2"),
        ]
        let (old, path) = (DiskPath(Self.decomposed), DiskPath(Self.composed))
        var preferences = AppPreferences.defaults()
        preferences.tabViews = views
        #expect(SavedSpellings.preferencesHold(old, preferences))
        #expect(!SavedSpellings.preferencesHold(path, preferences))

        let taken = try #require(SavedSpellings.tabViews(views, from: old, to: path))

        #expect(bytes(taken[0].keeps.folders) == bytes([Self.composed, Self.composed]))
        #expect(taken[1] == views[1])
        #expect(SavedSpellings.tabViews(taken, from: old, to: path) == nil)
        preferences.tabViews = taken
        #expect(!SavedSpellings.preferencesHold(old, preferences))
    }
}
