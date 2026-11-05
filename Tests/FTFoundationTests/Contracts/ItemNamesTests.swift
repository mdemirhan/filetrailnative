import FTTestSupport
import Testing

@testable import FTFoundation

struct ItemNamesTests {
    @Test func acceptsOrdinaryNamesIncludingDotsAndColons() {
        #expect(ItemNames.error(for: "report.pdf") == nil)
        #expect(ItemNames.error(for: ".env") == nil)
        #expect(ItemNames.error(for: "...") == nil)
        #expect(ItemNames.error(for: "a:b") == nil)
        // A Windows path kept as a name: "\" is an ordinary character on macOS.
        #expect(ItemNames.error(for: "C:\\notes.txt") == nil)
    }

    @Test func rejectsEmptyAndDotSegmentNames() {
        #expect(ItemNames.error(for: "   ") == "Enter a name.")
        #expect(ItemNames.error(for: ".") == "\".\" is not a valid name.")
        #expect(ItemNames.error(for: " .. ") == "\"..\" is not a valid name.")
    }

    @Test func rejectsNamesContainingPathSeparatorsOrNul() {
        #expect(ItemNames.error(for: "../escape") != nil)
        #expect(ItemNames.error(for: "sub/child") == "Names can\u{2019}t contain \u{201C}/\u{201D}.")
        #expect(ItemNames.error(for: "nul\0byte") != nil)
    }

    @Test func limitsNamesTo255BytesOfUTF8NotCharacters() {
        let tooLong = "The name is too long."
        #expect(ItemNames.error(for: String(repeating: "a", count: 255)) == nil)
        #expect(ItemNames.error(for: String(repeating: "a", count: 256)) == tooLong)
        // 128 two-byte characters: 128 characters, 256 bytes.
        #expect(ItemNames.error(for: String(repeating: "\u{E9}", count: 127)) == nil)
        #expect(ItemNames.error(for: String(repeating: "\u{E9}", count: 128)) == tooLong)
        // Three bytes each: 86 of them are 258 bytes.
        #expect(ItemNames.error(for: String(repeating: "\u{65E5}", count: 85)) == nil)
        #expect(ItemNames.error(for: String(repeating: "\u{65E5}", count: 86)) == tooLong)
        // Surrounding spaces are trimmed before counting.
        #expect(ItemNames.error(for: " \(String(repeating: "a", count: 255))") == nil)
    }

    @Test func knowsAPackageByItsExtensionInAnyCase() {
        #expect(ItemNames.isMacOSPackageName("Safari.app"))
        #expect(ItemNames.isMacOSPackageName("Foo.FRAMEWORK"))
        #expect(ItemNames.isMacOSPackageName("Sound.prefPane"))
        #expect(!ItemNames.isMacOSPackageName("Applications"))
        #expect(!ItemNames.isMacOSPackageName(".app"))
        #expect(!ItemNames.isMacOSPackageName("notes.txt"))
    }

    struct Output: Codable, Equatable, Sendable {
        let error: String?
        let package: Bool
    }

    @Test func validationMatchesTheGoldenFile() throws {
        let cases: [GoldenCase<String, Output>] = try Golden.load(suite: "item-name-validation")
        #expect(cases.count >= 300)
        Golden.expectMatches(cases) {
            Output(error: ItemNames.error(for: $0), package: ItemNames.isMacOSPackageName($0))
        }
    }

    @Test func limitsHaveTheirSetValues() {
        #expect(Limits.maxPathsPerRequest == 100_000)
        #expect(Limits.maxFileDragImages == 5)
    }
}
