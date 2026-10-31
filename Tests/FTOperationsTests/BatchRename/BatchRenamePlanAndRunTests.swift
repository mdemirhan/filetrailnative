// Port of the run half of apps/desktop/src/main/bootstrap/batchRenamePlanAndRun.test.ts (the plan half is in
// FTFoundationTests/BatchRename/BatchRenameTests.swift)
import FTFoundation
import Foundation
import Testing

@testable import FTOperations

// The sheet's preview and the rename must agree: the plan the window shows is turned into a request as the window
// does (`BatchRenameRequest(plan:items:settings:)`), and the rename, on a disk holding the same names, gives every
// item the name the plan gave it, with no number added on the way.

private let format = BatchRenameSettings(mode: .format)
private let now = "2026-10-04T11:32:10"

private struct PlannedRun {
    var plan: BatchRenamePlan
    var request: BatchRenameRequest?
    var inos: [Int?]
    /// The items the rename didn't complete; none when the plan was kept.
    var notCompleted: [WriteOperationItem]
}

/// Plans the items with these settings against the disk, as the sheet does, and renames as the coordinator would.
private func planAndRename(_ disk: MemoryDisk, _ paths: [String], _ settings: BatchRenameSettings) -> PlannedRun {
    let items = paths.map {
        BatchRenameItem(
            path: $0, name: NodePath.basename($0), isFolder: false, createdAt: "2026-09-30T10:12:40",
            modifiedAt: "2026-10-01T08:30:15", takenAt: nil)
    }
    var folders: [String: BatchRenameFolder] = [:]
    for path in paths {
        let folder = BatchRename.parentPath(of: path)
        folders[folder] = BatchRenameFolder(names: disk.names(folder), caseSensitive: disk.caseSensitive)
    }
    let plan = BatchRename.planBatchRename(
        BatchRenamePlanInput(settings: settings, items: items, folders: folders, now: now))
    let request = BatchRenameRequest(plan: plan, items: items, settings: settings)
    let inos = paths.map { disk.inoOf($0) }
    var notCompleted: [WriteOperationItem] = []
    if let request {
        var temporary = 0
        let run = BatchRenameExecution.run(
            request, fileSystem: disk, signal: StopSignal(),
            temporaryName: {
                defer { temporary += 1 }
                return ".tmp-\(temporary)"
            })
        notCompleted = run.items.filter { $0.status != .completed }
    }
    return PlannedRun(plan: plan, request: request, inos: inos, notCompleted: notCompleted)
}

/// Where each item is, and where the plan said it would be: its new name, or its old one.
private func placesAfter(_ disk: MemoryDisk, _ paths: [String], _ result: PlannedRun) -> [(
    planned: String, actual: String?
)] {
    paths.enumerated().map { index, path in
        var name = NodePath.basename(path)
        if index < result.plan.items.count, case .rename(let planned, _, _, _, _, _) = result.plan.items[index] {
            name = planned
        }
        return ("\(BatchRename.parentPath(of: path))/\(name)", result.inos[index].flatMap(disk.pathOf))
    }
}

private func planKept(_ disk: MemoryDisk, _ paths: [String], _ result: PlannedRun) -> Bool {
    result.notCompleted.isEmpty
        && placesAfter(disk, paths, result).allSatisfy { place in
            place.actual.map { $0.unicodeScalars.elementsEqual(place.planned.unicodeScalars) } == true
        }
}

private func addedNumber(_ planItem: BatchRenamePlanItem) -> Int? {
    if case .rename(_, _, let added, _, _, _) = planItem { added } else { nil }
}

@Suite struct BatchRenamePlanAndRunTests {
    // T-a966a460 F-119
    @Test func numberATakenNameAlikeWhenFormatHasNoSeparator() {
        let disk = MemoryDisk(["/trip/IMG_a.jpg", "/trip/IMG_b.jpg", "/trip/File1.jpg"])
        let paths = ["/trip/IMG_a.jpg", "/trip/IMG_b.jpg"]
        var settings = format
        settings.separator = .none
        let result = planAndRename(disk, paths, settings)
        // "File1.jpg" is taken outside the batch: the plan adds a number with a space.
        #expect(result.request?.items.map(\.destinationName) == ["File1 2.jpg", "File2.jpg"])
        #expect(result.request?.numberSeparator == " ")
        #expect(planKept(disk, paths, result))
        #expect(disk.names() == ["File1 2.jpg", "File1.jpg", "File2.jpg"])
    }

    // T-5fb53308 F-119
    @Test func numberATakenNameAlikeWithFormatsSeparator() {
        let disk = MemoryDisk(["/trip/a.jpg", "/trip/b.jpg", "/trip/File_1.jpg"])
        let paths = ["/trip/a.jpg", "/trip/b.jpg"]
        var settings = format
        settings.separator = .underscore
        let result = planAndRename(disk, paths, settings)
        #expect(result.request?.items.map(\.destinationName) == ["File_1_2.jpg", "File_2.jpg"])
        #expect(planKept(disk, paths, result))
    }

    // T-2c22d4ff F-119
    @Test func swapTwoNamesAndPassNamesAlongAChainWithoutNumbers() {
        let swap = MemoryDisk(["/trip/File 1.jpg", "/trip/File 2.jpg"])
        // Listed in reverse: the second becomes "File 1" and the first "File 2".
        let swapPaths = ["/trip/File 2.jpg", "/trip/File 1.jpg"]
        let swapped = planAndRename(swap, swapPaths, format)
        #expect(swapped.plan.items.map(addedNumber) == [nil, nil])
        #expect(planKept(swap, swapPaths, swapped))

        let chain = MemoryDisk(["/trip/File 1.jpg", "/trip/File 2.jpg", "/trip/File 3.jpg"])
        let chainPaths = ["/trip/File 1.jpg", "/trip/File 2.jpg", "/trip/File 3.jpg"]
        var settings = format
        settings.startAt = 2
        let passed = planAndRename(chain, chainPaths, settings)
        #expect(planKept(chain, chainPaths, passed))
        #expect(chain.names() == ["File 2.jpg", "File 3.jpg", "File 4.jpg"])
    }

    // T-bfffc022 F-119
    @Test func giveItemsInSeveralFoldersTheNamesPlannedForEachFolder() {
        let disk = MemoryDisk([
            "/trip/a.jpg", "/trip/b.jpg", "/trip/File 3.jpg", "/home/c.jpg", "/home/File 1.jpg", "/home/File 2.jpg",
        ])
        // Numbered across the folders in the order given; each folder settles its own clashes.
        let paths = ["/trip/a.jpg", "/home/c.jpg", "/trip/b.jpg", "/home/File 1.jpg"]
        let result = planAndRename(disk, paths, format)
        #expect(
            result.request?.items.map(\.destinationName) == [
                "File 1.jpg", "File 2 2.jpg", "File 3 2.jpg", "File 4.jpg",
            ])
        #expect(planKept(disk, paths, result))
        #expect(disk.names("/home") == ["File 2 2.jpg", "File 2.jpg", "File 4.jpg"])
    }

    // T-661d40ce F-119
    @Test func changeOnlyTheCaseOfANameInPlaceAndNumberItOnADiskThatMindsCase() {
        let lower = BatchRenameSettings(mode: .changeCase, caseStyle: .lower)
        let insensitive = MemoryDisk(["/trip/Notes.txt", "/trip/Todo.txt"])
        let paths = ["/trip/Notes.txt", "/trip/Todo.txt"]
        let lowered = planAndRename(insensitive, paths, lower)
        #expect(planKept(insensitive, paths, lowered))
        #expect(insensitive.names() == ["notes.txt", "todo.txt"])

        let sensitive = MemoryDisk(["/trip/Notes.txt", "/trip/notes.txt", "/trip/Todo.txt"], caseSensitive: true)
        let numbered = planAndRename(sensitive, paths, lower)
        #expect(numbered.request?.items.map(\.destinationName) == ["notes 2.txt", "todo.txt"])
        #expect(planKept(sensitive, paths, numbered))
    }

    // T-669eb707 F-119
    @Test func treatANameWithItsAccentsTypedAnotherWayAsTakenAsTheDiskDoes() {
        let nfd = "Re\u{301}sume\u{301}"
        let disk = MemoryDisk(["/trip/a.txt", "/trip/b.txt", "/trip/R\u{E9}sum\u{E9}.txt"])
        let paths = ["/trip/a.txt", "/trip/b.txt"]
        let result = planAndRename(disk, paths, BatchRenameSettings(find: "^[ab]$", replaceWith: nfd, useRegex: true))
        #expect(
            result.request?.items.map { Array($0.destinationName.unicodeScalars) } == [
                Array("\(nfd) 2.txt".unicodeScalars), Array("\(nfd) 3.txt".unicodeScalars),
            ])
        #expect(planKept(disk, paths, result))
    }

    // T-988f1c26 F-119
    @Test func leaveTheItemsSkipLeavesAndGiveTheRestTheirPlannedNames() {
        let disk = MemoryDisk(["/trip/a.jpg", "/trip/b.jpg", "/trip/c.jpg", "/trip/File 2.jpg"])
        let paths = ["/trip/a.jpg", "/trip/b.jpg", "/trip/c.jpg"]
        var settings = format
        settings.onConflict = .skip
        let result = planAndRename(disk, paths, settings)
        #expect(result.plan.skippedCount == 1)
        #expect(result.request?.items.map(\.sourcePath) == ["/trip/a.jpg", "/trip/c.jpg"])
        #expect(planKept(disk, paths, result))
        #expect(disk.names() == ["File 1.jpg", "File 2.jpg", "File 3.jpg", "b.jpg"])
    }

    // "File 1 2.jpg" asks for "File 1.jpg", which is taken, and would be numbered " 2": its own name. Asked for, the
    // rename would find that name taken by the item itself and make it "File 1 2 2.jpg".
    // T-20addbaa F-119
    @Test func leaveAnItemAloneWhenTheNumberedNameItGetsIsTheOneItHas() {
        let disk = MemoryDisk(["/trip/File 1.jpg", "/trip/File 1 2.jpg", "/trip/a.jpg"])
        let paths = ["/trip/File 1 2.jpg", "/trip/a.jpg"]
        var settings = format
        settings.startAt = 1
        let result = planAndRename(disk, paths, settings)
        #expect(disk.names() == ["File 1 2.jpg", "File 1.jpg", "File 2.jpg"])
        #expect(planKept(disk, paths, result))
    }

    // T-107fe08c F-119
    @Test func agreeAtRandomForNamesThatClashInEveryWay() {
        let names = [
            "a.jpg", "A.jpg", "b.jpg", "File 1.jpg", "File 2.jpg", "File 3.jpg", "File1.jpg", "File-1.jpg",
            "File_2.jpg", "file 1.JPG", "File 1 2.jpg", "R\u{E9}sum\u{E9}.jpg", "notes", "Notes.txt",
        ]
        var renamed = 0
        var disagreements: [String] = []
        for seed in 1...60 {
            var rng = Mulberry32(seed: UInt32(seed))
            let caseSensitive = rng.chance(0.25)
            func key(_ name: String) -> [UInt8] {
                let normalized = name.decomposedStringWithCanonicalMapping
                return Array((caseSensitive ? normalized : normalized.lowercased(with: nil)).utf8)
            }
            var onDisk: [String] = []
            var keys: [[UInt8]] = []
            for name in rng.shuffle(names).prefix(rng.integer(2, 8)) {
                if let at = keys.firstIndex(of: key(name)) {
                    onDisk[at] = name
                } else {
                    keys.append(key(name))
                    onDisk.append(name)
                }
            }
            let disk = MemoryDisk(onDisk.map { "/trip/\($0)" }, caseSensitive: caseSensitive)
            let paths = rng.shuffle(onDisk).prefix(rng.integer(1, onDisk.count)).map { "/trip/\($0)" }
            // Every choice is drawn before one is picked, as the original's array of them is.
            var separated = format
            separated.separator = rng.pick([.space, .hyphen, .underscore, .none])
            let counted = BatchRenameSettings(
                mode: .format, nameFormat: .counter, startAt: rng.integer(0, 3), digits: .auto)
            let cased = BatchRenameSettings(mode: .changeCase, caseStyle: rng.pick([.lower, .upper, .title]))
            let find = rng.pick(["a", "1", "File", " "])
            let replaced = BatchRenameSettings(find: find, replaceWith: rng.pick(["", "File", "2", "A"]))
            let added = BatchRenameSettings(mode: .add, addText: rng.pick([" 1", "1", " 2"]))
            var settings = rng.pick([separated, counted, cased, replaced, added])
            settings.onConflict = rng.pick([.number, .skip])
            let result = planAndRename(disk, paths, settings)
            renamed += result.request == nil ? 0 : 1
            if !planKept(disk, paths, result) {
                disagreements.append("seed \(seed): \(placesAfter(disk, paths, result)) \(result.notCompleted)")
            }
        }
        #expect(disagreements.isEmpty, Comment(rawValue: disagreements.joined(separator: "\n")))
        // Most cases rename something: the agreement isn't checked on nothing.
        #expect(renamed > 40)
    }
}
