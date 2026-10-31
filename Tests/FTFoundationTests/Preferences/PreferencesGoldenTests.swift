// Checks the port against goldens recorded from the reference: tools/parity/golden/prefs-sanitize.ts
import FTTestSupport
import Foundation
import Testing

@testable import FTFoundation

struct PreferencesGoldenTests {
    struct Input: Codable, Sendable {
        let defaultTheme: String?
        let text: String
    }

    static func read(_ input: Input) -> AppState {
        let theme = input.defaultTheme.flatMap { ThemePreference(rawValue: $0) } ?? .auto
        return (try? AppStateReader.read(data: Data(input.text.utf8), defaults: .defaults(theme: theme))) ?? AppState()
    }

    // B-DLG-078 B-DLG-174 B-TREE-046
    @Test func savedStatesAreReadLikeTheOriginalReadsThem() throws {
        let cases: [GoldenCase<Input, AppState>] = try Golden.load(suite: "prefs-sanitize")
        #expect(cases.count >= 300)
        Golden.expectMatches(cases) { Self.read($0) }
    }
}
