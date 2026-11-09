// What is read for items one at a time: which are read, when again, and which answers count
import Testing

@testable import FTFoundation

struct PathReadCacheTests {
    private typealias Cache = PathReadCache<Int>

    @Test func readsWhatIsNotKnownOnceAtATime() {
        var cache = Cache()
        #expect(cache.begin(["/a", "/b"]) == ["/a", "/b"])
        #expect(cache.isReading)
        #expect(cache.begin(["/a", "/c"]) == ["/c"])
        #expect(cache.finish(["/a", "/b"], from: cache.generation, answers: ["/a": 1, "/b": 2]) == [])
        #expect(cache["/a"] == 1 && cache["/b"] == 2)
        #expect(cache.begin(["/a", "/b"]).isEmpty)
        #expect(cache.reading == ["/c"])
    }

    // A changed item keeps what it has until it is read again.
    @Test func aChangedItemKeepsWhatItHasUntilReadAgain() {
        var cache = Cache()
        _ = cache.begin(["/a", "/b"])
        _ = cache.finish(["/a", "/b"], from: cache.generation, answers: ["/a": 1, "/b": 2])
        cache.markChanged(["/a", "/unknown"])
        #expect(cache.stale == ["/a"])
        #expect(cache["/a"] == 1)
        #expect(cache.begin(["/a", "/b"]) == ["/a"])
        _ = cache.finish(["/a"], from: cache.generation, answers: ["/a": 10])
        #expect(cache["/a"] == 10 && cache.stale.isEmpty)
        cache.markChanged(nil)
        #expect(cache.stale == ["/a", "/b"])
    }

    // An item that changes while it is read is read once more: the answer may be from before.
    @Test func anItemThatChangesWhileItIsReadIsReadOnceMore() {
        var cache = Cache()
        _ = cache.begin(["/a"])
        _ = cache.finish(["/a"], from: cache.generation, answers: ["/a": 1])
        cache.markChanged(["/a"])
        _ = cache.begin(["/a"])
        cache.markChanged(["/a"])
        #expect(cache.finish(["/a"], from: cache.generation, answers: ["/a": 1]) == ["/a"])
        #expect(cache.stale == ["/a"])
        #expect(cache.begin(["/a"]) == ["/a"])
        #expect(cache.finish(["/a"], from: cache.generation, answers: ["/a": 2]) == [])
        #expect(cache["/a"] == 2 && cache.stale.isEmpty)
        // Everything changed (nil) counts the same for what is being read.
        cache.markChanged(nil)
        _ = cache.begin(["/a"])
        cache.markChanged(nil)
        #expect(cache.finish(["/a"], from: cache.generation, answers: ["/a": 2]) == ["/a"])
    }

    // After a start over an answer from before changes nothing, and leaves the read begun since under way.
    @Test func anAnswerFromBeforeAStartOverIsDropped() {
        var cache = Cache()
        _ = cache.begin(["/a"])
        let before = cache.generation
        cache.startOver()
        #expect(!cache.isReading)
        #expect(cache.begin(["/a"]) == ["/a"])
        #expect(cache.finish(["/a"], from: before, answers: ["/a": 1]) == nil)
        #expect(cache["/a"] == nil)
        #expect(cache.isReading)
        #expect(cache.finish(["/a"], from: cache.generation, answers: ["/a": 2]) == [])
        #expect(cache["/a"] == 2)
    }

    // An answer that no longer belongs to what is shown only ends the read.
    @Test func anAnswerThatNoLongerBelongsOnlyEndsTheRead() {
        var cache = Cache()
        _ = cache.begin(["/a"])
        cache.markChanged(["/a"])
        #expect(cache.finish(["/a"], from: cache.generation, answers: nil) == [])
        #expect(cache["/a"] == nil && !cache.isReading)
    }

    // A folder back from under search results has what it had, and nothing being read.
    @Test func startingOverCanKeepWhatAnotherKnew() {
        var folder = Cache()
        _ = folder.begin(["/a", "/b"])
        _ = folder.finish(["/a", "/b"], from: folder.generation, answers: ["/a": 1, "/b": 2])
        folder.markChanged(["/b"])
        let kept = folder
        _ = folder.begin(["/c"])
        folder.startOver()
        folder.startOver(keeping: kept)
        #expect(folder.values == ["/a": 1, "/b": 2])
        #expect(folder.stale == ["/b"])
        #expect(!folder.isReading)
        #expect(folder.generation > kept.generation)
    }
}
