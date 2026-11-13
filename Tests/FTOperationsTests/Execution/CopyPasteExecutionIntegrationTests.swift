import FTFoundation
import FTTestSupport
import Foundation
import Testing
import os

@testable import FTOperations

struct CopyPasteExecutionIntegrationTests {

    @Test func copyFileAndInlineCutNativeCopyThenInlineDelete() async throws {
        let fileSystem = MockWriteServiceFileSystem([
            ("/source/a.txt", .file(size: 10, dev: 1)), ("/target", .directory(dev: 2)),
        ])
        let copied = Flag()
        fileSystem.copyFileImpl = { source, destination, _, _ in
            copied.set()
            let node = fileSystem.readNode(source)
            fileSystem.addFile(destination, .file(size: node?.size, mode: node?.mode))
        }
        let operation = try createResolvedOperation(fileSystem, mode: .cut, sources: ["/source/a.txt"], into: "/target")

        await execute(fileSystem, operation, operationId: "cross-native-cut")

        #expect(copied.isSet)
        #expect(!fileSystem.exists("/source/a.txt"))
        #expect(fileSystem.exists("/target/a.txt"))
    }

    @Test func mergeWithRenamedChildrenAndCopyFileFallbackMixesPathsInOneOperation() async throws {
        // Some items on the same disk (renamed), some on another (copied).
        let fileSystem = MockWriteServiceFileSystem([
            ("/source/dir", .directory(dev: 1)), ("/source/dir/same-dev.txt", .file(size: 5, dev: 1)),
            ("/source/dir/cross-dev.txt", .file(size: 8, dev: 2)), ("/target", .directory(dev: 1)),
            ("/target/dir", .directory(dev: 1)), ("/target/dir/existing.txt", .file(size: 3, dev: 1)),
        ])
        fileSystem.copyFileImpl = copyingSize(fileSystem)
        let operation = try createResolvedOperation(fileSystem, mode: .cut, sources: ["/source/dir"], into: "/target")

        await execute(fileSystem, operation, operationId: "cross-mixed")

        #expect(fileSystem.exists("/target/dir/existing.txt"))
        #expect(fileSystem.exists("/target/dir/same-dev.txt"))
        #expect(!fileSystem.exists("/source/dir/same-dev.txt"))
        #expect(fileSystem.exists("/target/dir/cross-dev.txt"))
        #expect(!fileSystem.exists("/source/dir/cross-dev.txt"))
    }

    @Test func doesntRemoveAnItemAfterAFailedCopyUnlessTheCopyCreatedIt() async throws {
        let fileSystem = MockWriteServiceFileSystem([
            ("/source", .directory()), ("/source/a.txt", .file(size: 5)), ("/target", .directory()),
        ])
        let operation = try createResolvedOperation(fileSystem, sources: ["/source/a.txt"], into: "/target")
        // "a.txt" is someone else's, saved while the paste was starting (the runtime check doesn't see it yet),
        // and the copy then fails on it.
        fileSystem.addFile("/target/a.txt", .file(size: 7))
        let hidden = OSAllocatedUnfairLock(initialState: true)
        fileSystem.lstatImpl = { path in
            let hide =
                path == "/target/a.txt"
                && hidden.withLock { value in
                    defer { value = false }
                    return value
                }
            if hide {
                throw codedError(.errno(ENOENT), "ENOENT: \(path)")
            }
            return try fileSystem.lstatDirectly(path)
        }
        fileSystem.copyFileImpl = { _, _, _, _ in throw codedError(.errno(EACCES)) }

        let events = await execute(fileSystem, operation, operationId: "someone-elses-file")

        #expect(events.last?.result?.items.first?.status == .failed)
        #expect(fileSystem.readNode("/target/a.txt")?.size == 7)
    }

    @Test func asksAboutAFileThatTakesItsNameWhileItIsBeingCopiedInsteadOfFailing() async throws {
        let fileSystem = MockWriteServiceFileSystem([
            ("/source", .directory()), ("/source/a.txt", .file(size: 5)), ("/target", .directory()),
        ])
        let policy = CopyPastePolicy(file: .keepBoth, directory: .merge, mismatch: .skip)
        let operation = try createResolvedOperation(
            fileSystem, sources: ["/source/a.txt"], into: "/target", policy: policy)
        fileSystem.copyFileImpl = { source, destination, _, _ in
            fileSystem.copyFileImpl = nil
            // Another app saves a file at the name while the copy is made.
            fileSystem.addFile("/target/a.txt", .file(size: 9))
            try fileSystem.copyDirectly(source, destination)
        }
        let recorder = PasteRecorder()

        let events = await execute(
            fileSystem, operation, operationId: "intruder", policy: policy, recorder: recorder,
            requestResolution: { _ in .immediate(.keepBoth) })

        #expect(recorder.conflicts.map(\.reason) == [.destinationCreated])
        let item = events.last?.result?.items.first
        #expect(item?.status == .completed)
        #expect(item?.destinationPath == "/target/a copy.txt")
        #expect(fileSystem.readNode("/target/a.txt")?.size == 9)
        #expect(fileSystem.readNode("/target/a copy.txt")?.size == 5)
    }

    // MARK: Folder metadata and unreadable folders

    /// A folder on another volume (dev 2), so a move copies it item by item.
    private func otherVolumeFolder() -> MockWriteServiceFileSystem {
        let fileSystem = MockWriteServiceFileSystem([
            ("/source", .directory(dev: 2)), ("/source/dir", .directory(mode: 0o40555, mtimeMs: 1234, dev: 2)),
            ("/source/dir/a.txt", .file(size: 1, dev: 2)), ("/target", .directory()),
        ])
        fileSystem.enableUtimes()
        return fileSystem
    }

    private func run(_ fileSystem: MockWriteServiceFileSystem, _ mode: CopyPasteMode, _ sources: [String])
        async throws -> CopyPasteOperationResult?
    {
        let operation = try createResolvedOperation(fileSystem, mode: mode, sources: sources, into: "/target")
        return await execute(fileSystem, operation, operationId: "op-metadata").last?.result
    }

    @Test func putsAFoldersOwnMetadataOnAfterItsItemsAndItsDateBackAfterAMove() async throws {
        let fileSystem = otherVolumeFolder()
        let order = Recorded<String>()
        fileSystem.copyFileImpl = { _, destination, _, _ in
            order.append("file \(destination)")
            fileSystem.addFile(destination, .file(size: 1))
        }
        fileSystem.copyMetadataImpl = { source, destination in
            order.append("metadata \(source) -> \(destination)")
            // As copyfile(3) would: the source folder's date, which the move just changed.
            fileSystem.readNode(destination)?.mtimeMs = 9999
        }

        let result = try await run(fileSystem, .cut, ["/source/dir"])

        #expect(result?.status == .completed)
        // The folder is built under a hidden name, its file written straight in; the folder's own metadata goes
        // on once it has its name.
        #expect(order.all.count == 2)
        #expect(order.all.first?.wholeMatch(of: /file \/target\/\.dir\.filetrail-[0-9a-f]+\/a\.txt/) != nil)
        #expect(order.all.last == "metadata /source/dir -> /target/dir")
        #expect(fileSystem.readNode("/target/dir/a.txt")?.size == 1)
        #expect(fileSystem.readNode("/target/dir")?.mtimeMs == 1234)
    }

    /// Which folders of a paste of `sources` got metadata that lets a quarantined app run in place, and which the
    /// plain kind.
    private func metadataCalls(_ sources: [String], folders: [String]) async throws -> (
        inPlace: [String], plain: [String]
    ) {
        let fileSystem = MockWriteServiceFileSystem([("/source", .directory(dev: 2)), ("/target", .directory())])
        for folder in folders {
            fileSystem.addDirectory(folder, .directory(dev: 2))
        }
        fileSystem.enableUtimes()
        let inPlace = Recorded<String>()
        let plain = Recorded<String>()
        fileSystem.copyMetadataToRunInPlaceImpl = { _, destination in inPlace.append(destination) }
        fileSystem.copyMetadataImpl = { _, destination in plain.append(destination) }
        let result = try await run(fileSystem, .copy, sources)
        #expect(result?.status == .completed)
        return (inPlace.all, plain.all)
    }

    @Test func anAppCopiedOnItsOwnRunsInPlace() async throws {
        let calls = try await metadataCalls(
            ["/source/Foo.app"], folders: ["/source/Foo.app", "/source/Foo.app/Contents"])
        #expect(calls.inPlace == ["/target/Foo.app"])
        #expect(calls.plain.allSatisfy { !$0.hasSuffix("/Foo.app") })
    }

    @Test func anAppCopiedWithOtherItemsOrInAFolderDoesntRunInPlace() async throws {
        let beside = try await metadataCalls(
            ["/source/Foo.app", "/source/other"], folders: ["/source/Foo.app", "/source/other"])
        #expect(beside.inPlace.isEmpty)
        let inside = try await metadataCalls(["/source/dir"], folders: ["/source/dir", "/source/dir/Foo.app"])
        #expect(inside.inPlace.isEmpty)
        let notAnApp = try await metadataCalls(["/source/dir"], folders: ["/source/dir"])
        #expect(notAnApp.inPlace.isEmpty)
    }

    @Test func fallsBackToTheModeAndDateWhenAFoldersMetadataCantBeCopied() async throws {
        let fileSystem = otherVolumeFolder()
        let chmods = Recorded<[String]>()
        fileSystem.chmodImpl = { path, mode in chmods.append([path, String(mode, radix: 8)]) }
        fileSystem.copyMetadataImpl = { _, _ in throw codedError(.errno(ENOTSUP)) }

        let result = try await run(fileSystem, .copy, ["/source/dir"])

        #expect(result?.status == .completed)
        #expect(chmods.all.filter { $0.first == "/target/dir" } == [["/target/dir", "40555"]])
        #expect(fileSystem.readNode("/target/dir")?.mtimeMs == 1234)
    }

    @Test func leavesAnUnreadableFolderInPlaceWhenMovingAndSaysItWasntMoved() async throws {
        let fileSystem = otherVolumeFolder()
        fileSystem.readdirImpl = { path in
            if path == "/source/dir" {
                throw codedError(.errno(EACCES))
            }
            return []
        }

        let result = try await run(fileSystem, .cut, ["/source/dir"])

        #expect(result?.status == .failed)
        #expect(result?.items.map(\.sourcePath) == ["/source/dir"])
        #expect(result?.items.map(\.status) == [.failed])
        #expect(
            result?.items.map(\.error) == [
                "This folder couldn't be read, so it wasn't moved. You don't have permission to access this item."
            ])
        #expect(fileSystem.readNode("/source/dir/a.txt") != nil)
        #expect(fileSystem.readNode("/target/dir") == nil)
    }
}
