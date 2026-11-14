// Paste as File's write: a new file holding the clipboard's bytes, under a free name, and its Undo
import Darwin
import FTFileSystem
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTOperations

@MainActor
@Suite(.localOperationHang) struct CreateFileOperationTests {
    /// What is in the folder, the test's Trash left out.
    static func names(_ folder: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder).filter { $0 != ".Trash" }.sorted()
    }

    @discardableResult
    static func paste(
        _ t: UndoTest, _ name: String, _ text: String, nextFreeName: Bool = true
    ) async throws -> WriteOperationEvent {
        try await t.finish(
            t.coordinator.createFile(
                parentDirectoryPath: t.root, fileName: name, contents: Data(text.utf8), nextFreeName: nextFreeName,
                window: t.window))
    }

    @Test func writesTheBytesUnderTheNameAndLeavesNothingElse() async throws {
        try await withUndoFolder { root, trashDir in
            let t = UndoTest(root: root, trashDir: trashDir)
            let end = try await Self.paste(t, "Pasted Text.txt", "hello\nworld")
            #expect(end.action == .pasteAsFile)
            #expect(end.status == .completed)
            #expect(end.currentDestinationPath == "\(root)/Pasted Text.txt")
            #expect(try String(contentsOfFile: "\(root)/Pasted Text.txt", encoding: .utf8) == "hello\nworld")
            // The hidden file it was filled under is gone.
            #expect(try Self.names(root) == ["Pasted Text.txt"])
            await t.shutDown()
        }
    }

    @Test func aNameTakenMeanwhileGivesTheNextFreeOne() async throws {
        try await withUndoFolder { root, trashDir in
            try UndoDisk.write("\(root)/Pasted Image.png", "first")
            try UndoDisk.write("\(root)/Pasted Image 2.png", "second")
            let t = UndoTest(root: root, trashDir: trashDir)
            let end = try await Self.paste(t, "Pasted Image.png", "third")
            #expect(end.currentDestinationPath == "\(root)/Pasted Image 3.png")
            // A numbered name goes on from its number.
            let next = try await Self.paste(t, "Pasted Image 3.png", "fourth")
            #expect(next.currentDestinationPath == "\(root)/Pasted Image 4.png")
            #expect(try String(contentsOfFile: "\(root)/Pasted Image.png", encoding: .utf8) == "first")
            await t.shutDown()
        }
    }

    @Test func aNameGivenAsItIsNeverReplacesWhatIsThere() async throws {
        try await withUndoFolder { root, trashDir in
            try UndoDisk.write("\(root)/notes.txt", "mine")
            let t = UndoTest(root: root, trashDir: trashDir)
            await #expect(throws: (any Error).self) {
                try await Self.paste(t, "notes.txt", "pasted", nextFreeName: false)
            }
            #expect(try String(contentsOfFile: "\(root)/notes.txt", encoding: .utf8) == "mine")
            await t.shutDown()
        }
    }

    @Test func undoMovesTheFileToTheTrashAndRedoPutsItBack() async throws {
        try await withUndoFolder { root, trashDir in
            let t = UndoTest(root: root, trashDir: trashDir)
            let before = t.snapshot()
            try await Self.paste(t, "Pasted Text.txt", "text")
            #expect(t.history.menu().undo == "Paste as File")
            let after = t.snapshot()
            try await t.undo()
            #expect(t.snapshot() == before)
            #expect(t.inTrash() == ["1-Pasted Text.txt"])
            try await t.undo(.redo)
            #expect(t.snapshot() == after)
            await t.shutDown()
        }
    }

    @Test func nothingIsMadeInTheTrash() async throws {
        try await withUndoFolder { root, trashDir in
            let trash = "\(root)/.Trash"
            let t = UndoTest(root: root, trashDir: trashDir)
            await #expect(throws: (any Error).self) {
                try await t.coordinator.createFile(
                    parentDirectoryPath: trash, fileName: "Pasted Text.txt", contents: Data("x".utf8),
                    window: t.window)
            }
            let inTrash = try FileManager.default.contentsOfDirectory(atPath: trash)
            #expect(inTrash.isEmpty)
            await t.shutDown()
        }
    }

    @Test func aFileThatCantBeWrittenFailsAndIsNeverGivenItsName() async throws {
        let fileSystem = TestLocalFileSystem.stub()
        fileSystem.writeNewFileImpl = { path, _ in throw NativeError.errno(ENOSPC, syscall: "write", path: path) }
        let coordinator = WriteCoordinator.local(fileSystem)
        let window = TestWindow()
        _ = try await coordinator.createFile(
            parentDirectoryPath: "/Users/demo", fileName: "Pasted Image.png", contents: Data([1, 2, 3]), window: window)
        let end = await window.ended("write-op-1")
        #expect(end.status == .failed)
        #expect(fileSystem.calls.writeNewFile.count == 1)
        #expect(fileSystem.calls.writeNewFile[0].hasPrefix("/Users/demo/."))
        #expect(fileSystem.calls.renameExclusive.isEmpty)
        await coordinator.shutDown(maxWaitMs: 0)
    }

    @Test func aFileThatCantBeGivenItsNameIsRemoved() async throws {
        let fileSystem = TestLocalFileSystem.stub()
        fileSystem.renameExclusiveImpl = { from, _ in throw NativeError.errno(EEXIST, syscall: "rename", path: from) }
        let coordinator = WriteCoordinator.local(fileSystem)
        let window = TestWindow()
        _ = try await coordinator.createFile(
            parentDirectoryPath: "/Users/demo", fileName: "Pasted Text.txt", contents: Data("x".utf8), window: window)
        let end = await window.ended("write-op-1")
        #expect(end.status == .failed)
        #expect(end.result?.error == "An item named \u{201C}Pasted Text.txt\u{201D} already exists.")
        let partial = fileSystem.calls.writeNewFile.first
        #expect(partial != nil && fileSystem.calls.rm.map(\.0) == [partial!])
        await coordinator.shutDown(maxWaitMs: 0)
    }

    @Test func theDiskWritesANewFileAndNeverOverOne() throws {
        let folder = NSTemporaryDirectory() + "filetrail-new-file-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let disk = NativeWriteFileSystem()
        try disk.writeNewFile("\(folder)/a.bin", Data([0, 1, 2]))
        #expect(FileManager.default.contents(atPath: "\(folder)/a.bin") == Data([0, 1, 2]))
        #expect(throws: (any Error).self) { try disk.writeNewFile("\(folder)/a.bin", Data([9])) }
        #expect(FileManager.default.contents(atPath: "\(folder)/a.bin") == Data([0, 1, 2]))
        try disk.writeNewFile("\(folder)/empty", Data())
        #expect(FileManager.default.contents(atPath: "\(folder)/empty") == Data())
    }
}
