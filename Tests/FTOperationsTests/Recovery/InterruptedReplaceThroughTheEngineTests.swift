import FTTestSupport
import Foundation
import Testing

@testable import FTOperations

/// A real Replace on the disk, killed right after each write of the journal in turn, and the app's startup recovery
/// run on what it left: whatever the stage, neither the pasted item nor the one it replaces is lost, no copy under a
/// hidden name is left, and the journal ends empty. Copies and moves, of a file and of a folder, on one disk (the
/// recordings of exec-crash add a move to another disk).
struct InterruptedReplaceThroughTheEngineTests {
    enum Shape: String, CaseIterable, Sendable {
        case copyFile, moveFile, copyFolder, moveFolder

        var mode: String { self == .copyFile || self == .copyFolder ? "copy" : "cut" }
        var isFolder: Bool { self == .copyFolder || self == .moveFolder }

        /// The new item at source, the old one at destination; a folder's file is what is compared.
        var tree: [ExecScenario.Item] {
            isFolder
                ? [
                    .init(path: "source/f/a.txt", kind: "file", content: "new a\n"),
                    .init(path: "source/f/sub/b.txt", kind: "file", content: "new b\n"),
                    .init(path: "destination/f/a.txt", kind: "file", content: "old a\n"),
                ]
                : [
                    .init(path: "source/a.txt", kind: "file", content: "new a\n"),
                    .init(path: "destination/a.txt", kind: "file", content: "old a\n"),
                ]
        }

        var name: String { isFolder ? "f" : "a.txt" }
        var isMove: Bool { mode == "cut" }
    }

    private struct Run {
        var crashed: Bool
        var before: [TreeSnapshot.Entry]
        var recovery: ExecOutcome.Recovery?
    }

    private func run(_ shape: Shape, crashAfterJournalWrite write: Int) async throws -> Run {
        let scenario = ExecScenario(
            name: "\(shape) crashed after journal write \(write)", tree: shape.tree,
            paste: .init(mode: shape.mode, sources: ["source/\(shape.name)"], destination: "destination"),
            policy: .init(file: "overwrite", directory: "overwrite", mismatch: "overwrite"),
            crashAt: .init(journalWrite: write))
        let places = try ExecPlaces.make(for: scenario)
        defer { places.remove() }
        try scenario.build(in: places)
        let outcome = try await SwiftExecEngine().run(
            scenario, answers: [], stopAt: nil, crashAt: scenario.crashAt, in: places)
        let crashed = outcome.events.contains { $0["kind"]?.stringValue == "crash" }
        return Run(crashed: crashed, before: outcome.before, recovery: outcome.recovery)
    }

    /// The item at `path` as a whole: each file and folder in it by its path inside, with a file's contents. Nil when
    /// nothing is there.
    private func item(_ entries: [TreeSnapshot.Entry], at path: String) -> [String: String]? {
        var found: [String: String] = [:]
        for entry in entries {
            if entry.path == path {
                found[""] = entry.sha256 ?? entry.kind
            } else if entry.path.hasPrefix(path + "/") {
                found[String(entry.path.dropFirst(path.count + 1))] = entry.sha256 ?? entry.kind
            }
        }
        return found.isEmpty ? nil : found
    }

    /// The items whole in the Trash, which names them "<n>-<name>".
    private func trashed(_ entries: [TreeSnapshot.Entry], named name: String) -> [[String: String]] {
        Set(entries.map { String($0.path.split(separator: "/")[0]) })
            .filter { $0.hasSuffix("-" + name) }
            .compactMap { item(entries, at: $0) }
    }

    @Test(arguments: Shape.allCases)
    func nothingIsLostWhereverAReplaceIsKilled(_ shape: Shape) async throws {
        var write = 1
        var stages = 0
        // Each write in turn, until the paste ends before the write the crash waits for.
        while write <= 10 {
            let run = try await run(shape, crashAfterJournalWrite: write)
            guard run.crashed else { break }
            stages += 1
            let recovery = try #require(run.recovery, "write \(write)")
            let newer = try #require(item(run.before, at: "source/\(shape.name)"))
            let older = try #require(item(run.before, at: "destination/\(shape.name)"))
            let after = recovery.after
            let destination = item(after, at: "destination/\(shape.name)")
            let source = item(after, at: "source/\(shape.name)")
            let inTrash = trashed(recovery.trash, named: shape.name)

            #expect(recovery.journal == .array([]), "\(shape) after write \(write): the journal is empty")
            // Whole, file for file: the one pasted and the one it replaces.
            #expect(
                destination == newer || destination == older,
                "\(shape) after write \(write): the destination holds one of the two, whole")
            #expect(
                destination == newer || source == newer,
                "\(shape) after write \(write): the pasted item is whole where it went or where it was")
            if !shape.isMove {
                #expect(source == newer, "\(shape) after write \(write): a copy leaves its source as it was")
            }
            #expect(
                destination == older || inTrash.contains(older),
                "\(shape) after write \(write): the replaced item is kept, or whole in the Trash")
            #expect(
                !(after + recovery.trash).contains { $0.path.contains(".filetrail-") },
                "\(shape) after write \(write): no copy under a hidden name is left")
            write += 1
        }
        #expect(stages >= 2, "\(shape): killed at \(stages) stages")
    }

    /// A folder moved to another disk is put in place whole before its originals are removed: wherever the move is
    /// killed, after recovery it is where it went, or where it was, and when it is in both the person is told.
    @Test(.tags(.diskImage), .diskImages)
    func aFolderMovedToAnotherDiskIsNeverInBothPlacesUntold() async throws {
        var write = 1
        var stages = 0
        while write <= 10 {
            let scenario = ExecScenario(
                name: "folder moved to another disk, crashed after journal write \(write)",
                tree: [
                    .init(path: "source/f/a.txt", kind: "file", content: "a\n"),
                    .init(path: "source/f/b.txt", kind: "file", content: "b\n"),
                    .init(path: "destination", kind: "dir"),
                ],
                paste: .init(mode: "cut", sources: ["source/f"], destination: "destination"),
                policy: .init(file: "skip", directory: "skip", mismatch: "skip"),
                crashAt: .init(journalWrite: write), volumes: ["destination": "apfs"])
            let places = try ExecPlaces.make(for: scenario)
            defer { places.remove() }
            try scenario.build(in: places)
            let outcome = try await SwiftExecEngine().run(
                scenario, answers: [], stopAt: nil, crashAt: scenario.crashAt, in: places)
            guard outcome.events.contains(where: { $0["kind"]?.stringValue == "crash" }) else { break }
            stages += 1
            let recovery = try #require(outcome.recovery, "write \(write)")
            let paths = Set(recovery.after.map(\.path))
            let moved = paths.contains("destination/f/a.txt") && paths.contains("destination/f/b.txt")
            let original = paths.contains("source/f")
            #expect(moved || original, "after write \(write): the folder is where it went or where it was")
            if moved && original {
                #expect(!recovery.notices.isEmpty, "after write \(write): in both places, and the person is told")
            }
            #expect(recovery.journal == .array([]), "after write \(write): the journal is empty")
            write += 1
        }
        #expect(stages >= 3, "killed at \(stages) stages")
    }
}
