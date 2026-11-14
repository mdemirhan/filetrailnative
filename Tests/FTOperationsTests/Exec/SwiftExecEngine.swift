// The Swift paste engine, as the scenario checks drive it. The review and the paste go through the write service,
// with the native file system, the app's Trash wrapper (TrashItem) around a folder Trash (ExecPlaces.trashFor), and
// the app's journal file at places.journal. Questions are answered as the window does, the paste is stopped as the
// Stop button does, and each thing that happens is recorded in order. A crash right after the n-th write of the
// journal stops everything reaching the disk, the journal and the record at that point, as a killed process does,
// and the app's startup recovery (recoverWrites) then runs on what was left.
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
        let before = try places.snapshotTree()
        let log = Log()
        let fileSystem = RecordedWriteFileSystem(trash: try Self.trash(scenario, places), killed: { log.crashed })
        let journal = RecordingJournal(
            file: FileWriteJournal.open(places.journal), path: places.journal, log: log,
            crashAfterWrite: crashAt?.journalWrite)
        let service = WriteService(
            .init(
                fileSystem: fileSystem, writeJournal: journal, createOperationId: { "op-test" },
                createAnalysisId: { "analysis-test" }))

        // The review.
        let mode = try Self.mode(scenario.paste.mode)
        let report: CopyPasteAnalysisReport
        do {
            report = try await service.analyze(
                CopyPasteAnalysisRequest(
                    mode: mode, sourcePaths: scenario.paste.sources.map(places.resolve),
                    destinationDirectoryPath: places.resolve(scenario.paste.destination)),
                signal: StopSignal())
        } catch {
            log.append(.object(["kind": .string("error"), "message": .string(errorMessage(error))]))
            return try outcome(before, log, places)
        }
        if !report.issues.isEmpty {
            log.append(.object(["kind": .string("issues"), "issues": .array(report.issues.map(EngineJSON.issue))]))
            return try outcome(before, log, places)
        }
        try applyChanges(scenario, afterEvent: nil, places, log)

        // The paste, from the moment it is queued until its last event.
        let script = Script(
            answers: answers, applyToRemaining: scenario.applyToRemaining ?? [], stopAfterEvent: stopAt?.afterEvent)
        let finished = AsyncStream<Void>.makeStream()
        let unsubscribe = service.subscribe { event in
            // A killed process hears nothing more, and nothing more is done for it; the paste is only waited out. Its
            // disk calls fail from the crash on, so a question may follow: the paste is stopped, which can't reach
            // the disk either.
            if log.crashed {
                if event.status == .awaitingResolution { service.cancelOperation(event.operationId) }
                if Self.terminal.contains(event.status) { finished.continuation.finish() }
                return
            }
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
        let handle = try service.startCopyPaste(
            report: report,
            policy: CopyPastePolicy(
                file: try Self.choice(scenario.policy.file), directory: try Self.choice(scenario.policy.directory),
                mismatch: try Self.choice(scenario.policy.mismatch)),
            overrides: try (scenario.overrides ?? []).map {
                CopyPasteNodeOverride(nodeId: $0.nodeId, action: try Self.choice($0.action))
            })
        for await _ in finished.stream {}
        // The service lets the operation go just after its last event: that is done before anything is read.
        while !service.hasReleased(handle.operationId) { await Task.yield() }
        if log.crashed {
            // The tree, the Trash and the journal as the crash left them, then what recovery made of them.
            var left = try outcome(before, log, places)
            left.recovery = try Self.recover(places)
            return left
        }
        if let undo, let script = scenario.undo {
            try await undo.waitForRecord(of: log.records)
            let steps = try await undo.run(script, places)
            return try outcome(before, log, places, undo: .object(["steps": .array(steps)]))
        }
        return try outcome(before, log, places)
    }

    /// The app's startup recovery, on the journal and the disk a crash left, with what it logged.
    private static func recover(_ places: ExecPlaces) throws -> ExecOutcome.Recovery {
        let logged = OSAllocatedUnfairLock(initialState: [JSONValue]())
        let report = recoverWrites(
            FileWriteJournal.open(places.journal), NativeWriteFileSystem(),
            logger: RecoveryLogger(
                info: { message, details in
                    // The recordings give a Replace's recovery a path, null when nothing was put in place (its copy
                    // removed, or nothing left of it); the log takes text alone, so it leaves out a path it doesn't
                    // have. Any other outcome without a path stays without one, and differs.
                    let nothingPutInPlace = ["removed_copy", "nothing_left"].contains(details["outcome"] ?? "")
                    let fields = details.mapValues { JSONValue.string($0) }.merging(
                        nothingPutInPlace && details["path"] == nil ? ["path": .null] : [:]
                    ) { kept, _ in kept }
                    logged.withLock {
                        $0.append(
                            .object([
                                "level": .string("info"), "message": .string(message), "details": .object(fields),
                            ]))
                    }
                },
                error: { message, error in
                    logged.withLock {
                        $0.append(
                            .object([
                                "level": .string("error"), "message": .string(message), "details": .string(error),
                            ]))
                    }
                }),
            answerWithinMs: recoveryAnswerWithinMs)
        return ExecOutcome.Recovery(
            notices: report.notices, finished: report.finished, log: logged.withLock { $0 },
            after: try places.snapshotTree(), trash: try places.snapshotTrash(), journal: try places.readJournal())
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

    /// The Trash given to the write service: TrashItem (which tells a locked item, and a disk that may
    /// have no Trash, from other failures) around a folder per disk items are moved into as "<n>-<name>", numbered
    /// across them; on a disk without a Trash it fails as the Trash does there, with ENOTSUP. None at all when the
    /// scenario says so, and the file system then fails as on a disk without one.
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
                    code: .errno(ENOTSUP))
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

/// What happened, in order, from every thread that records, until a crash: a killed process records nothing more.
private final class Log: Sendable {
    private struct State {
        var records: [JSONValue] = []
        var crashed = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func append(_ record: JSONValue) {
        state.withLock { if !$0.crashed { $0.records.append(record) } }
    }

    /// The process is killed here: the crash is the last record.
    func crash(_ point: [String: JSONValue]) {
        state.withLock {
            guard !$0.crashed else { return }
            $0.records.append(.object(["kind": .string("crash")].merging(point) { first, _ in first }))
            $0.crashed = true
        }
    }

    var crashed: Bool { state.withLock { $0.crashed } }
    var records: [JSONValue] { state.withLock { $0.records } }
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
    /// The write after which the process is killed.
    let crashAfterWrite: Int?
    private let writes = OSAllocatedUnfairLock(initialState: 0)

    init(file: FileWriteJournal, path: String, log: Log, crashAfterWrite: Int? = nil) {
        self.file = file
        self.path = path
        self.log = log
        self.crashAfterWrite = crashAfterWrite
    }

    // A killed process writes nothing more.
    func add(_ entry: WriteJournalEntry) throws {
        if log.crashed { return }
        try file.add(entry)
        wrote()
    }

    func remove(_ id: String) throws {
        if log.crashed { return }
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
        if write == crashAfterWrite {
            log.crash(["afterJournalWrite": .int(write)])
        }
    }
}

/// The disk as the recordings expect it: the app's native file system, but with a realpath that opens the
/// item, so it fails (EACCES) on an item its owner can't read (see RecordedFileSystem). Once `killed` says the
/// process was killed, every call fails without reaching the disk.
struct RecordedWriteFileSystem: UndoFileSystem {
    struct Killed: CodedError {
        var code: ErrorCode? { .errno(ECANCELED) }
        var message: String { "The engine was killed." }
    }

    private let disk: NativeWriteFileSystem
    private let reader = RecordedFileSystem()
    private let killed: @Sendable () -> Bool

    init(trash: (@Sendable (String) throws -> String?)?, killed: @escaping @Sendable () -> Bool = { false }) {
        disk = NativeWriteFileSystem(trash: trash)
        self.killed = killed
    }

    private func alive() throws {
        if killed() { throw Killed() }
    }

    func lstat(_ path: String) throws -> WriteServiceStats {
        try alive()
        return try disk.lstat(path)
    }
    func stat(_ path: String) throws -> WriteServiceStats {
        try alive()
        return try disk.stat(path)
    }
    func realpath(_ path: String) throws -> String {
        try alive()
        return try reader.realpath(path)
    }
    func readdir(_ path: String) throws -> [String] {
        try alive()
        return try disk.readdir(path)
    }
    func readlink(_ path: String) throws -> String {
        try alive()
        return try disk.readlink(path)
    }
    func isCaseSensitive(_ path: String) throws -> Bool? {
        try alive()
        return try disk.isCaseSensitive(path)
    }
    func isPackage(_ path: String) throws -> Bool? {
        try alive()
        return try disk.isPackage(path)
    }
    func isAppleDouble(_ path: String) -> Bool { disk.isAppleDouble(path) }
    func renameExclusive(_ from: String, _ to: String) throws {
        try alive()
        try disk.renameExclusive(from, to)
    }
    func mkdir(_ path: String) throws {
        try alive()
        try disk.mkdir(path)
    }
    func writeNewFile(_ path: String, _ contents: Data) throws {
        try alive()
        try disk.writeNewFile(path, contents)
    }
    func rm(_ path: String, recursive: Bool, force: Bool) throws {
        try alive()
        try disk.rm(path, recursive: recursive, force: force)
    }
    func rmdir(_ path: String) throws {
        try alive()
        try disk.rmdir(path)
    }
    func copyFile(
        _ source: String, _ destination: String, stop: StopSignal?, onProgress: (@Sendable (Int64) -> Void)?
    ) throws {
        try alive()
        try disk.copyFile(source, destination, stop: stop, onProgress: onProgress)
    }
    func getFlags(_ path: String) throws -> UInt32 {
        try alive()
        return try disk.getFlags(path)
    }
    func setFlags(_ path: String, _ flags: UInt32) throws {
        try alive()
        try disk.setFlags(path, flags)
    }
    func chmod(_ path: String, _ mode: UInt32) throws {
        try alive()
        try disk.chmod(path, mode)
    }
    func utimes(_ path: String, _ atimeMs: Double, _ mtimeMs: Double) throws {
        try alive()
        try disk.utimes(path, atimeMs, mtimeMs)
    }
    func copyMetadata(_ source: String, _ destination: String) throws {
        try alive()
        try disk.copyMetadata(source, destination)
    }
    func copyMetadataToRunInPlace(_ source: String, _ destination: String) throws {
        try alive()
        try disk.copyMetadataToRunInPlace(source, destination)
    }
    func setAcl(_ path: String, _ acl: String?) throws {
        try alive()
        try disk.setAcl(path, acl)
    }
    func trash(_ path: String) throws -> String? {
        try alive()
        return try disk.trash(path)
    }
    func canModifyFolder(_ path: String) throws {
        try alive()
        try disk.canModifyFolder(path)
    }
    // What Undo asks besides, as the app's own.
    func rename(_ from: String, _ to: String) throws {
        try alive()
        try disk.rename(from, to)
    }
    func itemSize(_ path: String) throws -> ItemSize {
        try alive()
        return try disk.itemSize(path)
    }
    func getAcl(_ path: String) throws -> String? {
        try alive()
        return try disk.getAcl(path)
    }
}

/// The engine's values as JSON, every key present.
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
