// Tests of addNumberToName and the New Folder numbering, against tools/parity/golden/number-names.ts and the original's code
import FTTestSupport
import Testing

@testable import FTFoundation

struct NumberedNamesTests {
    struct NumberInput: Codable, Sendable {
        let name: String
        let isFolder: Bool
        let separator: String
        let number: Int
    }

    struct NumberOutput: Codable, Equatable, Sendable {
        let name: String
        let keptStemLength: Int
        let stemLength: Int
    }

    // F-042 F-063
    @Test func addNumberToNameMatchesTheReference() throws {
        let cases: [GoldenCase<NumberInput, NumberOutput>] = try Golden.load(suite: "number-names")
        #expect(cases.count >= 200)
        Golden.expectMatches(cases) {
            let numbered = NumberedNames.addNumberToName(
                $0.name, isFolder: $0.isFolder, separator: $0.separator, number: $0.number)
            return NumberOutput(
                name: numbered.name, keptStemLength: numbered.keptStemLength, stemLength: numbered.stemLength)
        }
    }

    // F-042 F-063
    @Test func numbersBeforeTheExtension() {
        #expect(
            NumberedNames.addNumberToName("Lisbon.jpg", isFolder: false, separator: " ", number: 2).name
                == "Lisbon 2.jpg")
        #expect(
            NumberedNames.addNumberToName("Lisbon.jpg", isFolder: true, separator: " ", number: 2).name
                == "Lisbon.jpg 2")
        #expect(NumberedNames.addNumberToName(".env", isFolder: false, separator: " ", number: 3).name == ".env 3")
    }

    static func folder(_ name: String, taken: Set<String>) throws -> String {
        try NumberedNames.nextFreeFolderPath(in: "/p", name: name, exists: { taken.contains($0) })
    }

    // F-298
    @Test func newFolderCountsUpFromTwo() throws {
        #expect(try Self.folder("untitled folder", taken: []) == "/p/untitled folder 2")
        #expect(try Self.folder("untitled folder", taken: ["/p/untitled folder 2"]) == "/p/untitled folder 3")
    }

    // F-298
    @Test func newFolderContinuesFromTheNumberItAlreadyEndsIn() throws {
        #expect(try Self.folder("untitled folder 3", taken: []) == "/p/untitled folder 4")
        #expect(try Self.folder("Photos 2024", taken: []) == "/p/Photos 2025")
        #expect(try Self.folder("a 1 2", taken: []) == "/p/a 1 3")
        #expect(try Self.folder("a 0", taken: []) == "/p/a 1")
        #expect(try Self.folder("a 007", taken: []) == "/p/a 8")
        #expect(try Self.folder("a 1x", taken: []) == "/p/a 1x 2")
        #expect(try Self.folder(" 5", taken: []) == "/p/ 6")
        #expect(try Self.folder("a\n 5", taken: []) == "/p/a\n 5 2")
    }

    // F-298
    @Test func newFolderGivesUpAfterTenThousandTries() {
        let error = #expect(throws: NumberedNames.NameTaken.self) {
            try NumberedNames.nextFreeFolderPath(in: "/p", name: "x", exists: { _ in true })
        }
        #expect(error?.description == "An item named \u{201C}x\u{201D} already exists.")
    }

    // F-298
    @Test func newFolderWritesNumbersAsJavaScriptDoes() throws {
        #expect(try Self.folder("x 99999999999999999999", taken: []) == "/p/x 100000000000000000000")
        #expect(JSText.integerText(1e21) == "1e+21")
        #expect(JSText.integerText(1.2345678901234568e20) == "123456789012345680000")
    }
}
