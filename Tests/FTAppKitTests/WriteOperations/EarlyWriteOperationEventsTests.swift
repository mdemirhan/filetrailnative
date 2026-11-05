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

    @Test func keepsNothingOfOtherWindowsOperationsWhileThisWindowStartsNone() {
        let early = EarlyWriteOperationEvents()

        for count in 0..<1_000 {
            early.note(progress("other-op", .running, count))
        }
        early.note(progress("other-op", .completed, 1_000))

        #expect(early.size == 0)
        #expect(early.take("other-op") == [])
    }

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

    @Test func letsGoOfWhatItKeptWhenTheStartIsRefused() async {
        let early = EarlyWriteOperationEvents()
        let request = StartRequest()
        let started = await starting(early, request)
        early.note(progress("other-op", .running))

        request.refuse("Another write operation is already running.")

        await #expect(throws: WriteCoordinatorError.busy) { try await started.value }
        #expect(early.size == 0)
    }

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
