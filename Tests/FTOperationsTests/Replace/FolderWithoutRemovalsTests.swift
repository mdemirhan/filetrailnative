// Pastes into a folder that lets items be added but not renamed or removed (a drop box): nothing is built there
// under a hidden name, which could be neither put in place nor cleared away
import Darwin
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTOperations

struct FolderWithoutRemovalsTests {
    private static let rule = "everyone deny delete_child"

    private func chmod(_ arguments: String...) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/chmod")
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    /// A source folder and a destination that refuses removals, holding `old`; the rule is taken off afterwards.
    private func withDropBox(
        holding old: [String], _ body: (_ source: String, _ destination: String) async throws -> Void
    ) async throws {
        try await withTemporaryDirectory(prefix: "drop-box") { root in
            let source = root.path + "/src"
            let destination = root.path + "/dst"
            try Disk.makeDirectories(source)
            try Disk.makeDirectories(destination)
            for name in old { try Disk.write(destination + "/" + name, "old") }
            try chmod("+a", Self.rule, destination)
            defer { try? chmod("-a", Self.rule, destination) }
            try await body(source, destination)
        }
    }

    @Test func tellsAFolderThatRefusesRemovalsFromOneThatTakesThemAndOneThatTakesNothing() async throws {
        try await withDropBox(holding: []) { source, destination in
            let fileSystem = NativeWriteFileSystem()
            try fileSystem.assertItemsCanLeave(source)
            let refused = #expect(throws: NativeError.self) { try fileSystem.assertItemsCanLeave(destination) }
            #expect(
                refused?.message
                    == "Items can be added to “dst” but not renamed or removed there, so nothing was put in it.")
            // A folder nothing can be added to fails with its own reason when written to.
            try chmod("555", source)
            defer { try? chmod("755", source) }
            try fileSystem.assertItemsCanLeave(source)
            try fileSystem.assertItemsCanLeave(source + "/gone")
        }
    }

    // A move that replaces would put the moved item there under a hidden name, with no way back out.
    @Test func aMoveThatReplacesLeavesTheItemWhereItWasAndNothingHidden() async throws {
        try await withDropBox(holding: ["note.txt"]) { source, destination in
            try Disk.write(source + "/note.txt", "new")
            let run = try await runPaste(
                mode: .cut, sources: [source + "/note.txt"], into: destination, policy: NativePaste.replaceAll)
            #expect(run.result?.status == .failed)
            #expect(run.result?.items.first?.error?.contains("but not renamed or removed there") == true)
            #expect(Disk.read(source + "/note.txt") == "new")
            #expect(Disk.list(destination) == ["note.txt"])
            #expect(Disk.read(destination + "/note.txt") == "old")
        }
    }

    @Test func aFileAndAFolderCopiedThereLeaveNothingHidden() async throws {
        try await withDropBox(holding: []) { source, destination in
            try Disk.write(source + "/a.txt", "a")
            try Disk.write(source + "/F/inner.txt", "i")
            let run = try await runPaste(
                mode: .copy, sources: [source + "/a.txt", source + "/F"], into: destination)
            #expect(run.result?.status == .failed)
            #expect(Disk.list(destination) == [])
            #expect(Disk.list(source) == ["F", "a.txt"])
        }
    }

    // A move on one disk with nothing in its way is a rename into the folder, which only adds to it.
    @Test func aMoveWithNothingInItsWayStillGoesIn() async throws {
        try await withDropBox(holding: []) { source, destination in
            try Disk.write(source + "/a.txt", "a")
            let run = try await runPaste(mode: .cut, sources: [source + "/a.txt"], into: destination)
            #expect(run.result?.status == .completed)
            #expect(Disk.list(destination) == ["a.txt"])
            #expect(Disk.list(source) == [])
        }
    }
}
