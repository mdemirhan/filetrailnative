// Port of the "emptying the Trash" describe of apps/desktop/src/main/bootstrap/writeOperations.test.ts
import FTFileSystem
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTOperations

@MainActor
@Suite(.localOperationHang) struct EmptyTrashTests {
    /// An Empty Trash whose Finder the test answers for.
    @MainActor
    final class HeldEmpty {
        private var continuation: CheckedContinuation<(ok: Bool, error: String?), Never>?
        private var waiters: [CheckedContinuation<Void, Never>] = []
        var isWaiting: Bool { continuation != nil }

        func empty() async -> (ok: Bool, error: String?) {
            await withCheckedContinuation {
                continuation = $0
                for waiter in waiters { waiter.resume() }
                waiters = []
            }
        }

        /// Returns once Finder is being asked: told when it is, not polled for until a deadline.
        func waiting() async {
            if isWaiting { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func finish(_ outcome: (ok: Bool, error: String?) = (true, nil)) {
            continuation?.resume(returning: outcome)
            continuation = nil
        }
    }

    // Items replaced by a running paste are on their way to the Trash; emptying it then would delete them for good.
    // F-304 T-932ae3fa
    @Test func waitsItsTurnRefusedWhileAnotherOperationRuns() async throws {
        let held = HeldCall()
        let fileSystem = TestLocalFileSystem.stub()
        fileSystem.rmImpl = { _, _, _ in held.hold() }
        let coordinator = WriteCoordinator.local(fileSystem, homePath: "/Users/demo")
        let window = TestWindow()
        var emptied = 0
        try await coordinator.deleteImmediately(paths: ["/Users/demo/.Trash/a.txt"], window: window)
        await held.begun()

        let refused = await coordinator.emptyTrash {
            emptied += 1
            return (true, nil)
        }
        #expect(refused.ok == false)
        #expect(
            refused.error
                == "The Trash can't be emptied while another operation is running. Try again when it has finished.")
        #expect(emptied == 0)

        held.release()
        _ = await window.ended("write-op-1")
        let outcome = await coordinator.emptyTrash {
            emptied += 1
            return (true, nil)
        }
        #expect(outcome.ok && outcome.error == nil)
        #expect(emptied == 1)
        await coordinator.shutDown(maxWaitMs: 0)
    }

    // F-304 T-7a64b1e5
    @Test func holdsTheWriteSlotWhileEmptyingSoNothingStartsAlongside() async throws {
        let coordinator = WriteCoordinator.local(.stub())
        let held = HeldEmpty()
        let emptying = Task { await coordinator.emptyTrash { await held.empty() } }
        await held.waiting()

        await #expect(throws: WriteCoordinatorError.busy) {
            try await coordinator.trash(paths: ["/Users/demo/a.txt"], window: TestWindow())
        }
        #expect(WriteCoordinatorError.busy.message == "Another write operation is already running.")

        held.finish()
        _ = await emptying.value
        await coordinator.shutDown(maxWaitMs: 0)
    }

    // Other windows were refused with nothing to show for it, and quitting didn't ask.
    // F-304 T-d8a45f00
    @Test func runsAsAnOperationOfItsOwnWhichTheOtherWindowsAndQuittingSee() async throws {
        let coordinator = WriteCoordinator.local(.stub())
        let held = HeldEmpty()
        let emptying = Task { await coordinator.emptyTrash { await held.empty() } }
        await held.waiting()

        let active = try #require(coordinator.activeOperation)
        #expect(active.kind == .emptyTrash)
        #expect(coordinator.activeOperationId == active.operationId)

        held.finish()
        _ = await emptying.value
        #expect(coordinator.activeOperation == nil)
        #expect(coordinator.activeOperationId == nil)
        await coordinator.shutDown(maxWaitMs: 0)
    }

    // Finder goes on emptying it after File Trail quits.
    // F-305 T-59d7a463
    @Test func doesntHoldQuittingUpWhileFinderEmptiesTheTrash() async throws {
        let coordinator = WriteCoordinator.local(.stub())
        let held = HeldEmpty()
        let emptying = Task { await coordinator.emptyTrash { await held.empty() } }
        await held.waiting()

        let started = Date()
        await coordinator.shutDown(maxWaitMs: 60_000)
        #expect(Date().timeIntervalSince(started) < 0.5)
        held.finish()
        _ = await emptying.value
    }

    // The coordinator forgot the Trash's size, but each window kept showing its own.
    // F-305 T-63f49a11
    @Test func tellsTheWindowsOnceTheTrashWasEmptiedOrTriedToBeAndNotWhenRefused() async throws {
        var told = 0
        let coordinator = WriteCoordinator.local(
            .stub(), options: WriteCoordinatorOptions(onTrashEmptied: { told += 1 }))

        _ = await coordinator.emptyTrash { (true, nil) }
        #expect(told == 1)
        // Part of it may be gone all the same.
        _ = await coordinator.emptyTrash { (false, "Finder stopped.") }
        #expect(told == 2)

        await coordinator.shutDown(maxWaitMs: 0)
        _ = await coordinator.emptyTrash { (true, nil) }
        #expect(told == 2)
    }
}
