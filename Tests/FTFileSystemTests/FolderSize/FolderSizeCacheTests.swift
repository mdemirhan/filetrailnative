// Ports apps/desktop/src/main/bootstrap/folderSizeCache.test.ts
import FTFoundation
import Foundation
import Testing

@testable import FTFileSystem

func stats(_ sizeBytes: Int64, fileCount: Int = 1, folderCount: Int = 0, dev: Int64 = 16, measurement: Int = 1)
    -> FolderSizeStats
{
    FolderSizeStats(
        sizeBytes: sizeBytes, diskBytes: sizeBytes, fileCount: fileCount, folderCount: folderCount, dev: dev,
        measurement: measurement)
}

/// A small random generator, so a failure can be run again from its seed.
private struct RandomGenerator {
    var state: UInt64

    init(seed: Int) {
        state = UInt64(seed)
    }

    mutating func next(_ limit: Int) -> Int {
        state = (state &* 1_103_515_245 &+ 12_345) % 2_147_483_648
        return Int(state % UInt64(limit))
    }
}

private func randomPaths(_ next: inout RandomGenerator, count: Int) -> [String] {
    let names = ["a", "b", "ab", "a b", ".Trash"]
    return (0..<count).map { _ in
        let depth = next.next(5)
        var path = ""
        for _ in 0..<depth {
            path += "/\(names[next.next(names.count)])"
        }
        // Now and then the odd forms a path can be written in.
        let form = next.next(12)
        return path.isEmpty ? "/" : form == 0 ? "\(path)/" : form == 1 ? "/\(path)" : path
    }
}

private func isAtOrInside(_ path: String, folder: String) -> Bool {
    let prefix = folder.hasSuffix("/") ? folder : "\(folder)/"
    return path == folder || path.hasPrefix(prefix)
}

private struct RandomCache {
    var cache = FolderSizeCache()
    var next: RandomGenerator

    /// The sizes kept, after random stores, changes and deletes of 60 paths.
    init(seed: Int) {
        next = RandomGenerator(seed: seed)
        let paths = randomPaths(&next, count: 60)
        for step in 0..<80 {
            let path = paths[next.next(paths.count)]
            let action = next.next(10)
            if action < 7 {
                cache.store(path, stats(Int64(step)))
            } else if action < 8 {
                cache.set(path, stats(Int64(step)))
            } else {
                cache.delete(path)
            }
        }
    }

    var kept: [String] { cache.entries().map(\.path).sorted() }
}

@Suite struct FolderSizeCacheTests {
    // T-c40c6dc9
    @Test func forgetsWhatAChangeTouchedAsLookingAtEverySizeDoes() {
        for seed in 1...300 {
            var random = RandomCache(seed: seed)
            let changed = randomPaths(&random.next, count: 1 + (seed % 6))
            let expected = random.kept.filter { !WriteEffects.isAffectedByChange($0, changedPaths: changed) }

            random.cache.forgetAffected(changed)

            #expect(random.kept == expected, "seed \(seed), \(changed)")
        }
    }

    // T-7079a4e2
    @Test func forgetsWhatIsAtOrInsidePathsAsLookingAtEverySizeDoes() {
        for seed in 1...300 {
            var random = RandomCache(seed: seed)
            let removed = randomPaths(&random.next, count: 1 + (seed % 4))
            let expected = random.kept.filter { path in !removed.contains { isAtOrInside(path, folder: $0) } }

            random.cache.forgetAtOrInside(removed)

            #expect(random.kept == expected, "seed \(seed), \(removed)")
        }
    }

    // T-963f544d
    @Test func findsWhatIsInsideAFolderAgainAfterSizesComeAndGo() {
        let cache = FolderSizeCache()
        cache.store("/Users/demo/a/b/c", stats(1))
        cache.store("/Users/demo/a", stats(2))
        cache.delete("/Users/demo/a")
        cache.store("/Users/demo/a/b", stats(3))
        cache.delete("/Users/demo/a/b/c")
        cache.store("/Users/demo/a/b/c/d", stats(4))
        cache.set("/Users/demo/x", stats(5))

        cache.forgetAffected(["/Users/demo/a"])

        #expect(cache.entries().map(\.path) == ["/Users/demo/x"])
        cache.forgetAffected(["/"])
        #expect(cache.size == 0)
    }

    // A home folder's walk stores 176,000 sizes. With a limit of 100,000, the folders it finished first (small
    // ones directly in the home folder among them) were let go, and showed no size until the home folder was
    // measured again.
    // T-ac9e4e45
    @Test func keepsEverySizeStoredQuickly() {
        let cache = FolderSizeCache()
        let started = ContinuousClock.now
        for index in 0..<400_000 {
            cache.store("/Users/demo/Library/c\(index % 400)/d\(index)", stats(Int64(index)))
        }
        // Well under a second on a laptop.
        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(cache.size == 400_000)
        #expect(cache.has("/Users/demo/Library/c0/d0"))
    }

    @Test func keepsNormalizationVariantsOfAPathApart() {
        let cache = FolderSizeCache()
        let composed = "/Users/demo/caf\u{E9}"
        let decomposed = "/Users/demo/cafe\u{301}"
        cache.store(composed, stats(1))
        cache.store(decomposed, stats(2))

        #expect(cache.size == 2)
        #expect(cache.get(composed)?.sizeBytes == 1)
        #expect(cache.get(decomposed)?.sizeBytes == 2)
        cache.delete(composed)
        #expect(cache.get(decomposed)?.sizeBytes == 2)
    }

    @Suite struct WhileAWriteRuns {
        // T-a3935b15
        @Test func forgetsOfTheSizesStoredMeanwhileThoseOfTheFoldersHoldingWhatItRemoved() {
            let cache = FolderSizeCache()
            cache.store("/Users/demo/Work", stats(1))
            cache.startRecording()
            for path in ["/Users/demo/Projects", "/Users/demo/Projects/app", "/Users/demo/Music"] {
                cache.store(path, stats(2))
            }

            cache.forgetRecordedHolding(["/Users/demo/Projects/app/a.txt", "/Users/demo/Work/b"], atToo: false)

            #expect(cache.entries().map(\.path).sorted() == ["/Users/demo/Music", "/Users/demo/Work"])
            cache.forgetRecordedHolding(["/Users/demo/Music"], atToo: true)
            #expect(!cache.has("/Users/demo/Music"))
        }

        // Every size stored after the first write was noted until the next one started: 70 MB for a million.
        // T-765710f6
        @Test func notesOnlyWhatIsStoredUntilItEndsAndLetsGoOfWhatGoes() {
            let cache = FolderSizeCache()
            cache.store("/before", stats(1))
            cache.startRecording()
            for index in 0..<30 {
                cache.store("/f\(index)", stats(Int64(index)))
            }
            #expect(cache.recordedCount == 30)
            cache.delete("/f29")
            #expect(cache.recordedCount == 29)

            cache.stopRecording()
            cache.store("/after", stats(1))
            #expect(cache.recordedCount == 0)
            cache.forgetRecordedHolding(["/after/x"], atToo: false)
            #expect(cache.has("/after"))
        }
    }
}
