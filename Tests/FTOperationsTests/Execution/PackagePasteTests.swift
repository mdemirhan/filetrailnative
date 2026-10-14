// Port of the paste cases of packages/core/src/fs/copyPastePackages.realfs.test.ts, but for the one that Replaces
// (P3-04's): packages (apps, Keynote documents, photo libraries) are folders macOS shows as one item. Two of them
// clash like two files: one replaces the other or both are kept, never merged, since an app or document made of two
// versions is broken.
import Darwin
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTOperations

private let keepAll = CopyPastePolicy(file: .keepBoth, directory: .merge, mismatch: .keepBoth)

private func makeApp(_ folder: String, _ version: String, _ extraFile: String) throws {
    try Disk.write(folder + "/Foo.app/Contents/Info.plist", version)
    try Disk.write(folder + "/Foo.app/Contents/" + extraFile, extraFile)
}

/// A package that clashes with one already there.
struct PackagePasteTests {
    private func folders(_ root: TemporaryDirectory) throws -> (src: String, dst: String) {
        let (src, dst) = (root.path + "/src", root.path + "/dst")
        try Disk.makeDirectories(src)
        try Disk.makeDirectories(dst)
        return (src, dst)
    }

    // T-726a5109 F-450
    @Test func isLeftWholeByAddMissing() async throws {
        try await withTemporaryDirectory { root in
            let (src, dst) = try folders(root)
            try makeApp(src, "v2", "new.png")
            try makeApp(dst, "v1", "old.png")

            let run = try await runPaste(mode: .copy, sources: [src + "/Foo.app"], into: dst)

            #expect(run.result?.items.first?.status == .skipped)
            #expect(Disk.list(dst + "/Foo.app/Contents") == ["Info.plist", "old.png"])
        }
    }

    // T-63458da3 F-450
    @Test func isKeptBesideTheExistingOneByKeepAllUnderACopyName() async throws {
        try await withTemporaryDirectory { root in
            let (src, dst) = try folders(root)
            try makeApp(src, "v2", "new.png")
            try makeApp(dst, "v1", "old.png")

            let run = try await runPaste(mode: .copy, sources: [src + "/Foo.app"], into: dst, policy: keepAll)

            #expect(run.result?.status == .completed)
            #expect(Disk.list(dst) == ["Foo copy.app", "Foo.app"])
            #expect(Disk.read(dst + "/Foo copy.app/Contents/Info.plist") == "v2")
            #expect(Disk.list(dst + "/Foo.app/Contents") == ["Info.plist", "old.png"])
        }
    }

    // T-124863ab F-450
    @Test func isntMergedWhenAMergeAnswerIsGivenForItByItsOwnChoice() async throws {
        try await withTemporaryDirectory { root in
            let (src, dst) = try folders(root)
            try makeApp(src, "v2", "new.png")
            try makeApp(dst, "v1", "old.png")

            // "merge" for folders reaches a package only as an override the review never offers.
            let run = try await runPaste(
                mode: .copy, sources: [src + "/Foo.app"], into: dst,
                policy: CopyPastePolicy(file: .skip, directory: .merge, mismatch: .skip))

            #expect(run.result?.items.first?.status == .skipped)
            #expect(Disk.read(dst + "/Foo.app/Contents/Info.plist") == "v1")
        }
    }

    // T-bc27ba96 F-325
    @Test func appearingAtTheDestinationDuringThePasteIsAskedAboutWithoutMerge() async throws {
        try await withTemporaryDirectory { root in
            let (src, dst) = try folders(root)
            try makeApp(src, "v2", "new.png")

            let run = try await runPaste(
                mode: .copy, sources: [src + "/Foo.app"], into: dst,
                beforeExecute: { try makeApp(dst, "v1", "old.png") }, resolve: { _ in .skip })

            #expect(run.conflicts.map(\.reason) == [.destinationCreated])
            #expect(run.conflicts.map(\.conflictClass) == [.fileConflict])
        }
    }

    // T-dc846056 F-448
    @Test func stillMergesTwoPlainFolders() async throws {
        try await withTemporaryDirectory { root in
            let (src, dst) = try folders(root)
            try Disk.write(src + "/Photos/new.jpg", "new")
            try Disk.write(dst + "/Photos/old.jpg", "old")

            let run = try await runPaste(mode: .copy, sources: [src + "/Photos"], into: dst)

            #expect(run.report.nodes.first?.conflictClass == .directoryConflict)
            #expect(run.result?.status == .completed)
            #expect(Disk.list(dst + "/Photos") == ["new.jpg", "old.jpg"])
        }
    }
}

// Like Finder, a copy of a package keeps its extension at the end, whichever packages macOS knows: "Backup
// copy.sparsebundle", never "Backup.sparsebundle copy".
struct PackageCopyNameTests {
    // T-2838f1c8 F-450
    @Test func hasCopyBeforeTheExtensionWhenDuplicated() async throws {
        try await withTemporaryDirectory { root in
            let src = root.path + "/src"
            let packages = ["Backup.sparsebundle", "Flow.workflow", "Foo.app"]
            for name in packages + ["Notes.v2"] {
                try Disk.makeDirectories(src + "/" + name)
            }

            _ = try await runPaste(mode: .copy, sources: (packages + ["Notes.v2"]).map { src + "/" + $0 }, into: src)

            #expect(
                Disk.list(src) == [
                    "Backup copy.sparsebundle", "Backup.sparsebundle", "Flow copy.workflow", "Flow.workflow",
                    "Foo copy.app", "Foo.app", "Notes.v2", "Notes.v2 copy",
                ])
        }
    }

    // T-96aa43f3 F-450
    @Test func hasCopyBeforeTheExtensionWhenKeepBothKeepsItBesideTheOldOne() async throws {
        try await withTemporaryDirectory { root in
            let (src, dst) = (root.path + "/src", root.path + "/dst")
            try Disk.makeDirectories(src + "/Model.custompkg")
            try Disk.makeDirectories(dst + "/Model.custompkg")
            // A package by its package bit or an app's document type, not by a known extension.
            let fileSystem = TestFileSystem()
            fileSystem.isPackageImpl = { $0.hasSuffix(".custompkg") }

            let run = try await runPaste(
                mode: .copy, sources: [src + "/Model.custompkg"], into: dst, policy: keepAll, fileSystem: fileSystem)

            #expect(run.report.nodes.first?.keepBothDestinationPath == dst + "/Model copy.custompkg")
            #expect(Disk.list(dst) == ["Model copy.custompkg", "Model.custompkg"])
        }
    }
}
