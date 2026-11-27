// The names the Icons view remembers are laid out as a name laid out afresh is
import AppKit
import FTFoundation
import Testing

@testable import FTAppKit

@MainActor
struct IconLabelCacheTests {
    private static let names = [
        "note.txt", "Quarterly Report – Brightwater Ceramics Q3 2026 final version.pdf", "İstanbul Gezi Planı.pages",
        "東京の写真 001.heic", "a very long name without any spaces_or_breaks_at_all_anywhere_in_it_at_all.swift",
    ]

    private func layOut(_ layout: IconGridLayout) -> [String: (fitted: String, lines: [String], width: Double)] {
        var out: [String: (String, [String], Double)] = [:]
        for name in Self.names {
            let ext = (name as NSString).pathExtension
            let fitted = IconLabelText.fit(name: name, extension: ext, layout: layout)
            out[name] = (
                fitted, IconLabelText.lines(fitted, layout: layout), IconLabelText.width(fitted, layout: layout)
            )
        }
        return out
    }

    // Remembered, at every size, a name is fitted, wrapped and measured as it is the first time.
    @Test func aNameRememberedIsLaidOutAsAfresh() {
        for density in [Density.standard, .finder] {
            for iconSize in [32.0, 64.0, 128.0] {
                var layout = DesignTokens.iconGrid(density: density)
                layout.iconSize = iconSize
                IconLabelText.forgetNames()
                let afresh = layOut(layout)
                let remembered = layOut(layout)
                for name in Self.names {
                    #expect(remembered[name]?.fitted == afresh[name]?.fitted, "\(name) at \(iconSize)")
                    #expect(remembered[name]?.lines == afresh[name]?.lines, "\(name) at \(iconSize)")
                    #expect(remembered[name]?.width == afresh[name]?.width, "\(name) at \(iconSize)")
                }
            }
        }
    }
}
