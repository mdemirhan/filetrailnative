// Port of the recovery cases of packages/core/src/fs/copyPasteLocked.realfs.test.ts ("putting right a Replace a crash
// cut short"), on the real disk
import Darwin
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTOperations

struct LockedRecoveryTests {
    private func withPlaces(_ body: (_ root: String, _ src: String, _ dst: String) throws -> Void) throws {
        try withTemporaryDirectory { root in
            let (src, dst) = (root.path + "/src", root.path + "/dst")
            try Disk.makeDirectories(src)
            try Disk.makeDirectories(dst)
            try body(root.path, src, dst)
        }
    }

    private func entry(
        _ id: String, staging: String, final: String, source: String, moved: Bool = false, staged: Bool
    ) -> ReplaceJournalEntry {
        ReplaceJournalEntry(
            id: id, stagingPath: staging, finalPath: final, sourcePath: source, moved: moved, staged: staged)
    }

    // T-00cf8c5b F-355 F-489
    @Test func finishesAReplaceWhoseNewItemIsLocked() throws {
        try withPlaces { _, src, dst in
            let staged = dst + "/.f.txt.filetrail-00001234"
            try Disk.write(staged, "new")
            Disk.lock(staged)

            let outcomes = recoverInterruptedReplaces(
                [entry("1", staging: staged, final: dst + "/f.txt", source: src + "/f.txt", staged: true)],
                NativeWriteFileSystem())

            #expect(outcomes.map(\.outcome) == [.finished(path: dst + "/f.txt")])
            #expect(Disk.read(dst + "/f.txt") == "new")
            #expect(Disk.flags(dst + "/f.txt") & UInt32(UF_IMMUTABLE) != 0)
        }
    }

    // T-8de531ef F-355 F-346
    @Test func removesAnUnfinishedLockedCopy() throws {
        try withPlaces { _, src, dst in
            let staged = dst + "/.f.txt.filetrail-00001234"
            try Disk.write(staged, "half")
            Disk.lock(staged)
            try Disk.write(dst + "/f.txt", "old")

            let outcomes = recoverInterruptedReplaces(
                [entry("1", staging: staged, final: dst + "/f.txt", source: src + "/f.txt", staged: false)],
                NativeWriteFileSystem())

            #expect(outcomes.map(\.outcome) == [.removedCopy])
            #expect(Disk.list(dst) == ["f.txt"])
        }
    }

    // T-bc3d1d00 F-353 F-525
    @Test(.enabled(if: getuid() != 0, "folders that can't be read are readable anyway as root"))
    func keepsAnEntryWhoseHiddenItemCantBeReachedAndDropsOneThatIsGone() throws {
        try withPlaces { root, src, dst in
            let unreadable = root + "/unreadable"
            try Disk.write(unreadable + "/.moved.filetrail-00000001", "only copy")
            Disk.chmod(unreadable, 0o000)
            defer { Disk.chmod(unreadable, 0o755) }
            func moved(_ id: String, _ staging: String) -> ReplaceJournalEntry {
                entry(id, staging: staging, final: dst + "/moved", source: src + "/moved", moved: true, staged: true)
            }

            let outcomes = recoverInterruptedReplaces(
                [
                    // Its disk isn't connected.
                    moved("unmounted", "/Volumes/FileTrailNotConnected/.moved.filetrail-00000001"),
                    // Its folder can't be read.
                    moved("unreadable", unreadable + "/.moved.filetrail-00000001"),
                    // Really gone: its folder is there, the item isn't.
                    moved("gone", dst + "/.moved.filetrail-00000001"),
                ], NativeWriteFileSystem())

            #expect(outcomes.map(\.entry.id) == ["unmounted", "unreadable", "gone"])
            let kinds = outcomes.map { outcome -> String in
                if case .unreachable = outcome.outcome { return "unreachable" }
                return outcome.outcome == .nothingLeft ? "nothing_left" : "other"
            }
            #expect(kinds == ["unreachable", "unreachable", "nothing_left"])
            Disk.chmod(unreadable, 0o755)
            #expect(Disk.read(unreadable + "/.moved.filetrail-00000001") == "only copy")
        }
    }
}
