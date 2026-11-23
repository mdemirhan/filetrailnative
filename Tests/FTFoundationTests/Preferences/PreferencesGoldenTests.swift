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
        let cases: [GoldenCase<Input, AppState>] = try GoldenChanges.load(suite: "prefs-sanitize")
        #expect(cases.count == 44)
        Golden.expectMatches(cases) { Self.read($0) }
    }

    // Over many saved states made of every preference with values of the right kind, the wrong kind and none: what
    // is read, written and read again is what was read the first time, so a launch never changes what it saved.
    @Test func whatIsReadIsReadTheSameOnceWritten() throws {
        var random = SeededGenerator(seed: 0x5EED_0003)
        let keys = PreferenceKey.allCases.map(\.rawValue) + ["notAPreference"]
        let values: [JSONNode] = [
            .bool(true), .bool(false), .number(0), .number(-1), .number(1e9), .number(2.5), .string(""),
            .string("dark"), .string("light"), .string("#007aff"), .string("details"), .string("/Users/demo"),
            .array([]), .array([.string("x"), .number(1)]), .object([:]), .object(["standard": .number(96)]), .null,
        ]
        for _ in 0..<300 {
            var preferences: [String: JSONNode] = [:]
            for _ in 0..<Int.random(in: 0...12, using: &random) {
                preferences[keys.randomElement(using: &random)!] = values.randomElement(using: &random)!
            }
            let saved = JSONNode.object(["preferences": .object(preferences)])
            let text = String(decoding: try JSONEncoder().encode(saved), as: UTF8.self)
            let first = Self.read(Input(defaultTheme: nil, text: text))
            let written = String(decoding: try JSONEncoder().encode(first), as: UTF8.self)
            let second = Self.read(Input(defaultTheme: nil, text: written))
            let before = try JSONNode.of(first.preferences).object ?? [:]
            let after = try JSONNode.of(second.preferences).object ?? [:]
            let differing = Set(before.keys).union(after.keys).sorted().filter { before[$0] != after[$0] }
                .map { "\($0): \(before[$0].map { "\($0)" } ?? "none") then \(after[$0].map { "\($0)" } ?? "none")" }
            #expect(
                Golden.render(second) == Golden.render(first),
                "\(differing) \(Golden.render(first.windows)) then \(Golden.render(second.windows)) from \(text)")
        }
    }
}
