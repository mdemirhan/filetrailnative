// Port of packages/core/src/fs/writeService.runtime.test.ts and of the runtime cases of
// packages/core/src/fs/writeService.analysis.test.ts
import FTFoundation
import FTTestSupport
import Foundation
import Testing
import os

@testable import FTOperations

/// What the person answers a question with: an answer (for the rest of the operation, perhaps), or Stop.
private struct Answer {
    var action: CopyPasteChoice
    var applyToRemaining = false
}

/// What a paste through the write service did.
private struct ServicePaste {
    var service: WriteService
    var events: [CopyPasteProgressEvent]
    var asked: [CopyPasteRuntimeConflict]
    var result: CopyPasteOperationResult?
}

/// Collects a paste's events and questions, from any thread.
private final class ServiceLog: Sendable {
    private struct State {
        var events: [CopyPasteProgressEvent] = []
        var asked: [CopyPasteRuntimeConflict] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func record(_ event: CopyPasteProgressEvent) { state.withLock { $0.events.append(event) } }
    func ask(_ conflict: CopyPasteRuntimeConflict) { state.withLock { $0.asked.append(conflict) } }
    var events: [CopyPasteProgressEvent] { state.withLock { $0.events } }
    var asked: [CopyPasteRuntimeConflict] { state.withLock { $0.asked } }
}

/// Runs a paste through the write service. `afterAnalysis` changes the disk between the review and the paste;
/// `answer` plays the person answering each question (nil: Stop), later on another thread, or from inside the
/// event listener before it returns (`answerSynchronously`).
private func runServicePaste(
    _ fileSystem: MockWriteServiceFileSystem, mode: CopyPasteMode = .copy, sources: [String], into destination: String,
    policy: CopyPastePolicy, overrides: ((CopyPasteAnalysisReport) -> [CopyPasteNodeOverride])? = nil,
    afterAnalysis: (() -> Void)? = nil, answer: (@Sendable (CopyPasteRuntimeConflict) -> Answer?)? = nil,
    answerSynchronously: Bool = false
) async throws -> ServicePaste {
    let service = WriteService(.init(fileSystem: fileSystem))
    let log = ServiceLog()
    _ = service.subscribe { event in
        log.record(event)
        guard event.status == .awaitingResolution, let conflict = event.runtimeConflict else { return }
        log.ask(conflict)
        let given = answer?(conflict)
        let respond = {
            guard let given else {
                service.cancelOperation(event.operationId)
                return
            }
            service.resolveRuntimeConflict(
                event.operationId, conflictId: conflict.conflictId, action: given.action,
                applyToRemaining: given.applyToRemaining)
        }
        if answerSynchronously {
            respond()
        } else {
            DispatchQueue.global().async(execute: respond)
        }
    }
    let analysisId = try service.startCopyPasteAnalysis(
        CopyPasteAnalysisRequest(mode: mode, sourcePaths: sources, destinationDirectoryPath: destination)
    ).analysisId
    #expect(await waitFor { try service.getCopyPasteAnalysisUpdate(analysisId).done })
    let report = try service.getCopyPasteAnalysisUpdate(analysisId).report
    afterAnalysis?()
    let operationId = try service.startCopyPaste(
        CopyPasteExecutionRequest(
            analysisId: analysisId, policy: policy, overrides: report.flatMap { report in overrides?(report) }))
        .operationId
    func result() -> CopyPasteOperationResult? {
        log.events.first { $0.operationId == operationId && $0.result != nil }?.result
    }
    #expect(await waitFor { result() != nil })
    return ServicePaste(service: service, events: log.events, asked: log.asked, result: result())
}

private let keepBoth = CopyPastePolicy(file: .keepBoth, directory: .merge, mismatch: .skip)

struct WriteServiceRuntimeTests {
    // T-bf2a01fb F-327
    @Test func appliesAStandingAnswerOnlyToConflictsOfTheSameKind() async throws {
        let fileSystem = MockWriteServiceFileSystem([
            ("/source/a.txt", .file(size: 1)), ("/source/b.txt", .file(size: 2)), ("/source/c.txt", .file(size: 3)),
            ("/target", .directory()),
        ])
        let run = try await runServicePaste(
            fileSystem, sources: ["/source/a.txt", "/source/b.txt", "/source/c.txt"], into: "/target",
            policy: keepBoth,
            afterAnalysis: {
                // "a" and "c" appear at the destination; "b" changes at the source.
                fileSystem.addFile("/target/a.txt", .file(size: 9))
                fileSystem.addFile("/target/c.txt", .file(size: 9))
                fileSystem.mutateNode("/source/b.txt") { $0.size = 20 }
            },
            answer: { conflict in
                conflict.reason == .destinationCreated
                    ? Answer(action: .keepBoth, applyToRemaining: true) : Answer(action: .skip)
            })

        // "Keep Both for the rest" answered "c", but said nothing about the changed "b".
        #expect(
            run.asked.map { [$0.sourcePath, $0.reason.rawValue] } == [
                ["/source/a.txt", "destination_created"], ["/source/b.txt", "source_changed"],
            ])
        #expect(
            run.result?.items.map { [$0.destinationPath, $0.status.rawValue] } == [
                ["/target/a copy.txt", "completed"], ["/target/b.txt", "skipped"], ["/target/c copy.txt", "completed"],
            ])
    }

    // T-23fe5269 F-327
    @Test func doesntReuseAKeepBothAnswerWhereTheDestinationNoLongerExists() async throws {
        let fileSystem = MockWriteServiceFileSystem([
            ("/source/a.txt", .file(size: 1)), ("/source/b.txt", .file(size: 2)), ("/target", .directory()),
            ("/target/a.txt", .file(size: 5)), ("/target/b.txt", .file(size: 5)),
        ])
        fileSystem.enableTrash()
        let run = try await runServicePaste(
            fileSystem, sources: ["/source/a.txt", "/source/b.txt"], into: "/target",
            policy: CopyPastePolicy(file: .overwrite, directory: .merge, mismatch: .skip),
            afterAnalysis: {
                fileSystem.mutateNode("/source/a.txt") { $0.size = 6 }
                fileSystem.mutateNode("/source/b.txt") { $0.size = 7 }
                fileSystem.deleteNode("/target/b.txt")
            },
            answer: { conflict in
                conflict.sourcePath == "/source/a.txt"
                    ? Answer(action: .keepBoth, applyToRemaining: true) : Answer(action: .overwrite)
            })

        // With nothing left at "b.txt" there is nothing to keep both of: asked again.
        #expect(
            run.asked.map { [$0.sourcePath, $0.reason.rawValue] } == [
                ["/source/a.txt", "source_changed"], ["/source/b.txt", "source_changed"],
            ])
        #expect(run.result?.items.map(\.destinationPath) == ["/target/a copy.txt", "/target/b.txt"])
    }

    // Replace answers the question about the item it showed: one put there while it was open is asked about
    // again, never sent to the Trash unseen.
    // T-7c41629f F-325 F-328
    @Test func asksAgainWhenTheItemAReplaceAnswerWasAboutChangedWhileItWasAsked() async throws {
        let fileSystem = MockWriteServiceFileSystem([
            ("/source/a.txt", .file(size: 1)), ("/target", .directory()), ("/target/a.txt", .file(size: 5)),
        ])
        fileSystem.enableTrash()
        let questions = OSAllocatedUnfairLock(initialState: 0)
        let run = try await runServicePaste(
            fileSystem, sources: ["/source/a.txt"], into: "/target",
            policy: CopyPastePolicy(file: .overwrite, directory: .merge, mismatch: .skip),
            afterAnalysis: { fileSystem.mutateNode("/target/a.txt") { $0.size = 6 } },
            answer: { _ in
                let question = questions.withLock { count in
                    count += 1
                    return count
                }
                if question == 1 {
                    fileSystem.mutateNode("/target/a.txt") { $0.size = 999 }
                    return Answer(action: .overwrite)
                }
                return Answer(action: .skip)
            })

        #expect(run.asked.map(\.reason) == [.destinationChanged, .destinationChanged])
        #expect(run.asked.dropFirst().first?.currentDestinationFingerprint.size == 999)
        #expect(fileSystem.trashed == [])
        #expect(run.result?.items.map(\.status) == [.skipped])
    }

    // A file saved again while its question was open is asked about again, as a new question: the window
    // remembers which question it answered by its id.
    // T-294d7878 F-328
    @Test func givesAQuestionAskedAgainAboutTheSameItemAnIdOfItsOwn() async throws {
        let fileSystem = MockWriteServiceFileSystem([("/source/a.txt", .file(size: 1)), ("/target", .directory())])
        let questions = OSAllocatedUnfairLock(initialState: 0)
        let run = try await runServicePaste(
            fileSystem, sources: ["/source/a.txt"], into: "/target", policy: keepBoth,
            afterAnalysis: { fileSystem.mutateNode("/source/a.txt") { $0.size = 2 } },
            answer: { _ in
                let question = questions.withLock { count in
                    count += 1
                    return count
                }
                if question == 1 {
                    fileSystem.mutateNode("/source/a.txt") { $0.size = 3 }
                }
                return Answer(action: .overwrite)
            })

        #expect(run.asked.map(\.reason) == [.sourceChanged, .sourceChanged])
        #expect(run.asked.count == 2 && run.asked[1].conflictId != run.asked[0].conflictId)
        #expect(run.result?.items.map(\.status) == [.completed])
    }

    // T-2b37961e F-328
    @Test func acceptsAnAnswerGivenWhileTheQuestionIsBeingAnnounced() async throws {
        let fileSystem = MockWriteServiceFileSystem([("/source/a.txt", .file(size: 1)), ("/target", .directory())])
        let run = try await runServicePaste(
            fileSystem, sources: ["/source/a.txt"], into: "/target", policy: keepBoth,
            afterAnalysis: { fileSystem.addFile("/target/a.txt", .file(size: 9)) },
            answer: { _ in Answer(action: .keepBoth) }, answerSynchronously: true)

        #expect(run.result?.status == .completed)
        #expect(fileSystem.readNode("/target/a copy.txt")?.size == 1)
    }

    // T-82406f22 F-326
    @Test func refusesAnAnswerTheConflictDoesntOfferAndKeepsWaitingForAValidOne() async throws {
        let fileSystem = MockWriteServiceFileSystem([("/source/a.txt", .file(size: 1)), ("/target", .directory())])
        let service = WriteService(.init(fileSystem: fileSystem))
        let refused = OSAllocatedUnfairLock(initialState: [Bool]())
        _ = service.subscribe { event in
            guard event.status == .awaitingResolution, let conflict = event.runtimeConflict else { return }
            // A deleted source can only be skipped; "merge" isn't even a file answer.
            let answers = [CopyPasteChoice.overwrite, .merge, .skip].map {
                service.resolveRuntimeConflict(event.operationId, conflictId: conflict.conflictId, action: $0)
            }
            refused.withLock { $0 += answers }
        }
        let log = ServiceLog()
        _ = service.subscribe { log.record($0) }
        let analysisId = try service.startCopyPasteAnalysis(
            CopyPasteAnalysisRequest(mode: .copy, sourcePaths: ["/source/a.txt"], destinationDirectoryPath: "/target")
        ).analysisId
        #expect(await waitFor { try service.getCopyPasteAnalysisUpdate(analysisId).done })
        try fileSystem.rm("/source/a.txt", recursive: false, force: false)
        _ = try service.startCopyPaste(CopyPasteExecutionRequest(analysisId: analysisId, policy: keepBoth))
        #expect(await waitFor { log.events.contains { $0.result != nil } })

        #expect(refused.withLock { $0 } == [false, false, true])
        let item = log.events.last?.result?.items.first
        #expect(item?.status == .skipped)
        #expect(item?.skipReason == .runtimeConflictResolution)
    }

    // T-45ccf3ee F-327
    @Test func givesARuntimeKeepBothCopyANameNoLaterItemOfThePasteWillUse() async throws {
        let fileSystem = MockWriteServiceFileSystem([
            ("/source/X.txt", .file(size: 1)), ("/source/X copy.txt", .file(size: 2)), ("/target", .directory()),
        ])
        let run = try await runServicePaste(
            fileSystem, mode: .cut, sources: ["/source/X.txt", "/source/X copy.txt"], into: "/target",
            policy: keepBoth, afterAnalysis: { fileSystem.addFile("/target/X.txt", .file(size: 9)) },
            answer: { _ in Answer(action: .keepBoth) })

        #expect(run.result?.status == .completed)
        // The result names where each item really went.
        #expect(
            run.result?.items.map { [$0.sourcePath, $0.destinationPath] } == [
                ["/source/X.txt", "/target/X copy 2.txt"], ["/source/X copy.txt", "/target/X copy.txt"],
            ])
        #expect(fileSystem.readNode("/target/X copy 2.txt")?.size == 1)
        #expect(fileSystem.readNode("/target/X copy.txt")?.size == 2)
        #expect(fileSystem.readNode("/target/X.txt")?.size == 9)
    }
}

struct WriteServiceRuntimeCoordinationTests {
    // T-384a8f35 F-242
    @Test func rejectsRuntimeConflictResolutionsForUnknownConflicts() {
        let service = WriteService(.init(fileSystem: MockWriteServiceFileSystem()))

        #expect(!service.resolveRuntimeConflict("missing-op", conflictId: "missing-conflict", action: .skip))
        #expect(!service.cancelCopyPasteAnalysis("missing-analysis"))
        #expect(!service.cancelOperation("missing-op"))
        #expect(throws: (any Error).self) { try service.getCopyPasteAnalysisUpdate("missing-analysis") }
    }

    // T-986eb932 F-242 F-257
    @Test func cancelsOperationsThatArePausedOnARuntimeConflict() async throws {
        let fileSystem = MockWriteServiceFileSystem([
            ("/source", .directory()), ("/source/file.txt", .file(size: 5)), ("/target", .directory()),
        ])
        let service = WriteService(
            .init(fileSystem: fileSystem, createOperationId: { "copy-op-1" }, createAnalysisId: { "analysis-1" }))
        let log = ServiceLog()
        _ = service.subscribe { event in
            log.record(event)
            if event.status == .awaitingResolution {
                DispatchQueue.global().async { service.cancelOperation(event.operationId) }
            }
        }
        _ = try service.startCopyPasteAnalysis(
            CopyPasteAnalysisRequest(mode: .copy, sourcePaths: ["/source/file.txt"], destinationDirectoryPath: "/target"))
        #expect(await waitFor { try service.getCopyPasteAnalysisUpdate("analysis-1").status == .complete })
        fileSystem.addFile("/target/file.txt", .file(size: 99))

        _ = try service.startCopyPaste(CopyPasteExecutionRequest(analysisId: "analysis-1", policy: .defaultCopyPaste))

        #expect(await waitFor { log.events.contains { $0.status == .cancelled } })
    }

    // A listener can't throw in Swift; what the original guards is that one listener can't keep the next from
    // its events: here the first one drops itself while an event is going out.
    // T-4b4ee729 F-242
    @Test func isolatesListenerFailuresSoLaterSubscribersStillReceiveTerminalEvents() async throws {
        let service = WriteService(
            .init(
                fileSystem: MockWriteServiceFileSystem([
                    ("/source", .directory()), ("/source/file.txt", .file(size: 5)), ("/target", .directory()),
                ]), createOperationId: { "listener-op" }, createAnalysisId: { "analysis-1" }))
        let unsubscribeFirst = OSAllocatedUnfairLock<(@Sendable () -> Void)?>(initialState: nil)
        let first = service.subscribe { _ in unsubscribeFirst.withLock { $0 }?() }
        unsubscribeFirst.withLock { $0 = first }
        let log = ServiceLog()
        _ = service.subscribe { log.record($0) }

        _ = try service.startCopyPasteAnalysis(
            CopyPasteAnalysisRequest(mode: .copy, sourcePaths: ["/source/file.txt"], destinationDirectoryPath: "/target"))
        #expect(await waitFor { try service.getCopyPasteAnalysisUpdate("analysis-1").status == .complete })
        _ = try service.startCopyPaste(CopyPasteExecutionRequest(analysisId: "analysis-1", policy: .defaultCopyPaste))

        #expect(await waitFor { log.events.contains { $0.status == .completed } })
    }
}
