// Port of apps/desktop/src/renderer/lib/responsiveLayout.test.ts
import Testing

@testable import FTFoundation

struct ResponsiveLayoutTests {
    // T-7750e04f F-664
    @Test func returnsWideForLargeSinglePanelLayouts() {
        #expect(ResponsiveLayout.resolveSinglePanelLayout(width: 1280) == .wide)
    }

    // T-1c5474fe F-664
    // B-VIEW-016
    @Test func returnsNarrowForMediumSinglePanelLayouts() {
        #expect(ResponsiveLayout.resolveSinglePanelLayout(width: 920) == .narrow)
    }

    // T-1d40ab78 F-664
    @Test func returnsCompactForSmallSinglePanelLayouts() {
        #expect(ResponsiveLayout.resolveSinglePanelLayout(width: 640) == .compact)
    }

    // F-664 the breakpoints are 1100 and 760
    @Test func switchesAtTheBreakpoints() {
        #expect(ResponsiveLayout.resolveSinglePanelLayout(width: 1100) == .wide)
        #expect(ResponsiveLayout.resolveSinglePanelLayout(width: 1099.5) == .narrow)
        #expect(ResponsiveLayout.resolveSinglePanelLayout(width: 760) == .narrow)
        #expect(ResponsiveLayout.resolveSinglePanelLayout(width: 759.5) == .compact)
        #expect(ResponsiveLayout.resolveSinglePanelLayout(width: 0) == .compact)
    }
}
