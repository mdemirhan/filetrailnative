import FTTestSupport
import Foundation
import Testing

@testable import FTFoundation

@Suite struct AccentPaletteTests {
    /// The accent golden's token keys the palette still has, in the Swift palette.
    nonisolated(unsafe) private static let tokenFields: [(String, KeyPath<AccentPalette, RGBA>)] = [
        ("solid", \.solid), ("solidButton", \.solidButton), ("onSolid", \.onSolid), ("selectionBg", \.selectionBg),
        ("onSelection", \.onSelection), ("pillText", \.pillText), ("border", \.border), ("softBg", \.softBg),
        ("folderTint", \.folderTint), ("actionHoverBg", \.actionHoverBg),
    ]

    /// The accent golden's CSS variable keys the palette still has.
    nonisolated(unsafe) private static let variableFields: [(String, KeyPath<AccentPalette, RGBA>)] = [
        ("--ft-accent-solid", \.solid), ("--ft-accent-solid-button", \.solidButton),
        ("--ft-accent-on-solid", \.onSolid), ("--ft-accent-selection-bg", \.selectionBg),
        ("--ft-accent-on-selection", \.onSelection), ("--ft-accent-on-selection-soft", \.onSelectionSoft),
        ("--ft-accent-border", \.border), ("--ft-accent-pill-text", \.pillText),
        ("--ft-accent-folder-tint", \.folderTint), ("--ft-accent-soft-bg", \.softBg),
        ("--ft-accent-action-hover-bg", \.actionHoverBg),
    ]

    /// The cases of `Tests/Golden/accent.json`.
    private static func cases() throws -> [[String: Any]] {
        let data = try Data(contentsOf: Golden.url(suite: "accent"))
        let golden = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(golden["cases"] as? [[String: Any]])
    }

    @Test func everyGoldenCaseMatchesExactly() throws {
        let cases = try Self.cases()
        #expect(cases.count >= 600)

        var mismatches: [String] = []
        func check(_ label: String, _ expected: String?, _ actual: RGBA) {
            if expected != Self.css(actual) {
                mismatches.append("\(label): expected \(expected ?? "nil"), got \(Self.css(actual))")
            }
        }
        for entry in cases {
            let input = try #require(entry["input"] as? [String: String])
            let output = try #require(entry["output"] as? [String: Any])
            let hex = try #require(input["accent"])
            let themeName = try #require(input["theme"])
            let appearance = try #require(ThemeAppearance(rawValue: themeName))
            let palette = AccentPalette(hex: hex, appearance: appearance)
            let label = "\(hex)/\(appearance)"

            let tokens = try #require(output["tokens"] as? [String: String])
            for (key, path) in Self.tokenFields {
                check("\(label) \(key)", tokens[key], palette[keyPath: path])
            }
            let variables = try #require(output["cssVariables"] as? [String: String])
            for (key, path) in Self.variableFields {
                check("\(label) \(key)", variables[key], palette[keyPath: path])
            }
            check("\(label) batchRenameMarkText", output["batchRenameMarkText"] as? String, palette.batchRenameMarkText)
            check("\(label) batchRenameMarkBg", output["batchRenameMarkBg"] as? String, palette.batchRenameMarkBg)
        }
        #expect(mismatches.isEmpty, "\(mismatches.count) mismatches, first: \(mismatches.prefix(8))")
    }

    @Test func goldenCoversPresetsAndRandomColors() throws {
        let cases = try Self.cases()
        let accents = Set(cases.compactMap { ($0["input"] as? [String: String])?["accent"] })
        let presets = [
            "#007aff", "#a550a7", "#f74f9e", "#e0383e", "#f7821b", "#ffc600", "#62ba46", "#8c8c8c", "#d4845a",
        ]
        // Yellow is the one preset white text cannot reach 4.5:1 on: the golden holds it with black button text.
        for preset in presets {
            #expect(accents.contains(preset))
        }
        #expect(accents.count >= 300)
    }

    @Test func unparseableAccentFallsBackToTheDefault() {
        let fallback = AccentPalette(hex: "not a colour", appearance: .dark)
        #expect(fallback == AccentPalette(hex: AccentPalette.defaultHex, appearance: .dark))
    }

    // Six hex digits only: a sign makes it no colour.
    @Test func aSignedHexIsNoColour() {
        #expect(RGBA(hex: "-12345") == nil)
        #expect(RGBA(hex: "#+12345") == nil)
        #expect(RGBA(hex: "#12AB3c") == RGBA(r: 0x12, g: 0xab, b: 0x3c))
    }

    /// A colour as the golden spells it: `#rrggbb` when opaque, otherwise `rgba(r, g, b, a)`.
    private static func css(_ color: RGBA) -> String {
        guard color.alpha != 1 else { return color.hexString }
        let (r, g, b) = color.bytes
        let alpha = color.alpha == color.alpha.rounded() ? String(Int(color.alpha)) : "\(color.alpha)"
        return "rgba(\(r), \(g), \(b), \(alpha))"
    }
}
