// Port of apps/desktop/src/main/bootstrap/trashItem.test.ts
import Foundation
import Testing

@testable import FTOperations

private let home = "/Users/demo"
private let startupDev: Int64 = 16_777_231

private let refusal = OperationError("“a.txt” couldn’t be moved to the trash because it’s in use.")

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []

    func record(_ path: String) { lock.withLock { paths.append(path) } }
    var all: [String] { lock.withLock { paths } }
}

private func makeTrashItem(
    devices: [String: Int64], flags: [String: UInt32] = [:], diskHasTrash: (@Sendable (String) -> Bool)? = nil,
    trash: @escaping TrashItem.Trash
) -> TrashItem {
    TrashItem(
        trash: trash,
        lstat: { path in
            guard let dev = devices[path] else {
                throw OperationError("ENOENT: \(path)", code: "ENOENT")
            }
            return WriteServiceStats(type: .file, dev: dev)
        },
        getFlags: { flags[$0] ?? 0 }, homePath: home, diskHasTrash: diskHasTrash)
}

private func failure(_ body: () throws -> String?) -> OperationError? {
    do {
        _ = try body()
        return nil
    } catch {
        return error as? OperationError
    }
}

struct TrashItemTests {
    // T-512f25b4 F-406
    @Test func movesTheItemToTheTrash() throws {
        let recorder = Recorder()
        let trashItem = makeTrashItem(devices: [:]) { path in
            recorder.record(path)
            return "/Users/demo/.Trash/a 2.txt"
        }

        #expect(try trashItem("/Users/demo/a.txt") == "/Users/demo/.Trash/a 2.txt")
        #expect(recorder.all == ["/Users/demo/a.txt"])
    }

    // T-051125df
    @Test func givesTheTrashsOwnReasonOnTheStartupDiskNeverSuggestingToDelete() {
        let trashItem = makeTrashItem(devices: [home: startupDev, "/Users/demo/a.txt": startupDev]) { _ in throw refusal
        }

        let error = failure { try trashItem("/Users/demo/a.txt") }

        #expect(error?.message == refusal.message)
        #expect(error?.code == nil)
    }

    // T-c3b3fa5b F-334
    @Test func saysALockedItemIsLocked() {
        let trashItem = makeTrashItem(
            devices: [home: startupDev, "/Users/demo/a.txt": startupDev], flags: ["/Users/demo/a.txt": 0x2]
        ) { _ in throw refusal }

        #expect(
            failure { try trashItem("/Users/demo/a.txt") }?.message
                == "“a.txt” is locked. Unlock it in Finder's Get Info and try again.")
    }

    // A network share or some USB drives have no Trash: only there may deleting be offered. The Trash says so with
    // NSFeatureUnsupportedError, which NativeFS.trashItem gives as ENOTSUP.
    // T-56182f7a
    @Test func marksADiskTheTrashSaysHasNoneAsOneThatMayHaveNoTrash() {
        let trashItem = makeTrashItem(devices: [home: startupDev, "/Volumes/Share/a.txt": 50]) { _ in
            throw NativeError(
                message: "“a.txt” couldn’t be moved to the trash because the volume “Share” doesn’t have one.",
                code: "ENOTSUP", cocoaCode: 3328)
        }

        let error = failure { try trashItem("/Volumes/Share/a.txt") }

        #expect(error?.code == CopyPasteErrors.noTrashErrorCode)
        #expect(error?.message == "“a.txt” couldn’t be moved to the Trash. This disk may not have a Trash.")
    }

    // A failure the Trash gives no errno for (NSFileWriteUnknownError, say) says nothing about the disk having no
    // Trash: taken for one, it offered to delete for good with that reason.
    // T-a29b3fa8
    @Test func givesTheTrashsOwnReasonOnAnotherDiskForAFailureItGivesNoCodeFor() {
        let reason = NativeError(message: "“a.txt” couldn’t be moved to the trash.", cocoaCode: 512)
        let trashItem = makeTrashItem(devices: [home: startupDev, "/Volumes/Share/a.txt": 50]) { _ in throw reason }

        let error = failure { try trashItem("/Volumes/Share/a.txt") }

        #expect(error?.message == reason.message)
        #expect(error?.code != CopyPasteErrors.noTrashErrorCode)
    }

    // A network share without a Trash often answers with no errno once something was trashed: the kind of disk
    // tells then.
    // T-4180c814
    @Test func marksAFailureWithNoCodeOnADiskTakenToHaveNoTrash() {
        let reason = NativeError(message: "“a.txt” couldn’t be moved to the trash.", cocoaCode: 512)
        let trashItem = makeTrashItem(
            devices: [home: startupDev, "/Volumes/Share/a.txt": 50],
            diskHasTrash: { !$0.hasPrefix("/Volumes/Share/") }, trash: { _ in throw reason })

        let error = failure { try trashItem("/Volumes/Share/a.txt") }

        #expect(error?.code == CopyPasteErrors.noTrashErrorCode)
        #expect(error?.cause as? NativeError == reason)
    }

    // T-ee1f1e86
    @Test func keepsTheTrashsReasonForAFailureWithACodeOnADiskTakenToHaveNoTrash() {
        let reason = NativeError(message: "The disk is full.", code: "ENOSPC")
        let trashItem = makeTrashItem(
            devices: [home: startupDev, "/Volumes/Share/a.txt": 50], diskHasTrash: { _ in false },
            trash: { _ in throw reason })

        let error = failure { try trashItem("/Volumes/Share/a.txt") }

        #expect(error?.message == reason.message)
        #expect(error?.code != CopyPasteErrors.noTrashErrorCode)
    }

    // Deleting for good must never be offered for these: the disk has a Trash, the item just couldn't go to it.
    // T-0b99d712
    @Test(arguments: ["EACCES", "EPERM", "EROFS", "ENOENT", "EIO", "ENOSPC", "ECANCELED", "EINVAL"])
    func givesTheTrashsOwnReasonOnAnotherDisk(code: String) {
        let reason = NativeError(message: "You don’t have permission to access “a.txt”.", code: code)
        let trashItem = makeTrashItem(devices: [home: startupDev, "/Volumes/USB/a.txt": 50]) { _ in throw reason }

        let error = failure { try trashItem("/Volumes/USB/a.txt") }

        #expect(error?.message == reason.message)
        #expect(error?.code != CopyPasteErrors.noTrashErrorCode)
    }

    // T-034c7003
    @Test func givesTheTrashsReasonForAnItemThatIsGone() {
        let trashItem = makeTrashItem(devices: [home: startupDev]) { _ in throw refusal }

        #expect(failure { try trashItem("/Volumes/Share/a.txt") }?.message == refusal.message)
    }

    // Without a sentence of its own, the failure names the item.
    @Test func namesTheItemWhenTheTrashGaveNoReason() {
        let trashItem = makeTrashItem(devices: [home: startupDev, "/Users/demo/a.txt": startupDev]) { _ in
            throw OperationError("")
        }

        #expect(failure { try trashItem("/Users/demo/a.txt") }?.message == "“a.txt” couldn’t be moved to the Trash.")
    }
}
