// Port of apps/desktop/src/renderer/lib/iconLabel.test.ts, with the icon-label golden recorded from the
// reference (tools/parity/golden/icon-label.ts): the same fake text width on both sides.
import FTTestSupport
import Testing

@testable import FTFoundation

struct IconLabelTests {
    struct Input: Codable, Sendable {
        let name: String
        let `extension`: String
        let limit: Int
    }

    // Stands in for the label: a name "fits" when it is at most `limit` characters long.
    private func fitsWithin(_ limit: Int) -> (String) -> Bool {
        { $0.utf16.count <= limit }
    }

    private func shorten(_ name: String, _ fileExtension: String, _ fits: (String) -> Bool) -> String {
        IconLabel.shortenInMiddle(name: name, extension: fileExtension, fits: fits)
    }

    // T-56a7ac62
    @Test func returnsANameThatFitsUnchanged() {
        #expect(shorten("notes.txt", "txt", fitsWithin(20)) == "notes.txt")
    }

    // T-4695b6ea F-069
    @Test func keepsTheStartTheEndOfTheNameAndTheExtension() {
        #expect(
            shorten("Panorama Miradouro da Senhora do Monte.jpeg", "jpeg", fitsWithin(35))
                == "Panorama Miradouro da Se…Monte.jpeg")
    }

    // T-7dbf72ef
    @Test func usesAllTheRoomThereIs() {
        let shortened = shorten(String(repeating: "a", count: 80), "", fitsWithin(30))
        #expect(shortened.count == 30)
        #expect(shortened == String(repeating: "a", count: 24) + "…" + String(repeating: "a", count: 5))
    }

    // T-62cad7de
    @Test func doesNotLeaveASpaceBeforeTheEllipsis() {
        #expect(shorten("Quarterly report final version.pdf", "pdf", fitsWithin(20)) == "Quarterly…rsion.pdf")
    }

    // T-e4e6d3ab
    @Test func keepsLessOfTheEndWhenTheNameBeforeTheExtensionIsShort() {
        #expect(shorten("abcdef.verylongextension", "verylongextension", fitsWithin(23)) == "a…def.verylongextension")
    }

    // T-af019005
    @Test func keepsLessOfTheEndWhenAllOfItLeavesNoRoomForAStart() {
        #expect(shorten("Miradouro da Senhora do Monte at sunset.png", "png", fitsWithin(10)) == "M…nset.png")
        #expect(shorten("Miradouro da Senhora do Monte at sunset.png", "png", fitsWithin(6)) == "M….png")
    }

    // T-31947138
    @Test func returnsTheNameWholeWhenNoShorteningFits() {
        #expect(shorten("abcdefghij.txt", "txt", fitsWithin(3)) == "abcdefghij.txt")
    }

    // T-99ce80bb
    @Test func neverCutsACharacterOutsideTheBasicPlaneInHalf() {
        let name = String(repeating: "😀", count: 20) + ".png"
        let shortened = shorten(name, "png") { $0.unicodeScalars.count <= 12 }
        #expect(shortened.unicodeScalars.count == 12)
        #expect(shortened == String(repeating: "😀", count: 2) + "…" + String(repeating: "😀", count: 5) + ".png")
    }

    // N/A T-e1345f3d fitIconLabel measures the label in the DOM and leaves names whole where nothing can be measured; AppKit supplies the text widths and the two-line wrapping later
    @Test func aNameThatCannotBeMeasuredIsLeftToTheLabel() {
        let name = String(repeating: "long name ", count: 12) + ".txt"
        #expect(shorten(name, "txt", { _ in false }) == name)
    }

    // The fake width the golden was recorded with: each code point is 2 + (code point mod 5) wide.
    private func fakeWidth(_ text: String) -> Int {
        text.unicodeScalars.reduce(0) { $0 + 2 + Int($1.value % 5) }
    }

    // F-069
    @Test func shortenedNamesMatchTheReference() throws {
        let cases: [GoldenCase<Input, String>] = try Golden.load(suite: "icon-label")
        #expect(cases.count >= 300)
        Golden.expectMatches(cases) { input in
            shorten(input.name, input.extension) { fakeWidth($0) <= input.limit }
        }
    }
}
