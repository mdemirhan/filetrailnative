import Foundation
import Testing

@testable import FTFoundation

@Suite struct AccentPaletteTests {
    /// The reference's `AccentTokens` keys, in the Swift palette.
    nonisolated(unsafe) private static let tokenFields: [(String, KeyPath<AccentPalette, RGBA>)] = [
        ("solid", \.solid), ("solidDark", \.solidDark), ("solidButton", \.solidButton), ("onSolid", \.onSolid),
        ("selectionBg", \.selectionBg), ("onSelection", \.onSelection), ("hoverBg", \.hoverBg),
        ("pillBg", \.pillBg), ("pillText", \.pillText), ("border", \.border), ("focusBorder", \.focusBorder),
        ("softBg", \.softBg), ("activeBg", \.activeBg), ("heroIconBg", \.heroIconBg),
        ("folderTint", \.folderTint), ("pathCrumbHover", \.pathCrumbHover),
        ("actionHoverBg", \.actionHoverBg), ("searchPillBorder", \.searchPillBorder),
        ("locationRing", \.locationRing), ("ringSoft", \.ringSoft),
    ]

    /// `accentTokensToCssVariables`' keys.
    nonisolated(unsafe) private static let variableFields: [(String, KeyPath<AccentPalette, RGBA>)] = [
        ("--bg-active", \.activeBg), ("--crumb-active-bg", \.activeBg), ("--ft-accent-solid", \.solid),
        ("--ft-accent-solid-dark", \.solidDark), ("--ft-accent-solid-button", \.solidButton),
        ("--ft-accent-on-solid", \.onSolid), ("--ft-accent-selection-bg", \.selectionBg),
        ("--ft-accent-on-selection", \.onSelection), ("--ft-accent-on-selection-soft", \.onSelectionSoft),
        ("--ft-accent-border", \.border), ("--ft-accent-hover-bg", \.hoverBg),
        ("--ft-accent-pill-bg", \.pillBg), ("--ft-accent-pill-text", \.pillText),
        ("--ft-accent-folder-tint", \.folderTint), ("--ft-accent-soft-bg", \.softBg),
        ("--ft-accent-hero-icon-bg", \.heroIconBg), ("--ft-accent-path-crumb-hover", \.pathCrumbHover),
        ("--ft-accent-action-hover-bg", \.actionHoverBg),
        ("--ft-accent-search-pill-border", \.searchPillBorder),
        ("--ft-accent-location-ring", \.locationRing), ("--ft-accent-ring-soft", \.ringSoft),
    ]

    @Test func everyGoldenCaseMatchesExactly() throws {
        let golden = try GoldenFile.json("accent.json")
        let cases = try #require(golden["cases"] as? [[String: Any]])
        #expect(cases.count >= 600)

        var mismatches: [String] = []
        func check(_ label: String, _ expected: String?, _ actual: RGBA) {
            if expected != actual.cssString {
                mismatches.append("\(label): expected \(expected ?? "nil"), got \(actual.cssString)")
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
            #expect(tokens.count == Self.tokenFields.count)
            for (key, path) in Self.tokenFields {
                check("\(label) \(key)", tokens[key], palette[keyPath: path])
            }
            let variables = try #require(output["cssVariables"] as? [String: String])
            #expect(variables.count == Self.variableFields.count)
            for (key, path) in Self.variableFields {
                check("\(label) \(key)", variables[key], palette[keyPath: path])
            }
            check("\(label) batchRenameMarkText", output["batchRenameMarkText"] as? String, palette.batchRenameMarkText)
            check("\(label) batchRenameMarkBg", output["batchRenameMarkBg"] as? String, palette.batchRenameMarkBg)
        }
        #expect(mismatches.isEmpty, "\(mismatches.count) mismatches, first: \(mismatches.prefix(8))")
    }

    @Test func goldenCoversPresetsAndRandomColors() throws {
        let cases = try #require(try GoldenFile.json("accent.json")["cases"] as? [[String: Any]])
        let accents = Set(cases.compactMap { ($0["input"] as? [String: String])?["accent"] })
        let presets = [
            "#007aff", "#a550a7", "#f74f9e", "#e0383e", "#f7821b", "#ffc600", "#62ba46", "#8c8c8c", "#d4845a",
        ]
        for preset in presets {
            #expect(accents.contains(preset))
        }
        #expect(accents.count >= 300)
    }

    @Test func yellowKeepsBlackButtonTextAndWhiteSelectionText() {
        // White on yellow cannot reach 4.5:1 within 20% darkening: black text on the plain accent.
        let yellow = AccentPalette(hex: "#ffc600", appearance: .light)
        #expect(yellow.onSolid == .black)
        #expect(yellow.solidButton == yellow.solid)
        #expect(yellow.onSelection == .white)
    }

    @Test func unparseableAccentFallsBackToTheDefault() {
        let fallback = AccentPalette(hex: "not a colour", appearance: .dark)
        #expect(fallback == AccentPalette(hex: AccentPalette.defaultHex, appearance: .dark))
    }

    @Test func focusRingIsThreePixelsOfAccentAtHalfAlpha() {
        let palette = AccentPalette(hex: "#007aff", appearance: .light)
        #expect(palette.focusRing.cssString == "0 0 0 3px rgba(0, 122, 255, 0.5)")
    }
}
