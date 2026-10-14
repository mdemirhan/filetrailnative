// Port of the read-only and unreadable folder cases of packages/core/src/fs/copyPasteFolderSafety.realfs.test.ts (its
// Replace, Replace journal and recovery cases are P3-04's)
import Darwin
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTOperations

struct FolderSafetyTests {
    private func paste(_ mode: CopyPasteMode, _ sources: [String], into destination: String) async throws
        -> CopyPasteOperationResult?
    {
        let fileSystem = NativeWriteFileSystem()
        let report = try buildCopyPasteAnalysisReport(
            analysisId: "analysis-folder-safety",
            request: CopyPasteAnalysisRequest(mode: mode, sourcePaths: sources, destinationDirectoryPath: destination),
            fileSystem: fileSystem,
            thresholds: CopyPasteThresholds(largeBatchItemThreshold: 1000, largeBatchByteThreshold: 1_000_000_000))
        #expect(report.issues.isEmpty)
        let resolvedNodes = try resolveAnalysisWithPolicy(report: report, policy: addMissing, fileSystem: fileSystem)
        return await execute(fileSystem, (report, resolvedNodes), operationId: "op-folder-safety").last?.result
    }

    private func modeOf(_ path: String) -> UInt32 {
        (Disk.lstat(path)?.mode ?? 0) & 0o777
    }

    // T-3c416b0d F-335 F-454
    @Test func copiesAReadOnlyFolderWithEverythingInItAndKeepsItReadOnly() async throws {
        try await withTemporaryDirectory { root in
            let source = root.path + "/src/module"
            try Disk.write(source + "/a.txt", "a")
            try Disk.write(source + "/nested/b.txt", "b")
            Disk.chmod(source + "/nested", 0o555)
            Disk.chmod(source, 0o555)
            try Disk.makeDirectories(root.path + "/dst")

            let result = try await paste(.copy, [source], into: root.path + "/dst")

            #expect(result?.status == .completed)
            let copy = root.path + "/dst/module"
            #expect(Disk.read(copy + "/a.txt") == "a")
            #expect(Disk.read(copy + "/nested/b.txt") == "b")
            #expect(modeOf(copy) == 0o555)
            #expect(modeOf(copy + "/nested") == 0o555)
        }
    }

    // T-d9e41bda F-335
    @Test func removesAStagedCopyEvenWhenFoldersInsideItAreReadOnly() throws {
        try withTemporaryDirectory { root in
            let staged = root.path + "/.module.filetrail-0000"
            try Disk.write(staged + "/inner/f.txt", "f")
            Disk.chmod(staged + "/inner", 0o555)
            Disk.chmod(staged, 0o555)

            try removeStagedItem(NativeWriteFileSystem(), staged)

            #expect(!Disk.exists(staged))
        }
    }

    // T-0d72c378 F-261 F-458
    @Test(.enabled(if: getuid() != 0, "folders that can't be read are readable anyway as root"))
    func pastesEverythingElseAndReportsOnlyTheUnreadableFolder() async throws {
        try await withTemporaryDirectory { root in
            let source = root.path + "/src/project"
            try Disk.write(source + "/readme.txt", "readme")
            try Disk.write(source + "/locked/secret.txt", "secret")
            Disk.chmod(source + "/locked", 0o000)
            defer { Disk.chmod(source + "/locked", 0o755) }
            try Disk.makeDirectories(root.path + "/dst")

            let result = try await paste(.copy, [source], into: root.path + "/dst")

            #expect(result?.status == .partial)
            #expect(Disk.read(root.path + "/dst/project/readme.txt") == "readme")
            #expect(!Disk.exists(root.path + "/dst/project/locked"))
            let failed = (result?.items ?? []).filter { $0.status == .failed }
            #expect(failed.map(\.sourcePath).contains(source + "/locked"))
            #expect(
                failed.first { $0.sourcePath == source + "/locked" }?.error
                    == "This folder couldn't be read, so it wasn't copied. You don't have permission to access this item."
            )
        }
    }

    // T-c602b1b3 F-261
    @Test(.enabled(if: getuid() != 0, "folders that can't be read are readable anyway as root"))
    func anUnreadableFolderPastedOnItsOwnFailsWithoutStoppingTheOthers() async throws {
        try await withTemporaryDirectory { root in
            try Disk.makeDirectories(root.path + "/src/locked")
            try Disk.write(root.path + "/src/other.txt", "other")
            Disk.chmod(root.path + "/src/locked", 0o000)
            defer { Disk.chmod(root.path + "/src/locked", 0o755) }
            try Disk.makeDirectories(root.path + "/dst")

            let result = try await paste(
                .copy, [root.path + "/src/locked", root.path + "/src/other.txt"], into: root.path + "/dst")

            #expect(result?.status == .partial)
            #expect(Disk.list(root.path + "/dst") == ["other.txt"])
        }
    }
}
