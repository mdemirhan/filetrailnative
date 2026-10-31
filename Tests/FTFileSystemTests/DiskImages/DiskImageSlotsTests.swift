// The test disk images' pool of slots (FTTestSupport): images of one kind are attached side by side, up to the pool's size
import FTTestSupport
import Foundation
import Testing

@Suite struct DiskImageSlotsTests {
    /// The descriptor `acquire` returns within `seconds`; nil when it was still waiting.
    private func acquire(_ kind: String, slots: Int, in folder: URL, within seconds: Double) async throws -> Int32? {
        try await withThrowingTaskGroup(of: Int32?.self) { group in
            group.addTask { try await DiskImageSlots.acquire(kind, slots: slots, in: folder) }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                return nil
            }
            let first = try await group.next() ?? nil
            group.cancelAll()
            // The other one: a slot taken after the time ran out is given back.
            if let late = try? await group.next(), let late { DiskImageSlots.release(late) }
            return first
        }
    }

    @Test func twoImagesOfOneKindAreAttachedAtOnce() async throws {
        let folder = try TemporaryDirectory(prefix: "disk-slots")
        defer { folder.remove() }
        let first = try #require(try await acquire("fat32", slots: 2, in: folder.url, within: 5))
        defer { DiskImageSlots.release(first) }
        let second = try await acquire("fat32", slots: 2, in: folder.url, within: 5)
        #expect(second != nil)
        if let second { DiskImageSlots.release(second) }
    }

    @Test func oneMoreThanThePoolWaitsForASlotToBeGivenBack() async throws {
        let folder = try TemporaryDirectory(prefix: "disk-slots")
        defer { folder.remove() }
        let first = try #require(try await acquire("apfs", slots: 2, in: folder.url, within: 5))
        let second = try #require(try await acquire("apfs", slots: 2, in: folder.url, within: 5))
        defer { DiskImageSlots.release(second) }
        #expect(try await acquire("apfs", slots: 2, in: folder.url, within: 0.3) == nil)
        // Another kind has slots of its own.
        let other = try await acquire("hfs", slots: 2, in: folder.url, within: 5)
        #expect(other != nil)
        if let other { DiskImageSlots.release(other) }
        DiskImageSlots.release(first)
        let third = try await acquire("apfs", slots: 2, in: folder.url, within: 5)
        #expect(third != nil)
        if let third { DiskImageSlots.release(third) }
    }
}
