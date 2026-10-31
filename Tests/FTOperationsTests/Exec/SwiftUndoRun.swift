// The Undo and Redo of a pasted scenario, as the differential drives them: what tools/parity/exec/engine.ts
// (undoCoordinator, runUndoAndRedo, undoEnd) records of the reference. The app's coordinator on the same write service,
// with the Undo history, on the scenario's file system and Trash; Undo and Redo as the Edit menu runs them (prepare,
// the questions, start), each recorded with the menu before and after, the tree and the Trash.
import FTFoundation
import FTTestSupport
import Foundation

@testable import FTOperations

@MainActor
final class SwiftUndoRun {
    let history = UndoHistory()
    let coordinator: WriteCoordinator
    let window = TestWindow()

    private init(_ service: WriteService, _ fileSystem: RecordedWriteFileSystem, _ places: ExecPlaces, hasTrash: Bool) {
        let history = history
        coordinator = WriteCoordinator(
            writeService: service, fileSystem: fileSystem,
            options: WriteCoordinatorOptions(
                homePath: NSHomeDirectory(), recordUndo: { history.record($0) },
                // A disk without a Trash has none for Undo too, nor has any without the scenario's Trash.
                diskHasTrash: { hasTrash && places.hasTrash($0) }, undoHistory: history))
    }

    nonisolated static func make(
        _ service: WriteService, _ fileSystem: RecordedWriteFileSystem, _ places: ExecPlaces, hasTrash: Bool
    ) async -> SwiftUndoRun {
        await MainActor.run { SwiftUndoRun(service, fileSystem, places, hasTrash: hasTrash) }
    }

    /// The coordinator hears the paste's end on the main actor once the write service has let go of it: waits for it
    /// to be kept, when the paste's log is one the history keeps.
    nonisolated func waitForRecord(of records: [JSONValue]) async throws {
        let log = records.first { $0["kind"]?.stringValue == "result" }?["result"]?["undoLog"] ?? .null
        guard log != .null else { return }
        if log["undoable"] == .bool(true), log["units"]?.arrayValue?.isEmpty == true { return }
        let deadline = Date().addingTimeInterval(5)
        while await MainActor.run(body: { history.generation == 0 }) {
            if Date() >= deadline { throw OperationError("The paste was never kept for Undo.") }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    /// `runUndoAndRedo`.
    func run(_ script: ExecScenario.UndoScript, _ places: ExecPlaces) async throws -> [JSONValue] {
        var answers = script.answers ?? []
        var steps: [JSONValue] = []
        let directions: [UndoDirection] = script.redo ?? true ? [.undo, .redo] : [.undo]
        for direction in directions {
            let ops = (direction == .undo ? script.changes : script.redoChanges) ?? []
            try ExecScenario.apply(ops, in: places)
            var step: [String: JSONValue] = [
                "direction": .string(direction.rawValue), "changes": Self.json(ops, places),
                "menu": Self.json(history.menu()),
            ]
            var ticket: String?
            var counts = (nameTaken: 0, changed: 0)
            do {
                let prepared = try await coordinator.prepareUndo(direction)
                ticket = prepared.ticket
                counts = (prepared.nameTaken.count, prepared.changed.count)
                step["prepared"] = Self.json(prepared)
            } catch {
                step["prepared"] = .object(["error": .string(errorMessage(error))])
            }
            var asked: [JSONValue] = []
            var goAhead = ticket != nil
            for (kind, count) in [("nameTaken", counts.nameTaken), ("changed", counts.changed)]
            where goAhead && count > 0 {
                let answer = answers.isEmpty ? true : answers.removeFirst()
                asked.append(.object(["kind": .string(kind), "answer": .bool(answer)]))
                goAhead = answer
            }
            step["asked"] = .array(asked)
            step["start"] = .null
            if goAhead, let ticket {
                do {
                    let handle = try await coordinator.startUndo(ticket: ticket, window: window)
                    step["start"] = Self.json(try await end(handle.operationId))
                } catch {
                    step["start"] = .object(["error": .string(errorMessage(error))])
                }
            }
            step["after"] = try JSONValue.of(places.snapshotTree())
            step["trash"] = try JSONValue.of(places.snapshotTrash())
            step["menuAfter"] = Self.json(history.menu())
            steps.append(.object(step))
        }
        await coordinator.shutDown(maxWaitMs: 0)
        return steps
    }

    /// `undoEnd`: how an Undo or Redo ended, as its window is told.
    private func end(_ operationId: String) async throws -> WriteOperationEvent {
        let deadline = Date().addingTimeInterval(20)
        while true {
            if let end = window.end(of: operationId) { return end }
            if Date() >= deadline { throw OperationError("Timed out waiting for the end of the Undo.") }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    // MARK: JSON, every key as engine.ts writes it

    private static func optional(_ text: String?) -> JSONValue { text.map { .string($0) } ?? .null }

    static func json(_ menu: UndoMenuLabels) -> JSONValue {
        .object(["undo": optional(menu.undo), "redo": optional(menu.redo), "cantUndo": .bool(menu.cantUndo)])
    }

    /// What `undo:prepare` answered, without its ticket.
    static func json(_ prepared: UndoPrepared) -> JSONValue {
        .object([
            "refusal": optional(prepared.refusal?.rawValue), "label": optional(prepared.label),
            "action": optional(prepared.action?.rawValue),
            "nameTaken": .array(prepared.nameTaken.map { .string($0) }),
            "changed": .array(
                prepared.changed.map {
                    .object(["name": .string($0.name), "putBack": .bool($0.putBack), "replaced": .bool($0.replaced)])
                }),
        ])
    }

    static func json(_ end: WriteOperationEvent) -> JSONValue {
        .object([
            "status": .string(end.status.rawValue), "completedItemCount": .int(end.completedItemCount),
            "totalItemCount": .int(end.totalItemCount), "error": optional(end.result?.error),
            "items": .array(
                (end.result?.items ?? []).map {
                    .object([
                        "sourcePath": optional($0.sourcePath), "destinationPath": optional($0.destinationPath),
                        "status": .string($0.status.rawValue), "error": optional($0.error), "note": .bool($0.note),
                    ])
                }),
        ])
    }

    /// The changes as engine.ts is given them: each op with its path made absolute.
    static func json(_ ops: [ExecScenario.Change.Op], _ places: ExecPlaces) -> JSONValue {
        .array(
            ops.map { op in
                var object: [String: JSONValue] = ["op": .string(op.op), "path": .string(places.resolve(op.path))]
                if let content = op.content { object["content"] = .string(content) }
                if let mode = op.mode { object["mode"] = .string(mode) }
                return .object(object)
            })
    }
}
