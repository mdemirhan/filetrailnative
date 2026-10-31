// Port of the Trash cases of apps/desktop/src/renderer/hooks/useFolderSizeCache.test.tsx: what a write that touches the
// Trash forgets and asks about again, over a stand-in for the folder size jobs
import FTFileSystem
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

@MainActor
struct WindowFolderSizesTrashTests {
    private let jobs = FakeJobs()
    private let timers = ManualTimers()

    private func sizes(home: String = "/Users/demo") -> WindowFolderSizes {
        WindowFolderSizes(backend: jobs, owner: 1, homePath: home, scheduler: timers) { [timers] in timers.time }
    }

    /// Everything of `known` cached and ready, and the questions so far forgotten.
    private func cached(_ sizes: WindowFolderSizes, _ known: [String: Int64]) async {
        jobs.known = known
        for path in known.keys { _ = sizes.entry(path) }
        await settle()
        for path in known.keys { #expect(sizes.readySize(path) == known[path]) }
        jobs.probes = []
    }

    private var asked: Set<String> { Set(jobs.probes.flatMap { $0 }) }

    // T-78dcb4c4 B-INFO-149: a move to the Trash asks again about the Trash and what holds it, and the folder it left;
    // what it moved is forgotten and an unrelated folder not asked about. A home folder with trailing slashes is the
    // same place.
    @Test(arguments: ["/Users/demo", "/Users/demo//"])
    func aMoveToTheTrashAsksAgainAboutTheTrash(_ home: String) async {
        let sizes = sizes(home: home)
        await cached(
            sizes,
            [
                "/Users/demo/.Trash": 10, "/Users/demo": 20, "/opt/tools": 30, "/opt/tools/old": 5,
                "/Users/demo/Music": 7,
            ])
        sizes.forgetChangedSizes(["/opt/tools/old"], intoTrash: true)
        await settle()
        #expect(asked == ["/Users/demo/.Trash", "/Users/demo", "/opt/tools"])
        #expect(sizes.cachedEntry("/opt/tools/old") == nil)
        #expect(sizes.readySize("/Users/demo/Music") == 7)
    }

    // B-INFO-149: other operations don't treat the Trash as changed on their own.
    @Test func anotherWriteLeavesTheTrashAlone() async {
        let sizes = sizes()
        await cached(sizes, ["/Users/demo/.Trash": 10, "/opt/tools": 30, "/opt/tools/old": 5])
        sizes.forgetChangedSizes(["/opt/tools/old"], intoTrash: false)
        await settle()
        #expect(asked == ["/opt/tools"])
    }

    // T-5c5478a3: a Replace moved what it replaced to the Trash: named among what changed, the Trash is asked about.
    @Test func aReplaceAsksAgainAboutTheTrashItMovedItemsTo() async {
        let sizes = sizes()
        await cached(sizes, ["/Users/demo/.Trash": 10, "/Users/demo/Music": 7])
        sizes.forgetChangedSizes(["/Users/demo/.Trash/old.txt"], intoTrash: false)
        await settle()
        #expect(asked.contains("/Users/demo/.Trash"))
        #expect(!asked.contains("/Users/demo/Music"))
    }

    // T-52a59b70: a drag to the Trash from another window: the jobs forgot the holders and the Trash too, so they read
    // as unknown; the rest keeps its size.
    @Test func aDragToTheTrashForgetsWhatTheJobsForgot() async {
        let sizes = sizes()
        await cached(
            sizes, ["/Users/demo/.Trash": 10, "/Users/demo/Docs": 20, "/Users/demo/Docs/a": 5, "/Users/demo/Music": 7])
        jobs.known = ["/Users/demo/Music": 7]
        sizes.forgetChangedSizes(["/Users/demo/Docs/a"], intoTrash: true)
        await settle()
        #expect(sizes.readySize("/Users/demo/Docs") == nil)
        #expect(sizes.readySize("/Users/demo/.Trash") == nil)
        #expect(sizes.cachedEntry("/Users/demo/Docs/a") == nil)
        #expect(sizes.readySize("/Users/demo/Music") == 7)
    }

    // T-0124f0b4 B-INFO-151: the Trash emptied: it and what holds it are asked again, what was in it forgotten unasked.
    @Test func theTrashEmptiedAsksAboutItAndForgetsWhatWasInIt() async {
        let sizes = sizes()
        await cached(
            sizes, ["/Users/demo/.Trash": 10, "/Users/demo/.Trash/old": 4, "/Users/demo": 20, "/Users/demo/Music": 7])
        jobs.known = ["/Users/demo/.Trash": 0, "/Users/demo": 16]
        sizes.forgetChangedSizes(["/Users/demo/.Trash"], intoTrash: true)
        await settle()
        #expect(asked == ["/Users/demo/.Trash", "/Users/demo"])
        #expect(sizes.readySize("/Users/demo/.Trash") == 0)
        #expect(sizes.readySize("/Users/demo") == 16)
        #expect(sizes.cachedEntry("/Users/demo/.Trash/old") == nil)
    }
}
