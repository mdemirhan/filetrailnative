// The list of what the word at the caret of the toolbar's search field can be: in the window, just under the toolbar,
// lined up with the field, over the files and never over the toolbar's items. It is there only while the field has
// the keyboard and the word at the caret has something to offer.
import AppKit
import FTFoundation

@MainActor
final class SearchFieldDropdown {
    let view = SearchSuggestionsView(floating: true, identifier: "searchSuggestions")
    /// Gap between the toolbar's bottom and the list, and between the list and the window's edges.
    static let gap = 6.0
    static let minWidth = 300.0

    var isShown: Bool { view.superview != nil }
    var suggestions: SearchQuerySuggestions? { isShown ? view.suggestions : nil }

    /// Shows `suggestions` under the toolbar, its left edge on `field`'s, inside the window.
    func show(_ suggestions: SearchQuerySuggestions, under field: NSView) {
        guard let window = field.window, let host = window.contentView else {
            hide()
            return
        }
        view.show(suggestions)
        if view.superview !== host {
            // The list is made with its pane, and shows in the look the app has now: light or dark and the accent may
            // have changed since.
            view.applyTheme(AppearanceModel.shared.theme)
            view.removeFromSuperview()
            host.addSubview(view, positioned: .above, relativeTo: nil)
        }
        let fieldInWindow = field.convert(field.bounds, to: nil)
        let windowWidth = window.frame.width
        let width = min(max(view.preferredWidth, Self.minWidth, fieldInWindow.width), windowWidth - 2 * Self.gap)
        let x = max(Self.gap, min(fieldInWindow.minX, windowWidth - Self.gap - width))
        // The content's top, under the toolbar, in the window's own coordinates; a short window has the rows scroll.
        let top = window.contentLayoutRect.maxY - Self.gap
        let height = view.height(fitting: max(80, top - Self.gap))
        let frame = host.convert(NSRect(x: x, y: top - height, width: width, height: height), from: nil)
        if view.frame != frame { view.frame = frame }
        view.needsDisplay = true
    }

    func hide() {
        guard isShown else { return }
        view.removeFromSuperview()
        // Shown again, the list starts afresh: a row highlighted before it closed isn't one Return would take.
        view.show(nil)
    }
}
