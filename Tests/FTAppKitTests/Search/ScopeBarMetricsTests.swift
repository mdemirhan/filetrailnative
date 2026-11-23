import AppKit
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

@MainActor
@Suite struct ScopeBarMetricsTests {
    // The bar holds the scope track (the 24 pt control height: 20 pt segments in a 2 pt track) from the pane's content
    // top, 10 pt down and clear of the active pane's line, with 6 pt under it: 40 tall, the header 41 with its edge. Its text is the header's 500
    // weight.
    @Test func theScopeBarHoldsItsTrackAndTheHeadersWeight() throws {
        let header = SearchHeaderView(frame: NSRect(x: 0, y: 0, width: 912, height: 41))
        header.show(
            scopes: [
                SearchScopeOption(path: "/a/components", label: "components"),
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
        #expect(chipFrame.minY == 12 && chipFrame.height == 20, "\(chipFrame)")
        let weight = { (font: NSFont?) in
            (font?.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any])?[.weight] as? Double
        }
        #expect(weight(chip.font) == weight(NSFont.systemFont(ofSize: 12, weight: .medium)))
        // No "Search:" before the segments: they start at the bar's edge and say what they are to VoiceOver.
        let track = try #require(Views.first(SearchSegmentTrack.self, in: header) { _ in true })
        #expect(track.frame.minX == 12)
        #expect(track.accessibilityLabel() == SearchBarText.scopeToolbarName)
        #expect(Views.first(NSTextField.self, in: header) { $0.accessibilityIdentifier() == "searchBar.label" } == nil)
    }

    // The results' filter is 280 wide where there is room and gives up room first beside the segments, down to 200.
    // With less room Options is its icon alone, and with less again the scopes are one pop-up button and the filter
    // takes the rest. The filter has no icon: its mode chip is at its start.
    @Test func theScopesBecomeAPopUpWhereTheSegmentsLeaveTheFilterTooLittle() throws {
        func shown(width: CGFloat) throws -> SearchHeaderView {
            let header = SearchHeaderView(frame: NSRect(x: 0, y: 0, width: width, height: 41))
            header.show(
                scopes: [
                    SearchScopeOption(path: "/a/Application Support", label: "Application Support"),
                    SearchScopeOption(path: "/a", label: "Home"), SearchScopeOption(path: "/", label: "Macintosh HD"),
                ],
                rootPath: "/a/Application Support", isRunning: false, truncated: false, filterText: "")
            header.showFilterMode(.contains)
            header.layoutSubtreeIfNeeded()
            header.filter.layoutSubtreeIfNeeded()
            return header
        }
        let wide = try shown(width: 1_400)
        let track = try #require(Views.first(SearchSegmentTrack.self, in: wide) { _ in true })
        #expect(!wide.showsScopeMenu && wide.scopeMenu.isHidden && !track.isHidden)
        #expect(track.frame.minX == 12)
        #expect(wide.filter.frame.width == 280)
        #expect(wide.filter.modeChip.frame.minX == 4)
        #expect(wide.filter.input.frame.minX > wide.filter.modeChip.frame.maxX)
        #expect(wide.filter.input.frame.width >= 150)
        // Options, with its title, between the filter and Done.
        #expect(wide.optionsButton.showsTitle)
        #expect(wide.filter.frame.maxX == wide.optionsButton.frame.minX - 6)
        #expect(wide.optionsButton.frame.maxX == wide.doneButton.frame.minX - 6)

        // What the segments and the bar's right end take, whatever the width.
        let segmentsEnd = track.frame.maxX + 6
        let trailing = 1_400 - (wide.optionsButton.frame.minX - 6)
        let titleWidth = wide.optionsButton.frame.width - wide.optionsButton.preferredWidth(showingTitle: false)
        #expect(titleWidth > 30)

        let tight = try shown(width: segmentsEnd + 240 + trailing)
        #expect(!tight.showsScopeMenu)
        #expect(tight.optionsButton.showsTitle)
        #expect(tight.filter.frame.width == 240)

        // Short of the filter's 200 beside the segments, Options gives up its title before the scopes become the
        // pop-up, and the filter has the room it gave.
        let iconOnly = try shown(width: segmentsEnd + 190 + trailing)
        #expect(!iconOnly.showsScopeMenu)
        #expect(!iconOnly.optionsButton.showsTitle)
        #expect(iconOnly.filter.frame.width == 190 + titleWidth)

        let narrow = try shown(width: segmentsEnd + 190 + trailing - titleWidth)
        #expect(narrow.showsScopeMenu)
        // The segments are hidden, which the finder of views passes over.
        #expect(Views.first(SearchSegmentTrack.self, in: narrow) { _ in true } == nil)
        #expect(!narrow.scopeMenu.isHidden)
        #expect(narrow.scopeMenu.frame.minX == 12)
        #expect(narrow.scopeMenu.frame.width <= 220)
        #expect(narrow.scopeMenu.titleOfSelectedItem == "Application Support")
        // The filter is no wider than beside the segments: what is left over stays after the pop-up.
        #expect(narrow.filter.frame.maxX == narrow.optionsButton.frame.minX - 6)
        #expect(
            narrow.filter.frame.width
                == min(280, narrow.optionsButton.frame.minX - 6 - (narrow.scopeMenu.frame.maxX + 6)))
        #expect(narrow.filter.frame.maxX == narrow.optionsButton.frame.minX - 6)
        #expect(narrow.filter.frame.width >= 200)
        // Options stays its icon beside the pop-up, so it doesn't get its title back as the window narrows.
        #expect(!narrow.optionsButton.showsTitle)

        // The pop-up is as wide as the place searched, not its longest place: a shorter one leaves the filter more.
        let longWidth = narrow.scopeMenu.frame.width
        narrow.show(
            scopes: [
                SearchScopeOption(path: "/a/Application Support", label: "Application Support"),
                SearchScopeOption(path: "/a", label: "Home"), SearchScopeOption(path: "/", label: "Macintosh HD"),
            ],
            rootPath: "/a", isRunning: false, truncated: false, filterText: "")
        narrow.layoutSubtreeIfNeeded()
        #expect(narrow.scopeMenu.titleOfSelectedItem == "Home")
        #expect(narrow.scopeMenu.frame.width < longWidth - 50)
        // The filter is no wider than beside the segments: what is left over stays after the pop-up.
        #expect(narrow.filter.frame.maxX == narrow.optionsButton.frame.minX - 6)
        #expect(
            narrow.filter.frame.width
                == min(280, narrow.optionsButton.frame.minX - 6 - (narrow.scopeMenu.frame.maxX + 6)))

        // A pane of two at its narrowest, 280 pt: the place's name is cut short, Options is its icon alone, and the
        // filter keeps what a filter needs, its chip inside it.
        let pane = try shown(width: 280)
        #expect(pane.showsScopeMenu)
        #expect(pane.scopeMenu.frame.width == 72)
        #expect(!pane.optionsButton.showsTitle)
        #expect(pane.optionsButton.frame.width < 40)
        #expect(pane.filter.frame.width >= 85)
        #expect(pane.filter.frame.maxX == pane.optionsButton.frame.minX - 6)
        #expect(pane.filter.modeChip.frame.maxX < pane.filter.bounds.width)
        // A bar with room for the filter's 200 and less than the place's name: the name gives way, not the filter.
        let between = try shown(width: 400)
        #expect(between.showsScopeMenu)
        // Options gives up its title before the filter gives up any of its 200.
        #expect(!between.optionsButton.showsTitle)
        #expect(between.filter.frame.width == 200)
        #expect(between.scopeMenu.frame.width > 72 && between.scopeMenu.frame.width < longWidth)
    }

    // "No results" is drawn in the body size, at weight 500, in the primary text color.
    @Test func anEmptyStatesTitleIsTheContentStatesStrongText() throws {
        let state = ContentStateView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let theme = AppearanceModel.shared.theme
        state.show(.noMatches(query: "zzqqx"), theme: theme)
        let title = try #require(
            Views.first(NSView.self, in: state) { $0.accessibilityIdentifier() == "emptyState.title" } as? ThemedText)
        let font = try #require(title.font)
        // The body size.
        #expect(font.pointSize == 13)
        let traits = font.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]
        #expect(traits?[.weight] as? Double == Double(NSFont.Weight.medium.rawValue))
        let color = try #require(title.textColor?.usingColorSpace(.sRGB))
        let primary = theme.palette.textPrimary
        #expect(abs(color.redComponent - primary.red) < 0.01 && abs(color.blueComponent - primary.blue) < 0.01)
        #expect(color.alphaComponent == 1)
    }
}
