import FTTestSupport
import Foundation
import Testing

@testable import FTFileSystem

struct TrashFoldersTests {
    private let trash = TrashFolders(
        homePath: "/Users/me", uid: 501,
        listMounts: {
            [
                Mount(path: "/", isLocal: true), Mount(path: "/System/Volumes/Data", isLocal: true),
                Mount(path: "/Volumes/Photos", isLocal: true), Mount(path: "/Volumes/Backup", isLocal: true),
                Mount(path: "/Volumes/NAS", isLocal: false), Mount(path: "/Volumes/.timemachine/x", isLocal: true),
            ]
        })

    /// A fake with the home Trash holding a.txt, Photos' holding b.txt and a.txt, and Backup that has none.
    private func disks() -> FakeFileSystem {
        let fake = FakeFileSystem()
        fake.statHandler = { path in
            fakeStats(directory: !path.hasSuffix(".txt"), file: path.hasSuffix(".txt"), size: 1)
        }
        fake.directory = { path in
            switch path {
            case "/Users/me/.Trash": [fakeDirent("a.txt", file: true), fakeDirent(".DS_Store", file: true)]
            case "/Volumes/Photos/.Trashes/501": [fakeDirent("b.txt", file: true), fakeDirent("a.txt", file: true)]
            default: throw ExplorerError.system(code: ENOENT, path: path)
            }
        }
        return fake
    }

    private func service(_ fake: FakeFileSystem) -> DirectoryService {
        DirectoryService(fileSystem: fake, cache: ResponseCache(), kinds: KindLabeler(describer: nil), trash: trash)
    }

    @Test func theTrashOfEachLocalDiskIsPartOfTheOneTrash() {
        #expect(trash.onOtherDisks == ["/Volumes/Backup/.Trashes/501", "/Volumes/Photos/.Trashes/501"])
        #expect(trash.listedWith("/Users/me/.Trash") == trash.onOtherDisks)
        #expect(trash.listedWith("/Users/me") == [])
        #expect(trash.isOnOtherDisk("/Volumes/Photos/.Trashes/501"))
        #expect(!trash.isOnOtherDisk("/Volumes/Photos/.Trashes/502"))
        #expect(!trash.isOnOtherDisk("/Volumes/Photos/.Trashes/501/a"))
        #expect(TrashFolders.disk(of: "/Volumes/Photos/.Trashes/501") == "/Volumes/Photos")
    }

    @Test func theTrashListsWhatIsOnEveryDiskUnderItsOwnPath() async throws {
        let snapshot = try await service(disks()).snapshot(path: "/Users/me/.Trash")
        #expect(snapshot.path == "/Users/me/.Trash")
        #expect(snapshot.parentPath == "/Users/me")
        // The same name on two disks is two items, each in its name's place in one sorted list.
        #expect(
            snapshot.entries.map(\.path).sorted() == [
                "/Users/me/.Trash/a.txt", "/Volumes/Photos/.Trashes/501/a.txt", "/Volumes/Photos/.Trashes/501/b.txt",
            ])
        #expect(snapshot.entries.map(\.name) == ["a.txt", "a.txt", "b.txt"])
    }

    @Test func aSortOtherThanNameLinesUpWithTheItemsOfEveryDisk() async throws {
        let fake = disks()
        fake.statHandler = { path in
            let isFile = path.hasSuffix(".txt")
            return fakeStats(directory: !isFile, file: isFile, size: path.hasPrefix("/Volumes") ? 9 : 1)
        }
        let snapshot = try await service(fake).snapshot(path: "/Users/me/.Trash", sortBy: .size)
        #expect(snapshot.entries.map(\.sizeBytes) == [1, 9, 9])
        #expect(snapshot.entries.first?.path == "/Users/me/.Trash/a.txt")
    }

    @Test func aDisksOwnTrashIsTheOneTrashByAnotherName() async throws {
        let snapshot = try await service(disks()).snapshot(path: "/Volumes/Photos/.Trashes/501")
        #expect(snapshot.path == "/Users/me/.Trash")
        #expect(snapshot.entries.count == 3)
    }

    @Test func whatIsInsideADisksTrashIsAFolderLikeAnyOther() async throws {
        let fake = disks()
        fake.directory = { path in
            guard path == "/Volumes/Photos/.Trashes/501/album" else { throw FakeError() }
            return [fakeDirent("c.txt", file: true)]
        }
        let snapshot = try await service(fake).snapshot(path: "/Volumes/Photos/.Trashes/501/album")
        #expect(snapshot.entries.map(\.path) == ["/Volumes/Photos/.Trashes/501/album/c.txt"])
        #expect(snapshot.parentPath == "/Volumes/Photos/.Trashes/501")
    }

    @Test func theHomeTrashIsKnownByItsRealPathHoweverTheHomeIsSpelled() throws {
        try withTemporaryDirectory { directory in
            let real = try NativeFileSystem().realpath(directory.path) + "/real"
            let link = try NativeFileSystem().realpath(directory.path) + "/link"
            try FileManager.default.createDirectory(atPath: real + "/.Trash", withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: real)
            let trash = TrashFolders(
                homePath: link, uid: 501, listMounts: { [Mount(path: "/Volumes/Photos", isLocal: true)] })
            #expect(trash.home == real + "/.Trash")
            #expect(trash.listedWith(real + "/.Trash") == ["/Volumes/Photos/.Trashes/501"])
            #expect(trash.listedWith(link + "/.Trash") == ["/Volumes/Photos/.Trashes/501"])
            #expect(trash.listedFolder(for: link + "/.Trash") == real + "/.Trash")
        }
    }

    @Test func aHomeTrashRefusedIsSaidEvenWithOtherDisksToList() async {
        let fake = disks()
        let refused = ExplorerError.system(code: EPERM, path: "/Users/me/.Trash")
        fake.directory = { path in
            if path == "/Users/me/.Trash" { throw refused }
            return [fakeDirent("b.txt", file: true)]
        }
        await #expect(throws: refused) { try await service(fake).snapshot(path: "/Users/me/.Trash") }
        // A disk's own Trash can still be opened as itself.
        let own = try? await service(fake).snapshot(path: "/Volumes/Photos/.Trashes/501")
        #expect(own?.path == "/Volumes/Photos/.Trashes/501")
        #expect(own?.entries.map(\.name) == ["b.txt"])
    }

    @Test func aFolderOutsideTheTrashListsOnlyItself() async throws {
        let fake = disks()
        fake.directory = { path in
            guard path == "/Users/me" else { throw FakeError() }
            return [fakeDirent("a.txt", file: true)]
        }
        let snapshot = try await service(fake).snapshot(path: "/Users/me")
        #expect(snapshot.entries.map(\.path) == ["/Users/me/a.txt"])
    }
}

@MainActor
struct TrashFoldersWatchTests {
    @Test func aDisksTrashIsToldOfAsTheTrashChanging() async throws {
        try await withTemporaryDirectory { directory in
            let disk = try NativeFileSystem().realpath(directory.path)
            let home = disk + "/home"
            let other = disk + "/.Trashes/501"
            try FileManager.default.createDirectory(atPath: home + "/.Trash", withIntermediateDirectories: true)
            var told: [FolderChange] = []
            let stop = FSEventsFolderWatcher.watchFolder(
                path: other, onDisk: disk,
                onChange: { name in told.append(FolderChange(path: other, changedPaths: name.map { [$0] })) },
                onFail: {})
            defer { stop() }
            try await Task.sleep(for: .milliseconds(300))
            // Its Trash is made by the first item trashed on the disk, after the watch began.
            try FileManager.default.createDirectory(atPath: other, withIntermediateDirectories: true)
            try Data().write(to: URL(fileURLWithPath: other + "/item"))
            let deadline = ContinuousClock.now + .seconds(8)
            while !told.contains(where: { $0.changedPaths == ["item"] }) && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(25))
            }
            #expect(told.contains { $0.changedPaths == ["item"] })
            // What else happens on the disk is not.
            told = []
            try Data().write(to: URL(fileURLWithPath: home + "/elsewhere"))
            try await Task.sleep(for: .milliseconds(600))
            #expect(told.isEmpty)
        }
    }
}
