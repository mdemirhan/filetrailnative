import FTFoundation
import FTTestSupport
import Foundation
import Synchronization
import Testing

// Two folders whose names differ only in how an accent is spelled, which a disk can keep side by side (FAT, a share
// from Linux): each has its own listing, its own details and its own place in what is forgotten
@testable import FTFileSystem

/// "/x/café" with the accent as one scalar, and with the accent apart: equal to `==` on text, two names on such a
/// disk.
private let composed = "/x/caf\u{E9}"
private let decomposed = "/x/cafe\u{301}"

private func bytes(_ paths: [String]) -> [DiskPath] { paths.map(DiskPath.init) }

/// A disk holding both folders: the composed one has "one.txt", the decomposed one "two.txt" and a folder "inner".
private func disk() -> FakeFileSystem {
    let fake = FakeFileSystem()
    fake.statHandler = { path in fakeStats(directory: !path.hasSuffix(".txt"), file: path.hasSuffix(".txt"), size: 3) }
    fake.lstatHandler = fake.statHandler
    fake.directory = { path in
        if DiskPath(path) == DiskPath(composed) {
            return [fakeDirent("one.txt", file: true), fakeDirent("left", directory: true)]
        }
        if DiskPath(path) == DiskPath(decomposed) {
            return [fakeDirent("two.txt", file: true), fakeDirent("inner", directory: true)]
        }
        if path == "/x" {
            return [fakeDirent("caf\u{E9}", directory: true), fakeDirent("cafe\u{301}", directory: true)]
        }
        throw ExplorerError.system(code: ENOENT, path: path)
    }
    return fake
}

private func detail(_ path: String, size: Int64) -> EntryMetadata {
    EntryMetadata(
        path: path, kindLabel: "File", createdAt: nil, modifiedAt: nil, sizeBytes: size, sizeStatus: .ready,
        permissionMode: nil)
}

struct TwoSpellingsListingTests {
    @Test func theTextsAreEqualAndTheirBytesAreNot() {
        #expect(composed == decomposed)
        #expect(DiskPath(composed) != DiskPath(decomposed))
    }

    // The cache answers each folder with its own listing, in both orders of asking.
    @Test func eachFolderIsListedAndKeptAsItself() async throws {
        let service = DirectoryService(fileSystem: disk(), cache: ResponseCache(), kinds: KindLabeler(describer: nil))
        let first = try await service.snapshot(path: composed)
        let second = try await service.snapshot(path: decomposed)
        #expect(first.entries.map(\.name) == ["left", "one.txt"])
        #expect(second.entries.map(\.name) == ["inner", "two.txt"])
        #expect(DiskPath(first.path) == DiskPath(composed))
        #expect(DiskPath(second.path) == DiskPath(decomposed))
        // Asked again, each is still itself: the one kept for the other spelling isn't handed over.
        #expect(try await service.snapshot(path: composed).entries.map(\.name) == ["left", "one.txt"])
        #expect(try await service.snapshot(path: decomposed).entries.map(\.name) == ["inner", "two.txt"])
        // The folder holding both lists both, each row with its own path.
        let both = try await service.snapshot(path: "/x")
        #expect(Set(bytes(both.entries.map(\.path))) == Set(bytes([composed, decomposed])))
    }

    @Test func eachFolderHasItsOwnFoldersInTheTree() async throws {
        let service = DirectoryService(fileSystem: disk(), cache: ResponseCache(), kinds: KindLabeler(describer: nil))
        #expect(try await service.treeChildren(path: composed).children.map(\.name) == ["left"])
        #expect(try await service.treeChildren(path: decomposed).children.map(\.name) == ["inner"])
        #expect(try await service.treeChildren(path: composed).children.map(\.name) == ["left"])
    }

    // A change in one folder forgets that folder's listings, and the other's are kept.
    @Test func forgettingOneFoldersListingsKeepsTheOthers() async throws {
        let cache = ResponseCache()
        let loads = CallCounter()
        func listing(_ path: String) async -> DirectorySnapshot {
            await cache.directorySnapshot(ListingKey(path: path)) {
                loads.add()
                return DirectorySnapshot(path: path, parentPath: "/x", entries: [])
            }
        }
        func children(_ path: String) async -> TreeChildren {
            await cache.treeChildren(TreeKey(path: path)) {
                loads.add()
                return TreeChildren(path: path, children: [])
            }
        }
        #expect(DiskPath(await listing(composed).path) == DiskPath(composed))
        #expect(DiskPath(await listing(decomposed).path) == DiskPath(decomposed))
        #expect(DiskPath(await children(composed).path) == DiskPath(composed))
        #expect(DiskPath(await children(decomposed).path) == DiskPath(decomposed))
        #expect(loads.count == 4)
        #expect(cache.sizes.directorySnapshots == 2 && cache.sizes.treeChildren == 2)

        cache.forgetFolderListings(composed, changedPaths: [])
        #expect(cache.sizes.directorySnapshots == 1 && cache.sizes.treeChildren == 1)
        // The other folder is still answered from what is kept, as itself.
        #expect(DiskPath(await listing(decomposed).path) == DiskPath(decomposed))
        #expect(DiskPath(await children(decomposed).path) == DiskPath(decomposed))
        #expect(loads.count == 4)
        // The one forgotten is read again.
        #expect(DiskPath(await listing(composed).path) == DiskPath(composed))
        #expect(loads.count == 5)
    }

    // Item details are kept by path: an item in one folder isn't answered with the one of the same name in the other,
    // and a change to one leaves the other's kept.
    @Test func eachItemsDetailsAreItsOwn() async throws {
        let cache = ResponseCache()
        let inComposed = composed + "/a.txt"
        let inDecomposed = decomposed + "/a.txt"
        let asked = Mutex<[[String]]>([])
        func details(_ paths: [String]) async -> [EntryMetadata] {
            await cache.metadata(for: paths) { missing in
                asked.withLock { $0.append(missing) }
                return missing.map { detail($0, size: DiskPath($0) == DiskPath(inComposed) ? 1 : 2) }
            }
        }
        let both = await details([inComposed, inDecomposed])
        #expect(both.map(\.sizeBytes) == [1, 2])
        #expect(bytes(both.map(\.path)) == bytes([inComposed, inDecomposed]))
        #expect(asked.withLock { $0.map(bytes) } == [bytes([inComposed, inDecomposed])])
        #expect(cache.sizes.directoryMetadata == 2)

        // The item that changed is read again; the other is answered from what is kept.
        cache.forgetFolderListings(composed, changedPaths: [inComposed])
        #expect(cache.sizes.directoryMetadata == 1)
        #expect(await details([inDecomposed, inComposed]).map(\.sizeBytes) == [2, 1])
        #expect(asked.withLock { $0.map(bytes) } == [bytes([inComposed, inDecomposed]), bytes([inComposed])])

        // Anything in one folder may have changed: its items' details go, the other folder's stay.
        cache.forgetFolderListings(decomposed, changedPaths: nil)
        #expect(cache.sizes.directoryMetadata == 1)
        #expect(await details([inComposed]).map(\.sizeBytes) == [1])
        #expect(asked.withLock { $0.count } == 2)
    }

    // The Date Added a listing gave each of two items named alike is shown on its own row.
    @Test func eachRowShowsTheDateAddedItsOwnListingGave() async throws {
        let fake = disk()
        fake.directory = { _ in
            [fakeDirent("caf\u{E9}.txt", file: true), fakeDirent("cafe\u{301}.txt", file: true)]
        }
        let service = DirectoryService(fileSystem: fake, cache: ResponseCache(), kinds: KindLabeler(describer: nil))
        let first = "/x/caf\u{E9}.txt"
        let second = "/x/cafe\u{301}.txt"
        var listed: [DiskPath: Int64?] = [:]
        listed.updateValue(jan2 + 1_000, forKey: DiskPath(first))
        listed.updateValue(jan2 + 2_000, forKey: DiskPath(second))
        let batch = try await service.metadata(directoryPath: "/x", paths: [first, second], listedAdded: listed)
        #expect(bytes(batch.items.map(\.path)) == bytes([first, second]))
        #expect(
            batch.items.map(\.addedAt) == [
                FileTime.date(milliseconds: jan2 + 1_000), FileTime.date(milliseconds: jan2 + 2_000),
            ])
        // Kept details take the date their listing gives now, each its own.
        listed.updateValue(jan2 + 3_000, forKey: DiskPath(second))
        let again = try await service.metadata(directoryPath: "/x", paths: [first, second], listedAdded: listed)
        #expect(
            again.items.map(\.addedAt) == [
                FileTime.date(milliseconds: jan2 + 1_000), FileTime.date(milliseconds: jan2 + 3_000),
            ])
        #expect(fake.addedRead.isEmpty)
    }

    // An item asked about as in one folder is refused when it is in the other.
    @Test func anItemOfTheOtherFolderIsOutsideTheFolderAsked() async throws {
        let service = DirectoryService(fileSystem: disk(), cache: ResponseCache(), kinds: KindLabeler(describer: nil))
        await #expect(throws: ExplorerError.self) {
            try await service.metadata(directoryPath: composed, paths: [decomposed + "/two.txt"])
        }
        let own = try await service.metadata(directoryPath: decomposed, paths: [decomposed + "/two.txt"])
        #expect(own.items.count == 1)
    }

    // The home folder's Trash is one path: a folder beside it spelled the other way is a folder like any other.
    @Test func theTrashIsKnownByItsPathsBytes() {
        let trash = TrashFolders(homePath: "/Users/jos\u{E9}", uid: 501, listMounts: { [] })
        #expect(trash.isAlwaysHidden(".Trash", in: "/Users/jos\u{E9}"))
        #expect(!trash.isAlwaysHidden(".Trash", in: "/Users/jose\u{301}"))
        #expect(DiskPath(trash.listedFolder(for: "/Users/jose\u{301}/.Trash")) == DiskPath("/Users/jose\u{301}/.Trash"))
        #expect(DiskPath(trash.listedFolder(for: "/Users/jos\u{E9}/.Trash")) == DiskPath(trash.home))
    }
}
