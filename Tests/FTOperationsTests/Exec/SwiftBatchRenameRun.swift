// A batch-rename scenario through the Swift engine, as tools/parity/exec/batch-rename.ts records the reference's: the
// Rename sheet's checks first when asked, then the rename on the disk itself (BatchRenameExecution.run with the app's
// journal file), recording each item as it starts, each rename that went ahead, each journal write, a stop, the
// results and the undo record; a crash stops everything reaching the disk and the journal at that point, as a killed
// process does, and the app's startup recovery (recoverWrites) then runs on the same folders.
import FTFileSystem
import FTFoundation
import FTTestSupport
import Foundation

@testable import FTOperations

/// What the run recorded, from the disk thread it runs on.
private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [JSONValue] = []
    private var dead = false

    var events: [JSONValue] { lock.withLock { recorded } }
    var crashed: Bool { lock.withLock { dead } }

    /// Recorded unless the run has crashed: a killed process writes nothing more.
    func record(_ fields: [String: JSONValue]) {
        lock.withLock {
            if !dead { recorded.append(.object(fields)) }
        }
    }

    func crash(_ point: [String: JSONValue]) {
        record(["kind": .string("crash")].merging(point) { first, _ in first })
        lock.withLock { dead = true }
    }
}

/// The disk the run renames on, counting the renames that went ahead (to stop or crash after one).
private struct RecordedRenameDisk: BatchRenameFileSystem {
    let disk: LocalBatchRenameFileSystem
    let recorder: Recorder
    let moves: Locked<Int>
    let stopAfterMoves: Int?
    let crashAfterMoves: Int?
    let signal: StopSignal

    private func alive() throws {
        if recorder.crashed { throw OperationError("The engine was killed.", code: "ECANCELED") }
    }

    private func moved(_ op: String, _ from: String, _ to: String) {
        moves.mutate { $0 += 1 }
        let count = moves.value
        recorder.record(["kind": .string("move"), "op": .string(op), "from": .string(from), "to": .string(to)])
        if count == crashAfterMoves {
            recorder.crash(["afterMoves": .int(count)])
        }
        if count == stopAfterMoves {
            recorder.record(["kind": .string("stop")])
            signal.stop()
        }
    }

    func lstat(_ path: String) throws -> WriteServiceStats {
        try alive()
        return try disk.lstat(path)
    }

    func renameExclusive(_ from: String, _ to: String) throws {
        try alive()
        try disk.renameExclusive(from, to)
        moved("renameExclusive", from, to)
    }

    func rename(_ from: String, _ to: String) throws {
        try alive()
        try disk.rename(from, to)
        moved("rename", from, to)
    }

    var readFolder: ((String) throws -> [String])? {
        { [disk, recorder] in
            if recorder.crashed { throw OperationError("The engine was killed.", code: "ECANCELED") }
            return try disk.readFolder?($0) ?? []
        }
    }

    var readFlags: ((String) throws -> UInt32)? { disk.readFlags }
    var caseSensitivity: ((String) throws -> Bool?)? { disk.caseSensitivity }
}

/// The app's journal file, each write recorded as the file then says (the engine's `wrote`).
private struct RecordedJournal: WriteJournal {
    let file: FileWriteJournal
    let path: String
    let recorder: Recorder
    let writes: Locked<Int>
    let crashAfterJournalWrite: Int?

    func add(_ entry: WriteJournalEntry) throws {
        if recorder.crashed { return }
        try file.add(entry)
        wrote()
    }

    func remove(_ id: String) throws {
        if recorder.crashed { return }
        let writesFile = file.entries().contains { $0.id == id }
        try file.remove(id)
        if writesFile { wrote() }
    }

    private func wrote() {
        writes.mutate { $0 += 1 }
        let count = writes.value
        let entries = (try? JSONValue.parse(Data(contentsOf: URL(fileURLWithPath: path)))) ?? .null
        recorder.record(["kind": .string("journal"), "write": .int(count), "entries": entries])
        if count == crashAfterJournalWrite {
            recorder.crash(["afterJournalWrite": .int(count)])
        }
    }
}

enum SwiftBatchRenameRun {
    static let engine: ExecBatchRenameHarness.Engine = { scenario, places in
        try await run(scenario, places)
    }

    static func run(_ scenario: ExecBatchRenameScenario, _ places: ExecPlaces) async throws -> JSONValue {
        let before = try JSONValue.of(try places.snapshotTree())
        var inspected = JSONValue.null
        if let inspect = scenario.inspect {
            let answer = await BatchRenameInspect.inspect(
                BatchRenameInspectRequest(
                    paths: inspect.paths.map(places.resolve), includeDateTaken: inspect.includeDateTaken),
                .native(homePath: NSHomeDirectory()))
            inspected = ExecBatchRenameScenario.maskInspection(json(answer))
        }
        let recorder = Recorder()
        let signal = StopSignal()
        let fileSystem = LocalBatchRenameFileSystem(NativeWriteFileSystem())
        let disk = RecordedRenameDisk(
            disk: fileSystem, recorder: recorder, moves: Locked(0), stopAfterMoves: scenario.stopAt?.afterMoves,
            crashAfterMoves: scenario.crashAt?.afterMoves, signal: signal)
        let journal = RecordedJournal(
            file: FileWriteJournal.open(places.journal), path: places.journal, recorder: recorder, writes: Locked(0),
            crashAfterJournalWrite: scenario.crashAt?.journalWrite)
        let request = BatchRenameRequest(
            items: scenario.batchRename.items.map {
                .init(sourcePath: places.resolve($0.path), destinationName: $0.destinationName, isFolder: $0.isFolder)
            },
            onConflict: BatchRenameOnConflict(rawValue: scenario.batchRename.onConflict) ?? .number,
            numberSeparator: scenario.batchRename.numberSeparator)
        if scenario.stopAt?.afterMoves == 0 {
            recorder.record(["kind": .string("stop")])
            signal.stop()
        }
        let stopAtItemStart = scenario.stopAt?.itemStart
        let (run, undo) = await LocalOperations.onDisk { () -> (BatchRenameRun, [BatchRenamedItem]) in
            let run = BatchRenameExecution.run(
                request, fileSystem: disk, signal: signal,
                onItemStart: { source, destination, completed in
                    recorder.record([
                        "kind": .string("itemStart"), "sourcePath": .string(source),
                        "destinationPath": .string(destination), "completed": .int(completed),
                    ])
                    if completed == stopAtItemStart {
                        recorder.record(["kind": .string("stop")])
                        signal.stop()
                    }
                }, temporaryName: ExecBatchRenameScenario.temporaryNames(), journal: journal)
            return (run, BatchRenameExecution.movedItemsOf(fileSystem, run.items))
        }
        let crashed = recorder.crashed
        // As the engine left them, before any recovery.
        let after = try JSONValue.of(try places.snapshotTree())
        let journalLeft = try places.readJournal()
        var recovery = JSONValue.null
        if crashed {
            let logged = Locked<[JSONValue]>([])
            let report = recoverWrites(
                FileWriteJournal.open(places.journal), NativeWriteFileSystem(),
                logger: RecoveryLogger(
                    info: { message, details in
                        logged.mutate {
                            $0.append(
                                .object([
                                    "level": .string("info"), "message": .string(message),
                                    "details": .object(details.mapValues { .string($0) }),
                                ]))
                        }
                    },
                    error: { message, error in
                        logged.mutate {
                            $0.append(
                                .object([
                                    "level": .string("error"), "message": .string(message), "details": .string(error),
                                ]))
                        }
                    }),
                answerWithinMs: recoveryAnswerWithinMs)
            recovery = .object([
                "notices": .array(report.notices.map { .string($0) }),
                "finished": .array(report.finished.map { .string($0) }),
                "log": .array(logged.value),
                "after": try JSONValue.of(try places.snapshotTree()),
                "journal": try places.readJournal(),
            ])
        }
        return .object([
            "before": before,
            "after": after,
            "inspect": inspected,
            "events": .array(recorder.events),
            "run": crashed ? .null : json(run),
            "undo": crashed ? .null : .array(undo.map(json)),
            "journal": journalLeft,
            "recovery": recovery,
        ])
    }

    private static func optional(_ text: String?) -> JSONValue { text.map { .string($0) } ?? .null }

    private static func json(_ run: BatchRenameRun) -> JSONValue {
        .object([
            "items": .array(
                run.items.map { item in
                    .object([
                        "sourcePath": optional(item.sourcePath), "destinationPath": optional(item.destinationPath),
                        "status": .string(item.status.rawValue), "error": optional(item.error),
                        "skipReason": optional(item.skipReason?.rawValue),
                    ])
                }),
            "completedItemCount": .int(run.completedItemCount),
            "cancelled": .bool(run.cancelled),
        ])
    }

    private static func json(_ item: BatchRenamedItem) -> JSONValue {
        .object([
            "from": .string(item.from), "to": .string(item.to),
            "id": item.id.map { .object(["dev": .int(Int($0.dev)), "ino": .int(Int($0.ino))]) } ?? .null,
            "itemKind": optional(item.itemKind?.rawValue),
        ])
    }

    private static func json(_ answer: BatchRenameInspection) -> JSONValue {
        .object([
            "items": .array(
                answer.items.map { item in
                    .object([
                        "path": .string(item.path), "createdAt": optional(item.createdAt),
                        "modifiedAt": optional(item.modifiedAt), "takenAt": optional(item.takenAt),
                        "cannotRename": optional(item.cannotRename),
                    ])
                }),
            "folders": .array(
                answer.folders.map { folder in
                    .object([
                        "path": .string(folder.path), "names": .array(folder.names.map { .string($0) }),
                        "caseSensitive": .bool(folder.caseSensitive),
                    ])
                }),
        ])
    }
}
