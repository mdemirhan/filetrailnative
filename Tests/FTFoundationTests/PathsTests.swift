// Port of packages/contracts/src/paths.test.ts and trash.test.ts, and tests of the system-location rules of writeOperations.ts
import Testing

@testable import FTFoundation

struct PathsTests {
    // T-2463dcda F-029 F-121
    @Test func keepsAFolderAndDropsWhatIsInsideItAndRepeats() {
        #expect(
            Paths.withoutNestedPaths(["/a/F/x.txt", "/a/F", "/a/G", "/a/F/sub/y.txt", "/a/G", "/a/Fx"])
                == ["/a/F", "/a/G", "/a/Fx"])
    }

    // T-71688b9d F-029 F-121
    @Test func dropsEverythingUnderTheStartupDiskWhenItIsPicked() {
        #expect(Paths.withoutNestedPaths(["/Users/demo", "/"]) == ["/"])
    }

    // T-f94ecc09 F-030 F-120
    @Test func knowsTheHomeFoldersTrashAndWhatIsInIt() {
        #expect(Paths.isInsideTrash("/Users/demo/.Trash", homePath: "/Users/demo"))
        #expect(Paths.isInsideTrash("/Users/demo/.Trash/old/a.txt", homePath: "/Users/demo"))
        #expect(Paths.isInsideTrash("/Users/demo/.Trash", homePath: "/Users/demo/"))
    }

    // T-1a5171dc F-030 F-120
    @Test func knowsAnotherDisksTrash() {
        #expect(Paths.isInsideTrash("/Volumes/USB/.Trashes", homePath: "/Users/demo"))
        #expect(Paths.isInsideTrash("/Volumes/USB/.Trashes/501/a.txt", homePath: "/Users/demo"))
    }

    // T-6a61c326 F-030 F-120
    @Test func ignoresLetterCaseAsTheDiskDoes() {
        #expect(Paths.isInsideTrash("/users/DEMO/.trash/a.txt", homePath: "/Users/demo"))
    }

    // T-48a6c8c1 F-030 F-120
    @Test func isntFooledByNamesThatOnlyBeginLikeTheTrash() {
        #expect(!Paths.isInsideTrash("/Users/demo/.Trash2", homePath: "/Users/demo"))
        #expect(!Paths.isInsideTrash("/Users/demo/Documents/.Trash", homePath: "/Users/demo"))
        #expect(!Paths.isInsideTrash("/Volumes/USB/.TrashesBackup", homePath: "/Users/demo"))
        #expect(!Paths.isInsideTrash("/Volumes/USB/Stuff/.Trashes", homePath: "/Users/demo"))
        #expect(!Paths.isInsideTrash("/Users/demo/.Trash", homePath: ""))
    }

    // T-f760ee44 F-030 F-120
    @Test func knowsTheTrashFolderOfTheHomeAndOfOtherDisksAndEachUsersTrash() {
        #expect(Paths.isTrashFolder("/Users/demo/.Trash", homePath: "/Users/demo"))
        #expect(Paths.isTrashFolder("/users/DEMO/.trash/", homePath: "/Users/demo/"))
        #expect(Paths.isTrashFolder("/Volumes/USB/.Trashes", homePath: "/Users/demo"))
        #expect(Paths.isTrashFolder("/Volumes/USB/.Trashes/501", homePath: "/Users/demo"))
        #expect(Paths.isTrashFolder("/volumes/usb/.TRASHES/501/", homePath: "/Users/demo"))
    }

    // T-47750504 F-030 F-120
    @Test func leavesWhatIsInATrashToBeDeleted() {
        #expect(!Paths.isTrashFolder("/Users/demo/.Trash/a.txt", homePath: "/Users/demo"))
        #expect(!Paths.isTrashFolder("/Volumes/USB/.Trashes/501/a.txt", homePath: "/Users/demo"))
        #expect(!Paths.isTrashFolder("/Volumes/USB/.Trashes2", homePath: "/Users/demo"))
        #expect(!Paths.isTrashFolder("/Volumes/USB/Stuff/.Trashes", homePath: "/Users/demo"))
        #expect(!Paths.isTrashFolder("/Users/demo/.Trash", homePath: ""))
        #expect(!Paths.isTrashFolder("/", homePath: "/Users/demo"))
    }

    // MARK: System locations

    static func refusal(_ path: String, verb: String = "moved") -> String? {
        Paths.systemLocationRefusal(path: path, verb: verb, homePath: "/Users/demo")
    }

    @Test func refusesTheStartupDiskAndTheFoldersThatHoldTheSystem() {
        #expect(Self.refusal("/") == "The startup disk can't be moved.")
        #expect(Self.refusal("//") == "The startup disk can't be moved.")
        #expect(Self.refusal("/Users") == "\u{201C}Users\u{201D} can't be moved.")
        #expect(Self.refusal("/USERS/") == "\u{201C}USERS\u{201D} can't be moved.")
        #expect(Self.refusal("/System/Volumes/Data", verb: "deleted") == "\u{201C}Data\u{201D} can't be deleted.")
        #expect(Self.refusal("/private/../etc") == "\u{201C}etc\u{201D} can't be moved.")
    }

    @Test func refusesTheHomeFolderAndItsOwnFolders() {
        for path in [
            "/Users/demo", "/users/DEMO/documents", "/Users/demo/Library", "/Users/demo/.Trash", "/Users/demo/Public/",
        ] {
            #expect(Self.refusal(path) != nil, "\(path)")
        }
        #expect(Self.refusal("/Users/demo/Documents/report.txt") == nil)
        #expect(Self.refusal("/Users/demo/Documents/Desktop") == nil)
        #expect(Self.refusal("/Users/demo2") == nil)
    }

    @Test func refusesAWholeDiskButNotWhatIsInIt() {
        #expect(Self.refusal("/Volumes/USB") == "\u{201C}USB\u{201D} can't be moved.")
        #expect(Self.refusal("/volumes/usb/") != nil)
        #expect(Self.refusal("/Volumes/USB/folder") == nil)
        #expect(Self.refusal("/Volumes/") == "\u{201C}Volumes\u{201D} can't be moved.")
    }

    @Test func wantsAnAbsolutePath() {
        #expect(Self.refusal("relative/path") == "Expected an absolute path.")
        #expect(Self.refusal("") == "Expected an absolute path.")
    }
}
