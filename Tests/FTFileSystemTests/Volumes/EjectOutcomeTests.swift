import Foundation
import Testing

@testable import FTFileSystem

/// Records what the eject was asked.
private final class Calls: @unchecked Sendable {
    var all: [(path: String, force: Bool, wholeDisk: Bool)] = []
}

@Suite struct EjectOutcomeTests {
    let request = EjectRequest(path: "/Volumes/Backup", wholeDisk: true, force: false)

    // T-8956207d
    @Test func passesTheChoicesOnAndSaysTheDiskIsEjected() async {
        let calls = Calls()
        let response = await EjectOutcome.ejectVolume(request) { path, force, wholeDisk in
            calls.all.append((path, force, wholeDisk))
        }
        #expect(response == EjectResponse(status: .ejected, failedPath: nil, code: nil, reason: nil))
        #expect(calls.all.count == 1)
        #expect(calls.all.first?.path == "/Volumes/Backup")
        #expect(calls.all.first?.force == false)
        #expect(calls.all.first?.wholeDisk == true)
    }

    // T-b6d277d8
    @Test func namesTheVolumeInUseWhichMayBeAnotherOnTheSameDisk() async {
        let response = await EjectOutcome.ejectVolume(request) { _, _, _ in
            throw EjectError(errnum: EBUSY, path: "/Volumes/Backup 2")
        }
        #expect(
            response
                == EjectResponse(status: .busy, failedPath: "/Volumes/Backup 2", code: "EBUSY", reason: nil))
    }

    // T-a48b7c51
    @Test func countsAVolumeAlreadyGoneAsEjected() async {
        let response = await EjectOutcome.ejectVolume(request) { _, _, _ in
            throw EjectError(errnum: ENOENT, path: "/Volumes/Backup")
        }
        #expect(response.status == .ejected)
    }

    @Test func aVolumeOfTheDiskGoneIsAFailureNotAnEject() async {
        let response = await EjectOutcome.ejectVolume(request) { _, _, _ in
            throw EjectError(errnum: ENOENT, path: "/Volumes/Backup 2")
        }
        #expect(response.status == .failed)
    }

    // T-824a0559
    @Test func givesAnyOtherFailureWithDiskArbitrationsSentence() async {
        let response = await EjectOutcome.ejectVolume(request) { _, _, _ in
            throw EjectError(errnum: EPERM, path: "/dev/disk4", reason: "Not permitted by a claim.")
        }
        #expect(
            response
                == EjectResponse(
                    status: .failed, failedPath: "/dev/disk4", code: "EPERM", reason: "Not permitted by a claim."))
    }

    @Test func statusesMapToErrnosAsTheOriginalDoes() {
        // unix_err(EBUSY): the system's errno wrapped.
        #expect(VolumeEjector.errno(ofStatus: Int32(0xc000 | EBUSY)) == EBUSY)
        #expect(VolumeEjector.errno(ofStatus: Int32(bitPattern: 0xf8da_0002)) == EBUSY)
        #expect(VolumeEjector.errno(ofStatus: Int32(bitPattern: 0xf8da_000b)) == EIO)
        #expect(ErrnoName.name(of: ETIMEDOUT) == "ETIMEDOUT")
        #expect(ErrnoName.name(of: 9999) == "UNKNOWN")
    }
}
