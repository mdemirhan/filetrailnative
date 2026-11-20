// A folder a disk is mounted in is never replaced: what would go to the Trash, or be deleted for good, is that disk
import Darwin
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTOperations

struct MountPointReplaceTests {
    private static let reviewNote = "It is a disk mounted here."
    private static func refusal(_ name: String) -> String {
        "Can't replace \u{201C}\(name)\u{201D} because it is a disk mounted here."
    }

    /// "/dst/Photos" is where a disk is mounted (another device than "/dst"), and a folder "Photos" is pasted
    /// into "/dst".
    private func mountedInDestination() -> MockWriteServiceFileSystem {
        let fileSystem = MockWriteServiceFileSystem([
            ("/src", .directory()), ("/src/Photos", .directory()), ("/src/Photos/new.jpg", .file(size: 3)),
            ("/dst", .directory()), ("/dst/Photos", .directory(dev: 2)), ("/dst/Photos/kept.jpg", .file(size: 7)),
            ("/dst/Photos/album", .directory()), ("/dst/Photos/album/old.jpg", .file(size: 9)),
        ])
        fileSystem.enableTrash()
        return fileSystem
    }

    private func review(_ fileSystem: MockWriteServiceFileSystem, _ mode: CopyPasteMode) throws
        -> CopyPasteAnalysisReport
    {
        try buildCopyPasteAnalysisReport(
            analysisId: "analysis-1",
            request: CopyPasteAnalysisRequest(
                mode: mode, sourcePaths: ["/src/Photos"], destinationDirectoryPath: "/dst"),
            fileSystem: fileSystem)
    }

    /// Nothing went to the Trash or was removed, nothing is under a hidden name, and the pasted folder is where
    /// it was.
    private func expectUntouched(_ fileSystem: MockWriteServiceFileSystem) throws {
        #expect(fileSystem.trashed == [])
        #expect(try fileSystem.readdir("/dst") == ["Photos"])
        #expect(try fileSystem.readdir("/dst/Photos") == ["album", "kept.jpg"])
        #expect(fileSystem.readNode("/dst/Photos/kept.jpg")?.size == 7)
        #expect(fileSystem.readNode("/dst/Photos/album/old.jpg")?.size == 9)
        #expect(try fileSystem.readdir("/src") == ["Photos"])
        #expect(fileSystem.readNode("/src/Photos/new.jpg")?.size == 3)
    }

    // The review says so on the row, and Replace for all isn't taken for it.
    @Test(arguments: [CopyPasteMode.copy, .cut])
    func theReviewSaysADiskMountedInTheFolderCantBeReplaced(mode: CopyPasteMode) throws {
        let fileSystem = mountedInDestination()

        let report = try review(fileSystem, mode)

        let node = try #require(report.nodes.first)
        #expect(node.conflictClass == .directoryConflict)
        #expect(node.replaceBlockedReason == Self.reviewNote)
        let resolved = try resolveAnalysisWithPolicy(
            report: report, policy: NativePaste.replaceAll, fileSystem: fileSystem)
        #expect(resolved.first?.action == .merge)
    }

    // Inside a folder that is merged, the folder holding it is the merged one. The folders on their folder's own
    // disk, beside it and around it, are replaced as ever.
    @Test func aDiskMountedInsideAMergedFolderCantBeReplacedEither() throws {
        let fileSystem = MockWriteServiceFileSystem([
            ("/src/Trip", .directory()), ("/src/Trip/Photos", .directory()), ("/src/Trip/Notes", .directory()),
            ("/dst/Trip", .directory()), ("/dst/Trip/Photos", .directory(dev: 2)), ("/dst/Trip/Notes", .directory()),
            ("/dst/Trip/Photos/kept.jpg", .file(size: 7)),
        ])

        let report = try buildCopyPasteAnalysisReport(
            analysisId: "analysis-1",
            request: CopyPasteAnalysisRequest(
                mode: .copy, sourcePaths: ["/src/Trip"], destinationDirectoryPath: "/dst"),
            fileSystem: fileSystem)

        let trip = try #require(report.nodes.first)
        #expect(trip.conflictClass == .directoryConflict)
        #expect(trip.replaceBlockedReason == nil)
        let photos = try #require(trip.children.first { $0.sourcePath == "/src/Trip/Photos" })
        #expect(photos.replaceBlockedReason == Self.reviewNote)
        let notes = try #require(trip.children.first { $0.sourcePath == "/src/Trip/Notes" })
        #expect(notes.conflictClass == .directoryConflict)
        #expect(notes.replaceBlockedReason == nil)
    }

    // A plan made without the review's note (or a Replace answered while the paste runs): the paste itself refuses,
    // before the pasted folder is moved aside and before anything goes to the Trash.
    @Test(arguments: [CopyPasteMode.copy, .cut])
    func thePasteItselfRefusesWhenThePlanSaysReplace(mode: CopyPasteMode) async throws {
        let fileSystem = mountedInDestination()
        var report = try review(fileSystem, mode)
        report.nodes[0].replaceBlockedReason = nil
        let resolvedNodes = try resolveAnalysisWithPolicy(
            report: report, policy: NativePaste.replaceAll, fileSystem: fileSystem)
        #expect(resolvedNodes.first?.action == .overwrite)

        let events = await execute(
            fileSystem, (report, resolvedNodes), operationId: "op-1", policy: NativePaste.replaceAll)

        let result = try #require(events.last?.result)
        let refused = itemFor(result, "/src/Photos")
        #expect(refused?.status == .failed)
        #expect(refused?.error == Self.refusal("Photos"))
        #expect(result.replacedPaths == nil)
        try expectUntouched(fileSystem)
    }

    // A disk mounted there after the review: the folder the review agreed to replace is a disk by the time the
    // paste reaches it.
    @Test(arguments: [CopyPasteMode.copy, .cut])
    func aDiskMountedThereSinceTheReviewIsRefusedToo(mode: CopyPasteMode) async throws {
        let fileSystem = mountedInDestination()
        let mountPoint = try #require(fileSystem.readNode("/dst/Photos"))
        mountPoint.dev = 1
        let report = try review(fileSystem, mode)
        #expect(report.nodes.first?.replaceBlockedReason == nil)
        let resolvedNodes = try resolveAnalysisWithPolicy(
            report: report, policy: NativePaste.replaceAll, fileSystem: fileSystem)
        #expect(resolvedNodes.first?.action == .overwrite)
        mountPoint.dev = 2
        let recorder = PasteRecorder()

        let events = await execute(
            fileSystem, (report, resolvedNodes), operationId: "op-1", policy: NativePaste.replaceAll,
            recorder: recorder, requestResolution: { _ in .immediate(.overwrite) })

        let result = try #require(events.last?.result)
        let refused = itemFor(result, "/src/Photos")
        #expect(refused?.status == .failed)
        #expect(refused?.error == Self.refusal("Photos"))
        // Asked about, as any item that changed since the review is; the answer of Replace is the one refused.
        #expect(recorder.conflicts.map(\.reason) == [.destinationChanged])
        try expectUntouched(fileSystem)
    }

    // On a real disk, mounted in a folder of its own, with no Trash to take it and "delete for good" agreed to:
    // every file on the disk is still there.
    @Test(.tags(.diskImage), .diskImages)
    func aRealDiskMountedInTheFolderKeepsEveryFile() async throws {
        try await DiskImage.withVolume(.apfsSmall, ownMountPoint: true) { volume in
            try await withTemporaryDirectory { root in
                // The folder the disk is mounted in, and the name it is mounted under.
                let around = volume.deletingLastPathComponent().path
                let name = volume.lastPathComponent
                let aroundStats = try #require(Disk.lstat(around))
                #expect(aroundStats.dev != Disk.lstat(volume.path)?.dev)
                try Disk.write(volume.path + "/kept.txt", "on the disk")
                try Disk.write(volume.path + "/album/old.txt", "deeper on the disk")
                let source = root.path + "/src/" + name
                let before = Disk.list(around)
                // The image's own file lies beside the mount point, on the folder's disk as any file is: only a
                // folder is ever where a disk is mounted.
                for other in before where other != name {
                    #expect(Disk.lstat(around + "/" + other)?.dev == aroundStats.dev)
                }

                for mode in [CopyPasteMode.copy, .cut] {
                    try Disk.write(source + "/new.txt", "new")
                    let fileSystem = TestFileSystem(NativeWriteFileSystem())
                    fileSystem.trashImpl = { _ in throw noTrashHere() }

                    let run = try await SafetyPaste(
                        mode: mode, sources: [source], destination: around, replaceEach: true,
                        resolve: { _ in .overwrite }
                    ).run(fileSystem)

                    #expect(run.report.nodes.first?.replaceBlockedReason == Self.reviewNote, "\(mode)")
                    #expect(run.result?.items.first?.status == .failed, "\(mode)")
                    #expect(run.result?.items.first?.error == Self.refusal(name), "\(mode)")
                    #expect(run.conflicts.isEmpty, "\(mode)")
                    #expect(Disk.read(volume.path + "/kept.txt") == "on the disk", "\(mode)")
                    #expect(Disk.read(volume.path + "/album/old.txt") == "deeper on the disk", "\(mode)")
                    #expect(Disk.list(around) == before, "\(mode)")
                    #expect(Disk.read(source + "/new.txt") == "new", "\(mode)")
                    #expect(Disk.list(root.path + "/src") == [name], "\(mode)")
                }
            }
        }
    }
}
