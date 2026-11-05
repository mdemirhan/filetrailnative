import Testing

@testable import FTFoundation

struct ResponsiveLayoutTests {
    @Test func returnsWideForLargeSinglePanelLayouts() {
        #expect(ResponsiveLayout.resolveSinglePanelLayout(width: 1280) == .wide)
    }

    @Test func returnsNarrowForMediumSinglePanelLayouts() {
        #expect(ResponsiveLayout.resolveSinglePanelLayout(width: 920) == .narrow)
    }

    @Test func returnsCompactForSmallSinglePanelLayouts() {
        #expect(ResponsiveLayout.resolveSinglePanelLayout(width: 640) == .compact)
    }

    // The breakpoints are 1100 and 760
    @Test func switchesAtTheBreakpoints() {
        #expect(ResponsiveLayout.resolveSinglePanelLayout(width: 1100) == .wide)
        #expect(ResponsiveLayout.resolveSinglePanelLayout(width: 1099.5) == .narrow)
        #expect(ResponsiveLayout.resolveSinglePanelLayout(width: 760) == .narrow)
        #expect(ResponsiveLayout.resolveSinglePanelLayout(width: 759.5) == .compact)
        #expect(ResponsiveLayout.resolveSinglePanelLayout(width: 0) == .compact)
    }
}
