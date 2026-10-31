// The Swift paste engine, as the differential drives it: what tools/parity/exec/engine.ts records of the reference.
// The review and the paste go through the write service, with the native file system, the app's Trash wrapper
// (TrashItem) around a folder Trash as testNativePaste.ts makes one (ExecPlaces.trashFor), and the app's journal
// file at places.journal. Questions are answered as the window does, the paste is stopped as the Stop button does,
// and each thing that happens is recorded in order. Crashes aren't injected (decided 2026-10-14).
import Darwin
import FTFileSystem
import FTFoundation
import FTTestSupport
import Foundation
import os

@testable import FTOperations

struct SwiftExecEngine: ExecEngine {
    struct Unsupported: Error, CustomStringConvertible {
        let description: String
    }

    private static let terminal: Set<CopyPasteOperationStatus> = [.completed, .partial, .failed, .cancelled]

    func run(
        _ scenario: ExecScenario, answers: [String], stopAt: ExecScenario.StopPoint?, crashAt: ExecScenario.CrashPoint?,
        in places: ExecPlaces
    ) async throws -> ExecOutcome {
        if crashAt != nil {
            throw Unsupported(description: "\(scenario.name): crashes aren't injected")
        }
        let before = try places.snapshotTree()
        let log = Log()
        let fileSystem = RecordedWriteFileSystem(trash: try Self.trash(scenario, places))
        let journal = RecordingJournal(file: FileWriteJournal.open(places.journal), path: places.journal, log: log)
        let service = WriteService(
            .init(
                fileSystem: fileSystem, writeJournal: journal, createOperationId: { "op-test" },
                createAnalysisId: { "analysis-test" },
                // No large-batch warnings: they don't change what is pasted.
                thresholds: CopyPasteThresholds(
                    largeBatchItemThreshold: 100_000, largeBatchByteThreshold: 1_000_000_000_000)))

        // The review.
        let mode = try Self.mode(scenario.paste.mode)
        let analysisId = try service.startCopyPasteAnalysis(
            CopyPasteAnalysisRequest(
                mode: mode, sourcePaths: scenario.paste.sources.map(places.resolve),
                destinationDirectoryPath: places.resolve(scenario.paste.destination))
        ).analysisId
        var update = try service.getCopyPasteAnalysisUpdate(analysisId)
        while !update.done {
            try await Task.sleep(for: .milliseconds(1))
            update = try service.getCopyPasteAnalysisUpdate(analysisId)
        }
        if update.status != .complete || update.report == nil {
            log.append(
                .object(["kind": .string("error"), "message": .string(update.error ?? "analysis \(update.status)")]))
            return try outcome(before, log, places)
        }
        if let report = update.report, !report.issues.isEmpty {
            log.append(.object(["kind": .string("issues"), "issues": .array(report.issues.map(EngineJSON.issue))]))
            return try outcome(before, log, places)
        }
        try applyChanges(scenario, afterEvent: nil, places, log)

        // The paste, from the moment it is queued until its last event.
        let script = Script(
            answers: answers, applyToRemaining: scenario.applyToRemaining ?? [], stopAfterEvent: stopAt?.afterEvent)
        let finished = AsyncStream<Void>.makeStream()
        let unsubscribe = service.subscribe { event in
            log.append(EngineJSON.event(event))
            if let result = event.result {
                log.append(.object(["kind": .string("result"), "result": EngineJSON.result(result)]))
            }
            let count = script.countEvent()
            try? applyChanges(scenario, afterEvent: count, places, log)
            if count == script.stopAfterEvent {
                // Stop: a question still open is dropped, unanswered.
                log.append(.object(["kind": .string("stop")]))
                service.cancelOperation(event.operationId)
            } else if event.status == .awaitingResolution, let conflict = event.runtimeConflict {
                let (text, standing) = script.nextAnswer()
                let allowed = getAllowedRuntimeResolutions(conflict)
                let choice = CopyPasteChoice(rawValue: text)
                let ok =
                    choice.map {
                        service.resolveRuntimeConflict(
                            event.operationId, conflictId: conflict.conflictId, action: $0, applyToRemaining: standing)
                    } ?? false
                log.append(
                    .object([
                        "kind": .string("answer"), "conflictId": .string(conflict.conflictId),
                        "allowed": .array(allowed.map { .string($0.rawValue) }), "answer": .string(text),
                        "applyToRemaining": .bool(standing),
                    ]))
                if !ok {
                    // The service refused it, and the question stays open.
                    service.cancelOperation(event.operationId)
                }
            }
            if Self.terminal.contains(event.status) {
                finished.continuation.finish()
            }
        }
        defer { unsubscribe() }
        // The app's coordinator hears the paste end, as it hears every paste, and keeps it for Undo.
        let undo =
            scenario.undo == nil
            ? nil : await SwiftUndoRun.make(service, fileSystem, places, hasTrash: scenario.trash != false)
        _ = try service.startCopyPaste(
            CopyPasteExecutionRequest(
                analysisId: analysisId,
                policy: CopyPastePolicy(
                    file: try Self.choice(scenario.policy.file), directory: try Self.choice(scenario.policy.directory),
                    mismatch: try Self.choice(scenario.policy.mismatch)),
                overrides: try (scenario.overrides ?? []).map {
                    CopyPasteNodeOverride(nodeId: $0.nodeId, action: try Self.choice($0.action))
                }))
        for await _ in finished.stream {}
        // Anything the service does after its last event (it lets the operation go) is done by now.
        try await Task.sleep(for: .milliseconds(10))
        if let undo, let script = scenario.undo {
            try await undo.waitForRecord(of: log.records)
            let steps = try await undo.run(script, places)
            return try outcome(before, log, places, undo: .object(["steps": .array(steps)]))
        }
        return try outcome(before, log, places)
    }

    private func applyChanges(_ scenario: ExecScenario, afterEvent: Int?, _ places: ExecPlaces, _ log: Log) throws {
        for change in scenario.changes ?? [] where change.afterEvent == afterEvent {
            try ExecScenario.apply(change.ops, in: places)
            log.append(
                .object([
                    "kind": .string("change"),
                    "ops": .array(
                        change.ops.map { op in
                            var object: [String: JSONValue] = [
                                "op": .string(op.op), "path": .string(places.resolve(op.path)),
                            ]
                            if let content = op.content { object["content"] = .string(content) }
                            if let mode = op.mode { object["mode"] = .string(mode) }
                            return .object(object)
                        }),
                ]))
        }
    }

    private func outcome(
        _ before: [TreeSnapshot.Entry], _ log: Log, _ places: ExecPlaces, undo: JSONValue? = nil
    ) throws -> ExecOutcome {
        let records = log.records
        let events = records.filter { $0["kind"]?.stringValue != "result" }
        var result: JSONValue = .null
        var undoLog: JSONValue = .null
        if case .object(var finished)? = records.first(where: { $0["kind"]?.stringValue == "result" })?["result"] {
            undoLog = finished.removeValue(forKey: "undoLog") ?? .null
            result = .object(finished)
        } else if let issues = records.first(where: { $0["kind"]?.stringValue == "issues" })?["issues"] {
            result = .object(["issues": issues])
        }
        return ExecOutcome(
            before: before, after: try places.snapshotTree(), trash: try places.snapshotTrash(), events: events,
            result: result, undoLog: undoLog, journal: try places.readJournal(), recovery: nil, undo: undo)
    }

    // MARK: The Trash

    /// The Trash as bootstrap.ts gives the write service: TrashItem (which tells a locked item, and a disk that may
    /// have no Trash, from other failures) around a folder per disk items are moved into as "<n>-<name>", numbered
    /// across them; on a disk without a Trash it fails as the Trash does there, with ENOTSUP. None at all when the
    /// scenario says so.
    private static func trash(_ scenario: ExecScenario, _ places: ExecPlaces) throws
        -> (@Sendable (String) throws -> String?)?
    {
        if scenario.trash == false {
            return nil
        }
        let folders = [places.trash] + places.volumes.map(\.trash)
        var highest = 0
        for folder in folders {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [] {
                highest = max(highest, Int(name.prefix { $0.isNumber }) ?? 0)
            }
        }
        let count = OSAllocatedUnfairLock(initialState: highest)
        let folderTrash: @Sendable (String) throws -> String? = { path in
            guard places.hasTrash(path) else {
                throw NativeError(
                    message:
                        "\u{201C}\(NodePath.basename(path))\u{201D} couldn\u{2019}t be moved to the trash because its volume doesn\u{2019}t have one.",
                    code: "ENOTSUP")
            }
            let number = count.withLock { value in
                value += 1
                return value
            }
            let inTrash = "\(places.trashFor(path))/\(number)-\(NodePath.basename(path))"
            if Darwin.rename(path, inTrash) != 0 {
                throw NativeError.errno(errno, syscall: "rename", path: path, dest: inTrash)
            }
            return inTrash
        }
        // Every disk here is local (a disk image), as listMounts would say.
        let mounts = [Mount(path: "/", isLocal: true)] + places.volumes.map { Mount(path: $0.mount, isLocal: true) }
        let disk = PosixFileSystem()
        let trashItem = TrashItem(
            trash: folderTrash, lstat: { try disk.lstat($0) }, getFlags: NativeFS.getFlags,
            homePath: NSHomeDirectory(), diskHasTrash: makeDiskHasTrash(listMounts: { mounts }))
        return { try trashItem($0) }
    }

    // MARK: Values

    private static func mode(_ text: String) throws -> CopyPasteMode {
        guard let mode = CopyPasteMode(rawValue: text) else { throw Unsupported(description: "mode \(text)") }
        return mode
    }

    private static func choice(_ text: String) throws -> CopyPasteChoice {
        guard let choice = CopyPasteChoice(rawValue: text) else { throw Unsupported(description: "choice \(text)") }
        return choice
    }
}

/// What happened, in order, from every thread that records.
private final class Log: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: [JSONValue]())

    func append(_ record: JSONValue) {
        state.withLock { $0.append(record) }
    }

    var records: [JSONValue] { state.withLock { $0 } }
}

/// The answers to give and when to stop, consumed as the paste goes.
private final class Script: Sendable {
    private struct State {
        var answers: [String]
        var applyToRemaining: [Bool]
        var events = 0
    }

    let stopAfterEvent: Int?
    private let state: OSAllocatedUnfairLock<State>

    init(answers: [String], applyToRemaining: [Bool], stopAfterEvent: Int?) {
        self.stopAfterEvent = stopAfterEvent
        state = OSAllocatedUnfairLock(initialState: State(answers: answers, applyToRemaining: applyToRemaining))
    }

    func countEvent() -> Int {
        state.withLock { state in
            state.events += 1
            return state.events
        }
    }

    /// The next answer ("skip" once they run out) and whether it is for the rest of the operation.
    func nextAnswer() -> (String, Bool) {
        state.withLock { state in
            let answer = state.answers.isEmpty ? "skip" : state.answers.removeFirst()
            let standing = state.applyToRemaining.isEmpty ? false : state.applyToRemaining.removeFirst()
            return (answer, standing)
        }
    }
}

/// The app's journal file, each write of it recorded as the file then says.
private final class RecordingJournal: WriteJournal {
    let file: FileWriteJournal
    let path: String
    let log: Log
    private let writes = OSAllocatedUnfairLock(initialState: 0)

    init(file: FileWriteJournal, path: String, log: Log) {
        self.file = file
        self.path = path
        self.log = log
    }

    func add(_ entry: WriteJournalEntry) throws {
        try file.add(entry)
        wrote()
    }

    func remove(_ id: String) throws {
        let writes = file.entries().contains { $0.id == id }
        try file.remove(id)
        if writes {
            wrote()
        }
    }

    private func wrote() {
        let write = writes.withLock { count in
            count += 1
            return count
        }
        let entries = (try? JSONValue.parse(Data(contentsOf: URL(fileURLWithPath: path)))) ?? .null
        log.append(.object(["kind": .string("journal"), "write": .int(write), "entries": entries]))
    }
}

/// The disk as the recordings' file system saw it: the app's native file system, but with Bun's
/// `fs.promises.realpath`, which opens the item, so it fails (EACCES) on an item its owner can't read (see
/// RecordedFileSystem).
struct RecordedWriteFileSystem: UndoFileSystem {
    private let disk: NativeWriteFileSystem
    private let reader = RecordedFileSystem()

    init(trash: (@Sendable (String) throws -> String?)?) {
        disk = NativeWriteFileSystem(trash: trash)
    }

    func lstat(_ path: String) throws -> WriteServiceStats { try disk.lstat(path) }
    func stat(_ path: String) throws -> WriteServiceStats { try disk.stat(path) }
    func realpath(_ path: String) throws -> String { try reader.realpath(path) }
    func readdir(_ path: String) throws -> [String] { try disk.readdir(path) }
    func readlink(_ path: String) throws -> String { try disk.readlink(path) }
    func isCaseSensitive(_ path: String) throws -> Bool? { try disk.isCaseSensitive(path) }
    func isPackage(_ path: String) throws -> Bool? { try disk.isPackage(path) }
    func isAppleDouble(_ path: String) -> Bool { disk.isAppleDouble(path) }
    func renameExclusive(_ from: String, _ to: String) throws { try disk.renameExclusive(from, to) }
    func mkdir(_ path: String) throws { try disk.mkdir(path) }
    func rm(_ path: String, recursive: Bool, force: Bool) throws {
        try disk.rm(path, recursive: recursive, force: force)
    }
    func rmdir(_ path: String) throws { try disk.rmdir(path) }
    func copyFile(
        _ source: String, _ destination: String, stop: StopSignal?, onProgress: (@Sendable (Int64) -> Void)?
    ) throws {
        try disk.copyFile(source, destination, stop: stop, onProgress: onProgress)
    }
    func getFlags(_ path: String) throws -> UInt32 { try disk.getFlags(path) }
    func setFlags(_ path: String, _ flags: UInt32) throws { try disk.setFlags(path, flags) }
    var chmod: ((String, UInt32) throws -> Void)? { disk.chmod }
    var utimes: ((String, Double, Double) throws -> Void)? { disk.utimes }
    var copyMetadata: ((String, String) throws -> Void)? { disk.copyMetadata }
    var setAcl: ((String, String?) throws -> Void)? { disk.setAcl }
    var trash: ((String) throws -> String?)? { disk.trash }
    var canModifyFolder: ((String) throws -> Void)? { disk.canModifyFolder }
    // What Undo asks besides, as the app's own (createOriginalWriteOperationFs).
    func rename(_ from: String, _ to: String) throws { try disk.rename(from, to) }
    var itemSize: ((String) throws -> ItemSize)? { disk.itemSize }
    var getAcl: ((String) throws -> String?)? { disk.getAcl }
}

/// The engine's values as JSON, every key present as the reference writes it.
enum EngineJSON {
    private static func optional(_ text: String?) -> JSONValue { text.map { .string($0) } ?? .null }
    private static func optional(_ number: Int64?) -> JSONValue { number.map { .int(Int($0)) } ?? .null }

    static func issue(_ issue: CopyPasteAnalysisIssue) -> JSONValue {
        .object([
            "code": .string(issue.code.rawValue), "message": .string(issue.message),
            "sourcePath": optional(issue.sourcePath), "destinationPath": optional(issue.destinationPath),
        ])
    }

    /// A progress event as a record: without its result.
    static func event(_ event: CopyPasteProgressEvent) -> JSONValue {
        .object([
            "kind": .string("event"),
            "operationId": .string(event.operationId),
            "analysisId": optional(event.analysisId),
            "mode": .string(event.mode.rawValue),
            "status": .string(event.status.rawValue),
            "completedItemCount": .int(event.completedItemCount),
            "totalItemCount": .int(event.totalItemCount),
            "completedByteCount": .int(Int(event.completedByteCount)),
            "totalBytes": optional(event.totalBytes),
            "currentSourcePath": optional(event.currentSourcePath),
            "currentDestinationPath": optional(event.currentDestinationPath),
            "runtimeConflict": event.runtimeConflict.map(conflict) ?? .null,
        ])
    }

    static func conflict(_ conflict: CopyPasteRuntimeConflict) -> JSONValue {
        .object([
            "conflictId": .string(conflict.conflictId),
            "analysisId": .string(conflict.analysisId),
            "sourcePath": .string(conflict.sourcePath),
            "destinationPath": .string(conflict.destinationPath),
            "sourceKind": .string(conflict.sourceKind.rawValue),
            "destinationKind": .string(conflict.destinationKind.rawValue),
            "conflictClass": .string(conflict.conflictClass.rawValue),
            "reason": .string(conflict.reason.rawValue),
            "sourceFingerprint": SwiftAnalysisEngine.json(conflict.sourceFingerprint),
            "destinationFingerprint": SwiftAnalysisEngine.json(conflict.destinationFingerprint),
            "currentSourceFingerprint": SwiftAnalysisEngine.json(conflict.currentSourceFingerprint),
            "currentDestinationFingerprint": SwiftAnalysisEngine.json(conflict.currentDestinationFingerprint),
        ])
    }

    /// A result, with its undo log. The engine's items carry `skipReason` (null or set); those of the write
    /// service's own failure (which has no undo log) don't.
    static func result(_ result: CopyPasteOperationResult) -> JSONValue {
        let fromEngine = result.undoLog != nil
        var object: [String: JSONValue] = [
            "operationId": .string(result.operationId),
            "mode": .string(result.mode.rawValue),
            "status": .string(result.status.rawValue),
            "destinationDirectoryPath": .string(result.destinationDirectoryPath),
            "startedAt": .string(ISO8601DateFormatter().string(from: result.startedAt)),
            "finishedAt": .string(ISO8601DateFormatter().string(from: result.finishedAt)),
            "summary": .object([
                "topLevelItemCount": .int(result.summary.topLevelItemCount),
                "totalItemCount": .int(result.summary.totalItemCount),
                "completedItemCount": .int(result.summary.completedItemCount),
                "failedItemCount": .int(result.summary.failedItemCount),
                "skippedItemCount": .int(result.summary.skippedItemCount),
                "cancelledItemCount": .int(result.summary.cancelledItemCount),
                "completedByteCount": .int(Int(result.summary.completedByteCount)),
                "totalBytes": optional(result.summary.totalBytes),
            ]),
            "items": .array(result.items.map { item(item: $0, withSkipReason: fromEngine) }),
            "error": optional(result.error),
        ]
        if let trashedPaths = result.trashedPaths {
            object["trashedPaths"] = .array(trashedPaths.map { .string($0) })
        }
        if let replacedPaths = result.replacedPaths {
            object["replacedPaths"] = .array(replacedPaths.map { .string($0) })
        }
        if let undoLog = result.undoLog {
            object["undoLog"] = (try? JSONValue.of(undoLog)) ?? .null
        }
        return .object(object)
    }

    private static func item(item: CopyPasteItemResult, withSkipReason: Bool) -> JSONValue {
        var object: [String: JSONValue] = [
            "sourcePath": .string(item.sourcePath),
            "destinationPath": .string(item.destinationPath),
            "sourceKind": .string(item.sourceKind.rawValue),
            "status": .string(item.status.rawValue),
            "error": optional(item.error),
        ]
        if withSkipReason {
            object["skipReason"] = optional(item.skipReason?.rawValue)
        }
        if let count = item.childFailureCount {
            object["childFailureCount"] = .int(count)
        }
        return .object(object)
    }
}
