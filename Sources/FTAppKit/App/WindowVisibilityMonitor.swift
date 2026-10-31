// Whether any explorer window can be seen, for what needn't run when none can (B-INFO-083, B-INFO-197)
import AppKit

/// Says when the answer to "can a window be seen?" changes: covered, minimized, hidden with the app, or back.
@MainActor
final class WindowVisibilityMonitor {
    private let isVisible: () -> Bool
    private let changed: () -> Void
    private var wasVisible: Bool
    private var observer: (any NSObjectProtocol)?
    private let center: NotificationCenter

    init(center: NotificationCenter = .default, isVisible: @escaping () -> Bool, changed: @escaping () -> Void) {
        self.center = center
        self.isVisible = isVisible
        self.changed = changed
        wasVisible = isVisible()
        observer = center.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
    }

    isolated deinit {
        if let observer { center.removeObserver(observer) }
    }

    private func check() {
        let visible = isVisible()
        guard visible != wasVisible else { return }
        wasVisible = visible
        changed()
    }

    /// An explorer window of the app is on screen, at least in part.
    static func anExplorerWindowCanBeSeen() -> Bool {
        NSApp.windows.contains { $0 is ExplorerTabWindow && $0.occlusionState.contains(.visible) }
    }
}
