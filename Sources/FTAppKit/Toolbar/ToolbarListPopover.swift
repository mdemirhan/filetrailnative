// A list under a toolbar button, in a popover: the clipboard's and the Undo History's
import AppKit

/// A tab's list while it is open under its toolbar button: the popover, the window's events while it shows, and the
/// keys the popover itself gets. A press outside the list and its button, and the window no longer being the main
/// one, ask the owner to close it (`dismiss`); the owner says what a key does (`key`).
@MainActor
final class ToolbarListPopover {
    private let content: NSView
    private let popover: AnchoredPopover
    private(set) weak var anchor: NSView?
    private weak var window: NSWindow?
    private var keys: Int?
    private var popoverKeys: Any?
    private var observers: [any NSObjectProtocol] = []
    /// What the list does with a key: true when it took it.
    private let key: (NSEvent) -> Bool
    private let dismiss: () -> Void

    init(content: NSView, size: NSSize, key: @escaping (NSEvent) -> Bool, dismiss: @escaping () -> Void) {
        self.content = content
        self.key = key
        self.dismiss = dismiss
        popover = AnchoredPopover(content: content, size: size)
    }

    isolated deinit {
        close()
    }

    func setSize(_ size: NSSize) {
        popover.setSize(size)
    }

    /// Under `button`, which shows as on while the list is open.
    func show(from button: NSView, in window: NSWindow) {
        anchor = button
        self.window = window
        popover.show(from: button, in: window)
        (button as? ToolbarButton)?.isOn = true
        keys = WindowEventRouting.add(window) { [weak self] event in self?.intercept(event) ?? false }
        // A click inside can give the popover the keyboard, though the window stays the main one: the keys still go
        // to the list.
        popoverKeys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            nonisolated(unsafe) var passed: NSEvent? = event
            MainActor.assumeIsolated {
                guard let self, let shown = self.popover.window, event.window === shown else { return }
                passed = self.popoverKey(event)
            }
            return passed
        }
        // Not when the window only stops being key: that happens for a click in the popover too.
        if NSApp.isActive {
            observers.append(
                NotificationCenter.default.addObserver(
                    forName: NSWindow.didResignMainNotification, object: window, queue: .main
                ) { [weak self] _ in MainActor.assumeIsolated { self?.dismiss() } })
        }
    }

    /// Takes the popover down and lets go of the window's events. The owner calls it, when it closes its list.
    func close() {
        popover.close()
        if let popoverKeys { NSEvent.removeMonitor(popoverKeys) }
        popoverKeys = nil
        content.removeFromSuperview()
        (anchor as? ToolbarButton)?.isOn = false
        anchor = nil
        if let keys, let window { WindowEventRouting.remove(keys, from: window) }
        keys = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
    }

    /// A key the popover has: the list takes it, or, closed by it, lets it go on as a key of the window, whose shortcuts
    /// and menu bar it is for. The popover's own window is gone by then.
    func popoverKey(_ event: NSEvent) -> NSEvent? {
        if intercept(event) { return nil }
        guard let window else { return event }
        return NSEvent.keyEvent(
            with: event.type, location: event.locationInWindow, modifierFlags: event.modifierFlags,
            timestamp: event.timestamp, windowNumber: window.windowNumber, context: nil,
            characters: event.characters ?? "", charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
            isARepeat: event.isARepeat, keyCode: event.keyCode) ?? event
    }

    /// The window's events while the list is open: its keys go to it first, and a press outside it (and its button)
    /// closes it.
    func intercept(_ event: NSEvent) -> Bool {
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            if event.window === content.window,
                content.bounds.contains(content.convert(event.locationInWindow, from: nil))
            {
                return false
            }
            if let anchor, anchor.bounds.contains(anchor.convert(event.locationInWindow, from: nil)) { return false }
            dismiss()
            return false
        case .keyDown:
            return key(event)
        default:
            return false
        }
    }
}
