// Port of apps/desktop/src/renderer/lib/windowActivity.ts
import AppKit

/// Selections turn grey while the window is in the background, as on macOS: a window that is not the key window (another
/// window or another app has the focus) is inactive, and what draws a selection asks `isActive`.
@MainActor
public final class WindowActivity {
    /// Whether the window has the focus now (`document.hasFocus()`).
    private let hasFocus: @MainActor () -> Bool
    private let center: NotificationCenter
    private var observers: [any NSObjectProtocol] = []
    public private(set) var isActive = true
    /// Told whenever the window gains or loses the focus.
    public var onChange: (Bool) -> Void = { _ in }

    /// Tracks `window` through its key-window notifications.
    public convenience init(window: NSWindow, center: NotificationCenter = .default) {
        self.init(hasFocus: { [weak window] in window?.isKeyWindow ?? false }, window: window, center: center)
    }

    /// `hasFocus` is asked at each change; the notifications of `window` say when.
    public init(hasFocus: @escaping @MainActor () -> Bool, window: NSWindow?, center: NotificationCenter = .default) {
        self.hasFocus = hasFocus
        self.center = center
        update()
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            observers.append(
                center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.update() }
                })
        }
    }

    private func update() {
        let next = hasFocus()
        let changed = next != isActive
        isActive = next
        if changed { onChange(next) }
    }

    /// Stops tracking: a window nothing tracks counts as active (`window-inactive` is taken off).
    public func stop() {
        for observer in observers { center.removeObserver(observer) }
        observers = []
        isActive = true
    }
}
