// Port of the BrowserWindow options of apps/desktop/src/main/main.ts:424-445, which set no acceptFirstMouse: on macOS the
// click that brings a window forward doesn't reach the page
import AppKit

/// The click that brings a window forward only brings it forward. It doesn't reach the window's content or the toolbar's
/// controls, where it would clear a selection, navigate or run a command. The traffic lights, the tab bar and the band's
/// empty room, which drags the window, are the frame's and take it as ever.
///
/// Asking each view (`acceptsFirstMouse`) isn't enough: the system's controls and table views answer yes unless each one
/// is told otherwise, and with the app in the background the window may be key again by the time the press gets here.
/// A press made before the window came forward is the press that brought it, whatever the window says now.
///
/// Only one press does that. A press kept back asks macOS for the app and the window, and macOS may be slow to answer or
/// not answer at all (another app kept the front after a drag from it). Keeping back every press until it does would
/// lose them all with the app looking hung, so the presses after the first go through to AppKit.
@MainActor
final class FirstClickGate {
    /// What the gate asks of macOS (injectable for tests).
    @MainActor struct System {
        var appIsActive: () -> Bool = { NSApp.isActive }
        /// `activate()` is cooperative: macOS refuses it while another app holds the front, and this asks only because
        /// someone clicked the app.
        var activateApp: () -> Void = { NSApp.activate(ignoringOtherApps: true) }
        var makeKey: (NSWindow) -> Void = { $0.makeKeyAndOrderFront(nil) }
    }
    static var system = System()

    /// When a window last became key or the app active, in the time events carry.
    private static var cameForwardAt: TimeInterval = 0
    private static var observing = false
    /// The windows whose press was kept back, until they lose the keyboard or the app the front: what the next click
    /// brings forward is then a new matter.
    private static let keptPressIn = NSHashTable<NSWindow>.weakObjects()
    /// The press kept back, whose drags and release are kept back with it.
    private var keepingPress = false

    init() { Self.observe() }

    /// Takes note of when windows come forward, from the first window on.
    private static func observe() {
        guard !observing else { return }
        observing = true
        for name in [NSApplication.didBecomeActiveNotification, NSWindow.didBecomeKeyNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { _ in
                let now = ProcessInfo.processInfo.systemUptime
                MainActor.assumeIsolated { cameForwardAt = now }
            }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: nil) {
            note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated {
                if let window { keptPressIn.remove(window) }
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: nil
        ) { _ in
            MainActor.assumeIsolated { keptPressIn.removeAllObjects() }
        }
    }

    /// Whether a press made at `pressedAt` is one that brings a window forward: the window isn't key, unless what has the
    /// keyboard is its own (a sheet keeps the press itself; a popover closes on it, and the press goes on), or it
    /// became key or the app active after the press was made. A press with no time of its own says nothing.
    static func bringsForward(
        pressedAt: TimeInterval, isKey: Bool, keyWindowIsItsOwn: Bool, cameForwardAt: TimeInterval
    ) -> Bool {
        if !isKey { return !keyWindowIsItsOwn }
        return pressedAt > 0 && pressedAt < cameForwardAt
    }

    /// True when the event goes no further. Only a window on screen can be clicked to bring it forward; and a press made
    /// by this process itself (event number 0), while it isn't in front, stands for no click: a process in the background
    /// can't make a window key at all, so nothing it drives would ever arrive.
    func keepsBack(_ event: NSEvent, in window: NSWindow) -> Bool {
        switch event.type {
        case .leftMouseDown:
            keepingPress = false
            guard window.isVisible, window.canBecomeKey, window.attachedSheet == nil, NSApp.modalWindow == nil,
                event.eventNumber != 0 || Self.system.appIsActive()
            else { return false }
            let own = NSApp.keyWindow.map { $0.parent === window } ?? false
            guard
                Self.bringsForward(
                    pressedAt: event.timestamp, isKey: window.isKeyWindow, keyWindowIsItsOwn: own,
                    cameForwardAt: Self.cameForwardAt),
                Self.isContent(under: event.locationInWindow, of: window)
            else { return false }
            Self.comeForward(window)
            guard !Self.keptPressIn.contains(window) else { return false }
            Self.keptPressIn.add(window)
            keepingPress = true
            return true
        case .leftMouseDragged:
            return keepingPress
        case .leftMouseUp:
            defer { keepingPress = false }
            return keepingPress
        default:
            return false
        }
    }

    private static func comeForward(_ window: NSWindow) {
        if !system.appIsActive() { system.activateApp() }
        if !window.isKeyWindow { system.makeKey(window) }
    }

    /// What the press lands on is the window's content or a control of the toolbar.
    private static func isContent(under point: NSPoint, of window: NSWindow) -> Bool {
        guard let frameView = window.contentView?.superview, let hit = frameView.hitTest(point)
        else { return false }
        return isContent(hit, of: window)
    }

    /// `hit`, the view under a press, is the window's content or a control of the toolbar.
    static func isContent(_ hit: NSView, of window: NSWindow) -> Bool {
        if let content = window.contentView, hit.isDescendant(of: content) { return true }
        // The search field's options button is a view of the field that opens its menu, no control of its own.
        guard hit is NSControl || hit is ToolbarSearchOptionsButton else { return false }
        return window.toolbar?.items.contains { item in
            let view = (item as? NSSearchToolbarItem)?.searchField ?? item.view
            return view.map(hit.isDescendant(of:)) ?? false
        } ?? false
    }
}
