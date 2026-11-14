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

    // An item a read found nothing for (its folder is gone) isn't asked for again, however often its row asks, until
    // it changes or the cache starts over; an item that changed while it was read is still read once more.
    @Test func anItemFoundNothingForIsNotAskedAgainUntilItChanges() {
        var cache = Cache()
        _ = cache.begin(["/gone/a", "/b"])
        #expect(cache.finish(["/gone/a", "/b"], from: cache.generation, answers: ["/b": 2]) == [])
        #expect(cache.unanswered == ["/gone/a"])
        #expect(cache.begin(["/gone/a", "/b"]).isEmpty)
        cache.markChanged(["/gone/a"])
        #expect(cache.begin(["/gone/a"]) == ["/gone/a"])
        _ = cache.finish(["/gone/a"], from: cache.generation, answers: [:])
        cache.markChanged(nil)
        #expect(cache.begin(["/gone/a"]) == ["/gone/a"])
        _ = cache.finish(["/gone/a"], from: cache.generation, answers: [:])
        cache.startOver()
        #expect(cache.begin(["/gone/a"]) == ["/gone/a"])
        cache.markChanged(["/gone/a"])
        #expect(cache.finish(["/gone/a"], from: cache.generation, answers: [:]) == ["/gone/a"])
        #expect(cache.unanswered.isEmpty)
        #expect(cache.begin(["/gone/a"]) == ["/gone/a"])
    }

    // An item known before that a read finds gone lets go of what it had, and isn't asked again until it changes.
    @Test func aKnownItemFoundGoneLetsGoOfWhatItHad() {
        var cache = Cache()
        _ = cache.begin(["/a", "/b"])
        _ = cache.finish(["/a", "/b"], from: cache.generation, answers: ["/a": 1, "/b": 2])
        cache.markChanged(["/a"])
        #expect(cache.stale == ["/a"] && cache["/a"] == 1)
        _ = cache.begin(["/a"])
        #expect(cache.finish(["/a"], from: cache.generation, answers: [:]) == [])
        #expect(cache["/a"] == nil && cache.stale.isEmpty && cache.unanswered == ["/a"])
        #expect(cache["/b"] == 2)
        #expect(cache.begin(["/a"]).isEmpty)
        // Everything may have changed: it is neither changed (it has nothing) nor kept from being asked for.
        cache.markChanged(nil)
        #expect(cache.stale == ["/b"] && cache.unanswered.isEmpty)
        #expect(cache.begin(["/a"]) == ["/a"])
        _ = cache.finish(["/a"], from: cache.generation, answers: ["/a": 3])
        #expect(cache["/a"] == 3 && cache.unanswered.isEmpty)
    }

    // An item that changed while the read that found it gone ran keeps what it had until it is read once more.
    @Test func aKnownItemFoundGoneThatChangedMeanwhileIsReadOnceMore() {
        var cache = Cache()
        _ = cache.begin(["/a"])
        _ = cache.finish(["/a"], from: cache.generation, answers: ["/a": 1])
        cache.markChanged(["/a"])
        _ = cache.begin(["/a"])
        cache.markChanged(["/a"])
        #expect(cache.finish(["/a"], from: cache.generation, answers: [:]) == ["/a"])
        #expect(cache["/a"] == 1 && cache.stale == ["/a"] && cache.unanswered.isEmpty)
        #expect(cache.begin(["/a"]) == ["/a"])
        #expect(cache.finish(["/a"], from: cache.generation, answers: [:]) == [])
        #expect(cache["/a"] == nil && cache.stale.isEmpty && cache.unanswered == ["/a"])
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
