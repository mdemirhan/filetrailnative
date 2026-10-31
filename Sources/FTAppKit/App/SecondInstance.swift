// Port of the second-instance handling of apps/desktop/src/main/main.ts
import AppKit
import Foundation

/// A second copy started by hand tells the one running that it was started, and quits. The running one brings its front
/// window forward, restoring it, or opens one if it has none (`app.on("second-instance")`).
@MainActor
enum SecondInstance {
    private static func name(_ bundleID: String) -> Notification.Name {
        Notification.Name(bundleID + ".secondInstance")
    }

    /// Told to whoever runs the same bundle. An app in the background has its distributed notifications held back unless
    /// they are sent to arrive at once.
    static func announce(bundleID: String) {
        DistributedNotificationCenter.default().postNotificationName(
            name(bundleID), object: nil, userInfo: nil, deliverImmediately: true)
    }

    /// Calls `arrived` on the main queue for each announcement. Keep the answer for as long as it should listen.
    static func listen(bundleID: String, _ arrived: @escaping @MainActor () -> Void) -> any NSObjectProtocol {
        DistributedNotificationCenter.default().addObserver(forName: name(bundleID), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { arrived() }
        }
    }

    static func arrived(shutdownInProgress: Bool, host: any ExplorerWindowHost) {
        if !shutdownInProgress { host.bringToFront() }
    }
}
