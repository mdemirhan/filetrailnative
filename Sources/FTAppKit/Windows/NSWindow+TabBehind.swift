import AppKit

extension NSWindow {
    /// The window is a tab with another tab of its group in front, so nothing in it can be seen.
    var isBehindAnotherTab: Bool {
        guard let selected = tabGroup?.selectedWindow else { return false }
        return selected !== self
    }
}
