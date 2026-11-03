// The sidebar size of System Settings › Appearance, which Finder's sizes take for the folder tree
import AppKit
import FTFoundation

/// The sidebar size of System Settings › Appearance (Small, Medium or Large), as AppKit reads it for a source list, and
/// its changes. With Finder's sizes the folder tree follows it, as Finder's sidebar does.
@MainActor
final class SystemSidebarSize {
    static let shared = SystemSidebarSize()
    /// Posted on the app's notification center when `size` changes.
    static let didChange = Notification.Name("FileTrail.SystemSidebarSizeDidChange")

    /// Set by a test to stand in for the system's.
    var size: SidebarDensity {
        didSet {
            if size != oldValue { NotificationCenter.default.post(name: Self.didChange, object: nil) }
        }
    }
    private var listener: (any NSObjectProtocol)?

    private init() {
        size = Self.read()
        // AppKit hears of a change from the same notice, so the size is read again once AppKit has taken it. An app in
        // the background gets the notice when it comes to the front.
        listener = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleSideBarDefaultIconSizeChanged"), object: nil, queue: .main
        ) { _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { SystemSidebarSize.shared.size = SystemSidebarSize.read() }
            }
        }
    }

    private static func read() -> SidebarDensity {
        let outline = NSOutlineView()
        outline.style = .sourceList
        outline.rowSizeStyle = .default
        switch outline.effectiveRowSizeStyle {
        case .small: return .small
        case .large: return .large
        default: return .medium
        }
    }
}
