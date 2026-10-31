// Port of apps/desktop/src/main/bootstrap/batchRenameExecution.fuzz.test.ts
import FTFoundation
import Foundation
import Testing

@testable import FTOperations

// Random folders and random renames, with random failures and stops: whatever happens, no item is lost or replaced,
// and every result says where its item really is. The cases come from seeds 1 to 400, as the original's do.
private let firstSeed = 1
private let cases = 400

private let nfcE = "\u{E9}"
private let nfdE = "e\u{301}"
// Few names, so they clash often: case variants, accents typed both ways, numbered names, and the temporary names the
// rename itself uses.
private let fuzzNames = [
    "a", "b", "c", "A", "B", "x.txt", "X.TXT", "File 1", "File 2", "File 3", "File 1.jpg", "File 2.jpg", "File-2.jpg",
    "notes", "Notes", nfcE, nfdE, "Caf\(nfcE)", "Caf\(nfdE)", "CAF\(nfcE.uppercased())", ".tmp-0", ".tmp-2",
]
private let codes = ["EACCES", "EIO", "ENOENT", "EEXIST"]
private let onConflicts: [BatchRenameOnConflict] = [.number, .skip, .block]
private let separators = [" ", "-", "_"]

private struct FuzzCase {
    var disk: MemoryDisk
    var request: BatchRenameRequest
    /// Stop as the item with this many done starts, or after this many renames.
    var stopAtItemStart: Int?
    var stopAfterMoves: Int?
    var failureRate: Double
    /// Where the failures come from: the same ones for the same case.
    var failureSeed: Int
}

private func same(_ left: String, _ right: String) -> Bool {
    left.unicodeScalars.elementsEqual(right.unicodeScalars)
}

private func makeCase(_ rng: inout Mulberry32, nested: Bool) -> FuzzCase {
    let caseSensitive = rng.chance(0.25)
    let disk = MemoryDisk([], caseSensitive: caseSensitive)
    func key(_ name: String) -> [UInt8] {
        let normalized = name.decomposedStringWithCanonicalMapping
        return Array((caseSensitive ? normalized : normalized.lowercased(with: nil)).utf8)
    }
    // Names unique as the disk compares them.
    func someNames(_ count: Int) -> [String] {
        var chosen: [String] = []
        var keys = Set<[UInt8]>()
        for name in rng.shuffle(fuzzNames) {
            if chosen.count == count { break }
            if keys.insert(key(name)).inserted {
                chosen.append(name)
            }
        }
        return chosen
    }

    let folders = rng.chance(0.4) ? ["/trip", "/home"] : ["/trip"]
    var children: [(path: String, names: [String])] = []
    for folder in folders {
        disk.add(folder)
        let names = someNames(rng.integer(2, 6))
        children.append((folder, names))
        for name in names {
            let path = "\(folder)/\(name)"
            disk.add(path)
            if nested && rng.chance(0.35) {
                let inside = someNames(rng.integer(1, 3))
                children.append((path, inside))
                for child in inside {
                    disk.add("\(path)/\(child)")
                }
            }
        }
    }
    let parents = Set(children.map { Array($0.path.utf8) })

    // Each folder's items to rename, and the names they ask for.
    var items: [BatchRenameRequest.Item] = []
    for (folder, names) in children {
        let chosen = names.filter { _ in rng.chance(0.6) }
        if chosen.isEmpty { continue }
        var destinations: [String] = []
        if chosen.count > 1 && rng.chance(0.3) {
            // A cycle (a swap, for two): each takes the next one's name.
            destinations = chosen.indices.map { chosen[($0 + 1) % chosen.count] }
        } else {
            destinations = chosen.map { destinationFor(&rng, $0, names) }
        }
        for (name, destinationName) in zip(chosen, destinations) {
            // The plan never asks for an item's own name.
            if same(destinationName, name) { continue }
            let sourcePath = "\(folder)/\(name)"
            items.append(
                .init(
                    sourcePath: sourcePath, destinationName: destinationName,
                    isFolder: parents.contains(Array(sourcePath.utf8))))
        }
    }
    if items.isEmpty {
        let name = children.first { $0.path == "/trip" }?.names.first ?? "a"
        items.append(.init(sourcePath: "/trip/\(name)", destinationName: "\(name) new", isFolder: false))
    }

    let stop = rng.next()
    let shuffled = rng.shuffle(items)
    let onConflict = rng.pick(onConflicts)
    let separator = rng.pick(separators)
    let stopAtItemStart = stop < 0.25 ? rng.integer(0, items.count) : nil
    let stopAfterMoves = stop >= 0.25 && stop < 0.4 ? rng.integer(0, items.count * 2) : nil
    let failureRate = rng.pick([0, 0, 0.1, 0.3])
    let failureSeed = rng.integer(1, 1 << 31)
    return FuzzCase(
        disk: disk, request: BatchRenameRequest(items: shuffled, onConflict: onConflict, numberSeparator: separator),
        stopAtItemStart: stopAtItemStart, stopAfterMoves: stopAfterMoves, failureRate: failureRate,
        failureSeed: failureSeed)
}

private func destinationFor(_ rng: inout Mulberry32, _ name: String, _ neighbours: [String]) -> String {
    let roll = rng.next()
    if roll < 0.25 {
        // A name another item in the folder has: a chain, or a name taken.
        return rng.pick(neighbours)
    }
    if roll < 0.4 {
        // Only the case changes.
        let flipped = same(name, name.lowercased()) ? name.uppercased() : name.lowercased()
        return same(flipped, name) ? "\(name)x" : flipped
    }
    if roll < 0.5 {
        // Only how the accents are typed changes.
        let isNFC = same(name, name.precomposedStringWithCanonicalMapping)
        let other = isNFC ? name.decomposedStringWithCanonicalMapping : name.precomposedStringWithCanonicalMapping
        return same(other, name) ? rng.pick(fuzzNames) : other
    }
    if roll < 0.6 {
        // A name the rename would number to.
        return "\(name)\(rng.pick(separators))2"
    }
    return rng.pick(fuzzNames)
}

private func runCase(_ fuzz: FuzzCase) -> BatchRenameRun {
    var failures = Mulberry32(seed: UInt32(truncatingIfNeeded: fuzz.failureSeed))
    let signal = StopSignal()
    let disk = fuzz.disk
    disk.failWith = { _ in
        fuzz.failureRate > 0 && failures.chance(fuzz.failureRate) ? errno(failures.pick(codes)) : nil
    }
    var moves = 0
    disk.afterMove = { _ in
        moves += 1
        if moves == fuzz.stopAfterMoves { signal.stop() }
    }
    var temporary = 0
    return BatchRenameExecution.run(
        fuzz.request, fileSystem: disk, signal: signal,
        onItemStart: { _, _, completed in if completed == fuzz.stopAtItemStart { signal.stop() } },
        temporaryName: {
            defer { temporary += 1 }
            return ".tmp-\(temporary)"
        })
}

private struct Before {
    var inos: [Int]
    var pathByIno: [Int: String]
    var sourceInos: [Int?]
}

private func snapshot(_ fuzz: FuzzCase) -> Before {
    let entries = fuzz.disk.entries()
    return Before(
        inos: entries.map(\.ino).sorted(), pathByIno: Dictionary(entries.map { ($0.ino, $0.path) }) { _, last in last },
        sourceInos: fuzz.request.items.map { fuzz.disk.inoOf($0.sourcePath) })
}

/// What is wrong after a run, as sentences; none when all is well. Each result's path must be exactly where its item
/// is, even when a folder it is in changed its name.
private func problems(_ fuzz: FuzzCase, _ before: Before, _ run: BatchRenameRun) -> [String] {
    let disk = fuzz.disk
    let after = disk.entries()
    var found: [String] = []
    let inos = after.map(\.ino).sorted()
    if inos != before.inos {
        found.append("items lost or replaced: \(before.inos) became \(inos)")
    }
    let order = run.items.map { $0.sourcePath ?? "" }
    if !zip(order, fuzz.request.items.map(\.sourcePath)).allSatisfy(same) || order.count != fuzz.request.items.count {
        found.append("results out of the order asked for: \(order)")
    }
    let completed = run.items.filter { $0.status == .completed }.count
    if run.completedItemCount != completed {
        found.append("completedItemCount \(run.completedItemCount), but \(completed) completed")
    }
    if run.items.contains(where: { $0.status == .cancelled }) && !run.cancelled {
        found.append("an item was cancelled, but the run says it wasn't")
    }
    for (index, result) in run.items.enumerated() {
        guard let ino = before.sourceInos[index] else { continue }
        let now = disk.pathOf(ino)
        let said = result.destinationPath ?? result.sourcePath ?? ""
        if result.status == .completed && result.destinationPath == nil {
            found.append("\(result.sourcePath ?? "") completed without a new path")
        }
        if now.map({ same($0, said) }) != true {
            found.append("\(result) is really at \(now ?? "nowhere")")
        }
    }
    // A temporary name is left only where a result says its item is. (An item named so before the rename, and not
    // renamed, may be anywhere its folder went.)
    var reportedByIno: [Int: String?] = [:]
    for (index, item) in run.items.enumerated() {
        if let ino = before.sourceInos[index] {
            reportedByIno[ino] = item.destinationPath
        }
    }
    for entry in after {
        let renamed = !same(NodePath.basename(before.pathByIno[entry.ino] ?? ""), NodePath.basename(entry.path))
        if !renamed || !NodePath.basename(entry.path).hasPrefix(".tmp-") {
            continue
        }
        let reported = reportedByIno[entry.ino] ?? nil
        if reported.map({ same($0, entry.path) }) != true {
            found.append("left under a temporary name, unreported: \(entry.path)")
        }
    }
    return found
}

private func fuzz(nested: Bool) -> (failure: String?, outcomes: Set<String>) {
    // What the cases came to, so a change to them that stops reaching an outcome is noticed.
    var outcomes = Set<String>()
    for seed in firstSeed..<(firstSeed + cases) {
        var rng = Mulberry32(seed: UInt32(seed))
        let fuzzCase = makeCase(&rng, nested: nested)
        let before = snapshot(fuzzCase)
        let run = runCase(fuzzCase)
        let found = problems(fuzzCase, before, run)
        if !found.isEmpty {
            let calls = fuzzCase.disk.calls.filter { !$0.hasPrefix("lstat") }.joined(separator: ", ")
            return (
                (["Seed \(seed) failed.", "Disk before: \(Array(before.pathByIno.values))", "Calls: \(calls)"] + found)
                    .joined(separator: "\n"), outcomes
            )
        }
        for result in run.items {
            outcomes.insert(result.status.rawValue)
            if result.status == .failed, let destinationPath = result.destinationPath {
                let hidden = NodePath.basename(destinationPath).hasPrefix(".tmp-")
                outcomes.insert(hidden ? "left hidden" : "put back with a number")
            }
        }
        if fuzzCase.disk.calls.contains(where: { $0.hasPrefix("rename:") }) {
            outcomes.insert("case changed in place")
        }
    }
    return (nil, outcomes)
}

private let everyOutcome: Set<String> = [
    "cancelled", "case changed in place", "completed", "failed", "left hidden", "put back with a number", "skipped",
]

@Suite struct BatchRenameFuzzTests {
    // T-ab6035f3 F-568
    @Test func neverLosesAnItemAndSaysWhereEachOneIsForItemsInFoldersSideBySide() {
        let (failure, outcomes) = fuzz(nested: false)
        #expect(failure == nil, Comment(rawValue: failure ?? ""))
        #expect(outcomes == everyOutcome)
    }

    // T-0a6d6bd4 F-568
    @Test func neverLosesAnItemAndSaysWhereEachOneIsWhenFoldersAreRenamedWithItemsInsideThem() {
        let (failure, outcomes) = fuzz(nested: true)
        #expect(failure == nil, Comment(rawValue: failure ?? ""))
        #expect(outcomes == everyOutcome)
    }

    // A folder that can't take its new name and is put back under another one takes the paths of the items inside it
    // along, as a renamed folder does: "/trip/sub/y" is now inside "a", the item that took the folder's name.
    // T-61ab1c72 F-397 F-568
    @Test func saysWhereAnItemIsWhenItsFolderWasPutBackUnderANumberedName() throws {
        let disk = MemoryDisk(["/trip/a", "/trip/sub", "/trip/sub/x", "/trip/c"])
        let xIno = try #require(disk.inoOf("/trip/sub/x"))
        let result = BatchRenameExecution.run(
            BatchRenameRequest(
                items: [
                    .init(sourcePath: "/trip/a", destinationName: "sub", isFolder: false),
                    .init(sourcePath: "/trip/sub", destinationName: "c", isFolder: true),
                    .init(sourcePath: "/trip/sub/x", destinationName: "y", isFolder: false),
                ], onConflict: .skip, numberSeparator: " "),
            fileSystem: disk, signal: StopSignal(), temporaryName: { ".tmp-0" })
        // "sub" moved aside for "a", couldn't become "c" (taken), and went back as "sub 2".
        #expect(result.items[1].status == .failed)
        #expect(result.items[1].destinationPath == "/trip/sub 2")
        #expect(disk.pathOf(xIno) == "/trip/sub 2/y")
        #expect(result.items[2].status == .completed)
        #expect(result.items[2].destinationPath == "/trip/sub 2/y")
    }
}
