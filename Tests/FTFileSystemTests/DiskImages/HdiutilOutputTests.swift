import Foundation
import Testing

@testable import FTFileSystem

private let deprecated = "hdiutil: WARNING: 'hdiutil attach ...' is deprecated.\n"

private func plist(_ body: String) -> String {
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<plist version=\"1.0\">\n<dict>\n\(body)\n</dict>\n</plist>\n"
}

private func attachOutput(_ mountPoints: String...) -> String {
    let entries = mountPoints.map { "<dict><key>mount-point</key>\n<string>\($0)</string></dict>" }.joined()
    return plist(
        "<key>system-entities</key>\n<array>\n<dict><key>dev-entry</key><string>/dev/disk5</string></dict>\(entries)</array>"
    )
}

@Suite struct HdiutilOutputTests {
    // T-31e7e6e9
    @Test func readsEveryValueOfAKeyWithXMLEscapesUndone() {
        #expect(
            HdiutilOutput.strings(in: attachOutput("/Volumes/Tom &amp; Jerry", "/Volumes/A&#38;B"), key: "mount-point")
                == ["/Volumes/Tom & Jerry", "/Volumes/A&B"])
        #expect(HdiutilOutput.strings(in: attachOutput(), key: "mount-point") == [])
    }

    // T-cc58861d
    @Test func readsABooleanOrNilWhenTheKeyIsntThere() {
        #expect(HdiutilOutput.boolean(in: plist("<key>encrypted</key>\n\t<true/>"), key: "encrypted") == true)
        #expect(HdiutilOutput.boolean(in: plist("<key>encrypted</key><false/>"), key: "encrypted") == false)
        #expect(HdiutilOutput.boolean(in: plist(""), key: "encrypted") == nil)
        // Only a boolean counts, as in the original.
        #expect(HdiutilOutput.boolean(in: plist("<key>encrypted</key><integer>1</integer>"), key: "encrypted") == nil)
    }

    @Test func outputThatIsNotAPlistReadsAsNothing() {
        #expect(HdiutilOutput.strings(in: "hdiutil: nope", key: "mount-point") == [])
        #expect(HdiutilOutput.boolean(in: "", key: "encrypted") == nil)
    }

    // T-f00e9d77
    @Test func readsWhyAnAttachFailedPastTheDeprecationWarning() {
        let image = HdiutilOutput.attachFailure(
            stderr: "\(deprecated)hdiutil: attach failed - image not recognized\n")
        #expect(image.canceled == false)
        #expect(image.reason == "image not recognized")
        let canceled = HdiutilOutput.attachFailure(stderr: "\(deprecated)hdiutil: attach canceled\n")
        #expect(canceled.canceled == true)
        #expect(canceled.reason == nil)
        let empty = HdiutilOutput.attachFailure(stderr: "")
        #expect(empty.canceled == false)
        #expect(empty.reason == nil)
    }
}

@Suite struct DiskImageNamesTests {
    // T-283a48d5
    @Test func namesTheImageAndGivesHdiutilsReasonAsASentence() {
        let notice = DiskImageNames.describeFailure(path: "/Users/demo/Broken.dmg", reason: "no mountable file systems")
        #expect(notice.title == "The disk image \u{201C}Broken.dmg\u{201D} couldn\u{2019}t be opened.")
        #expect(notice.message == "No mountable file systems.")
    }

    // T-82f5a19e
    @Test func saysAnUnexpectedErrorOccurredWithoutAReason() {
        #expect(
            DiskImageNames.describeFailure(path: "/Users/demo/Broken.dmg", reason: nil).message
                == "An unexpected error occurred.")
        #expect(
            DiskImageNames.describeFailure(path: "/Users/demo/Broken.dmg", reason: "  . ").message
                == "An unexpected error occurred.")
        #expect(DiskImageNames.describeFailure(path: "/Users/demo/Broken.dmg", reason: " busy. ").message == "Busy.")
    }

    // T-9e5c81d0 F-216
    @Test func knowsDiskImagesByTheExtensionsDiskImageMounterOpensInAnyCase() {
        #expect(DiskImageNames.isDiskImagePath("/Users/demo/Install.dmg"))
        #expect(DiskImageNames.isDiskImagePath("/Users/demo/Backup.SPARSEBUNDLE"))
        #expect(DiskImageNames.isDiskImagePath("/Users/demo/ubuntu.iso"))
        #expect(!DiskImageNames.isDiskImagePath("/Users/demo/notes.txt"))
        #expect(!DiskImageNames.isDiskImagePath("/Users/demo/.dmg"))
        #expect(!DiskImageNames.isDiskImagePath("/Users/demo/dmg"))
        #expect(DiskImageNames.extensions.count == 12)
    }
}

@MainActor @Suite struct OpenFileEntryPointTests {
    // The app's open-file handling (apps/desktop/src/main/main.ts): only disk images, queued until windows exist.
    @Test func takesOnlyDiskImagesAndWaitsForTheWindows() {
        var opened: [String] = []
        let entry = OpenFileEntryPoint { opened.append($0) }
        #expect(entry.open(["/a/b.txt", "/a/Install.dmg"]) == ["/a/Install.dmg"])
        #expect(opened.isEmpty)
        entry.startupWindowsOpened()
        #expect(opened == ["/a/Install.dmg"])
        entry.open(["/a/c.iso"])
        #expect(opened == ["/a/Install.dmg", "/a/c.iso"])
    }
}
