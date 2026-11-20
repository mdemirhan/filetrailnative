// Files moved to another disk one by one: written out once for the paste, their originals removed at its end
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTOperations

struct MovedFilesWrittenOutTests {
    private static let names = ["a.txt", "b.txt", "c.txt", "d.txt"]

    /// Four files on one disk (dev 1) and a folder on another (dev 2).
    private func looseFiles() -> MockWriteServiceFileSystem {
        let fileSystem = MockWriteServiceFileSystem(
            [("/source", .directory(dev: 1)), ("/target", .directory(dev: 2))]
                + Self.names.enumerated().map { ("/source/\($1)", .file(size: Int64($0 + 1), dev: 1)) })
        fileSystem.copyFileImpl = copyingSize(fileSystem)
        return fileSystem
    }

    /// A folder on one disk (dev 1) moved into a folder that has one of its name on another (dev 2): its files are
    /// moved one by one, into the folders there.
    private func mergedFolder() -> MockWriteServiceFileSystem {
        let fileSystem = MockWriteServiceFileSystem([
            ("/source", .directory(dev: 1)), ("/source/dir", .directory(dev: 1)),
            ("/source/dir/a.txt", .file(size: 1, dev: 1)), ("/source/dir/sub", .directory(dev: 1)),
            ("/source/dir/sub/b.txt", .file(size: 2, dev: 1)), ("/source/dir/sub/c.txt", .file(size: 3, dev: 1)),
            ("/target", .directory(dev: 2)), ("/target/dir", .directory(dev: 2)),
            ("/target/dir/sub", .directory(dev: 2)), ("/target/dir/sub/there.txt", .file(size: 9, dev: 2)),
        ])
        fileSystem.copyFileImpl = copyingSize(fileSystem)
        return fileSystem
    }

    private func move(
        _ fileSystem: MockWriteServiceFileSystem, _ sources: [String], signal: StopSignal = StopSignal()
    ) async throws -> CopyPasteOperationResult {
        let operation = try createResolvedOperation(fileSystem, mode: .cut, sources: sources, into: "/target")
        let events = await execute(fileSystem, operation, operationId: "moved-files", signal: signal)
        return try #require(events.last?.result, "The move didn't finish.")
    }

    private func list(_ fileSystem: MockWriteServiceFileSystem, _ path: String) -> [String] {
        (try? fileSystem.readdir(path)) ?? []
    }

    private func named(_ result: CopyPasteOperationResult) -> [String] {
        result.items.map { "\(NodePath.basename($0.sourcePath)) \($0.status.rawValue)" }
    }

    // One flush of the disk for the whole paste, with every copy made and every original still there; then the
    // originals go.
    @Test func filesMovedToAnotherDiskAreWrittenOutOnceBeforeAnyOriginalGoes() async throws {
        let fileSystem = looseFiles()
        let result = try await move(fileSystem, Self.names.map { "/source/\($0)" })

        #expect(fileSystem.flushes.count == 1)
        let flush = try #require(fileSystem.flushes.first)
        #expect(flush.wholeDisk && flush.path == "/target")
        for name in Self.names {
            #expect(flush.paths.contains("/source/\(name)") && flush.paths.contains("/target/\(name)"), "\(name)")
            #expect(!fileSystem.exists("/source/\(name)") && fileSystem.exists("/target/\(name)"), "\(name)")
        }
        #expect(result.status == .completed)
        #expect(result.items.allSatisfy { $0.status == .completed })
        #expect(result.undoLog == .notUndoable(reason: .otherDiskMove))
    }

    // The card is told once that the move is at its end, before the disk is asked to write out: with every copy
    // counted, and with the flush and the removals still to come. Its last event, with the result, isn't marked.
    @Test func saysItIsFinishingOnceBeforeTheDiskIsWrittenOut() async throws {
        let fileSystem = looseFiles()
        let recorder = PasteRecorder()
        let finishingAtFlush = Locked<[Int]>([])
        fileSystem.flushToDiskImpl = { _, _ in
            finishingAtFlush.mutate { $0.append(recorder.events.filter(\.finishing).count) }
            #expect(fileSystem.exists("/source/a.txt") && fileSystem.exists("/source/d.txt"))
        }
        let operation = try createResolvedOperation(
            fileSystem, mode: .cut, sources: Self.names.map { "/source/\($0)" }, into: "/target")

        let events = await execute(fileSystem, operation, operationId: "moved-files", recorder: recorder)

        #expect(finishingAtFlush.value == [1])
        let finishing = events.filter(\.finishing)
        #expect(finishing.count == 1)
        #expect(finishing.first?.status == .running && finishing.first?.result == nil)
        #expect(finishing.first?.completedItemCount == 4 && finishing.first?.totalItemCount == 4)
        #expect(finishing.first?.completedByteCount == 10 && finishing.first?.currentSourcePath == nil)
        // It is the last but one: nothing more is said until the end.
        #expect(events.dropLast().last?.finishing == true)
        #expect(events.last?.finishing == false && events.last?.result?.status == .completed)
    }

    // A paste with no originals left to its end says nothing new: a copy, a move on one disk, and a folder moved
    // whole to another disk, whose originals go as soon as it is in place.
    @Test func aPasteWithNoOriginalsLeftToItsEndNeverSaysFinishing() async throws {
        for (mode, sources, disk) in [
            (CopyPasteMode.copy, ["/source/a.txt", "/source/dir"], Int64(2)), (.cut, ["/source/a.txt"], 1),
            (.cut, ["/source/dir"], 2),
        ] {
            let fileSystem = MockWriteServiceFileSystem([
                ("/source", .directory(dev: 1)), ("/source/a.txt", .file(size: 1, dev: 1)),
                ("/source/dir", .directory(dev: 1)), ("/source/dir/in.txt", .file(size: 2, dev: 1)),
                ("/target", .directory(dev: disk)),
            ])
            fileSystem.copyFileImpl = copyingSize(fileSystem)
            let operation = try createResolvedOperation(fileSystem, mode: mode, sources: sources, into: "/target")

            let events = await execute(fileSystem, operation, operationId: "no-originals-left")

            #expect(events.last?.result?.status == .completed, "\(mode) \(sources)")
            #expect(events.filter(\.finishing).isEmpty, "\(mode) \(sources)")
        }
    }

    // Stopped part way: what was copied by then is written out and its originals go, as they did when each went
    // right after its copy; the rest wasn't started.
    @Test func aStopStillWritesOutAndRemovesTheOriginalsOfWhatWasCopied() async throws {
        let fileSystem = looseFiles()
        let signal = StopSignal()
        let copy = copyingSize(fileSystem)
        fileSystem.copyFileImpl = { source, destination, stop, onProgress in
            try copy(source, destination, stop, onProgress)
            if source == "/source/b.txt" { signal.stop() }
        }

        let result = try await move(fileSystem, Self.names.map { "/source/\($0)" }, signal: signal)

        #expect(fileSystem.flushes.count == 1)
        #expect(!fileSystem.exists("/source/a.txt") && !fileSystem.exists("/source/b.txt"))
        #expect(fileSystem.exists("/target/a.txt") && fileSystem.exists("/target/b.txt"))
        #expect(fileSystem.exists("/source/c.txt") && !fileSystem.exists("/target/c.txt"))
        #expect(named(result) == ["a.txt completed", "b.txt completed", "c.txt cancelled", "d.txt cancelled"])
        #expect(result.status == .partial)
    }

    // A disk that couldn't write out what it was given keeps every original, each said so.
    @Test func aDiskThatCantWriteOutKeepsEveryOriginal() async throws {
        let fileSystem = looseFiles()
        let asked = Locked(0)
        fileSystem.flushToDiskImpl = { path, _ in
            asked.mutate { $0 += 1 }
            throw NativeError.errno(EIO, syscall: "fsync", path: path)
        }

        let result = try await move(fileSystem, Self.names.map { "/source/\($0)" })

        #expect(asked.value == 1)
        for name in Self.names {
            #expect(fileSystem.exists("/source/\(name)") && fileSystem.exists("/target/\(name)"), "\(name)")
        }
        #expect(result.status == .failed)
        #expect(
            result.items.allSatisfy {
                $0.status == .failed && $0.error?.contains("couldn't be written out to the disk") == true
            })
    }

    // An original that can't be removed at the end is reported as it was: copied, the original kept; the others
    // are moved.
    @Test func anOriginalThatCantBeRemovedIsReportedWithTheOthersMoved() async throws {
        let fileSystem = looseFiles()
        fileSystem.rmImpl = { path, recursive, force in
            if path == "/source/b.txt" { throw MockWriteServiceFileSystem.error(EIO, path) }
            try fileSystem.removeDirectly(path, recursive: recursive, force: force)
        }

        let result = try await move(fileSystem, Self.names.map { "/source/\($0)" })

        #expect(named(result) == ["a.txt completed", "b.txt failed", "c.txt completed", "d.txt completed"])
        #expect(
            result.items[1].error == "It was copied, but the original couldn't be removed. A disk error occurred.")
        #expect(fileSystem.exists("/source/b.txt") && fileSystem.exists("/target/b.txt"))
        #expect(!fileSystem.exists("/source/a.txt") && !fileSystem.exists("/source/d.txt"))
        #expect(result.status == .partial)
    }

    // A copy that went away or came out short before the end keeps its original.
    @Test func aCopyNoLongerWholeAtTheEndKeepsItsOriginal() async throws {
        let fileSystem = looseFiles()
        let copy = copyingSize(fileSystem)
        fileSystem.copyFileImpl = { source, destination, stop, onProgress in
            try copy(source, destination, stop, onProgress)
            // Once the last is copied, the first copy is cut short.
            if source == "/source/d.txt" { fileSystem.readNode("/target/a.txt")?.size = 0 }
        }

        let result = try await move(fileSystem, Self.names.map { "/source/\($0)" })

        #expect(fileSystem.exists("/source/a.txt"))
        #expect(named(result).first == "a.txt failed")
        #expect(
            result.items.first?.error
                == "It changed while it was being moved, or its copy didn't come out whole, so the original was kept.")
        #expect(!fileSystem.exists("/source/b.txt"))
    }

    // The files of a folder merged into one on another disk are written out once too, and the folders they were
    // in go after them.
    @Test func aFolderMergedIntoOneOnAnotherDiskIsWrittenOutOnceAndRemoved() async throws {
        let fileSystem = mergedFolder()
        let result = try await move(fileSystem, ["/source/dir"])

        #expect(fileSystem.flushes.count == 1)
        let flush = try #require(fileSystem.flushes.first)
        #expect(flush.wholeDisk)
        for path in ["/source/dir/a.txt", "/source/dir/sub/c.txt", "/target/dir/a.txt", "/target/dir/sub/c.txt"] {
            #expect(flush.paths.contains(path), "\(path)")
        }
        #expect(!fileSystem.exists("/source/dir"))
        #expect(list(fileSystem, "/target/dir").sorted() == ["a.txt", "sub"])
        #expect(list(fileSystem, "/target/dir/sub").sorted() == ["b.txt", "c.txt", "there.txt"])
        #expect(result.status == .completed)
        #expect(named(result) == ["dir completed", "a.txt completed", "b.txt completed", "c.txt completed"])
    }

    // An original left in a merged folder keeps the folders above it, and the picked folder counts it.
    @Test func anOriginalLeftInAMergedFolderKeepsTheFoldersAboveIt() async throws {
        let fileSystem = mergedFolder()
        fileSystem.rmImpl = { path, recursive, force in
            if path == "/source/dir/sub/b.txt" { throw MockWriteServiceFileSystem.error(EIO, path) }
            try fileSystem.removeDirectly(path, recursive: recursive, force: force)
        }

        let result = try await move(fileSystem, ["/source/dir"])

        #expect(named(result) == ["dir failed", "a.txt completed", "b.txt failed", "c.txt completed"])
        #expect(result.items.first?.childFailureCount == 1)
        #expect(result.items.first?.error == nil)
        #expect(list(fileSystem, "/source/dir") == ["sub"])
        #expect(list(fileSystem, "/source/dir/sub") == ["b.txt"])
        #expect(result.status == .partial)
    }

    // An item put into a merged folder while it was moved keeps the folder, which is then listed, before its items,
    // with why.
    @Test func anItemAddedToAMergedFolderInsideIsNamedAtTheEnd() async throws {
        let fileSystem = mergedFolder()
        let copy = copyingSize(fileSystem)
        fileSystem.copyFileImpl = { source, destination, stop, onProgress in
            try copy(source, destination, stop, onProgress)
            if source == "/source/dir/sub/c.txt" { fileSystem.addFile("/source/dir/sub/new.txt", .file(size: 1)) }
        }

        let result = try await move(fileSystem, ["/source/dir"])

        #expect(
            named(result) == ["dir failed", "a.txt completed", "sub failed", "b.txt completed", "c.txt completed"])
        #expect(result.items.first?.childFailureCount == 1)
        #expect(
            result.items[2].error
                == "\u{201C}new.txt\u{201D} was added to \u{201C}sub\u{201D} while it was being moved, so it was left in the original \u{201C}sub\u{201D}."
        )
        #expect(list(fileSystem, "/source/dir/sub") == ["new.txt"])
        #expect(!fileSystem.exists("/target/dir/sub/new.txt"))
    }

    // A new folder inside a merged one whose copy failed, with the part written that couldn't be cleared away: it is
    // one item of the merged folder that failed, and stays where it was. The merged folder used to end there with
    // that reason alone: the file already moved out of it had no line, and the folders after it weren't moved.
    @Test func aNewFolderInsideAMergedOneThatCantBeClearedAwayIsOneFailedItemOfIt() async throws {
        let fileSystem = mergedFolder()
        fileSystem.addFile("/source/dir/new/x.txt", .file(size: 4))
        let copy = copyingSize(fileSystem)
        fileSystem.copyFileImpl = { source, destination, stop, onProgress in
            try copy(source, destination, stop, onProgress)
            // Cut short, with what was written left behind.
            if source == "/source/dir/new/x.txt" { throw MockWriteServiceFileSystem.error(EIO, destination) }
        }
        fileSystem.rmImpl = { path, recursive, force in
            // Nothing of the hidden copy can be removed.
            if path.contains(".filetrail-") { throw MockWriteServiceFileSystem.error(EIO, path) }
            try fileSystem.removeDirectly(path, recursive: recursive, force: force)
        }

        let result = try await move(fileSystem, ["/source/dir"])

        #expect(
            named(result) == ["dir failed", "a.txt completed", "new failed", "b.txt completed", "c.txt completed"])
        #expect(result.items.first?.childFailureCount == 1)
        #expect(result.items.first?.error == nil)
        #expect(result.items.first { $0.sourcePath == "/source/dir/new" }?.error == "A disk error occurred.")
        #expect(result.summary.completedItemCount == 3 && result.summary.failedItemCount == 2)
        #expect(result.status == .partial)
        // What failed is where it was, in its folder; what was moved is only in its new place.
        #expect(list(fileSystem, "/source/dir") == ["new"])
        #expect(list(fileSystem, "/source/dir/new") == ["x.txt"])
        #expect(list(fileSystem, "/target/dir").filter { !$0.contains(".filetrail-") }.sorted() == ["a.txt", "sub"])
        #expect(list(fileSystem, "/target/dir/sub").sorted() == ["b.txt", "c.txt", "there.txt"])
    }

    // Files that went to two disks: each disk is written out once.
    @Test func eachDiskTheFilesWentToIsWrittenOutOnce() async throws {
        let fileSystem = mergedFolder()
        // The folder merged into inside is on a disk of its own.
        fileSystem.readNode("/target/dir/sub")?.dev = 3

        let result = try await move(fileSystem, ["/source/dir"])

        #expect(fileSystem.flushes.map(\.path) == ["/target/dir", "/target/dir/sub"])
        #expect(fileSystem.flushes.map(\.wholeDisk) == [true, true])
        #expect(!fileSystem.exists("/source/dir"))
        #expect(result.status == .completed)
    }

    // On a real disk: the files are where they were moved to, and nowhere else.
    @Test func filesMovedOneByOneOnARealDiskEndUpOnlyInTheirNewPlace() async throws {
        try await withOtherDisk { source, destination, fileSystem in
            for name in Self.names {
                try Disk.write(source + "/" + name, name)
            }
            try Disk.write(source + "/dir/in.txt", "in")
            try Disk.makeDirectories(destination + "/dir")

            let run = try await runPaste(
                mode: .cut, sources: Self.names.map { source + "/" + $0 } + [source + "/dir"], into: destination,
                fileSystem: fileSystem)

            #expect(run.result?.status == .completed)
            #expect(Disk.list(source) == [])
            #expect(Disk.list(destination) == Self.names + ["dir"])
            #expect(Disk.read(destination + "/dir/in.txt") == "in")
            #expect(Disk.read(destination + "/c.txt") == "c.txt")
        }
    }

    // On a real disk that fails to write itself out, though the folder alone then flushes without error: every
    // original stays, of the files moved one by one and of the folder moved whole, each said so.
    @Test func originalsStayOnARealDiskThatFailsToWriteItselfOut() async throws {
        try await withTemporaryDirectory { root in
            let (source, destination) = (root.path + "/src", root.path + "/dst")
            try Disk.makeDirectories(destination)
            for name in Self.names {
                try Disk.write(source + "/" + name, name)
            }
            try Disk.write(source + "/dir/in.txt", "in")
            let (calls, asked) = FlushToDiskTests.calls(volumeAnswering: EIO)
            let fileSystem = NativePaste.asOnAnotherDisk(source, NativeWriteFileSystem(flushCalls: calls))

            let run = try await runPaste(
                mode: .cut, sources: Self.names.map { source + "/" + $0 } + [source + "/dir"], into: destination,
                fileSystem: fileSystem)

            // Asked once for the folder put in place and once for the files, and never flushed another way.
            #expect(asked.value == ["disk", "disk"])
            #expect(Disk.list(source) == Self.names + ["dir"])
            #expect(Disk.read(source + "/dir/in.txt") == "in")
            #expect(Disk.read(source + "/c.txt") == "c.txt")
            #expect(Disk.list(destination) == Self.names + ["dir"])
            // The file inside the folder counts as copied; nothing picked was moved.
            #expect(run.result?.status == .partial)
            let picked = run.result?.items.filter { NodePath.dirname($0.sourcePath) == source } ?? []
            #expect(picked.count == Self.names.count + 1)
            #expect(
                picked.allSatisfy {
                    $0.status == .failed && $0.error?.contains("couldn't be written out to the disk") == true
                })
        }
    }

    // A file moved from another disk in place of one there is flushed by itself. On a real disk whose drive fails to
    // write out its cache, though the plain sync then works: the original stays and the move says so. The new file is
    // in place and the one it replaced in the Trash, as they are by then.
    @Test func aFileReplacingOneOnARealDiskThatFailsItsFullSyncKeepsItsOriginal() async throws {
        try await withTemporaryDirectory { root in
            let (source, destination, trash) = (root.path + "/src", root.path + "/dst", root.path + "/trash")
            try Disk.makeDirectories(trash)
            try Disk.write(source + "/a.txt", "new")
            try Disk.write(destination + "/a.txt", "old")
            let (calls, asked) = FlushToDiskTests.calls(fullSyncAnswering: EIO, fsyncAnswering: 0)
            let fileSystem = NativePaste.asOnAnotherDisk(source, NativePaste.withTrash(trash, flushCalls: calls))

            let run = try await runPaste(
                mode: .cut, sources: [source + "/a.txt"], into: destination, policy: NativePaste.replaceAll,
                fileSystem: fileSystem)

            // The file alone, never the whole disk, and not flushed the lesser way after it failed.
            #expect(asked.value == ["full sync"])
            #expect(Disk.read(source + "/a.txt") == "new")
            #expect(Disk.read(destination + "/a.txt") == "new")
            #expect(Disk.list(destination) == ["a.txt"])
            #expect(Disk.read(trash + "/1-a.txt") == "old")
            #expect(run.result?.status == .failed)
            #expect(run.result?.items.map(\.status) == [.failed])
            #expect(
                run.result?.items.first?.error
                    == "It was copied, but the copy couldn't be written out to the disk, so the original was kept. A disk error occurred."
            )
        }
    }
}
