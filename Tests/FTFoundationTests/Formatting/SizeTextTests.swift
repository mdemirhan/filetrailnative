import FTTestSupport
import Foundation
import Testing

@testable import FTFoundation

struct SizeTextTests {
    struct SizeInput: Codable, Sendable {
        let bytes: Int64?
        let status: SizeStatus
    }

    let en = Locale(identifier: "en_US")

    @Test func formatsBytesAndDeferredStates() {
        #expect(SizeText.size(2048) == "2.0 KB")
        #expect(SizeText.size(nil, status: .deferred) == "Not yet available")
        #expect(SizeText.size(nil, status: .unavailable) == "Unavailable")
        #expect(SizeText.size(nil) == "Unavailable")
    }

    @Test func countsSizesInStepsOfOneThousand() {
        #expect(SizeText.size(999) == "999 B")
        #expect(SizeText.size(1000) == "1.0 KB")
        #expect(SizeText.size(1_500_000) == "1.5 MB")
        // The folders Finder showed as 99.43 GB and 226.59 GB.
        #expect(SizeText.size(99_433_647_655) == "99 GB")
        #expect(SizeText.size(226_587_120_929) == "227 GB")
        #expect(SizeText.size(2_000_000_000_000) == "2.0 TB")
    }

    @Test func stepsUpAUnitInsteadOfShowingAThousandOfOne() {
        #expect(SizeText.size(999_700) == "1.0 MB")
        #expect(SizeText.size(9_960) == "10 KB")
    }

    // A size halfway between two shown values rounds up, where printf would round it to even.
    @Test func roundsAHalfUpNotToEven() {
        #expect(SizeText.size(1250) == "1.3 KB")
        #expect(SizeText.size(2250) == "2.3 KB")
        #expect(SizeText.size(12_500) == "13 KB")
        #expect(SizeText.size(9_950) == "10 KB")
    }

    @Test func sizesMatchTheGoldenFile() throws {
        let cases: [GoldenCase<SizeInput, String>] = try Golden.load(suite: "sizes")
        #expect(cases.count >= 300)
        Golden.expectMatches(cases) { SizeText.size($0.bytes, status: $0.status) }
    }

    @Test func formatsUnixPermissionModes() {
        #expect(PermissionText.mode(0o755) == "755")
        #expect(PermissionText.mode(0o7) == "007")
        #expect(PermissionText.mode(nil) == "Unavailable")
        #expect(PermissionText.mode(-1) == "Unavailable")
        #expect(PermissionText.mode(0o100644) == "644")
    }

    @Test func splitsPermissionModesIntoSymbolicAndOctalParts() {
        #expect(PermissionText.split(0o644) == PermissionParts(symbolic: "rw-r--r--", octal: "644"))
        #expect(PermissionText.split(nil) == nil)
    }

    @Test func describesTheOwnersAccess() {
        #expect(PermissionText.ownerAccess(symbolic: "rw-r--r--") == "Owner: Read & Write")
        #expect(PermissionText.ownerAccess(symbolic: "r--r--r--") == "Owner: Read only")
        #expect(PermissionText.ownerAccess(symbolic: "-w-------") == "Owner: Write only")
        #expect(PermissionText.ownerAccess(symbolic: "---rwxrwx") == "Owner: No access")
        #expect(PermissionText.ownerAccess(symbolic: "") == "Owner: No access")
    }

    @Test func preservesTheExtensionSeparatelyForDisplayTruncation() {
        #expect(
            DisplayName.split("long filename.txt", extension: "txt")
                == DisplayNameParts(stem: "long filename", extensionSuffix: ".txt"))
        #expect(
            DisplayName.split("LONG.TXT", extension: "txt") == DisplayNameParts(stem: "LONG", extensionSuffix: ".TXT"))
        #expect(
            DisplayName.split("Symbols.dSYM", extension: "dsym")
                == DisplayNameParts(stem: "Symbols", extensionSuffix: ".dSYM"))
        #expect(DisplayName.split(".txt", extension: "txt") == DisplayNameParts(stem: ".txt", extensionSuffix: ""))
        #expect(DisplayName.split("name", extension: "txt") == DisplayNameParts(stem: "name", extensionSuffix: ""))
        #expect(DisplayName.split("name.txt", extension: "") == DisplayNameParts(stem: "name.txt", extensionSuffix: ""))
    }

    @Test func folderSizeDetailSaysTheSizeOnDisk() {
        let different = SizeText.folderDetail(
            sizeBytes: 1_000_000, diskBytes: 1_500_000, fileCount: 500, folderCount: 20, locale: en)
        #expect(different.size == "1.0 MB")
        #expect(different.disk == "1.5 MB on disk")
        let same = SizeText.folderDetail(
            sizeBytes: 1_000_000, diskBytes: 1_000_000, fileCount: 100, folderCount: 0, locale: en)
        #expect(same.size == "1.0 MB")
        #expect(same.disk == nil)
    }

    @Test func folderSizeDetailNamesWhatTheFolderHolds() {
        func items(_ files: Int, _ folders: Int) -> String {
            SizeText.folderDetail(sizeBytes: 1, diskBytes: 1, fileCount: files, folderCount: folders, locale: en).items
        }
        #expect(items(48611, 2765) == "48,611 files, 2,765 folders")
        #expect(items(153, 0) == "153 files")
        #expect(items(0, 4) == "4 folders")
        #expect(items(1, 1) == "1 file, 1 folder")
        let empty = SizeText.folderDetail(sizeBytes: 0, diskBytes: 0, fileCount: 0, folderCount: 0, locale: en)
        #expect(empty.size == "0 B")
        #expect(empty.disk == nil)
        #expect(empty.items == "Empty")
    }

    // A size and a count are written with the region's decimal mark and digit grouping, as Finder writes them.
    @Test func sizesAndCountsFollowTheRegion() {
        let germany = Locale(identifier: "en_DE")
        #expect(SizeText.size(1_500_000, locale: germany) == "1,5 MB")
        #expect(SizeText.size(2_000_000_000_000, locale: germany) == "2,0 TB")
        #expect(SizeText.size(99_433_647_655, locale: germany) == "99 GB")
        #expect(SizeText.size(999, locale: germany) == "999 B")
        let detail = SizeText.folderDetail(
            sizeBytes: 1_000_000, diskBytes: 1_500_000, fileCount: 48611, folderCount: 2765, locale: germany)
        #expect(detail.size == "1,0 MB")
        #expect(detail.disk == "1,5 MB on disk")
        #expect(detail.items == "48.611 files, 2.765 folders")
        let uk = Locale(identifier: "en_GB")
        #expect(SizeText.size(1_500_000, locale: uk) == "1.5 MB")
        #expect(FormatLocale.count(1_234_567, locale: uk) == "1,234,567")
        #expect(FormatLocale.count(1_234_567, locale: germany) == "1.234.567")
        #expect(FormatLocale.count(999, locale: germany) == "999")
    }

    // A test process writes in US English whatever the Mac is set to, so the expected texts hold on any Mac.
    @Test func aTestProcessWritesInUSEnglish() {
        #expect(FormatLocale.isTestProcess)
        #expect(FormatLocale.current == Locale(identifier: "en_US"))
        #expect(FormatLocale.count(1234) == "1,234")
        #expect(SizeText.size(1_500_000) == "1.5 MB")
    }
}
