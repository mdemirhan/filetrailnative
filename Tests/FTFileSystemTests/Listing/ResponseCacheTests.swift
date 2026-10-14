import FTTestSupport
import Foundation
import Testing

// Port of the getCachedResponse, forgetFolderListings and withTiming cases of
// apps/desktop/src/main/bootstrap/responseCache.test.ts
@testable import FTFileSystem

/// Holds a load until the test lets it go.
private actor Gate {
    private var waiter: CheckedContinuation<Void, Never>?
    private var released = false

    func wait() async {
        if released { return }
        await withCheckedContinuation { waiter = $0 }
    }

    var isWaiting: Bool { waiter != nil }

    func release() {
        released = true
        waiter?.resume()
        waiter = nil
    }
}

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 1_000_000.0

    var now: Double {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(_ milliseconds: Double) {
        lock.lock()
        value += milliseconds
        lock.unlock()
    }
}

private func snapshot(_ label: String) -> DirectorySnapshot {
    DirectorySnapshot(path: label, parentPath: nil, entries: [])
}

private func tree(_ label: String) -> TreeChildren {
    TreeChildren(path: label, children: [])
}

private func detail(_ path: String) -> EntryMetadata {
    EntryMetadata(
        path: path, kindLabel: "File", createdAt: nil, modifiedAt: nil, sizeBytes: nil, sizeStatus: .ready,
        permissionMode: nil)
}

struct ResponseCacheTests {
    // T-64ffebfe F-177
    @Test func capsCachedDirectorySnapshotsAndEvictsTheOldestFirst() async throws {
        let cache = ResponseCache()
        for index in 0..<200 {
            _ = await cache.directorySnapshot(ListingKey(path: "/dir/\(index)")) { snapshot("\(index)") }
        }
        #expect(cache.sizes.directorySnapshots == 64)

        let loads = CallCounter()
        let newest = await cache.directorySnapshot(ListingKey(path: "/dir/199")) {
            loads.add()
            return snapshot("-1")
        }
        #expect(newest.path == "199")
        let oldest = await cache.directorySnapshot(ListingKey(path: "/dir/0")) {
            loads.add()
            return snapshot("-1")
        }
        #expect(oldest.path == "-1")
        #expect(loads.count == 1)
    }

    // T-ee081cd1 F-177
    @Test func doesNotKeepAnAnswerThatWasLoadingWhenTheCachesWereCleared() async throws {
        let cache = ResponseCache()
        let gate = Gate()
        let key = ListingKey(path: "/dir")
        let pending = Task {
            await cache.directorySnapshot(key) {
                await gate.wait()
                return snapshot("before the write")
            }
        }
        while !(await gate.isWaiting) { await Task.yield() }
        // A write finishes while the folder is still being read: what the read returns may be from before
        // the write.
        cache.clear()
        await gate.release()
        #expect(await pending.value.path == "before the write")

        let loads = CallCounter()
        let after = await cache.directorySnapshot(key) {
            loads.add()
            return snapshot("after the write")
        }
        #expect(after.path == "after the write")
        #expect(loads.count == 1)
        // A load that started after the clear is kept as usual.
        let again = await cache.directorySnapshot(key) {
            loads.add()
            return snapshot("after the write")
        }
        #expect(again.path == "after the write")
        #expect(loads.count == 1)
    }

    // T-698fcd39
    @Test func doesNotKeepItemDetailsThatWereLoadingWhenTheCachesWereCleared() async throws {
        let cache = ResponseCache()
        let gate = Gate()
        let pending = Task {
            await cache.metadata(for: ["/dir/a.txt"]) { paths in
                await gate.wait()
                return paths.map(detail)
            }
        }
        while !(await gate.isWaiting) { await Task.yield() }
        cache.clear()
        await gate.release()
        _ = await pending.value
        #expect(cache.sizes.directoryMetadata == 0)

        let loads = CallCounter()
        _ = await cache.metadata(for: ["/dir/a.txt"]) { paths in
            loads.add()
            return paths.map(detail)
        }
        #expect(loads.count == 1)
        #expect(cache.sizes.directoryMetadata == 1)
    }

    // Expired listings were let go of only once there were too many: up to 64, of 23 MB each for a folder of
    // 100,000 items.
    // T-89b11564
    @Test func letsGoOfExpiredListingsWhenAnotherIsStored() async {
        let clock = Clock()
        let cache = ResponseCache(clock: { clock.now })
        _ = await cache.directorySnapshot(ListingKey(path: "/big")) { snapshot("100,000 items") }
        _ = await cache.treeChildren(TreeKey(path: "/big")) { tree("its folders") }
        clock.advance(3_001)

        _ = await cache.directorySnapshot(ListingKey(path: "/small")) { snapshot("2 items") }

        #expect(cache.sizes.directorySnapshots == 1)
        // The tree answer waits for the next tree answer stored to be swept, as in the original.
        #expect(cache.sizes.treeChildren == 1)
    }

    @Test func keepsAnAnswerForThreeSecondsOnly() async {
        let clock = Clock()
        let cache = ResponseCache(clock: { clock.now })
        let loads = CallCounter()
        let key = ListingKey(path: "/dir")
        for _ in 0..<2 {
            _ = await cache.directorySnapshot(key) {
                loads.add()
                return snapshot("listing")
            }
        }
        #expect(loads.count == 1)
        clock.advance(2_999)
        _ = await cache.directorySnapshot(key) {
            loads.add()
            return snapshot("listing")
        }
        #expect(loads.count == 1)
        clock.advance(2)
        _ = await cache.directorySnapshot(key) {
            loads.add()
            return snapshot("listing")
        }
        #expect(loads.count == 2)
    }

    @Test func keepsEveryVariantOfARequestApart() async {
        let cache = ResponseCache()
        let loads = CallCounter()
        let keys = [
            ListingKey(path: "/dir"), ListingKey(path: "/dir", includeHidden: true),
            ListingKey(path: "/dir", sortBy: .size), ListingKey(path: "/dir", sortDirection: .descending),
            ListingKey(path: "/dir", foldersFirst: false),
        ]
        for key in keys {
            _ = await cache.directorySnapshot(key) {
                loads.add()
                return snapshot("listing")
            }
        }
        #expect(loads.count == keys.count)
        #expect(cache.sizes.directorySnapshots == keys.count)
    }

    // Each item of a batch looked through the 5,000 kept once there were that many: 11 ms a batch of 500
    // while scrolling a large folder.
    // T-f728e863
    @Test func storesABatchOfItemDetailsWithoutLookingThroughAllThoseKeptForEach() async {
        let cache = ResponseCache()
        var next = 0
        func batch() async {
            let paths = (0..<500).map { _ in
                defer { next += 1 }
                return "/big/file-\(next).txt"
            }
            _ = await cache.metadata(for: paths) { $0.map(detail) }
        }
        for _ in 0..<10 { await batch() }
        // CPU time of the process, not wall time, so waiting for a turn on a busy machine does not fail it.
        let (_, seconds) = await CPUTime.measureProcess {
            for _ in 0..<200 { await batch() }
        }
        // A few ms on a laptop; the bound only catches looking through all of them for each.
        #expect(seconds < 1)
        #expect(cache.sizes.directoryMetadata == 5_000)
    }

    @Test func returnsItemDetailsInTheOrderAskedAndLeavesOutThoseTheLoadDoesNotGive() async {
        let cache = ResponseCache()
        _ = await cache.metadata(for: ["/d/b"]) { $0.map(detail) }
        let loaded = CallCounter()
        let items = await cache.metadata(for: ["/d/a", "/d/b", "/d/c"]) { missing in
            loaded.add()
            #expect(missing == ["/d/a", "/d/c"])
            return [detail("/d/c"), detail("/d/a")]
        }
        #expect(items.map(\.path) == ["/d/a", "/d/b", "/d/c"])
        let skipped = await cache.metadata(for: ["/d/x", "/d/a"]) { _ in [] }
        #expect(skipped.map(\.path) == ["/d/a"])
    }

    private let detailPaths = ["/p/a", "/p/a/x.txt", "/p/a/y.txt", "/p/b/z.txt"]

    /// Fills the caches as windows showing /p, /p/a and /p/b would.
    private func fill(_ cache: ResponseCache) async {
        for path in ["/p", "/p/a", "/p/b"] {
            _ = await cache.directorySnapshot(ListingKey(path: path)) { snapshot("listing") }
            _ = await cache.treeChildren(TreeKey(path: path)) { tree("children") }
        }
        _ = await cache.directorySnapshot(ListingKey(path: "/p/a", sortBy: .size)) { snapshot("by size") }
        _ = await cache.metadata(for: detailPaths) { $0.map(detail) }
    }

    /// Which of the cached answers are still handed out without reading the disk.
    private func stillCached(_ cache: ResponseCache) async -> [String] {
        var kept: [String] = []
        for path in ["/p", "/p/a", "/p/b"] {
            let loaded = CallCounter()
            _ = await cache.directorySnapshot(ListingKey(path: path)) {
                loaded.add()
                return snapshot("read again")
            }
            if loaded.count == 0 { kept.append("listing \(path)") }
            let treeLoaded = CallCounter()
            _ = await cache.treeChildren(TreeKey(path: path)) {
                treeLoaded.add()
                return tree("read again")
            }
            if treeLoaded.count == 0 { kept.append("children \(path)") }
        }
        let readAgain = Box<[String]>([])
        _ = await cache.metadata(for: detailPaths) { missing in
            readAgain.value = missing
            return []
        }
        for path in detailPaths where !readAgain.value.contains(path) {
            kept.append("details \(path)")
        }
        return kept
    }

    // T-42fbbeb8 F-178
    @Test func letsGoOfTheFoldersListingsAndTheDetailsOfTheItemsThatChanged() async {
        let cache = ResponseCache()
        await fill(cache)

        cache.forgetFolderListings("/p/a", changedPaths: ["/p/a/x.txt"])

        #expect(
            await stillCached(cache) == [
                "listing /p", "children /p", "listing /p/b", "children /p/b", "details /p/a", "details /p/a/y.txt",
                "details /p/b/z.txt",
            ])
    }

    // Read again however it is sorted.
    // T-42fbbeb8
    @Test func readsTheFolderAgainHoweverItIsSorted() async {
        let cache = ResponseCache()
        await fill(cache)
        cache.forgetFolderListings("/p/a", changedPaths: ["/p/a/x.txt"])
        let loads = CallCounter()
        _ = await cache.directorySnapshot(ListingKey(path: "/p/a", sortBy: .size)) {
            loads.add()
            return snapshot("read again")
        }
        #expect(loads.count == 1)
    }

    // T-0440a8ed F-178
    @Test func letsGoOfAllInTheFolderAndOfTheListingHoldingItWhenAnythingMayHaveChanged() async {
        let cache = ResponseCache()
        await fill(cache)

        // The folder itself may be gone, and the window then opens the folder above it.
        cache.forgetFolderListings("/p/a", changedPaths: nil)

        #expect(await stillCached(cache) == ["listing /p/b", "children /p/b", "details /p/b/z.txt"])
    }

    // T-2162fd54 F-178
    @Test func doesNotKeepAListingOfTheFolderThatWasLoadingWhenItChanged() async {
        let cache = ResponseCache()
        let gate = Gate()
        let key = ListingKey(path: "/p/a")
        let pending = Task {
            await cache.directorySnapshot(key) {
                await gate.wait()
                return snapshot("before the change")
            }
        }
        while !(await gate.isWaiting) { await Task.yield() }
        cache.forgetFolderListings("/p/a", changedPaths: ["/p/a/x.txt"])
        await gate.release()
        #expect(await pending.value.path == "before the change")

        let loads = CallCounter()
        let after = await cache.directorySnapshot(key) {
            loads.add()
            return snapshot("after the change")
        }
        #expect(after.path == "after the change")
        #expect(loads.count == 1)
    }

    // T-111af243
    @Test func logsOnlyASlowLoadWithItsLabelAndPath() async {
        let lines = Box<[String]>([])
        let fast = await withTiming("fast", path: "/a", log: { lines.value.append($0) }, load: { 1 })
        #expect(fast == 1)
        #expect(lines.value.isEmpty)

        let times = Box<[Double]>([0, 150])
        let slow = await withTiming(
            "slow", path: "/b", now: { times.value.removeFirst() }, log: { lines.value.append($0) }, load: { 2 })
        #expect(slow == 2)
        #expect(lines.value == ["[filetrail] slow /b 150ms"])
    }
}

private final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}
