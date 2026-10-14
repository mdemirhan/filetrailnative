import Foundation
import Testing

@testable import FTFileSystem

private func volume(_ name: String, isLocal: Bool = true, canEject: Bool = true, disk: String?? = nil) -> Volume {
    testVolume(name, isLocal: isLocal, canEject: canEject, disk: disk ?? "disk-\(name)")
}

@Suite struct EjectPlanningTests {
    // T-d8671ef9
    @Test func ejectsADiskOfItsOwnAtOnce() {
        #expect(
            EjectPlanning.planEject([volume("USB"), volume("Backup")], path: "/Volumes/USB")
                == .eject(path: "/Volumes/USB"))
    }

    // T-3bd103be
    @Test func asksFirstAboutAVolumeWhoseDiskHoldsOthersNamingThem() {
        let volumes = [volume("Photos", disk: "disk7"), volume("USB"), volume("Video", disk: "disk7")]
        #expect(
            EjectPlanning.planEject(volumes, path: "/Volumes/Photos")
                == .askWhichVolumes(path: "/Volumes/Photos", name: "Photos", otherNames: ["Video"]))
    }

    // T-a8912768
    @Test func neverGroupsNetworkSharesWhichHaveNoDisk() {
        let volumes = [
            volume("Shared", isLocal: false, disk: .some(nil)), volume("Media", isLocal: false, disk: .some(nil)),
        ]
        #expect(EjectPlanning.planEject(volumes, path: "/Volumes/Shared") == .eject(path: "/Volumes/Shared"))
    }

    // T-21da80a1
    @Test func doesNothingForADiskThatCantBeEjectedOrIsGone() {
        #expect(EjectPlanning.planEject([volume("Data", canEject: false)], path: "/Volumes/Data") == nil)
        #expect(EjectPlanning.planEject([], path: "/Volumes/USB") == nil)
    }

    private let volumes = [volume("USB"), volume("Data", canEject: false)]

    // T-b3821aa9
    @Test func targetIsTheDiskSelectedInTheSidebarItsLocationsRowOrTheTopOfTheTree() {
        for id in ["location:/Volumes/USB", "fs:/Volumes/USB"] {
            #expect(
                EjectPlanning.resolveEjectTargetPath(focusedPane: .tree, selectedTreeItemId: id, volumes: volumes)
                    == "/Volumes/USB")
            #expect(
                EjectPlanning.resolveEjectTargetPath(focusedPane: nil, selectedTreeItemId: id, volumes: volumes)
                    == "/Volumes/USB")
        }
    }

    // T-e835ed63
    @Test func targetIsNoneWithTheFileListInFrontOrForAnythingButAnEjectableDisk() {
        #expect(
            EjectPlanning.resolveEjectTargetPath(
                focusedPane: .content, selectedTreeItemId: "location:/Volumes/USB", volumes: volumes) == nil)
        for id in ["location:/Volumes/Data", "fs:/Volumes/USB/Photos", "location:/", "favorite:/Volumes/Gone"] {
            #expect(
                EjectPlanning.resolveEjectTargetPath(focusedPane: .tree, selectedTreeItemId: id, volumes: volumes)
                    == nil)
        }
        #expect(
            EjectPlanning.resolveEjectTargetPath(focusedPane: .tree, selectedTreeItemId: nil, volumes: volumes) == nil)
    }

    @Test func ejectablePath() {
        #expect(EjectPlanning.isEjectablePath(volumes, path: "/Volumes/USB"))
        #expect(!EjectPlanning.isEjectablePath(volumes, path: "/Volumes/Data"))
        #expect(!EjectPlanning.isEjectablePath(volumes, path: nil))
    }

    // T-2a218da2
    @Test func asksAboutAllTheVolumesOfTheDisk() {
        let notice = EjectPlanning.describeWhichVolumesQuestion(name: "Photos", otherNames: ["Video"])
        #expect(notice.title == "Do you want to eject \u{201C}Photos\u{201D} only, or all 2 volumes on its disk?")
        #expect(
            notice.message
                == "The disk also holds \u{201C}Video\u{201D}. Eject All lets you disconnect it; Eject leaves the others mounted."
        )
        #expect(
            EjectPlanning.describeWhichVolumesQuestion(name: "A", otherNames: ["B", "C", "D", "E"]).message
                .contains("\u{201C}B\u{201D}, \u{201C}C\u{201D}, \u{201C}D\u{201D} and 1 more"))
        #expect(
            EjectPlanning.describeWhichVolumesQuestion(name: "A", otherNames: ["B", "C"]).message
                .contains("\u{201C}B\u{201D} and \u{201C}C\u{201D}"))
    }

    // T-890fe2c5
    @Test func saysWhichDiskIsInUseAndCallsAServerAVolume() {
        let all = [volume("USB"), volume("Shared", isLocal: false, disk: .some(nil))]
        #expect(
            EjectPlanning.describeEjectBusy(all, busyPath: "/Volumes/USB").title
                == "The disk \u{201C}USB\u{201D} wasn\u{2019}t ejected because one or more programs may be using it.")
        #expect(
            EjectPlanning.describeEjectBusy(all, busyPath: "/Volumes/Shared").title
                == "The volume \u{201C}Shared\u{201D} wasn\u{2019}t ejected because one or more programs may be using it."
        )
        #expect(
            EjectPlanning.describeEjectBusy(all, busyPath: "/Volumes/Shared").message
                == "To eject the volume immediately, click Force Eject. A program using it may lose changes it hasn\u{2019}t saved."
        )
    }

    // T-ab270936
    @Test func namesTheDiskAskedForWhenTheDiskItselfFailedWithDiskArbitrationsReason() {
        let all = [volume("USB")]
        let failed = EjectPlanning.describeEjectFailure(
            all, path: "/Volumes/USB", failedPath: "/dev/disk7", code: "EIO", reason: "The device is not responding.")
        #expect(failed.title == "The disk \u{201C}USB\u{201D} couldn\u{2019}t be ejected.")
        #expect(failed.message == "The device is not responding.")
        #expect(
            EjectPlanning.describeEjectFailure(
                all, path: "/Volumes/USB", failedPath: "/Volumes/USB", code: "ETIMEDOUT", reason: nil
            ).message == "The disk didn\u{2019}t answer in time. Try again in a moment.")
    }

    @Test func otherFailureWording() {
        let all = [volume("USB")]
        func message(_ code: String?) -> String {
            EjectPlanning.describeEjectFailure(all, path: "/Volumes/USB", failedPath: nil, code: code, reason: nil)
                .message
        }
        #expect(message("EPERM") == "macOS didn\u{2019}t allow File Trail to eject it.")
        #expect(message("EACCES") == "macOS didn\u{2019}t allow File Trail to eject it.")
        #expect(message("EIO") == "An unexpected error occurred (EIO).")
        #expect(message(nil) == "An unexpected error occurred.")
    }
}
