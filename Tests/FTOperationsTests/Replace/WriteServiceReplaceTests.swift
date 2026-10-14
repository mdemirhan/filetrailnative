// Port of the Replace cases of packages/core/src/fs/writeService.runtime.test.ts and writeService.analysis.test.ts
// (their other cases are in WriteService/WriteServiceRuntimeTests.swift), through the write service
import FTFoundation
import FTTestSupport
import Foundation
import Testing
import os

@testable import FTOperations

private struct Answer {
    var action: CopyPasteChoice
    var applyToRemaining = false
}

private final class ServiceRecord: Sendable {
    private let state = OSAllocatedUnfairLock(
        initialState: (events: [CopyPasteProgressEvent](), asked: [CopyPasteRuntimeConflict]()))

    func record(_ event: CopyPasteProgressEvent) { state.withLock { $0.events.append(event) } }
    func ask(_ conflict: CopyPasteRuntimeConflict) { state.withLock { $0.asked.append(conflict) } }
    var events: [CopyPasteProgressEvent] { state.withLock { $0.events } }
    var asked: [CopyPasteRuntimeConflict] { state.withLock { $0.asked } }
}

/// Runs a paste through the write service. `afterAnalysis` changes the disk between the review and the paste;
/// `answer` plays the person answering each question (nil: Stop), later, on another thread.
private func servicePaste(
    _ fileSystem: MockWriteServiceFileSystem, sources: [String], into destination: String, policy: CopyPastePolicy,
    overrides: ((CopyPasteAnalysisReport) -> [CopyPasteNodeOverride])? = nil, afterAnalysis: (() -> Void)? = nil,
    answer: (@Sendable (CopyPasteRuntimeConflict) -> Answer?)? = nil
) async throws -> (asked: [CopyPasteRuntimeConflict], result: CopyPasteOperationResult?) {
    let service = WriteService(.init(fileSystem: fileSystem))
    let record = ServiceRecord()
    _ = service.subscribe { event in
        record.record(event)
        guard event.status == .awaitingResolution, let conflict = event.runtimeConflict else { return }
        record.ask(conflict)
        let given = answer?(conflict)
        DispatchQueue.global().async {
            guard let given else {
                service.cancelOperation(event.operationId)
                return
            }
            service.resolveRuntimeConflict(
                event.operationId, conflictId: conflict.conflictId, action: given.action,
                applyToRemaining: given.applyToRemaining)
        }
    }
    let analysisId = try service.startCopyPasteAnalysis(
        CopyPasteAnalysisRequest(mode: .copy, sourcePaths: sources, destinationDirectoryPath: destination)
    ).analysisId
    #expect(await waitFor { try service.getCopyPasteAnalysisUpdate(analysisId).done })
    let report = try service.getCopyPasteAnalysisUpdate(analysisId).report
    afterAnalysis?()
    let operationId = try service.startCopyPaste(
        CopyPasteExecutionRequest(
            analysisId: analysisId, policy: policy, overrides: report.flatMap { report in overrides?(report) })
    ).operationId
    func result() -> CopyPasteOperationResult? {
        record.events.first { $0.operationId == operationId && $0.result != nil }?.result
    }
    #expect(await waitFor { result() != nil })
    return (record.asked, result())
}

private let overwriteFiles = CopyPastePolicy(file: .overwrite, directory: .merge, mismatch: .skip)
private let overwriteFilesAndFolders = CopyPastePolicy(file: .overwrite, directory: .overwrite, mismatch: .skip)

struct WriteServiceReplaceTests {
    // T-30a95e18 F-339 F-522
    @Test func asksAgainWhenTheItemAReplaceAnswerWasAboutChangesJustBeforeTheReplace() async throws {
        let fileSystem = MockWriteServiceFileSystem([
            ("/source/a.txt", .file(size: 1)), ("/target", .directory()), ("/target/a.txt", .file(size: 5)),
        ])
        fileSystem.enableTrash()
        let answered = Locked(false)
        let changed = Locked(false)
        fileSystem.lstatImpl = { path in
            let stats = try fileSystem.lstatDirectly(path)
            if path == "/target/a.txt" && answered.value && !changed.value {
                changed.mutate { $0 = true }
                fileSystem.mutateNode("/target/a.txt") { $0.size = 999 }
            }
            return stats
        }

        let (asked, result) = try await servicePaste(
            fileSystem, sources: ["/source/a.txt"], into: "/target", policy: overwriteFiles,
            afterAnalysis: { fileSystem.mutateNode("/target/a.txt") { $0.size = 6 } },
            answer: { _ in
                if answered.value {
                    return Answer(action: .skip)
                }
                answered.mutate { $0 = true }
                return Answer(action: .overwrite)
            })

        #expect(changed.value)
        #expect(asked.map(\.reason) == [.destinationChanged, .destinationChanged])
        #expect(fileSystem.trashed == [])
        #expect(result?.items.map(\.status) == [.skipped])
    }

    // On a disk with no Trash a folder replaced is deleted for good: one that took in an item since the review, or
    // while the question about deleting it was open, is kept, never deleted with an item the person didn't see.
    // T-16d927c2 F-343 F-501
    @Test(arguments: ["afterAnalysis", "answer"])
    func keepsAFolderThatTookInAnItemInsteadOfDeletingItForGood(at: String) async throws {
        let fileSystem = MockWriteServiceFileSystem([
            ("/source/F", .directory()), ("/source/F/a.txt", .file(size: 1)), ("/target", .directory()),
            ("/target/F", .directory()), ("/target/F/old.txt", .file(size: 5)),
        ])
        let addItem: @Sendable () -> Void = { fileSystem.addFile("/target/F/new.txt", .file(size: 2)) }

        let (asked, result) = try await servicePaste(
            fileSystem, sources: ["/source/F"], into: "/target", policy: overwriteFilesAndFolders,
            afterAnalysis: {
                if at == "afterAnalysis" {
                    addItem()
                }
            },
            answer: { _ in
                if at == "answer" {
                    addItem()
                }
                return Answer(action: .overwrite)
            })

        #expect(asked.map(\.reason) == [.trashUnavailable])
        #expect(fileSystem.exists("/target/F/old.txt"))
        #expect(fileSystem.exists("/target/F/new.txt"))
        let item = result?.items.first { $0.sourcePath == "/source/F" }
        #expect(item?.status == .failed)
        #expect(
            item?.error
                == "\u{201C}F\u{201D} changed while it was being replaced, so it was kept and nothing was replaced.")
    }

    // The folder a question about the destination showed wasn't counted by the review: it is counted before the
    // no-Trash question, so an item it takes in meanwhile still keeps it.
    // T-0973956f F-343 F-501
    @Test func keepsAFolderAgreedToAtAQuestionThatTookInAnItemWhileDeletingItWasAsked() async throws {
        let fileSystem = MockWriteServiceFileSystem([
            ("/source/F", .directory()), ("/source/F/a.txt", .file(size: 1)), ("/target", .directory()),
            ("/target/F", .directory()), ("/target/F/old.txt", .file(size: 5)),
        ])

        let (asked, result) = try await servicePaste(
            fileSystem, sources: ["/source/F"], into: "/target", policy: overwriteFilesAndFolders,
            // Another folder of that name since the review.
            afterAnalysis: {
                fileSystem.deleteNode("/target/F/old.txt")
                fileSystem.deleteNode("/target/F")
                fileSystem.addDirectory("/target/F")
                fileSystem.addFile("/target/F/other.txt", .file(size: 3))
            },
            answer: { conflict in
                if conflict.reason == .trashUnavailable {
                    fileSystem.addFile("/target/F/new.txt", .file(size: 2))
                }
                return Answer(action: .overwrite)
            })

        #expect(asked.map(\.reason) == [.destinationChanged, .trashUnavailable])
        #expect(fileSystem.exists("/target/F/new.txt"))
        #expect(fileSystem.exists("/target/F/other.txt"))
        #expect(result?.items.first { $0.sourcePath == "/source/F" }?.status == .failed)
    }

    // T-89d07db7 F-522
    @Test func keepsTheReviewsChoicesForItemsInsideAFolderMergedAtRuntime() async throws {
        let fileSystem = MockWriteServiceFileSystem([
            ("/source/D", .directory()), ("/source/D/c.txt", .file(size: 1)), ("/source/D/d.txt", .file(size: 2)),
            ("/target/D", .directory()), ("/target/D/c.txt", .file(size: 8)), ("/target/D/d.txt", .file(size: 9)),
        ])
        fileSystem.enableTrash()

        let (_, result) = try await servicePaste(
            fileSystem, sources: ["/source/D"], into: "/target", policy: overwriteFilesAndFolders,
            // In the review the person kept the existing "c.txt".
            overrides: { report in
                [CopyPasteNodeOverride(nodeId: "\(report.nodes.first?.id ?? "")/c.txt", action: .skip)]
            },
            // Someone replaces the folder "D" before the paste reaches it.
            afterAnalysis: {
                fileSystem.deleteNode("/target/D")
                fileSystem.addDirectory("/target/D", .directory(ino: 999))
            },
            answer: { $0.reason == .destinationChanged ? Answer(action: .merge) : Answer(action: .skip) })

        #expect(result?.status == .partial)
        #expect(fileSystem.readNode("/target/D/c.txt")?.size == 8)
        #expect(fileSystem.readNode("/target/D/d.txt")?.size == 2)
    }

    // T-f21a582c F-521
    @Test func startsExecutionFromAnExistingAnalysisIdAndResolvesRuntimeConflicts() async throws {
        let fileSystem = MockWriteServiceFileSystem([
            ("/source", .directory()), ("/source/file.txt", .file(size: 5)), ("/target", .directory()),
        ])
        let service = WriteService(
            .init(fileSystem: fileSystem, createOperationId: { "copy-op-1" }, createAnalysisId: { "analysis-1" }))
        let record = ServiceRecord()
        _ = service.subscribe { event in
            record.record(event)
            if event.status == .awaitingResolution, let conflictId = event.runtimeConflict?.conflictId {
                DispatchQueue.global().async {
                    service.resolveRuntimeConflict(event.operationId, conflictId: conflictId, action: .overwrite)
                }
            }
        }

        _ = try service.startCopyPasteAnalysis(
            CopyPasteAnalysisRequest(
                mode: .copy, sourcePaths: ["/source/file.txt"], destinationDirectoryPath: "/target"))
        #expect(await waitFor { try service.getCopyPasteAnalysisUpdate("analysis-1").status == .complete })

        fileSystem.addFile("/target/file.txt", .file(size: 99))
        let handle = try service.startCopyPaste(
            CopyPasteExecutionRequest(
                analysisId: "analysis-1", policy: CopyPastePolicy(file: .skip, directory: .skip, mismatch: .skip)))
        #expect(handle == CopyPasteOperationHandle(operationId: "copy-op-1", status: .queued))

        #expect(
            await waitFor {
                record.events.contains { $0.operationId == "copy-op-1" && $0.status == .completed }
            })
        #expect(record.events.contains { $0.operationId == "copy-op-1" && $0.status == .awaitingResolution })
        #expect(fileSystem.readNode("/target/file.txt")?.size == 5)
    }
}

struct VolumeReplaceTests {
    private func visible(_ folder: String) -> [String] {
        Disk.list(folder).filter { !$0.hasPrefix(".") }
    }

    // T-b2ed4325 F-482
    @Test(.tags(.diskImage), .diskImages)
    func replacesAFileThereRemovingTheOriginalOnlyOnceTheNewOneIsInPlace() async throws {
        try await withTemporaryDirectory { root in
            try await DiskImage.withVolume(.apfs) { volume in
                let src = root.path + "/src"
                try Disk.write(src + "/a.txt", "new")
                try Disk.write(volume.path + "/a.txt", "old")
                let volumeTrash = volume.path + "/.test-trash"
                try Disk.makeDirectories(volumeTrash)

                let run = try await runPaste(
                    mode: .cut, sources: [src + "/a.txt"], into: volume.path, policy: NativePaste.replaceAll,
                    // The Trash of the disk the replaced item is on.
                    fileSystem: NativePaste.withTrash(volumeTrash))

                #expect(run.result?.status == .completed)
                #expect(Disk.read(volume.path + "/a.txt") == "new")
                #expect(visible(volume.path) == ["a.txt"])
                #expect(visible(src) == [])
                #expect(Disk.read(volumeTrash + "/1-a.txt") == "old")
            }
        }
    }

    // T-632ee76c F-342
    @Test(.tags(.diskImage), .diskImages, arguments: [DiskImage.Kind.fat32, .exfat])
    func replacesEmptyFilesInsideAMergedFolder(kind: DiskImage.Kind) async throws {
        try await DiskImage.withVolume(kind) { stick in
            try Disk.write(stick.path + "/src/pkg/__init__.py", "")
            try Disk.write(stick.path + "/dst/pkg/__init__.py", "")
            try Disk.makeDirectories(stick.path + "/.test-trash")

            let run = try await runPaste(
                mode: .copy, sources: [stick.path + "/src/pkg"], into: stick.path + "/dst", policy: overwriteFiles,
                fileSystem: NativePaste.withTrash(stick.path + "/.test-trash"))

            #expect(run.result?.status == .completed)
        }
    }
}

struct PackageReplaceTests {
    // T-e5058a23 F-494 F-342
    @Test func replacesTheExistingOneWholeKeepingNothingOfIt() async throws {
        try await withTemporaryDirectory { root in
            let (src, dst, trash) = (root.path + "/src", root.path + "/dst", root.path + "/trash")
            try Disk.write(src + "/Foo.app/Contents/Info.plist", "v2")
            try Disk.write(src + "/Foo.app/Contents/new.png", "new.png")
            try Disk.write(dst + "/Foo.app/Contents/Info.plist", "v1")
            try Disk.write(dst + "/Foo.app/Contents/old.png", "old.png")
            try Disk.makeDirectories(trash)

            let run = try await runPaste(
                mode: .copy, sources: [src + "/Foo.app"], into: dst, policy: NativePaste.replaceAll,
                fileSystem: NativePaste.withTrash(trash))

            #expect(run.result?.status == .completed)
            #expect(Disk.list(dst + "/Foo.app/Contents") == ["Info.plist", "new.png"])
            #expect(Disk.list(trash) == ["1-Foo.app"])
        }
    }
}
