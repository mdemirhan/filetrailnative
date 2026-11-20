// A move to another disk is a copy and then a removal: what happens between the two
import Darwin
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTOperations

struct MoveToAnotherDiskTests {
    private func withPlaces(_ body: (_ src: String, _ dst: String) async throws -> Void) async throws {
        try await withTemporaryDirectory { root in
            let (src, dst) = (root.path + "/src", root.path + "/dst")
            for folder in [src, dst] {
                try Disk.makeDirectories(folder)
            }
            try await body(src, dst)
        }
    }

    // A plain folder with an item that can't be copied: nothing in it is moved, and nothing of it is left on the
    // other disk.
    @Test func aFolderWithAnItemThatCantBeCopiedIsNotMoved() async throws {
        try await withPlaces { src, dst in
            try Disk.write(src + "/F/a.txt", "a")
            try Disk.write(src + "/F/b.txt", "b")
            try Disk.write(src + "/F/sub/c.txt", "c")
            let fileSystem = NativePaste.asOnAnotherDisk(src)
            fileSystem.copyFileImpl = { source, destination, stop, onProgress in
                if source == src + "/F/b.txt" { throw NativeError.errno(EIO, syscall: "copyfile", path: source) }
                try NativeWriteFileSystem().copyFile(source, destination, stop: stop, onProgress: onProgress)
            }

            let run = try await runPaste(mode: .cut, sources: [src + "/F"], into: dst, fileSystem: fileSystem)

            let item = run.result?.items.first { $0.sourcePath == src + "/F" }
            #expect(item?.status == .failed)
            #expect(
                item?.error
                    == "\u{201C}F\u{201D} wasn't moved because some items in it couldn't be copied. Nothing in it was moved."
            )
            #expect(Disk.list(dst) == [])
            #expect(Disk.list(src + "/F") == ["a.txt", "b.txt", "sub"])
            #expect(Disk.read(src + "/F/sub/c.txt") == "c")
        }
    }

    /// A file system for `src` as on another disk whose copy of `failing` fails with a disk error, and the files it
    /// was asked to copy, in order.
    private func failingToCopy(_ failing: String, from src: String) -> (TestFileSystem, Locked<[String]>) {
        let asked = Locked<[String]>([])
        let fileSystem = NativePaste.asOnAnotherDisk(src)
        fileSystem.copyFileImpl = { source, destination, stop, onProgress in
            asked.mutate { $0.append(String(source.dropFirst(src.count + 1))) }
            if source == failing { throw NativeError.errno(EIO, syscall: "copyfile", path: source) }
            try NativeWriteFileSystem().copyFile(source, destination, stop: stop, onProgress: onProgress)
        }
        return (fileSystem, asked)
    }

    // The folder isn't moved once one item in it failed, so nothing after that item is copied: the copy made so
    // far goes, and the result names the item that failed.
    @Test func aFolderMovedToAnotherDiskCopiesNothingMoreOnceAnItemFailed() async throws {
        try await withPlaces { src, dst in
            for name in ["a.txt", "b.txt", "c.txt", "sub/d.txt"] {
                try Disk.write(src + "/F/" + name, name)
            }
            let (fileSystem, asked) = failingToCopy(src + "/F/b.txt", from: src)

            let run = try await runPaste(mode: .cut, sources: [src + "/F"], into: dst, fileSystem: fileSystem)

            #expect(asked.value == ["F/a.txt", "F/b.txt"])
            let items = run.result?.items ?? []
            let named = items.map { [NodePath.basename($0.sourcePath), $0.status.rawValue] }
            #expect(named == [["F", "failed"], ["b.txt", "failed"]])
            #expect(items.last?.error == "A disk error occurred.")
            #expect(run.result?.summary.completedByteCount == 0)
            #expect(Disk.list(dst) == [])
            #expect(Disk.list(src + "/F") == ["a.txt", "b.txt", "c.txt", "sub"])
            #expect(Disk.read(src + "/F/sub/d.txt") == "sub/d.txt")
        }
    }

    // An item that fails in a folder inside ends the folders above it too.
    @Test func anItemThatFailsDeepInAFolderMovedToAnotherDiskEndsTheWholeCopy() async throws {
        try await withPlaces { src, dst in
            for name in ["a/deep/x.txt", "a/deep/y.txt", "a/z.txt", "b.txt"] {
                try Disk.write(src + "/F/" + name, name)
            }
            let (fileSystem, asked) = failingToCopy(src + "/F/a/deep/x.txt", from: src)

            let run = try await runPaste(mode: .cut, sources: [src + "/F"], into: dst, fileSystem: fileSystem)

            #expect(asked.value == ["F/a/deep/x.txt"])
            let failed = (run.result?.items ?? []).filter { $0.status == .failed }.map(\.sourcePath)
            #expect(failed.contains(src + "/F") && failed.contains(src + "/F/a/deep/x.txt"))
            #expect(Disk.list(dst) == [])
            #expect(Disk.read(src + "/F/b.txt") == "b.txt")
        }
    }

    // A copy is put in place with what it has, so everything else in it is still copied.
    @Test func aFolderCopiedGoesOnPastAnItemThatFailed() async throws {
        try await withPlaces { src, dst in
            for name in ["a.txt", "b.txt", "c.txt", "sub/d.txt"] {
                try Disk.write(src + "/F/" + name, name)
            }
            let (fileSystem, asked) = failingToCopy(src + "/F/b.txt", from: src)

            let run = try await runPaste(mode: .copy, sources: [src + "/F"], into: dst, fileSystem: fileSystem)

            #expect(asked.value == ["F/a.txt", "F/b.txt", "F/c.txt", "F/sub/d.txt"])
            let failed = run.result?.items.filter { $0.status == .failed }.map(\.sourcePath)
            #expect(failed == [src + "/F", src + "/F/b.txt"])
            #expect(Disk.list(dst + "/F") == ["a.txt", "c.txt", "sub"])
        }
    }

    // Stopped once the copy of a file is in place and before its original is removed: the file is whole in its
    // new place, and the result says it was moved only if its original is gone.
    @Test func aStopBetweenTheCopyAndTheRemovalLosesNothing() async throws {
        try await withPlaces { src, dst in
            try Disk.write(src + "/a.txt", "a's data")
            let signal = StopSignal()
            let fileSystem = NativePaste.asOnAnotherDisk(src)
            fileSystem.copyFileImpl = { source, destination, stop, onProgress in
                try NativeWriteFileSystem().copyFile(source, destination, stop: stop, onProgress: onProgress)
                signal.stop()
            }

            let run = try await runPaste(
                mode: .cut, sources: [src + "/a.txt"], into: dst, fileSystem: fileSystem, signal: signal)

            #expect(Disk.read(dst + "/a.txt") == "a's data")
            #expect(Disk.list(dst) == ["a.txt"])
            let item = run.result?.items.first { $0.sourcePath == src + "/a.txt" }
            #expect((item?.status == .completed) == !Disk.exists(src + "/a.txt"), "\(String(describing: item))")
            if Disk.exists(src + "/a.txt") { #expect(Disk.read(src + "/a.txt") == "a's data") }
        }
    }
}
