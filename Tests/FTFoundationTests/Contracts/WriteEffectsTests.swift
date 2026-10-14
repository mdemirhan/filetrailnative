// Port of packages/contracts/src/writeEffects.test.ts, checked against tools/parity/golden/write-effects.ts
import FTTestSupport
import Foundation
import Testing

@testable import FTFoundation

struct WriteEffectsTests {
    typealias Item = WriteEffectItem

    /// A small seeded generator, so a failure can be run again from its seed. (The original's has
    /// float rounding in its multiply that a port can't reproduce; this one wraps in 64 bits.)
    static func randomPaths(seed: Int, count: Int) -> [String] {
        var state = UInt64(seed)
        func next(_ limit: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(limit))
        }
        let names = ["a", "b", "ab", "a b", ".Trash", "\u{E9}"]
        return (0..<count).map { _ in
            var path = ""
            for _ in 0..<next(5) {
                path += "/\(names[next(names.count)])"
            }
            // Now and then the odd forms a path can be written in.
            let form = next(10)
            return path.isEmpty ? "/" : form == 0 ? "\(path)/" : form == 1 ? "/\(path)" : path
        }
    }

    static func changed(
        _ items: [(String?, String?)], target: String? = nil, directory: String? = nil, trashed: [String] = []
    )
        -> [String]
    {
        WriteEffects.pathsChangedByWrite(
            targetPath: target, destinationDirectoryPath: directory,
            items: items.map { (sourcePath: $0.0, destinationPath: $0.1) }, trashedPaths: trashed)
    }

    // MARK: pathsChangedByWrite

    // T-8699fb80 F-122
    @Test func listsTheFolderWrittenIntoAndEveryItemMovedMadeOrRemoved() {
        let paths = Self.changed(
            [("/Users/demo/a.txt", "/Users/demo/Dest/a.txt"), ("/Users/demo/Old", nil)],
            target: "/Users/demo/Dest")
        #expect(paths.sorted() == ["/Users/demo/Dest", "/Users/demo/Old", "/Users/demo/a.txt"])
    }

    // T-d0291da8 F-122
    @Test func listsWhereInTheTrashTheItemsAReplaceMovedOutOfTheWayWent() {
        let paths = Self.changed(
            [("/Users/demo/a.txt", "/Users/demo/Dest/a.txt")], directory: "/Users/demo/Dest",
            trashed: ["/Users/demo/.Trash/a.txt"])
        #expect(paths.sorted() == ["/Users/demo/.Trash/a.txt", "/Users/demo/Dest", "/Users/demo/a.txt"])
    }

    // T-f361383c F-122
    @Test func leavesOutAPathInsideAnotherWhichChangesNothingItCovers() {
        for seed in 1...200 {
            let all = Self.randomPaths(seed: seed, count: 1 + seed % 9)
            let changed = Self.changed(all.map { ($0, nil) })
            for path in changed {
                #expect(!changed.contains { $0 != path && WriteEffects.isAffectedByChange(path, changedPaths: [$0]) })
            }
            for path in Self.randomPaths(seed: seed * 7_919, count: 40) {
                #expect(
                    WriteEffects.isAffectedByChange(path, changedPaths: changed)
                        == WriteEffects.isAffectedByChange(path, changedPaths: all),
                    "seed \(seed), \(path) against \(all)")
            }
        }
    }

    // T-28acaf45 F-122
    @Test func keepsOnlyTheFolderOfACopyOfManyFiles() {
        var items: [(String?, String?)] = (0..<100_000).map {
            ("/Users/demo/Photos/\($0 % 100)/IMG_\($0).jpg", "/Volumes/Backup/Photos/\($0 % 100)/IMG_\($0).jpg")
        }
        items.append(("/Users/demo/Photos", "/Volumes/Backup/Photos"))
        let paths = Self.changed(items, directory: "/Volumes/Backup")
        #expect(paths.sorted() == ["/Users/demo/Photos", "/Volumes/Backup"])
    }

    @Test func skipsEmptyPathsAndKeepsFirstSeenOrder() {
        #expect(Self.changed([("", nil), (nil, "")], target: "") == [])
        #expect(Self.changed([("/b", "/a"), ("/a", "/b")]) == ["/b", "/a"])
    }

    // MARK: isAffectedByChange

    // T-831c2592 F-122
    @Test func coversTheItemWhatHoldsItAndWhatIsInsideIt() {
        let changed = ["/Users/demo/Projects/app"]
        #expect(WriteEffects.isAffectedByChange("/Users/demo/Projects/app", changedPaths: changed))
        #expect(WriteEffects.isAffectedByChange("/Users/demo/Projects", changedPaths: changed))
        #expect(WriteEffects.isAffectedByChange("/", changedPaths: changed))
        #expect(WriteEffects.isAffectedByChange("/Users/demo/Projects/app/src", changedPaths: changed))
    }

    // T-f9bd792e
    @Test func leavesFoldersBesideItAlone() {
        let changed = ["/Users/demo/Projects/app"]
        #expect(!WriteEffects.isAffectedByChange("/Users/demo/Projects/application", changedPaths: changed))
        #expect(!WriteEffects.isAffectedByChange("/Users/demo/Music", changedPaths: changed))
    }

    // MARK: ChangeMatcher

    /// A change somewhere inside the path, never the path itself.
    static func holdsAny(_ path: String, _ changed: [String]) -> Bool {
        let prefix = path.hasSuffix("/") ? path : "\(path)/"
        return changed.contains { $0 != path && $0.hasPrefix(prefix) }
    }

    static func isAtOrInsideAny(_ path: String, _ changed: [String]) -> Bool {
        changed.contains {
            let prefix = $0.hasSuffix("/") ? $0 : "\($0)/"
            return path == $0 || path.hasPrefix(prefix)
        }
    }

    // T-257b6c57
    @Test func answersAsAskingAboutEachChangeInTurnDoes() {
        for seed in 1...200 {
            let changed = Self.randomPaths(seed: seed, count: 1 + seed % 7)
            let matcher = ChangeMatcher(changedPaths: changed)
            for path in Self.randomPaths(seed: seed * 7_919, count: 40) {
                #expect(matcher.holdsChange(path) == Self.holdsAny(path, changed), "seed \(seed), \(path) holds")
                #expect(
                    matcher.isAtOrInsideChange(path) == Self.isAtOrInsideAny(path, changed),
                    "seed \(seed), \(path) at or inside")
                #expect(
                    matcher.isAffected(path) == WriteEffects.isAffectedByChange(path, changedPaths: changed),
                    "seed \(seed), \(path) affected")
            }
        }
    }

    // T-37d2531e F-122
    @Test func coversTheChangeWhatHoldsItAndWhatIsInsideItAndNothingBesideIt() {
        let matcher = ChangeMatcher(changedPaths: ["/Users/demo/Projects/app"])
        #expect(matcher.holdsChange("/Users/demo/Projects"))
        #expect(matcher.holdsChange("/"))
        #expect(!matcher.holdsChange("/Users/demo/Projects/app"))
        // Written with a "/" at the end, it still doesn't hold itself.
        #expect(!ChangeMatcher(changedPaths: ["/Users/demo/Projects/"]).holdsChange("/Users/demo/Projects/"))
        #expect(matcher.isAtOrInsideChange("/Users/demo/Projects/app"))
        #expect(matcher.isAtOrInsideChange("/Users/demo/Projects/app/src"))
        #expect(!matcher.isAffected("/Users/demo/Projects/application"))
        #expect(!matcher.isAffected("/Users/demo/Music"))
    }

    // T-9fedc531
    @Test func answersForManyPathsAgainstManyChangesQuickly() {
        let changed = (0..<5_000).map { "/Users/demo/Projects/p\($0 % 50)/src/file\($0).ts" }
        let cached = (0..<50_000).map { "/Users/demo/Library/Caches/c\($0 % 500)/d\($0)/e" }
        // CPU time of this thread, not wall time, so a busy machine does not fail it.
        let (affected, seconds) = CPUTime.measureThread {
            let matcher = ChangeMatcher(changedPaths: changed)
            return cached.filter { matcher.isAffected($0) }
        }
        // Well under 100 ms on a laptop; the bound only catches going back to every pair.
        #expect(seconds < 2)
        #expect(affected.isEmpty)
    }

    // MARK: itemsForOtherWindows

    static func item(_ source: String?, _ destination: String?, _ status: String = "completed") -> Item {
        Item(sourcePath: source, destinationPath: destination, status: status)
    }

    // T-754ce4b0 F-122
    @Test func leavesOutAnItemInAFolderAlreadyKnownToHoldWhatChanged() {
        let items = [
            Self.item("/a/F", "/b/F"), Self.item("/a/F/x", "/b/F/x"), Self.item("/a/F/y", "/b/F/y"),
            Self.item("/a/F/z", nil),
        ]
        #expect(
            WriteEffects.itemsForOtherWindows(action: "paste", targetPath: "/b", items: items) == Array(items[0..<2]))
    }

    // T-5ab80483
    @Test func takesAChangeWrittenWithATrailingSlashAsHoldingWhatIsInsideIt() {
        let items = [Self.item("/b/x", nil), Self.item("/b/y", nil)]
        #expect(WriteEffects.itemsForOtherWindows(action: "trash", targetPath: "/b/", items: items) == [])
    }

    // T-f59648a8 F-122
    @Test func keepsAnItemATabWouldFollowOnItsOwn() {
        let items = [Self.item("/a/F", "/b/F", "failed"), Self.item("/a/F/x", "/b/F/x")]
        #expect(WriteEffects.itemsForOtherWindows(action: "move_to", items: items) == items)
        #expect(WriteEffects.isFollowedMove(items[0], action: "batch_rename"))
        #expect(!WriteEffects.isFollowedMove(Self.item("/a", "/a"), action: "rename"))
    }

    // T-6c6a5043
    @Test func goesByTheNamesAloneForPathsThatArentAbsolute() {
        let items = [Self.item("x", nil), Self.item("x", nil), Self.item("y", "")]
        let kept = WriteEffects.itemsForOtherWindows(action: "trash", items: items)
        #expect(kept == [items[0], items[2]])
    }

    // MARK: Golden

    struct GoldenItem: Codable, Sendable {
        let sourcePath: String?
        let destinationPath: String?
        let status: String?
    }

    struct GoldenInput: Codable, Sendable {
        let fn: String
        let targetPath: String?
        let destinationDirectoryPath: String?
        let items: [GoldenItem]?
        let trashedPaths: [String]?
        let path: String?
        let changed: [String]?
        let action: String?
        let item: GoldenItem?
    }

    struct GoldenOutput: Codable, Equatable, Sendable {
        var paths: [String]?
        var value: Bool?
        var matcher: [Bool]?
        var indices: [Int]?
    }

    static func effectItem(_ item: GoldenItem) -> Item {
        Item(sourcePath: item.sourcePath, destinationPath: item.destinationPath, status: item.status ?? "completed")
    }

    /// An item that remembers its place, since equal items are told apart in the golden by identity.
    struct Indexed: WrittenItem {
        let index: Int
        let item: Item
        var sourcePath: String? { item.sourcePath }
        var destinationPath: String? { item.destinationPath }
        var status: String { item.status }
    }

    static func run(_ input: GoldenInput) -> GoldenOutput {
        var output = GoldenOutput()
        switch input.fn {
        case "pathsChangedByWrite":
            output.paths = WriteEffects.pathsChangedByWrite(
                targetPath: input.targetPath, destinationDirectoryPath: input.destinationDirectoryPath,
                items: (input.items ?? []).map { (sourcePath: $0.sourcePath, destinationPath: $0.destinationPath) },
                trashedPaths: input.trashedPaths ?? [])
        case "isAffectedByChange":
            output.value = WriteEffects.isAffectedByChange(input.path ?? "", changedPaths: input.changed ?? [])
        case "changeMatcher":
            let matcher = ChangeMatcher(changedPaths: input.changed ?? [])
            let path = input.path ?? ""
            output.matcher = [matcher.holdsChange(path), matcher.isAtOrInsideChange(path), matcher.isAffected(path)]
        case "isFollowedMove":
            output.value = input.item.map { WriteEffects.isFollowedMove(effectItem($0), action: input.action ?? "") }
        case "itemsForOtherWindows":
            let items = (input.items ?? []).enumerated().map { Indexed(index: $0.offset, item: effectItem($0.element)) }
            let kept = WriteEffects.itemsForOtherWindows(
                action: input.action ?? "", targetPath: input.targetPath, items: items
            ).map(\.index)
            output.indices = kept
        default:
            Issue.record("unknown golden function \(input.fn)")
        }
        return output
    }

    @Test func effectsMatchTheReference() throws {
        let cases: [GoldenCase<GoldenInput, GoldenOutput>] = try Golden.load(suite: "write-effects")
        #expect(cases.count >= 200)
        Golden.expectMatches(cases) { Self.run($0) }
    }
}
