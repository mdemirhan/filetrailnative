import FTTestSupport
import Foundation
import Testing

@testable import FTFileSystem

private let mounts: [Mount] = [
    Mount(path: "/", isLocal: true),
    Mount(path: "/System/Volumes/Data", isLocal: true),
    Mount(path: "/Volumes/Share", isLocal: false),
    Mount(path: "/Volumes/USB", isLocal: true),
    Mount(path: "/Volumes/Share 2", isLocal: true),
    // An automounted share, mounted outside /Volumes.
    Mount(path: "/System/Volumes/Data/mnt/nas", isLocal: false),
]

/// Every path is where it says, except the links listed.
private func linksAt(_ links: [String: String]) -> @Sendable (String) throws -> String {
    { path in
        for (link, target) in links where path == link || path.hasPrefix(link + "/") {
            return target + path.dropFirst(link.count)
        }
        return path
    }
}

private struct NoSuchFile: Error {}

@Suite struct DiskHasTrashTests {
    let diskHasTrash = makeDiskHasTrash(listMounts: { mounts }, realPath: linksAt([:]))

    // T-71566c6c F-155 F-236
    @Test func takesANetworkShareToHaveNoTrashInItOrAtItsTop() {
        #expect(!diskHasTrash("/Volumes/Share"))
        #expect(!diskHasTrash("/Volumes/Share/Projects/a.txt"))
    }

    // T-c3107dcb F-155 F-236
    @Test func takesAnyOtherDiskToHaveOne() {
        #expect(diskHasTrash("/Volumes/USB/a.txt"))
        #expect(diskHasTrash("/Users/demo/a.txt"))
    }

    // T-8a6058bb F-155 F-236
    @Test func doesntMistakeADiskWhoseNameStartsLikeASharesForTheShare() {
        #expect(diskHasTrash("/Volumes/Share 2/a.txt"))
    }

    // T-59f8c035 F-155 F-236
    @Test func readsTheDisksEachTimeSinceTheyComeAndGo() {
        final class Current: @unchecked Sendable { var mounts: [Mount] = [] }
        let current = Current()
        let hasTrash = makeDiskHasTrash(listMounts: { current.mounts }, realPath: linksAt([:]))
        #expect(hasTrash("/Volumes/Share/a.txt"))
        current.mounts = [Mount(path: "/Volumes/Share", isLocal: false)]
        #expect(!hasTrash("/Volumes/Share/a.txt"))
    }

    // T-861c8aae F-155 F-236
    @Test func findsAShareReachedThroughALink() {
        let hasTrash = makeDiskHasTrash(
            listMounts: { mounts }, realPath: linksAt(["/Users/demo/NAS": "/Volumes/Share"]))
        #expect(!hasTrash("/Users/demo/NAS/Projects"))
    }

    // T-550dc5fa F-155 F-236
    @Test func findsAShareNamedInAnotherCase() {
        #expect(!diskHasTrash("/volumes/SHARE/Projects"))
    }

    // T-cb592e69 F-155 F-236
    @Test func findsAShareMountedOutsideVolumes() {
        let hasTrash = makeDiskHasTrash(
            listMounts: { mounts }, realPath: linksAt(["/mnt": "/System/Volumes/Data/mnt"]))
        #expect(!hasTrash("/mnt/nas/a.txt"))
        #expect(hasTrash("/mnt/other/a.txt"))
    }

    // T-d5fc03ae F-155 F-236
    @Test func followsThePartOfThePathThatExists() {
        let hasTrash = makeDiskHasTrash(
            listMounts: { mounts },
            realPath: { path in
                if path == "/Users/demo/NAS" { return "/Volumes/Share" }
                if path.hasPrefix("/Users/demo/NAS/") { throw NoSuchFile() }
                return path
            })
        #expect(!hasTrash("/Users/demo/NAS/New/Deeper"))
    }

    // T-2ff64c9e F-155 F-236
    @Test func goesByThePathAsGivenWhenNoPartOfItCanBeRead() {
        let hasTrash = makeDiskHasTrash(listMounts: { mounts }, realPath: { _ in throw NoSuchFile() })
        #expect(!hasTrash("/Volumes/Share/a.txt"))
        #expect(hasTrash("/Users/demo/a.txt"))
    }

    // T-b3c7e3ed F-155
    @Test func theMountTableListsTheStartupDiskWhereverItIsMounted() {
        let listed = MountTable.list()
        #expect(listed.contains(Mount(path: "/", isLocal: true)))
        #expect(listed.contains(Mount(path: "/System/Volumes/Data", isLocal: true)))
    }

    // T-624fdb66 F-144 F-210 F-237
    @Test func followsALinkToTheDiskItLeadsTo() throws {
        try withTemporaryDirectory { root in
            try FileManager.default.createSymbolicLink(
                atPath: root.appending("Share").path, withDestinationPath: "/System/Volumes/Data")
            // The link leads to a share as far as this mount table says.
            let hasTrash = makeDiskHasTrash(
                listMounts: { [Mount(path: "/", isLocal: true), Mount(path: "/System/Volumes/Data", isLocal: false)] },
                realPath: MountTable.realPath)
            #expect(!hasTrash(root.appending("Share").appendingPathComponent("New Folder").path))
        }
    }
}

@Suite struct DiskIdsTests {
    // T-7bf85637 F-144 F-210 F-237
    @Test func givesFoldersOnOneDiskTheSameIdAndNilForAPathThatIsntThere() throws {
        try withTemporaryDirectory { root in
            try FileManager.default.createDirectory(at: root.appending("a"), withIntermediateDirectories: false)
            try FileManager.default.createDirectory(at: root.appending("b"), withIntermediateDirectories: false)
            let ids = SystemActions.diskIds(paths: [
                root.appending("a").path, root.appending("b").path, root.appending("missing").path,
            ])
            #expect(ids[0] != nil)
            #expect(ids[1] == ids[0])
            #expect(ids[2] == nil)
        }
    }

    // T-8c15b096 F-210 F-237
    @Test(.tags(.diskImage), .diskImages)
    func tellsAnotherDiskApartWhereverItIsMountedAlsoThroughALink() async throws {
        try await DiskImage.withVolume(.apfs) { volume in
            try withTemporaryDirectory { root in
                try FileManager.default.createSymbolicLink(
                    atPath: root.appending("link to disk").path, withDestinationPath: volume.path)
                let ids = SystemActions.diskIds(paths: [root.path, volume.path, root.appending("link to disk").path])
                #expect(ids[1] != ids[0])
                #expect(ids[2] == ids[1])
            }
        }
    }
}

@Suite struct TrashStateTests {
    private static func reader(_ folders: [String: Result<[String], POSIXError>]) -> TrashState.Reader {
        { path in
            guard let found = folders[path] else { throw POSIXError(.ENOENT) }
            return try found.get()
        }
    }

    // T-64afef80 F-146 F-154 F-231
    @Test func isEmptyWhenNoTrashHoldsAnythingButFindersDSStore() {
        let read = Self.reader([
            "/Users/demo/.Trash": .success([".DS_Store"]),
            "/Volumes": .success(["Macintosh HD", "USB"]),
            "/Volumes/USB/.Trashes/501": .success([]),
        ])
        #expect(TrashState.isEmpty(home: "/Users/demo", uid: 501, read: read) == true)
    }

    // Finder's Empty Trash empties every disk's Trash, so one with items makes it worth it.
    // T-d2c931c9 F-154 F-231
    @Test func isntEmptyWhenAnotherDisksTrashHoldsSomething() {
        let read = Self.reader([
            "/Users/demo/.Trash": .success([]),
            "/Volumes": .success(["USB"]),
            "/Volumes/USB/.Trashes/501": .success(["old.txt"]),
        ])
        #expect(TrashState.isEmpty(home: "/Users/demo", uid: 501, read: read) == false)
    }

    // Without Full Disk Access macOS refuses to list the Trash: nothing says it is empty.
    // T-6c935069 F-146 F-231
    @Test func cantTellWhenTheTrashCantBeRead() {
        let read = Self.reader([
            "/Users/demo/.Trash": .failure(POSIXError(.EPERM)),
            "/Volumes": .success([]),
        ])
        #expect(TrashState.isEmpty(home: "/Users/demo", uid: 501, read: read) == nil)
    }

    @Test func readsTheRealDirectoryListing() throws {
        try withTemporaryDirectory { root in
            try Data().write(to: root.appending("a.txt"))
            #expect(try TrashState.readDirectory(root.path) == ["a.txt"])
            #expect(throws: POSIXError.self) { try TrashState.readDirectory(root.appending("missing").path) }
        }
    }
}

private final class ScriptLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    var sources: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
    func add(_ source: String) {
        lock.lock()
        recorded.append(source)
        lock.unlock()
    }
}

@Suite struct EmptyTrashTests {
    // AppleScript stops waiting for Finder after two minutes, which a large Trash takes longer than.
    // T-e7e0eab4 F-146 F-232
    @Test func asksFinderWithAWaitOfADayNotAppleScriptsTwoMinutes() async {
        let log = ScriptLog()
        let result = await TrashState.empty { source in log.add(source) }
        #expect(result == .success)
        #expect(
            log.sources == [
                "with timeout of 86400 seconds\ntell application \"Finder\" to empty trash\nend timeout"
            ])
    }

    // T-8442c436
    @Test func reportsTheScriptEnginesOwnErrorLineNotTheScriptThatRan() async {
        let line = "execution error: Not authorized to send Apple events to Finder. (-1743)"
        let result = await TrashState.empty { _ in throw TrashState.AppleScriptFailure(message: line + "\n") }
        #expect(result == .failure(line))
    }
}
