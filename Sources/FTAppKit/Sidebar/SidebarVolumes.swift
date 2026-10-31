// Port of the volume list the renderer keeps (apps/desktop/src/renderer/hooks/useVolumes.ts) over VolumeWatcher
import AppKit
import FTFileSystem

/// The disks mounted, shared by every sidebar: one watcher for the app, and word of each change to the sidebars.
@MainActor
final class SidebarVolumes {
    static let shared = SidebarVolumes()

    private var observers: [UUID: ([Volume]) -> Void] = [:]
    /// Disks to show instead of the real ones (a window in a test, a scenario without a disk image mounted).
    var override: [Volume]? {
        didSet { notify() }
    }

    /// The watcher of the app (`ExplorerServices.volumeWatcher` is this one when the app made it from here).
    private(set) lazy var watcher: VolumeWatcher = VolumeWatcher(
        .init(onVolumesChanged: { [weak self] _ in self?.notify() }))

    var volumes: [Volume] { override ?? watcher.getVolumes() }

    /// Calls `handler` with the disks now, and again at each change, until the token goes.
    func observe(_ handler: @escaping ([Volume]) -> Void) -> Token {
        let id = UUID()
        observers[id] = handler
        handler(volumes)
        return Token { [weak self] in self?.observers[id] = nil }
    }

    /// The list is read again now: a window came to the front, an eject returned, a disk image was opened.
    func refresh() {
        watcher.refresh()
    }

    private func notify() {
        let volumes = volumes
        for handler in observers.values { handler(volumes) }
    }

    @MainActor
    final class Token {
        private var onCancel: (() -> Void)?

        fileprivate init(_ onCancel: @escaping () -> Void) {
            self.onCancel = onCancel
        }

        func cancel() {
            onCancel?()
            onCancel = nil
        }

        isolated deinit { cancel() }
    }
}
