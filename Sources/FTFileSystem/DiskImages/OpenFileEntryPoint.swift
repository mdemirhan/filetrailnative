// Port of the open-file handling in apps/desktop/src/main/main.ts (app.on("open-file"))
import Foundation

/// A disk image opened with File Trail from Finder (Open With) or another app opens in a tab, as one opened in
/// File Trail does. macOS sends it before the app is ready when it launches File Trail to open it: it waits
/// for the windows. Other files aren't File Trail's to open.
///
/// The app delegate's `application(_:open:)` hands the paths to `open(_:)` and calls `startupWindowsOpened()`
/// once the first windows exist.
@MainActor
public final class OpenFileEntryPoint {
    private let openDiskImage: (String) -> Void
    private var windowsReady = false
    private var pending: [String] = []

    public init(openDiskImage: @escaping (String) -> Void) {
        self.openDiskImage = openDiskImage
    }

    /// Takes the disk images among `paths`; returns those it claimed. The rest are left to the system.
    @discardableResult
    public func open(_ paths: [String]) -> [String] {
        let claimed = paths.filter(DiskImageNames.isDiskImagePath)
        for path in claimed {
            if windowsReady {
                openDiskImage(path)
            } else {
                pending.append(path)
            }
        }
        return claimed
    }

    /// The first windows are open: the images that came before them are opened now.
    public func startupWindowsOpened() {
        windowsReady = true
        let queued = pending
        pending = []
        for path in queued { openDiskImage(path) }
    }
}
