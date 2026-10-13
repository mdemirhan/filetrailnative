// Port of the size, permission, duration and name cases of apps/desktop/src/renderer/lib/formatting.test.ts,
// with the sizes golden recorded from the reference (tools/parity/golden/sizes.ts).
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

    // T-1a458436 F-089
    @Test func formatsBytesAndDeferredStates() {
        #expect(SizeText.size(2048) == "2.0 KB")
        #expect(SizeText.size(nil, status: .deferred) == "Not yet available")
        #expect(SizeText.size(nil, status: .unavailable) == "Unavailable")
        #expect(SizeText.size(nil) == "Unavailable")
    }

    // T-c1d84397 F-089
    @Test func countsSizesInStepsOfOneThousand() {
        #expect(SizeText.size(999) == "999 B")
        #expect(SizeText.size(1000) == "1.0 KB")
        #expect(SizeText.size(1_500_000) == "1.5 MB")
        // The folders Finder showed as 99.43 GB and 226.59 GB.
        #expect(SizeText.size(99_433_647_655) == "99 GB")
        #expect(SizeText.size(226_587_120_929) == "227 GB")
        #expect(SizeText.size(2_000_000_000_000) == "2.0 TB")
    }

    // T-cf726d7a F-089
    @Test func stepsUpAUnitInsteadOfShowingAThousandOfOne() {
        #expect(SizeText.size(999_700) == "1.0 MB")
        #expect(SizeText.size(9_960) == "10 KB")
    }

    // JavaScript's toFixed rounds a tie up where printf rounds it to even.
    @Test func roundsATieUpAsToFixedDoes() {
        #expect(SizeText.size(1250) == "1.3 KB")
        #expect(SizeText.size(2250) == "2.3 KB")
        #expect(SizeText.size(12_500) == "13 KB")
        #expect(SizeText.size(9_950) == "10 KB")
    }

    // F-089
    @Test func sizesMatchTheReference() throws {
        let cases: [GoldenCase<SizeInput, String>] = try Golden.load(suite: "sizes")
        #expect(cases.count >= 300)
        Golden.expectMatches(cases) { SizeText.size($0.bytes, status: $0.status) }
    }

    // T-4d93eedd F-091
    @Test func formatsUnixPermissionModes() {
        #expect(PermissionText.mode(0o755) == "755")
        #expect(PermissionText.mode(0o7) == "007")
        #expect(PermissionText.mode(nil) == "Unavailable")
        #expect(PermissionText.mode(-1) == "Unavailable")
        #expect(PermissionText.mode(0o100644) == "644")
    }

    // T-b9212962 F-091
    @Test func splitsPermissionModesIntoSymbolicAndOctalParts() {
        #expect(PermissionText.split(0o644) == PermissionParts(symbolic: "rw-r--r--", octal: "644"))
        #expect(PermissionText.split(nil) == nil)
    }

    // F-091
    @Test func describesTheOwnersAccess() {
        #expect(PermissionText.ownerAccess(symbolic: "rw-r--r--") == "Read & Write")
        #expect(PermissionText.ownerAccess(symbolic: "r--r--r--") == "Read only")
        #expect(PermissionText.ownerAccess(symbolic: "-w-------") == "Write only")
        #expect(PermissionText.ownerAccess(symbolic: "---rwxrwx") == "No access")
        #expect(PermissionText.ownerAccess(symbolic: "") == "No access")
    }

    // T-55337866
    @Test func splitsPathSegmentsIncludingRoot() {
        #expect(
            PathText.segments("/Users/demo/Documents") == [
                PathSegment(label: "/", path: "/"),
                PathSegment(label: "Users", path: "/Users"),
                PathSegment(label: "demo", path: "/Users/demo"),
                PathSegment(label: "Documents", path: "/Users/demo/Documents"),
            ])
        #expect(PathText.segments("/") == [PathSegment(label: "/", path: "/")])
        #expect(PathText.segments("") == [PathSegment(label: "/", path: "/")])
    }

    // T-4c7f5482
    @Test func preservesTheExtensionSeparatelyForDisplayTruncation() {
        #expect(
            DisplayName.split("long filename.txt", extension: "txt")
                == DisplayNameParts(stem: "long filename", extensionSuffix: ".txt"))
        #expect(
            DisplayName.split("LONG.TXT", extension: "txt") == DisplayNameParts(stem: "LONG", extensionSuffix: ".txt"))
        #expect(DisplayName.split(".txt", extension: "txt") == DisplayNameParts(stem: ".txt", extensionSuffix: ""))
        #expect(DisplayName.split("name", extension: "txt") == DisplayNameParts(stem: "name", extensionSuffix: ""))
        #expect(DisplayName.split("name.txt", extension: "") == DisplayNameParts(stem: "name.txt", extensionSuffix: ""))
    }

    // T-5005707e
    @Test func durationInMilliseconds() {
        #expect(SizeText.relativeDuration(milliseconds: 500) == "500 ms")
        // File timestamps carry sub-millisecond precision.
        #expect(SizeText.relativeDuration(milliseconds: 9.737548828125) == "10 ms")
    }

    // T-7d10f1e9
    @Test func durationInSeconds() {
        #expect(SizeText.relativeDuration(milliseconds: 2000) == "2 seconds")
        #expect(SizeText.relativeDuration(milliseconds: 1000) == "1 second")
        // Sub-millisecond precision must not round up to "1000 ms".
        #expect(SizeText.relativeDuration(milliseconds: 999.6) == "1 second")
        #expect(SizeText.relativeDuration(milliseconds: 999.4) == "999 ms")
    }

    // T-8e864ba0
    @Test func durationInMinutes() {
        #expect(SizeText.relativeDuration(milliseconds: 90000) == "1 min")
        #expect(SizeText.relativeDuration(milliseconds: 45 * 60 * 1000) == "45 min")
    }

    // T-e25f9802
    @Test func durationInHours() {
        #expect(SizeText.relativeDuration(milliseconds: 3_600_000) == "1 hour")
        #expect(SizeText.relativeDuration(milliseconds: 5 * 3_600_000) == "5 hours")
    }

    // T-a4a87e81
    @Test func durationInDays() {
        #expect(SizeText.relativeDuration(milliseconds: 86_400_000) == "1 day")
        #expect(SizeText.relativeDuration(milliseconds: 7 * 86_400_000) == "7 days")
    }

    // T-cd1e192a
    @Test func durationInMonths() {
        #expect(SizeText.relativeDuration(milliseconds: 30 * 86_400_000) == "1 month")
    }

    // T-e7f2053e
    @Test func durationInYears() {
        #expect(SizeText.relativeDuration(milliseconds: 365 * 86_400_000) == "1 year")
        #expect(SizeText.relativeDuration(milliseconds: 730 * 86_400_000) == "2 years")
    }

    // T-8b884841
    @Test func durationOfNegativeValues() {
        #expect(SizeText.relativeDuration(milliseconds: -5000) == "5 seconds")
    }

    // T-8cbd4faa T-ba805edb T-b03aa542 T-cb8fc5ea T-4f128644
    @Test func hintSizes() {
        #expect(SizeText.hint(nil) == nil)
        #expect(SizeText.hint(0) == "0 B")
        #expect(SizeText.hint(512) == "512 B")
        #expect(SizeText.hint(1000) == "1.0 KB")
        #expect(SizeText.hint(1_000_000) == "1.0 MB")
    }

    // T-dc463c3e T-9e77b684 T-f1ae4d99 T-b5c00c19 T-d4e8025e T-2bb3f254
    @Test func sizeComparisonWithoutADelta() {
        #expect(SizeText.comparison(src: nil, dest: 1024) == nil)
        #expect(SizeText.comparison(src: 1024, dest: nil) == nil)
        #expect(SizeText.comparison(src: nil, dest: nil) == nil)
        #expect(SizeText.comparison(src: 999, dest: 1000) == SizeComparison(src: "999 B", dest: "1.0 KB", delta: nil))
        #expect(SizeText.comparison(src: 1000, dest: 1000) == SizeComparison(src: "1.0 KB", dest: "1.0 KB", delta: nil))
        #expect(SizeText.comparison(src: 0, dest: 0) == SizeComparison(src: "0 B", dest: "0 B", delta: nil))
    }

    // T-ba7ea15a T-a082619c T-74a26cc5
    @Test func sizeComparisonWithADelta() {
        // 1010000 and 1011000 both format to "1.0 MB".
        let larger = SizeText.comparison(src: 1_011_000, dest: 1_010_000)
        #expect(larger?.src == "1.0 MB")
        #expect(larger?.dest == "1.0 MB")
        #expect(larger?.delta?.hasPrefix("+") == true)
        let smaller = SizeText.comparison(src: 1_010_000, dest: 1_011_000)
        #expect(smaller?.delta?.hasPrefix("-") == true)
        #expect(larger?.delta == "+1.0 KB")
    }

    // T-08e47033 T-8ca2198e F-090
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

    // T-7099a412 T-49b7ee5d T-9451db68 T-34419f12 F-090
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
}
