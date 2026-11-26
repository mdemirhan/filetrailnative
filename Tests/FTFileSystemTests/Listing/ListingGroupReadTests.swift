import FTFoundation
import Foundation
import Testing

@testable import FTFileSystem

/// A listing for groups (View ▸ Group By) reads the value of each item its groups need, besides what its order needs,
/// and nothing for groups of names or kinds.
struct ListingGroupReadTests {
    private func service(_ fileSystem: FakeFileSystem) -> DirectoryService {
        DirectoryService(fileSystem: fileSystem, cache: ResponseCache(), kinds: KindLabeler(describer: nil))
    }

    /// `/workspace` with two files and a folder; each file's times and size from `stats`.
    private func workspace() -> FakeFileSystem {
        let fake = FakeFileSystem()
        var withAdded = fakeDirent("b.txt", file: true)
        withAdded.addedMs = 5_000
        let added = withAdded
        fake.directory = { _ in [fakeDirent("a.txt", file: true), added, fakeDirent("Folder", directory: true)] }
        fake.statHandler = { path in
            switch path {
            case "/workspace", "/workspace/Folder": fakeStats(directory: true, file: false, size: 0)
            case "/workspace/a.txt":
                fakeStats(directory: false, file: true, size: 12, mtimeMs: 2_000, birthtimeMs: 1_000)
            default: fakeStats(directory: false, file: true, size: 3_000_000, mtimeMs: 4_000, birthtimeMs: 3_000)
            }
        }
        fake.lstatHandler = fake.statHandler
        return fake
    }

    private func entries(_ snapshot: DirectorySnapshot) -> [String: DirectoryEntry] {
        Dictionary(uniqueKeysWithValues: snapshot.entries.map { ($0.name, $0) })
    }

    @Test func groupsOfADateHaveThatDateOfEachItemWhateverTheOrder() async throws {
        let fake = workspace()
        let modified = entries(try await service(fake).snapshot(path: "/workspace", groupRead: .modified))
        #expect(modified["a.txt"]?.groupTimeMs == 2_000)
        #expect(modified["b.txt"]?.groupTimeMs == 4_000)
        let created = entries(try await service(fake).snapshot(path: "/workspace", groupRead: .created))
        #expect(created["a.txt"]?.groupTimeMs == 1_000)
        #expect(created["b.txt"]?.groupTimeMs == 3_000)
        // Date Added comes with the folder read: a disk that doesn't keep it leaves the item without one.
        let added = entries(try await service(fake).snapshot(path: "/workspace", groupRead: .added))
        #expect(added["b.txt"]?.groupTimeMs == 5_000)
        #expect(added["a.txt"]?.groupTimeMs == nil)
        // The order stays the one asked for: by name, folders first.
        let order = try await service(fake).snapshot(path: "/workspace", sortBy: .name, groupRead: .modified)
        #expect(order.entries.map(\.name) == ["Folder", "a.txt", "b.txt"])
    }

    @Test func groupsOfDateLastOpenedLookAtEachItemOnlyWhileGroupedByIt() async throws {
        let fake = workspace()
        fake.lastOpenedHandler = { $0.hasSuffix("a.txt") ? 7_000 : nil }
        let opened = entries(try await service(fake).snapshot(path: "/workspace", groupRead: .lastOpened))
        #expect(opened["a.txt"]?.groupTimeMs == 7_000)
        #expect(opened["b.txt"]?.groupTimeMs == nil)
        let plain = entries(try await service(fake).snapshot(path: "/workspace"))
        #expect(plain.values.allSatisfy { $0.groupTimeMs == nil })
    }

    // Files have their size as when sorted by Size; a folder has none, as its size is measured.
    @Test func groupsOfASizeHaveEachFilesSize() async throws {
        let sized = entries(try await service(workspace()).snapshot(path: "/workspace", groupRead: .size))
        #expect(sized["a.txt"]?.sizeBytes == 12)
        #expect(sized["b.txt"]?.sizeBytes == 3_000_000)
        #expect(sized["Folder"]?.sizeBytes == nil)
    }

    // Every item's tags are read, not only those with a colored label, as a tag can have no color; its group is its
    // first tag A to Z, as an order by tags reads them, whatever order they were put on in.
    @Test func groupsOfTagsReadEveryItemsFirstTag() async throws {
        let fake = workspace()
        fake.tagNamesHandler = { $0.hasSuffix("a.txt") ? ["Work", "Home"] : [] }
        let tagged = entries(try await service(fake).snapshot(path: "/workspace", groupRead: .tags))
        #expect(tagged["a.txt"]?.firstTag == "Home")
        #expect(tagged["b.txt"]?.firstTag == nil)
        #expect(Set(fake.tagNamesRead) == ["/workspace/a.txt", "/workspace/b.txt", "/workspace/Folder"])
    }

    // Groups of names and kinds need nothing the folder read doesn't give: nothing more is asked of the disk.
    @Test func otherGroupsReadNothingMore() async throws {
        let fake = workspace()
        let snapshot = try await service(fake).snapshot(path: "/workspace", groupRead: .none)
        #expect(snapshot.entries.allSatisfy { $0.groupTimeMs == nil && $0.firstTag == nil && $0.sizeBytes == nil })
        #expect(fake.tagNamesRead.isEmpty)
        #expect(!fake.lookedUp.contains { $0.hasSuffix(".txt") })
    }

    // A listing for other groups is another listing: what was kept for the first isn't given for it.
    @Test func aListingForOtherGroupsIsNotTakenFromTheCache() async throws {
        let fake = workspace()
        let service = service(fake)
        _ = try await service.snapshot(path: "/workspace")
        let grouped = try await service.snapshot(path: "/workspace", groupRead: .modified)
        #expect(grouped.entries.contains { $0.groupTimeMs != nil })
        #expect(ListingKey(path: "/a", groupRead: .size) != ListingKey(path: "/a"))
    }
}
