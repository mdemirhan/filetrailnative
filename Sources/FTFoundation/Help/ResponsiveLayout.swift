// Port of apps/desktop/src/renderer/lib/responsiveLayout.ts
import Foundation

public enum SinglePanelLayout: String, Sendable, Equatable {
    case wide
    case narrow
    case compact
}

public enum ResponsiveLayout {
    /// Single-panel pages use a separate breakpoint scale because they do not share space with the explorer panes and
    /// path/tree chrome.
    public static func resolveSinglePanelLayout(width: Double) -> SinglePanelLayout {
        if width >= 1100 { return .wide }
        if width >= 760 { return .narrow }
        return .compact
    }
}
