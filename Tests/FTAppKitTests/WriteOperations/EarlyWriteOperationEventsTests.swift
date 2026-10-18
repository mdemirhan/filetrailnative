// Port of apps/desktop/src/renderer/lib/earlyWriteOperationEvents.test.ts, and the N/A marks of
// apps/desktop/src/renderer/hooks/useWriteOperations.test.ts
import FTFoundation
import FTOperations
import Foundation
import Testing

@testable import FTAppKit

private func progress(_ operationId: String, _ status: WriteOperationStatus, _ completed: Int = 0)
    -> WriteOperationEvent
{
    WriteOperationEvent(
        operationId: operationId, action: .paste, status: status, completedItemCount: completed,
        totalItemCount: 100_000)
}

/// A start request whose reply the test sends.
@MainActor
private final class StartRequest {
    private var continuation: CheckedContinuation<String, any Error>?

    func send() async throws -> String {
        try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func reply(_ operationId: String) {
        continuation?.resume(returning: operationId)
    }

    func refuse(_ message: String) {
        continuation?.resume(throwing: WriteCoordinatorError(message))
    }
}

@MainActor
@Suite struct EarlyWriteOperationEventsTests {
    /// Starts `request` while `early` keeps events, and waits until it is waiting.
    private func starting(_ early: EarlyWriteOperationEvents, _ request: StartRequest) async -> Task<String, any Error>
    {
        let task = Task { try await early.whileStarting { try await request.send() } }
        await Task.yield()
        await Task.yield()
        return task
    }

    // F-542 T-7fb2bc2c
    @Test func keepsNothingOfOtherWindowsOperationsWhileThisWindowStartsNone() {
        let early = EarlyWriteOperationEvents()

        for count in 0..<1_000 {
            early.note(progress("other-op", .running, count))
        }
        early.note(progress("other-op", .completed, 1_000))

        #expect(early.size == 0)
        #expect(early.take("other-op") == [])
    }

    // F-542 T-1c1eaa0a
    @Test func keepsTheNewestProgressAndTheEndOfAnOperationWhileAStartWaits() async throws {
        let early = EarlyWriteOperationEvents()
        let request = StartRequest()
        let started = await starting(early, request)

        early.note(progress("op-1", .queued))
        for count in 0..<1_000 {
            early.note(progress("op-1", .running, count))
        }
        early.note(progress("op-1", .completed, 1_000))
        #expect(early.size == 2)
        request.reply("op-1")

        #expect(
            try await early.take(started.value) == [
                progress("op-1", .running, 999), progress("op-1", .completed, 1_000),
            ])
        #expect(early.size == 0)
    }

    // F-542 T-e0929847
    @Test func keepsOnlyTheNewestFewOperations() async throws {
        let early = EarlyWriteOperationEvents()
        let request = StartRequest()
        let started = await starting(early, request)

        for index in 1...10 {
            early.note(progress("op-\(index)", .running))
            early.note(progress("op-\(index)", .completed))
        }
        #expect(early.size == 8)
        request.reply("op-10")

        #expect(try await early.take(started.value) == [progress("op-10", .running), progress("op-10", .completed)])
        #expect(early.take("op-7") == [])
    }

    // F-542 T-39a98554
    @Test func letsGoOfWhatItKeptWhenTheStartIsRefused() async {
        let early = EarlyWriteOperationEvents()
        let request = StartRequest()
        let started = await starting(early, request)
        early.note(progress("other-op", .running))

        request.refuse("Another write operation is already running.")

        await #expect(throws: WriteCoordinatorError.busy) { try await started.value }
        #expect(early.size == 0)
    }

    // F-542 T-6145c121
    @Test func forgetsAnOperationItHeardOfInAnotherWay() async {
        let early = EarlyWriteOperationEvents()
        let request = StartRequest()
        let started = await starting(early, request)
        early.note(progress("op-1", .running))
        early.note(progress("op-2", .running))

        early.forget("op-1")

        #expect(early.size == 1)
        request.reply("op-2")
        _ = try? await started.value
    }
}

// useWriteOperations' reducer is React's useReducer with useState-style setters; the window's write state is plain
// stored properties of ExplorerWriteSession, with nothing to patch field by field.
// N/A T-b808b63d React reducer: one field patched with a value has no counterpart.
// N/A T-430cc037 React reducer: functional updaters have no counterpart.
// N/A T-a75b62af React reducer: returning the same state object has no counterpart.
