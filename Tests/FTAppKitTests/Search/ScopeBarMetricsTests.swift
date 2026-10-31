// Ports the search scope bar's and the empty states' metrics of apps/desktop/src/renderer/styles.css
// (.search-scope-bar padding 6px 12px over .segmented's 2px track; .content-header's weight 500; .content-state strong
// over .empty-state-title)
import AppKit
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

@MainActor
@Suite struct ScopeBarMetricsTests {
    // The bar holds the scope track (24 pt segments in a 2 pt track) with 6 pt above and below: 40 tall, the header
    // 41 with its edge. Its text is the header's 500 weight.
    // covered-by-feature F-750
    @Test func theScopeBarHoldsItsTrackAndTheHeadersWeight() throws {
        let header = SearchHeaderView(frame: NSRect(x: 0, y: 0, width: 912, height: 41))
        header.show(
            scopes: [
                SearchScopeOption(path: "/a/components", label: "“components”"),
                SearchScopeOption(path: "/", label: "Macintosh HD"),
            ],
            rootPath: "/a/components", isRunning: false, truncated: false, filterText: "")
        header.layoutSubtreeIfNeeded()
        #expect(SearchHeaderView.barHeight == 40)
        #expect(header.height == 41)
        let bar = try #require(Views.first(NSView.self, in: header) { $0.accessibilityIdentifier() == "searchBar" })
        #expect(bar.frame.height == 40)
        let chip = try #require(header.scopes.first)
        let chipFrame = header.convert(chip.bounds, from: chip)
        #expect(chipFrame.minY == 8 && chipFrame.height == 24, "\(chipFrame)")
        let weight = { (font: NSFont?) in
            (font?.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any])?[.weight] as? Double
        }
        #expect(weight(chip.font) == weight(NSFont.systemFont(ofSize: 12, weight: .medium)))
        let label = try #require(
            Views.first(NSTextField.self, in: header) { $0.accessibilityIdentifier() == "searchBar.label" })
        #expect(weight(label.font) == weight(NSFont.systemFont(ofSize: 12, weight: .medium)))
    }

    // "No matches" is drawn as the original's `.content-state strong`: the body size, 500, the primary text color.
    // covered-by-feature F-754 F-753
    @Test func anEmptyStatesTitleIsTheContentStatesStrongText() throws {
        let state = ContentStateView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let theme = AppearanceModel.shared.theme
        state.show(.noMatches(query: "zzqqx"), theme: theme)
        let title = try #require(
            Views.first(NSView.self, in: state) { $0.accessibilityIdentifier() == "emptyState.title" } as? ThemedText)
        let font = try #require(title.font)
        // `--font-size-body`.
        #expect(font.pointSize == 13)
        let traits = font.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]
        #expect(traits?[.weight] as? Double == Double(NSFont.Weight.medium.rawValue))
        let color = try #require(title.textColor?.usingColorSpace(.sRGB))
        let primary = theme.palette.textPrimary
        #expect(abs(color.redComponent - primary.red) < 0.01 && abs(color.blueComponent - primary.blue) < 0.01)
        #expect(color.alphaComponent == 1)
    }
}
