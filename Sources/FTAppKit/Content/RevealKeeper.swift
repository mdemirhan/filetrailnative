// Port of apps/desktop/src/renderer/hooks/useRevealIndex.ts
import AppKit
import FTFileSystem

/// How a view scrolls, for `RevealKeeper`.
@MainActor
protocol RevealScroller: AnyObject {
    var scrollOrigin: NSPoint { get }
    /// Whether the item at an index is in view as the view is scrolled now.
    func isInView(index: Int) -> Bool
    func bringIntoView(index: Int)
}

/// Keeps one item of a view (the selection's lead, or the item being renamed) in view. The item is brought into view
/// when it becomes the one to show, when it shows up in the list, when another order is chosen, and when asked again
/// (a refused name). When only the list changed around it, it is kept in view if it was in view, and otherwise the list
/// stays where it was scrolled. When the layout changed, it is kept in view unless the list was scrolled since: Back and
/// a tab coming back put back where the list was scrolled.
@MainActor
final class RevealKeeper {
    /// What asks for the item to be shown.
    struct Ask: Equatable {
        var path: String?
        var sortKey: String
        var askedAgain: Int
    }

    /// What happened since it last ran. The hook's effect runs on a change of the ask, the list or the layout.
    enum Change {
        case ask, list, layout
    }

    private struct Seen {
        var ask: Ask
        /// Where the item stood when last found in the list; nil while it never was.
        var index: Int?
        var scroll: NSPoint
    }

    private var seen: Seen?

    /// A new listing (a folder opened, other results): as the view made anew for it, with nothing seen (`key={viewKey}`).
    func forget() { seen = nil }

    /// `keepInView`. `index` is where the item stands in the list the view shows.
    func keepInView(_ change: Change, ask: Ask, index: Int?, scroller: some RevealScroller) {
        if change == .ask, seen?.ask == ask { return }
        let sameAsk = seen?.ask == ask
        if let index {
            let reveal: Bool
            if let seen, sameAsk, let seenIndex = seen.index {
                if change == .list {
                    reveal = seenIndex != index && scroller.isInView(index: seenIndex)
                } else {
                    let origin = scroller.scrollOrigin
                    reveal = abs(origin.x - seen.scroll.x) <= 1 && abs(origin.y - seen.scroll.y) <= 1
                }
            } else {
                reveal = true
            }
            if reveal { scroller.bringIntoView(index: index) }
        }
        seen = Seen(ask: ask, index: index ?? (sameAsk ? seen?.index : nil), scroll: scroller.scrollOrigin)
    }
}

extension ContentPaneHost {
    /// What asks a view to show its item. The Compact List follows only the lead: not the item being renamed, nor a
    /// refused name (ContentPane.tsx:1236).
    func revealAsk(followingRename: Bool) -> RevealKeeper.Ask {
        let lead = selection.leadPath
        let sortKey =
            search.map { "\($0.headerSortKey):\($0.sortDirection.rawValue)" }
            ?? "\(sortBy.rawValue):\(sortDirection.rawValue)"
        guard followingRename else { return RevealKeeper.Ask(path: lead, sortKey: sortKey, askedAgain: 0) }
        return RevealKeeper.Ask(
            path: inlineRename?.path ?? lead, sortKey: sortKey, askedAgain: inlineRename?.refusalCount ?? 0)
    }
}
