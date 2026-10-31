// Port of the open-file handling in apps/desktop/src/main/main.ts (app.on("open-file")) and of openRequestSchema in packages/contracts/src/ipc.ts
import Foundation

/// An item opened with File Trail from another app (Finder's Open With, a drop on the Dock icon,
/// `open -a "File Trail" <path>`), as the window in front is to open it.
public struct OpenRequest: Equatable, Sendable {
    public enum Kind: String, Sendable {
        /// Opened as a disk image opened in File Trail is.
        case diskImage
        /// Shown in a new tab.
        case folder
        /// Selected in its folder in a new tab.
        case reveal
        /// Selected in the folder the window opened on: a window opened for it, when none was open.
        case select
    }

    public let path: String
    public let kind: Kind

    public init(path: String, kind: Kind) {
        self.path = path
        self.kind = kind
    }
}

/// macOS sends the items before the app is ready when it launches File Trail to open them: they wait for the windows.
///
/// The app delegate's `application(_:open:)` hands the paths to `open(_:)` and calls `startupWindowsOpened()`
/// once the first windows exist.
@MainActor
public final class OpenFileEntryPoint {
    private let describe: (String) -> OpenRequest?
    private let openRequest: (OpenRequest) -> Void
    private var windowsReady = false
    private var pending: [OpenRequest] = []

    /// `describe` says what to do with a path, nil for one that isn't there.
    public init(describe: @escaping (String) -> OpenRequest?, open: @escaping (OpenRequest) -> Void) {
        self.describe = describe
        openRequest = open
    }

    /// Takes `paths`; returns what it claimed. An item that isn't there is left out.
    @discardableResult
    public func open(_ paths: [String]) -> [OpenRequest] {
        let claimed = paths.compactMap(describe)
        for request in claimed {
            if windowsReady {
                openRequest(request)
            } else {
                pending.append(request)
            }
        }
        return claimed
    }

    /// The first windows are open: the items that came before them are opened now.
    public func startupWindowsOpened() {
        windowsReady = true
        let queued = pending
        pending = []
        for request in queued { openRequest(request) }
    }
}
