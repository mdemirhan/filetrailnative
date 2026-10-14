// Port of packages/core/src/fs/copyPasteNative.realfs.test.ts and copyPasteSymlinkMetadata.realfs.test.ts: the
// paste on the app's native copy (copyfile(3))
import Darwin
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTOperations

/// Extended attributes of an item itself (a link not followed).
enum Attributes {
    static func write(_ path: String, _ name: String, _ value: String) throws {
        let bytes = Array(value.utf8)
        if setxattr(path, name, bytes, bytes.count, 0, XATTR_NOFOLLOW) != 0 {
            throw NativeError.errno(errno, syscall: "setxattr", path: path)
        }
    }

    static func read(_ path: String, _ name: String) -> String? {
        let size = getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
        guard size >= 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        guard getxattr(path, name, &bytes, size, 0, XATTR_NOFOLLOW) == size else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func names(_ path: String) -> [String] {
        let size = listxattr(path, nil, 0, XATTR_NOFOLLOW)
        guard size > 0 else { return [] }
        var bytes = [CChar](repeating: 0, count: size)
        guard listxattr(path, &bytes, size, XATTR_NOFOLLOW) == size else { return [] }
        return bytes.split(separator: 0).map { String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self) }
    }
}

struct NativePasteTests {
    private func copy(_ sources: [String], into destination: String) async throws -> CopyPasteOperationResult? {
        let fileSystem = NativeWriteFileSystem()
        let report = try buildCopyPasteAnalysisReport(
            analysisId: "analysis-native",
            request: CopyPasteAnalysisRequest(mode: .copy, sourcePaths: sources, destinationDirectoryPath: destination),
            fileSystem: fileSystem,
            thresholds: CopyPasteThresholds(largeBatchItemThreshold: 1000, largeBatchByteThreshold: 1_000_000_000))
        let resolvedNodes = try resolveAnalysisWithPolicy(report: report, policy: addMissing, fileSystem: fileSystem)
        return await execute(fileSystem, (report, resolvedNodes), operationId: "op-native").last?.result
    }

    // T-91071836 F-454
    @Test func copiesALockedFileAndTheCopyStaysLocked() async throws {
        try await withTemporaryDirectory { root in
            let source = root.path + "/src/locked.txt"
            try Disk.write(source, "keep me")
            try Disk.makeDirectories(root.path + "/dst")
            Disk.lock(source)

            let result = try await copy([source], into: root.path + "/dst")

            #expect(result?.status == .completed)
            #expect(Disk.flags(root.path + "/dst/locked.txt") & UInt32(UF_IMMUTABLE) != 0)
        }
    }

    // T-36fd50a5 F-454 F-457
    @Test func keepsAFoldersFinderTagsModeAndDate() async throws {
        try await withTemporaryDirectory { root in
            let source = root.path + "/src/Tagged"
            try Disk.write(source + "/inside.txt", "x")
            try Disk.makeDirectories(root.path + "/dst")
            try Attributes.write(source, "com.apple.metadata:_kMDItemUserTags", "(\"Red\\n6\")")
            // 2020-01-02T03:04:05Z
            try setDate(source, 1_577_934_245_000)
            Disk.chmod(source, 0o555)

            let result = try await copy([source], into: root.path + "/dst")

            #expect(result?.status == .completed)
            let copied = root.path + "/dst/Tagged"
            #expect(Attributes.names(copied).contains("com.apple.metadata:_kMDItemUserTags"))
            #expect((Disk.lstat(copied)?.mode ?? 0) & 0o777 == 0o555)
            #expect(mtimeMs(copied) == 1_577_934_245_000)
            #expect(Disk.lstat(copied + "/inside.txt")?.type == .file)
        }
    }

    // T-42cd2b28 F-454
    @Test func copiesALockedFolderWithItsItemsInside() async throws {
        try await withTemporaryDirectory { root in
            let source = root.path + "/src/Vault"
            try Disk.write(source + "/a.txt", "a")
            try Disk.makeDirectories(root.path + "/dst")
            Disk.lock(source)

            let result = try await copy([source], into: root.path + "/dst")

            #expect(result?.status == .completed)
            #expect(Disk.lstat(root.path + "/dst/Vault/a.txt")?.type == .file)
        }
    }

    // A link pasted keeps its own tags, as Finder's copy does: it is copied as the link itself. A move copies, as
    // to another disk.
    // T-d81c40a3 F-273 F-451
    @Test(arguments: [CopyPasteMode.copy, .cut])
    func keepsTheLinksOwnExtendedAttributes(mode: CopyPasteMode) async throws {
        try await withTemporaryDirectory { root in
            let (source, destination) = (root.path + "/src", root.path + "/dst")
            try Disk.makeDirectories(source + "/folder")
            try Disk.makeDirectories(destination)
            try Disk.symlink("nowhere.txt", source + "/folder/link")
            try Attributes.write(source + "/folder/link", "com.example.tag", "red")

            let run = try await runPaste(
                mode: mode, sources: [source + "/folder"], into: destination,
                fileSystem: NativePaste.asOnAnotherDisk(source))

            #expect(run.result?.status == .completed)
            #expect(try PosixFileSystem().readlink(destination + "/folder/link") == "nowhere.txt")
            #expect(Attributes.read(destination + "/folder/link", "com.example.tag") == "red")
            if mode == .cut {
                #expect(Disk.list(root.path) == ["dst", "src"])
                #expect(Disk.list(source) == [])
            }
        }
    }
}
