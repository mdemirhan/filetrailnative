import AppKit
import FTOperations
import Testing

@testable import FTAppKit

@Suite struct QuitWhileBusyTests {
    @Test func opensAWindowFromTheDockWhenNoExplorerWindowIsOpenEvenWithSettingsOpen() {
        #expect(QuitWhileBusy.shouldOpenWindowOnActivate(shutdownInProgress: false, explorerWindowCount: 0))
        #expect(!QuitWhileBusy.shouldOpenWindowOnActivate(shutdownInProgress: false, explorerWindowCount: 1))
    }

    @Test func doesntOpenOneWhileQuittingWaitsForAnOperationToStop() {
        #expect(!QuitWhileBusy.shouldOpenWindowOnActivate(shutdownInProgress: true, explorerWindowCount: 0))
    }

    @Test func asksAboutACopyAMoveATrashAndADeleteInTheirOwnWords() {
        let copy = QuitWhileBusy.describe(.copy)
        #expect(copy?.message == "A copy is still in progress.")
        #expect(
            copy?.detail
                == "If you quit now, it stops after the current item. Items already copied stay where they are; a folder still being copied isn't left half copied."
        )
        let move = QuitWhileBusy.describe(.move)
        #expect(move?.message == "A move is still in progress.")
        #expect(
            move?.detail
                == "If you quit now, it stops after the current item. Items already moved stay in their new place, and the rest stay where they were. A folder being moved to another disk may already be there in full, with some of its items still in the old place too."
        )
        #expect(QuitWhileBusy.describe(.trash)?.message == "Items are still being moved to the Trash.")
        #expect(QuitWhileBusy.describe(.delete)?.detail.contains("can't be recovered") == true)
        #expect(QuitWhileBusy.describe(.undo)?.message == "An Undo is still in progress.")
        #expect(QuitWhileBusy.describe(.redo)?.message == "A Redo is still in progress.")
        #expect(QuitWhileBusy.describe(.redo)?.detail.hasSuffix("What was already redone stays redone.") == true)
    }

    // A Redo is named as a Redo, not an Undo, and every kind the write coordinator reports has its question.
    @Test func namesEachRunningOperationAsTheCoordinatorReportsIt() {
        #expect(WriteOperationKind(.redo) == .redo)
        #expect(WriteOperationKind(.undo) == .undo)
        for kind in WriteOperationKind.allCases {
            #expect(BusyOperationKind(rawValue: kind.rawValue) != nil, "\(kind)")
        }
    }

    @Test func doesntAskAboutARenameOrANewFolderWhichAreOverInAMoment() {
        #expect(QuitWhileBusy.describe(.rename) == nil)
        #expect(QuitWhileBusy.describe(.newFolder) == nil)
    }

    @Test func asksAboutARenameOfSeveralItems() {
        let question = QuitWhileBusy.describe(.batchRename, trigger: .close)
        #expect(question?.message == "Items are still being renamed.")
        #expect(
            question?.detail
                == "If you close the window now, it stops after the current item. Items already renamed keep their new names; the rest keep their old ones."
        )
    }

    @Test func asksBeforeQuittingWhileTheTrashIsEmptiedWithoutOfferingToStopIt() {
        let question = QuitWhileBusy.describe(.emptyTrash)
        #expect(question?.message == "The Trash is still being emptied.")
        #expect(question?.detail == "Finder goes on emptying it after File Trail quits.")
        #expect(QuitWhileBusy.buttons(.quit, kind: .emptyTrash) == ["Keep Working", "Quit"])
        #expect(QuitWhileBusy.describe(.emptyTrash, trigger: .close) == nil)
    }

    @Test func makesKeepWorkingTheDefaultAndStopAndQuitTheSecondButton() {
        #expect(QuitWhileBusy.buttons(.quit)[QuitWhileBusy.keepWorkingButtonIndex] == "Keep Working")
        #expect(QuitWhileBusy.buttons(.quit)[QuitWhileBusy.stopButtonIndex] == "Stop and Quit")
    }

    @Test func asksInItsOwnWordsWhenTheWindowIsBeingClosed() {
        #expect(QuitWhileBusy.buttons(.close) == ["Keep Working", "Stop and Close"])
        let question = QuitWhileBusy.describe(.copy, trigger: .close)
        #expect(question?.message == "A copy is still in progress.")
        #expect(
            question?.detail
                == "If you close the window now, it stops after the current item. Items already copied stay where they are; a folder still being copied isn't left half copied."
        )
        #expect(QuitWhileBusy.describe(.rename, trigger: .close) == nil)
    }
}

@MainActor
@Suite struct QuitCoordinatorTests {
    private final class Run {
        var order: [String] = []
        var questions: [StopQuestion] = []
        var answer = QuitWhileBusy.keepWorkingButtonIndex
        var operation: BusyOperationKind?
        var windowOpen = true
        var forward = 0
        var shutDownGate: CheckedContinuation<Void, Never>?
        var holdShutDown = false
    }

    private func coordinator(_ run: Run) -> QuitCoordinator {
        var hooks = QuitCoordinator.Hooks()
        hooks.activeOperation = { run.operation }
        hooks.anyWindowOpen = { run.windowOpen }
        hooks.showStopQuestion = { question, _ in
            run.questions.append(question)
            run.order.append("asked")
            return run.answer
        }
        hooks.bringStopQuestionForward = { run.forward += 1 }
        hooks.recordAllBounds = { run.order.append("bounds") }
        hooks.flushStore = { run.order.append("flush") }
        hooks.shutDown = {
            run.order.append("shutDown")
            if run.holdShutDown { await withCheckedContinuation { run.shutDownGate = $0 } }
        }
        hooks.exit = { run.order.append("exit") }
        return QuitCoordinator(hooks: hooks)
    }

    @Test func asksFirstWhileACopyRunsAndKeepsWorkingWhenToldTo() async {
        let run = Run()
        run.operation = .copy
        let quit = coordinator(run)

        let outcome = await quit.quit()

        #expect(outcome == .keptWorking)
        #expect(run.questions.map(\.buttons) == [["Keep Working", "Stop and Quit"]])
        #expect(run.questions.first?.message == "A copy is still in progress.")
        #expect(run.order == ["asked"])
        #expect(!quit.shutdownInProgress)
    }

    @Test func recordsTheWindowsWritesTheStoreWaitsForTheWorkToStopThenExits() async {
        let run = Run()
        run.operation = .copy
        run.answer = QuitWhileBusy.stopButtonIndex
        let quit = coordinator(run)

        let outcome = await quit.quit()

        #expect(outcome == .exited)
        #expect(quit.shutdownInProgress)
        // The store is written before the work is stopped, in case that never ends, and again after.
        #expect(run.order == ["asked", "bounds", "flush", "shutDown", "bounds", "flush", "exit"])
    }

    @Test func writesWhatChangedWhileItWaitedForTheWorkToStop() async {
        let run = Run()
        let quit = coordinator(run)

        await quit.quit()

        #expect(run.order.filter { $0 == "flush" }.count == 2)
        #expect(run.order.last == "exit")
    }

    @Test func quitsWithoutAskingWithNoWindowOpen() async {
        let run = Run()
        run.operation = .copy
        run.windowOpen = false
        let quit = coordinator(run)

        let outcome = await quit.quit()

        #expect(outcome == .exited)
        #expect(run.questions.isEmpty)
    }

    // (the window the question hangs from is the front one, none with only Settings open)
    @Test func asksOnceAndAsksNothingOfARenameOrANewFolder() async {
        let run = Run()
        run.operation = .newFolder
        let quit = coordinator(run)

        let outcome = await quit.quit()

        #expect(outcome == .exited)
        #expect(run.questions.isEmpty)
    }

    @Test func bringsTheQuestionForwardWhenAnotherQuitComesWhileItIsOpen() async {
        let run = Run()
        run.operation = .move
        let quit = coordinator(run)
        var hooks = quit.hooks
        var second: QuitCoordinator.Outcome?
        hooks.showStopQuestion = { question, _ in
            run.questions.append(question)
            second = await quit.quit()
            return QuitWhileBusy.keepWorkingButtonIndex
        }
        quit.hooks = hooks

        let first = await quit.quit()

        #expect(second == .questionBroughtForward)
        #expect(first == .keptWorking)
        #expect(run.forward == 1)
        #expect(run.questions.count == 1)
    }

    // (a second quit while shutdown waits does not cut it short)
    @Test func doesNotCutShutdownShortWithASecondQuit() async {
        let run = Run()
        run.holdShutDown = true
        let quit = coordinator(run)

        let first = Task { await quit.quit() }
        while run.shutDownGate == nil { await Task.yield() }
        let second = await quit.quit()
        run.shutDownGate?.resume()
        let result = await first.value

        #expect(second == .alreadyShuttingDown)
        #expect(result == .exited)
        #expect(run.order.filter { $0 == "exit" }.count == 1)
    }

}
