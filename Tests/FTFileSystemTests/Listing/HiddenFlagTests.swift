import Darwin
import FTTestSupport
import Foundation
import Testing

@testable import FTFileSystem

/// The flag that hides an item whatever its name, on a real disk.
struct HiddenFlagTests {
    private func makeFolder(_ directory: TemporaryDirectory) throws -> String {
        let root = try NativeFileSystem().realpath(directory.path)
        let manager = FileManager.default
        try manager.createDirectory(atPath: root + "/shown", withIntermediateDirectories: true)
        try manager.createDirectory(atPath: root + "/flagged folder/inside", withIntermediateDirectories: true)
        manager.createFile(atPath: root + "/flagged folder/inside/note.txt", contents: nil)
        manager.createFile(atPath: root + "/flagged.txt", contents: nil)
        manager.createFile(atPath: root + "/plain.txt", contents: nil)
        manager.createFile(atPath: root + "/.dot.txt", contents: nil)
        try manager.createSymbolicLink(atPath: root + "/flagged link", withDestinationPath: "shown")
        #expect(chflags(root + "/flagged folder", UInt32(UF_HIDDEN)) == 0)
        #expect(chflags(root + "/flagged.txt", UInt32(UF_HIDDEN)) == 0)
        #expect(lchflags(root + "/flagged link", UInt32(UF_HIDDEN)) == 0)
        return root
    }

    private func service() -> DirectoryService {
        DirectoryService(
            fileSystem: NativeFileSystem(), cache: ResponseCache(), kinds: KindLabeler(describer: nil),
            trash: TrashFolders(homePath: "/Users/me", uid: 501, listMounts: { [] }))
    }

    @Test func aFolderReadSaysWhichItemsHaveTheFlag() throws {
        try withTemporaryDirectory { directory in
            let root = try makeFolder(directory)
            let flagged = try NativeFileSystem().readDirectory(root).filter(\.hasHiddenFlag).map(\.name).sorted()
            #expect(flagged == ["flagged folder", "flagged link", "flagged.txt"])
            #expect(try NativeFileSystem().lstat(root + "/flagged.txt").hasHiddenFlag)
            #expect(try !NativeFileSystem().lstat(root + "/plain.txt").hasHiddenFlag)
        }
    }

    @Test func listingsHideWhatHasTheFlagAsTheyHideADotAndShowItWithHiddenFiles() async throws {
        try await withTemporaryDirectory { directory in
            let root = try makeFolder(directory)
            let service = service()

            let plain = try await service.snapshot(path: root)
            #expect(plain.entries.map(\.name) == ["shown", "plain.txt"])
            #expect(try await service.treeChildren(path: root).children.map(\.name) == ["shown"])

            let all = try await service.snapshot(path: root, includeHidden: true)
            #expect(
                all.entries.filter(\.isHidden).map(\.name).sorted()
                    == [".dot.txt", "flagged folder", "flagged link", "flagged.txt"])
            let tree = try await service.treeChildren(path: root, includeHidden: true).children
            #expect(tree.first { $0.name == "flagged folder" }?.isHidden == true)
            #expect(await service.hasHiddenFlag(path: root + "/flagged folder"))
            #expect(await !service.hasHiddenFlag(path: root + "/shown"))
            #expect(await service.itemProperties(path: root + "/flagged.txt").isHidden)
        }
    }

    @Test func whatIsInAFolderWithTheFlagIsNotHiddenByIt() async throws {
        try await withTemporaryDirectory { directory in
            let root = try makeFolder(directory)
            let inside = try await service().snapshot(path: root + "/flagged folder")
            #expect(inside.entries.map(\.name) == ["inside"])
        }
    }
}
