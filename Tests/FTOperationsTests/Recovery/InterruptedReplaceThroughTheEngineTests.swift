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
        /// The file compared, inside the item.
        var file: String { isFolder ? "f/a.txt" : "a.txt" }
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

    private func digest(_ entries: [TreeSnapshot.Entry], _ path: String) -> String? {
        entries.first { $0.path == path }?.sha256
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
            let newer = try #require(digest(run.before, "source/\(shape.file)"))
            let older = try #require(digest(run.before, "destination/\(shape.file)"))
            let after = recovery.after
            let destination = digest(after, "destination/\(shape.file)")
            let kept = Set(after.compactMap(\.sha256) + recovery.trash.compactMap(\.sha256))

            #expect(recovery.journal == .array([]), "\(shape) after write \(write): the journal is empty")
            #expect(kept.contains(newer), "\(shape) after write \(write): the pasted item is still somewhere")
            #expect(kept.contains(older), "\(shape) after write \(write): the replaced item is kept or in the Trash")
            #expect(
                destination == newer || destination == older,
                "\(shape) after write \(write): the destination holds one of the two")
            #expect(
                !(after + recovery.trash).contains { $0.path.contains(".filetrail-") },
                "\(shape) after write \(write): no copy under a hidden name is left")
            write += 1
        }
        #expect(stages >= 2, "\(shape): killed at \(stages) stages")
    }
}
