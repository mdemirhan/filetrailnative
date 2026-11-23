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
        "Can’t replace \u{201C}\(name)\u{201D} because it is a disk mounted here."
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

    // MARK: A folder that holds one, deeper inside

    private static func heldInside(_ within: String, _ folder: String) -> String {
        "\u{201C}\(within)\u{201D} is another disk, mounted inside \u{201C}\(folder)\u{201D}, so \u{201C}\(folder)\u{201D} wasn’t deleted for good and nothing was replaced. Eject it and try again."
    }

    /// "/dst/Album" is a folder of its folder's disk that holds, two folders down, one a disk is mounted on
    /// ("/dst/Album/2024/share", another device), and a folder "Album" is pasted into "/dst". No Trash, unless
    /// enabled.
    private func mountedDeeperInside() -> MockWriteServiceFileSystem {
        MockWriteServiceFileSystem([
            ("/src", .directory()), ("/src/Album", .directory()), ("/src/Album/new.jpg", .file(size: 3)),
            ("/dst", .directory()), ("/dst/Album", .directory()), ("/dst/Album/a.jpg", .file(size: 5)),
            ("/dst/Album/2024", .directory()), ("/dst/Album/2024/b.jpg", .file(size: 6)),
            ("/dst/Album/2024/share", .directory(dev: 2)), ("/dst/Album/2024/share/kept.jpg", .file(size: 7)),
            ("/dst/Album/2024/share/deep", .directory()), ("/dst/Album/2024/share/deep/old.jpg", .file(size: 9)),
            ("/dst/Album/z.jpg", .file(size: 4)),
        ])
    }

    private static let heldPaths = [
        "/dst/Album/a.jpg", "/dst/Album/2024/b.jpg", "/dst/Album/2024/share/kept.jpg",
        "/dst/Album/2024/share/deep/old.jpg", "/dst/Album/z.jpg",
    ]

    /// The folders listed from now on.
    private func notingListings(_ fileSystem: MockWriteServiceFileSystem) -> Locked<[String]> {
        let listed = Locked<[String]>([])
        fileSystem.readdirImpl = { path in
            listed.mutate { $0.append(path) }
            return try fileSystem.readdirDirectly(path)
        }
        return listed
    }

    private func reviewAlbum(_ fileSystem: MockWriteServiceFileSystem, _ mode: CopyPasteMode) throws
        -> (report: CopyPasteAnalysisReport, resolvedNodes: [ResolvedCopyPasteNode])
    {
        let report = try buildCopyPasteAnalysisReport(
            analysisId: "analysis-1",
            request: CopyPasteAnalysisRequest(
                mode: mode, sourcePaths: ["/src/Album"], destinationDirectoryPath: "/dst"),
            fileSystem: fileSystem)
        let resolvedNodes = try resolveAnalysisWithPolicy(
            report: report, policy: NativePaste.replaceAll, fileSystem: fileSystem)
        return (report, resolvedNodes)
    }

    // Where there is no Trash and "delete for good" was agreed to, the delete would stop at the disk with the
    // folder half deleted: it is refused before anything is removed, the pasted folder stays where it was, and
    // nothing on the other disk is looked at, by the review or by the paste.
    @Test(arguments: [CopyPasteMode.copy, .cut])
    func aFolderHoldingADiskIsntDeletedForGood(mode: CopyPasteMode) async throws {
        let fileSystem = mountedDeeperInside()
        let listed = notingListings(fileSystem)
        let operation = try reviewAlbum(fileSystem, mode)
        let node = try #require(operation.report.nodes.first)
        // Offered, as the Trash would take it with the disk still mounted inside. The folder a disk is mounted on
        // counts as one item: a.jpg, 2024, b.jpg, share and z.jpg.
        #expect(node.replaceBlockedReason == nil)
        #expect(node.destinationTotalNodeCount == 5)
        #expect(node.destinationOnly?.count == 5)
        #expect(operation.resolvedNodes.first?.action == .overwrite)
        let recorder = PasteRecorder()

        let events = await execute(
            fileSystem, operation, operationId: "op-1", policy: NativePaste.replaceAll, recorder: recorder,
            requestResolution: { _ in .immediate(.overwrite) })

        let result = try #require(events.last?.result)
        let refused = itemFor(result, "/src/Album")
        #expect(refused?.status == .failed)
        #expect(refused?.error == Self.heldInside("2024/share", "Album"))
        // Asked, and answered yes: the look inside comes after.
        #expect(recorder.conflicts.map(\.reason) == [.trashUnavailable])
        #expect(result.replacedPaths == nil)
        for path in Self.heldPaths {
            #expect(fileSystem.exists(path), "\(path)")
        }
        #expect(try fileSystem.readdir("/dst") == ["Album"])
        #expect(try fileSystem.readdir("/src") == ["Album"])
        #expect(fileSystem.readNode("/src/Album/new.jpg")?.size == 3)
        #expect(fileSystem.temporaryLeftovers() == [])
        #expect(listed.value.contains("/dst/Album/2024"))
        #expect(!listed.value.contains { $0.hasPrefix("/dst/Album/2024/share") }, "\(listed.value)")
    }

    // A disk mounted in the folder after the review, which counted what was in that folder as the folder's own.
    @Test func aDiskMountedInsideSinceTheReviewIsFoundBeforeAnythingIsDeleted() async throws {
        let fileSystem = mountedDeeperInside()
        let onTheDisk = ["", "/kept.jpg", "/deep", "/deep/old.jpg"].map { "/dst/Album/2024/share" + $0 }
        for path in onTheDisk {
            fileSystem.readNode(path)?.dev = 1
        }
        let operation = try reviewAlbum(fileSystem, .copy)
        #expect(operation.report.nodes.first?.destinationTotalNodeCount == 8)
        for path in onTheDisk {
            fileSystem.readNode(path)?.dev = 2
        }
        let listed = notingListings(fileSystem)

        let events = await execute(
            fileSystem, operation, operationId: "op-1", policy: NativePaste.replaceAll,
            requestResolution: { _ in .immediate(.overwrite) })

        let result = try #require(events.last?.result)
        #expect(itemFor(result, "/src/Album")?.error == Self.heldInside("2024/share", "Album"))
        for path in Self.heldPaths {
            #expect(fileSystem.exists(path), "\(path)")
        }
        #expect(!listed.value.contains { $0.hasPrefix("/dst/Album/2024/share") }, "\(listed.value)")
    }

    // Where there is a Trash the folder goes there as ever, the disk still mounted in it.
    @Test func aFolderHoldingADiskStillGoesToTheTrash() async throws {
        let fileSystem = mountedDeeperInside()
        fileSystem.enableTrash()
        let operation = try reviewAlbum(fileSystem, .copy)

        let events = await execute(fileSystem, operation, operationId: "op-1", policy: NativePaste.replaceAll)

        let result = try #require(events.last?.result)
        #expect(itemFor(result, "/src/Album")?.status == .completed)
        #expect(fileSystem.trashed == ["/dst/Album"])
        #expect(try fileSystem.readdir("/dst/Album") == ["new.jpg"])
    }

    // On a real disk mounted in a folder that holds other files too, with no Trash to take the folder and "delete
    // for good" agreed to: the folder is as it was, every file beside the mount point and on the disk, and the pasted
    // folder is where it was.
    @Test(.tags(.diskImage), .diskImages)
    func aRealFolderHoldingADiskIsLeftWholeWhereThereIsNoTrash() async throws {
        try await DiskImage.withVolume(.apfsSmall, ownMountPoint: true) { volume in
            try await withTemporaryDirectory { root in
                // The folder that holds the mount point (and the image's own file), and the folder that one is in.
                let album = volume.deletingLastPathComponent().path
                let name = NodePath.basename(album)
                let holder = NodePath.dirname(album)
                let mounted = volume.lastPathComponent
                #expect(Disk.lstat(album)?.dev == Disk.lstat(holder)?.dev)
                #expect(Disk.lstat(album)?.dev != Disk.lstat(volume.path)?.dev)
                try Disk.write(album + "/beside.txt", "beside the mount point")
                try Disk.write(album + "/more/deeper.txt", "deeper beside it")
                try Disk.write(volume.path + "/kept.txt", "on the disk")
                try Disk.write(volume.path + "/album/old.txt", "deeper on the disk")
                let before = Disk.list(album)
                #expect(before.contains(mounted) && before.contains("beside.txt") && before.count >= 4)
                let source = root.path + "/src/" + name

                for mode in [CopyPasteMode.copy, .cut] {
                    try Disk.write(source + "/new.txt", "new")
                    let fileSystem = TestFileSystem(NativeWriteFileSystem())
                    fileSystem.trashImpl = { _ in throw noTrashHere() }

                    let run = try await SafetyPaste(
                        mode: mode, sources: [source], destination: holder, replaceEach: true,
                        resolve: { _ in .overwrite }
                    ).run(fileSystem)

                    #expect(run.report.nodes.first?.replaceBlockedReason == nil, "\(mode)")
                    #expect(run.conflicts.map(\.reason) == [.trashUnavailable], "\(mode)")
                    #expect(run.result?.items.first?.status == .failed, "\(mode)")
                    #expect(run.result?.items.first?.error == Self.heldInside(mounted, name), "\(mode)")
                    #expect(run.result?.replacedPaths == nil, "\(mode)")
                    #expect(Disk.list(album) == before, "\(mode)")
                    #expect(Disk.read(album + "/beside.txt") == "beside the mount point", "\(mode)")
                    #expect(Disk.read(album + "/more/deeper.txt") == "deeper beside it", "\(mode)")
                    #expect(Disk.read(volume.path + "/kept.txt") == "on the disk", "\(mode)")
                    #expect(Disk.read(volume.path + "/album/old.txt") == "deeper on the disk", "\(mode)")
                    #expect(Disk.read(source + "/new.txt") == "new", "\(mode)")
                    #expect(Disk.list(root.path + "/src") == [name], "\(mode)")
                    // Nothing of the paste's is left under a hidden name beside the folder.
                    #expect(Disk.list(holder).filter { $0.contains(name) } == [name], "\(mode)")
                }
            }
        }
    }
}
