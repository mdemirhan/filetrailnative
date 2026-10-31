// No TypeScript source: how an explorer window's events reach the open menu, the tooltips and the toolbar's customizing
import AppKit

/// A view that shows its text through a text field inside it: the capture compares that field's font and color.
@MainActor
protocol TextStyleSource: AnyObject {
    var styleTextField: NSTextField? { get }
}

/// What an explorer window's events pass through before the window handles them: the open menu, the tooltips and
/// the toolbar's customizing take their keys and presses here, whether the event came from the system or was sent
/// to the window directly.
@MainActor
enum WindowEventRouting {
    private static var interceptors: [ObjectIdentifier: [(id: Int, last: Bool, handle: (NSEvent) -> Bool)]] = [:]
    private static var nextID = 0

    /// Adds a handler for `window`'s events; true from it keeps the event from the window. Returns its id.
    /// With `last`, it comes after the handlers added before and after it: one that acts on a press itself leaves the
    /// others, which close what is open on any press outside it, their turn.
    @discardableResult
    static func add(_ window: NSWindow, last: Bool = false, _ handle: @escaping (NSEvent) -> Bool) -> Int {
        nextID += 1
        let handlers = interceptors[ObjectIdentifier(window)] ?? []
        let index = last ? handlers.endIndex : handlers.firstIndex { $0.last } ?? handlers.endIndex
        interceptors[ObjectIdentifier(window), default: []].insert((nextID, last, handle), at: index)
        return nextID
    }

    static func remove(_ id: Int, from window: NSWindow) {
        interceptors[ObjectIdentifier(window)]?.removeAll { $0.id == id }
    }

    static func forget(_ window: NSWindow) {
        interceptors.removeValue(forKey: ObjectIdentifier(window))
        TooltipController.remove(window)
    }

    /// True when something took the event.
    static func intercept(_ event: NSEvent, in window: NSWindow) -> Bool {
        TooltipController.of(window).observe(event)
        if AppMenuPresenter.shared.intercept(event, in: window) { return true }
        for interceptor in interceptors[ObjectIdentifier(window)] ?? [] where interceptor.handle(event) {
            return true
        }
        return false
    }
}
