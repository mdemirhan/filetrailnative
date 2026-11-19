// Replace Older on real disks: only files newer than the ones there replace them, folders merge, a second run
// replaces nothing, as copies keep their dates, packages are left uncompared, and a move leaves what it didn't take
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTOperations

private func setModified(_ path: String, _ seconds: TimeInterval) throws {
    try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSince1970: seconds)], ofItemAtPath: path)
}

struct ReplaceOlderTests {
    @Test func replacesOnlyNewerFilesAndASecondRunReplacesNothing() async throws {
        try await withTemporaryDirectory { root in
            let source = root.path + "/src"
            let destination = root.path + "/dest"
            try Disk.write(source + "/Project/a.txt", "new a")
            try Disk.write(source + "/Project/b.txt", "old b")
            try Disk.write(source + "/Project/sub/c.txt", "new c")
            try Disk.write(source + "/Project/d.txt", "added d")
            try Disk.write(destination + "/Project/a.txt", "old a")
            try Disk.write(destination + "/Project/b.txt", "new b")
            try Disk.write(destination + "/Project/sub/c.txt", "old c")
            try Disk.write(destination + "/Project/only-here.txt", "kept")
            try setModified(source + "/Project/a.txt", 2_000_000)
            try setModified(destination + "/Project/a.txt", 1_000_000)
            try setModified(source + "/Project/b.txt", 1_000_000)
            try setModified(destination + "/Project/b.txt", 2_000_000)
            try setModified(source + "/Project/sub/c.txt", 2_000_000)
            try setModified(destination + "/Project/sub/c.txt", 1_000_000)

            // Both sides are on the startup disk, APFS: dates compare to the millisecond.
            let policy = CopyPasteReview.policy(for: .replaceOlder, toleranceMs: 1)
            let trash = root.path + "/Trash"
            try FileManager.default.createDirectory(atPath: trash, withIntermediateDirectories: false)
            let fileSystem = NativePaste.withTrash(trash)
            let first = try await runPaste(
                mode: .copy, sources: [source + "/Project"], into: destination, policy: policy, fileSystem: fileSystem)
            #expect(first.report.newerToleranceMs == 1)
            #expect(first.result?.status == .partial)
            #expect(Disk.read(destination + "/Project/a.txt") == "new a")
            #expect(Disk.read(destination + "/Project/b.txt") == "new b")
            #expect(Disk.read(destination + "/Project/sub/c.txt") == "new c")
            #expect(Disk.read(destination + "/Project/d.txt") == "added d")
            #expect(Disk.read(destination + "/Project/only-here.txt") == "kept")
            let skipped = first.result?.items.filter { $0.status == .skipped } ?? []
            #expect(skipped.map(\.sourcePath) == [source + "/Project/b.txt"])
            #expect(skipped.map(\.skipReason) == [.notNewer])
            // The replaced files went to the Trash.
            #expect(Disk.list(trash).count == 2)

            let second = try await runPaste(
                mode: .copy, sources: [source + "/Project"], into: destination, policy: policy, fileSystem: fileSystem)
            #expect(second.result?.items.allSatisfy { $0.status == .skipped || $0.status == .completed } == true)
            #expect(
                second.result?.items.filter { $0.status == .skipped }.map(\.skipReason)
                    == [.notNewer, .notNewer, .notNewer, .notNewer])
            #expect(Disk.list(trash).count == 2)
        }
    }

    /// The node of the review at `sourcePath`, wherever it is in the tree.
    private func node(at sourcePath: String, in nodes: [CopyPasteAnalysisNode]) -> CopyPasteAnalysisNode? {
        for node in nodes {
            if node.sourcePath == sourcePath { return node }
            if let found = self.node(at: sourcePath, in: node.children) { return found }
        }
        return nil
    }

    // A package changed inside keeps its outer folder's date, so its date can't say it is newer, and one whose outer
    // date is newer may hold older things inside: Replace Older leaves both, and says it didn't compare them. A row's
    // own Replace still replaces a package whole, and the files beside them are compared as ever.
    @Test func leavesPackagesUncomparedAndARowsOwnReplaceStillReplaces() async throws {
        try await withTemporaryDirectory { root in
            let source = root.path + "/src/Project"
            let destination = root.path + "/dest/Project"
            // A disk image changed in place: a band inside is new, the outer folders' dates are the same.
            try Disk.write(source + "/Work.sparsebundle/bands/0", "new band")
            try Disk.write(destination + "/Work.sparsebundle/bands/0", "old band")
            // An app whose outer folder is newer than the one there.
            try Disk.write(source + "/Tool.app/Contents/tool", "new tool")
            try Disk.write(destination + "/Tool.app/Contents/tool", "old tool")
            // One the person sets to Replace in its row.
            try Disk.write(source + "/Own.app/Contents/own", "new own")
            try Disk.write(destination + "/Own.app/Contents/own", "old own")
            try Disk.write(destination + "/Own.app/Contents/only-there", "gone with the old one")
            try Disk.write(source + "/a.txt", "new a")
            try Disk.write(destination + "/a.txt", "old a")
            try Disk.write(source + "/b.txt", "old b")
            try Disk.write(destination + "/b.txt", "new b")
            try setModified(source + "/Work.sparsebundle/bands/0", 2_000_000)
            try setModified(destination + "/Work.sparsebundle/bands/0", 1_000_000)
            try setModified(source + "/Work.sparsebundle", 1_000_000)
            try setModified(destination + "/Work.sparsebundle", 1_000_000)
            try setModified(source + "/Tool.app", 2_000_000)
            try setModified(destination + "/Tool.app", 1_000_000)
            try setModified(source + "/Own.app", 1_000_000)
            try setModified(destination + "/Own.app", 2_000_000)
            try setModified(source + "/a.txt", 2_000_000)
            try setModified(destination + "/a.txt", 1_000_000)
            try setModified(source + "/b.txt", 1_000_000)
            try setModified(destination + "/b.txt", 2_000_000)

            let policy = CopyPasteReview.policy(for: .replaceOlder, toleranceMs: 1)
            let trash = root.path + "/Trash"
            try FileManager.default.createDirectory(atPath: trash, withIntermediateDirectories: false)
            let run = try await runPaste(
                mode: .copy, sources: [source], into: root.path + "/dest", policy: policy,
                fileSystem: NativePaste.withTrash(trash),
                overrides: { report in
                    self.node(at: source + "/Own.app", in: report.nodes).map {
                        [CopyPasteNodeOverride(nodeId: $0.id, action: .overwrite)]
                    } ?? []
                })
            // Two packages clash like two files, which is what Replace Older would have compared by date.
            #expect(node(at: source + "/Work.sparsebundle", in: run.report.nodes)?.conflictClass == .fileConflict)
            #expect(node(at: source + "/Tool.app", in: run.report.nodes)?.conflictClass == .fileConflict)

            #expect(Disk.read(destination + "/Work.sparsebundle/bands/0") == "old band")
            #expect(Disk.read(destination + "/Tool.app/Contents/tool") == "old tool")
            #expect(Disk.read(destination + "/Own.app/Contents/own") == "new own")
            #expect(!FileManager.default.fileExists(atPath: destination + "/Own.app/Contents/only-there"))
            #expect(Disk.read(destination + "/a.txt") == "new a")
            #expect(Disk.read(destination + "/b.txt") == "new b")
            let skipped = run.result?.items.filter { $0.status == .skipped } ?? []
            let reasons = Dictionary(uniqueKeysWithValues: skipped.map { ($0.sourcePath, $0.skipReason) })
            #expect(
                reasons == [
                    source + "/Work.sparsebundle": .packageNotCompared, source + "/Tool.app": .packageNotCompared,
                    source + "/b.txt": .notNewer,
                ])
            #expect(run.result?.status == .partial)
            // The replaced file and the replaced package went to the Trash, and nothing else.
            #expect(Disk.list(trash).count == 2)
            #expect(run.conflicts.isEmpty)
        }
    }

    // A move with Replace Older: the newer file moves and replaces the one there; the file that isn't newer and the
    // package stay where they were, each reported with why, and so does the folder that still holds them.
    @Test func aMoveLeavesWhatItDidNotTakeWhereItWas() async throws {
        try await withTemporaryDirectory { root in
            let source = root.path + "/src/Project"
            let destination = root.path + "/dest/Project"
            try Disk.write(source + "/a.txt", "new a")
            try Disk.write(destination + "/a.txt", "old a")
            try Disk.write(source + "/b.txt", "old b")
            try Disk.write(destination + "/b.txt", "new b")
            try Disk.write(source + "/c.txt", "added c")
            try Disk.write(source + "/Work.sparsebundle/bands/0", "new band")
            try Disk.write(destination + "/Work.sparsebundle/bands/0", "old band")
            try setModified(source + "/a.txt", 2_000_000)
            try setModified(destination + "/a.txt", 1_000_000)
            try setModified(source + "/b.txt", 1_000_000)
            try setModified(destination + "/b.txt", 2_000_000)
            try setModified(source + "/Work.sparsebundle", 2_000_000)
            try setModified(destination + "/Work.sparsebundle", 1_000_000)

            let trash = root.path + "/Trash"
            try FileManager.default.createDirectory(atPath: trash, withIntermediateDirectories: false)
            let run = try await runPaste(
                mode: .cut, sources: [source], into: root.path + "/dest",
                policy: CopyPasteReview.policy(for: .replaceOlder, toleranceMs: 1),
                fileSystem: NativePaste.withTrash(trash))

            // The newer file and the new one moved.
            #expect(Disk.read(destination + "/a.txt") == "new a")
            #expect(!FileManager.default.fileExists(atPath: source + "/a.txt"))
            #expect(Disk.read(destination + "/c.txt") == "added c")
            #expect(!FileManager.default.fileExists(atPath: source + "/c.txt"))
            #expect(Disk.list(trash).count == 1)
            // The one that isn't newer and the package are where they were, and the ones there are as they were.
            #expect(Disk.read(source + "/b.txt") == "old b")
            #expect(Disk.read(destination + "/b.txt") == "new b")
            #expect(Disk.read(source + "/Work.sparsebundle/bands/0") == "new band")
            #expect(Disk.read(destination + "/Work.sparsebundle/bands/0") == "old band")
            let skipped = run.result?.items.filter { $0.status == .skipped } ?? []
            let reasons = Dictionary(uniqueKeysWithValues: skipped.map { ($0.sourcePath, $0.skipReason) })
            #expect(
                reasons == [source + "/b.txt": .notNewer, source + "/Work.sparsebundle": .packageNotCompared])
            #expect(skipped.allSatisfy { $0.error == nil })
            #expect(run.result?.items.contains { $0.status == .failed || $0.status == .cancelled } == false)
            #expect(run.conflicts.isEmpty)
        }
    }

    // FAT keeps local time with no time zone: Replace Older isn't offered for a paste onto it.
    @Test(.tags(.diskImage), .diskImages)
    func isntOfferedOntoAFATDisk() async throws {
        try await withTemporaryDirectory { root in
            try Disk.write(root.path + "/a.txt", "a")
            try await DiskImage.withSharedVolume(.fat32) { stick in
                try Disk.write(stick.path + "/rob/a.txt", "old")
                let run = try await runPaste(
                    mode: .copy, sources: [root.path + "/a.txt"], into: stick.path + "/rob",
                    policy: NativePaste.keepExisting)
                #expect(run.report.newerToleranceMs == nil)
            }
        }
    }

    // exFAT keeps dates to 10 ms, with the time zone: offered, compared at that.
    @Test(.tags(.diskImage), .diskImages)
    func isOfferedOntoAnExFATDiskAt10Milliseconds() async throws {
        try await withTemporaryDirectory { root in
            try Disk.write(root.path + "/a.txt", "a")
            try await DiskImage.withSharedVolume(.exfat) { stick in
                try Disk.write(stick.path + "/rob2/a.txt", "old")
                let run = try await runPaste(
                    mode: .copy, sources: [root.path + "/a.txt"], into: stick.path + "/rob2",
                    policy: NativePaste.keepExisting)
                #expect(run.report.newerToleranceMs == 10)
            }
        }
    }
}
