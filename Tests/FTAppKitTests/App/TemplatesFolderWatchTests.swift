// The list of templates File ▸ New File shows, following a Templates folder in a temporary place as files come and
// go, and as the folder itself is made, renamed or deleted
import FTTestSupport
import Foundation
import Testing

@testable import FTAppKit

@MainActor
@Suite struct TemplatesFolderWatchTests {
    /// A Templates folder of the test's own, and a watch on it that counts how often the menu was asked to be built.
    @MainActor
    private final class Watched {
        let home: TemporaryDirectory
        let folder: String
        private(set) var watch: TemplatesFolderWatch
        private(set) var changes = 0

        /// `files`: the folder's files when the watch starts; nil starts it with no folder.
        init(files: [String]?) throws {
            home = try TemporaryDirectory(prefix: "filetrail-templates-watch")
            folder = home.path + "/Templates"
            watch = TemplatesFolderWatch(path: "/nonexistent-\(UUID().uuidString)")
            if let files { try make(files) }
            watch = TemplatesFolderWatch(path: folder)
            watch.onChange = { [weak self] in self?.changes += 1 }
        }

        func make(_ files: [String]) throws {
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: false)
            for name in files { add(name) }
        }

        func add(_ name: String) {
            FileManager.default.createFile(atPath: folder + "/" + name, contents: Data("x".utf8))
        }

        var names: [String] { watch.names }

        /// The list becomes `names` by the folder's own events, with nothing asking the watch to look.
        func follows(_ names: [String], sourceLocation: SourceLocation = #_sourceLocation) async {
            let followed = await waitUntil(sourceLocation: sourceLocation) { self.watch.names == names }
            #expect(followed, "the list is \(watch.names), not \(names)", sourceLocation: sourceLocation)
        }
    }

    // A file added, renamed and removed changes the list, and the menu is built again each time.
    @Test func followsAFileAddedRenamedAndRemoved() async throws {
        let watched = try Watched(files: ["Letter.txt"])
        defer { watched.home.remove() }
        #expect(watched.names == ["Letter.txt"])
        #expect(watched.changes == 0)

        watched.add("budget.csv")
        await watched.follows(["budget.csv", "Letter.txt"])
        #expect(watched.changes == 1)

        try FileManager.default.moveItem(
            atPath: watched.folder + "/budget.csv", toPath: watched.folder + "/Accounts.csv")
        await watched.follows(["Accounts.csv", "Letter.txt"])
        #expect(watched.changes == 2)

        try FileManager.default.removeItem(atPath: watched.folder + "/Letter.txt")
        await watched.follows(["Accounts.csv"])
        #expect(watched.changes == 3)

        // A folder made in it is no template: the list stays, and the next file is still followed.
        try FileManager.default.createDirectory(atPath: watched.folder + "/Project", withIntermediateDirectories: false)
        watched.add("Notes.md")
        await watched.follows(["Accounts.csv", "Notes.md"])
        #expect(watched.changes == 4)
    }

    // With no folder yet there is nothing to watch: once it is made (Open Templates Folder, Save as Template) the
    // watch is told, lists what it holds, and follows it from then on.
    @Test func aFolderMadeLaterIsPickedUpAndFollowed() async throws {
        let watched = try Watched(files: nil)
        defer { watched.home.remove() }
        #expect(watched.names.isEmpty)

        try watched.make(["Letter.txt"])
        watched.watch.folderMayExist()
        #expect(watched.names == ["Letter.txt"])
        #expect(watched.changes == 1)

        watched.add("budget.csv")
        await watched.follows(["budget.csv", "Letter.txt"])
        #expect(watched.changes == 2)
    }

    // The folder renamed away: its files are no templates any more. One made again in its place is picked up when
    // the app comes to the front, and followed, not the one that was renamed.
    @Test func aFolderRenamedAwayIsLetGoAndTheNewOneFollowed() async throws {
        let watched = try Watched(files: ["Letter.txt"])
        defer { watched.home.remove() }
        let away = watched.home.path + "/Templates old"

        try FileManager.default.moveItem(atPath: watched.folder, toPath: away)
        await watched.follows([])
        #expect(watched.changes == 1)

        try watched.make(["Memo.txt"])
        watched.watch.folderMayExist()
        #expect(watched.names == ["Memo.txt"])
        #expect(watched.changes == 2)

        watched.add("Agenda.txt")
        await watched.follows(["Agenda.txt", "Memo.txt"])
        // A file added to the folder that was renamed away changes nothing; the next one in the new folder shows
        // the list is still the new folder's.
        FileManager.default.createFile(atPath: away + "/Stray.txt", contents: Data("x".utf8))
        watched.add("Zebra.txt")
        await watched.follows(["Agenda.txt", "Memo.txt", "Zebra.txt"])
        #expect(!watched.names.contains("Stray.txt"))
    }

    // The folder deleted: the list empties. Made again, it is picked up when the app comes to the front, and
    // followed.
    @Test func aFolderDeletedAndMadeAgainIsFollowedAgain() async throws {
        let watched = try Watched(files: ["Letter.txt", "budget.csv"])
        defer { watched.home.remove() }

        try FileManager.default.removeItem(atPath: watched.folder)
        await watched.follows([])

        try watched.make(["Memo.txt"])
        watched.watch.folderMayExist()
        #expect(watched.names == ["Memo.txt"])

        watched.add("Agenda.txt")
        await watched.follows(["Agenda.txt", "Memo.txt"])
    }

    // Coming to the front reads the folder again: what changed is listed at once, and the menu is built again only
    // when the list is another one.
    @Test func comingToTheFrontReadsTheFolderAgain() async throws {
        let watched = try Watched(files: ["Letter.txt"])
        defer { watched.home.remove() }

        watched.watch.folderMayExist()
        #expect(watched.names == ["Letter.txt"])
        #expect(watched.changes == 0)

        // Read at once, before the folder's own event has been heard.
        watched.add("budget.csv")
        watched.watch.folderMayExist()
        #expect(watched.names == ["budget.csv", "Letter.txt"])
        #expect(watched.changes == 1)
        // The event that follows finds the same list, and says nothing more.
        watched.add("Notes.md")
        await watched.follows(["budget.csv", "Letter.txt", "Notes.md"])
        #expect(watched.changes == 2)
    }
}
