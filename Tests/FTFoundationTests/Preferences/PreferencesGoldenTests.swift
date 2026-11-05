// Checks how saved preferences are sanitized, against the prefs-sanitize golden
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

    @Test func savedStatesAreReadAsTheGoldenFileSays() throws {
        let cases: [GoldenCase<Input, AppState>] = try Golden.load(suite: "prefs-sanitize")
        #expect(cases.count >= 300)
        Golden.expectMatches(cases) { Self.read($0) }
    }
}
