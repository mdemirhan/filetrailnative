import AppKit
import FTFoundation

/// What the startup disk (`/`) is called, for every place in the app that names it: the tabs, the window title, the
/// path bar, the sidebar, the Info panel, Go To, Back and Forward, and search. Read at launch off the main thread, and
/// again when a disk is renamed; until the first read returns it is the name macOS gives the disk.
@MainActor
final class StartupDisk {
    static let shared = StartupDisk()

    /// Posted on the main thread when the name changed.
    static let nameChanged = Notification.Name("FileTrail.startupDiskNameChanged")

    private(set) var name = VolumePaths.defaultStartupDiskName
    private var renameObserver: (any NSObjectProtocol)?

    /// Reads the name, and reads it again whenever a disk is renamed.
    func start() {
        guard renameObserver == nil else { return }
        renameObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didRenameVolumeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // Any disk: reading the startup disk's name again is cheap, and only a change is told.
            MainActor.assumeIsolated { self?.read() }
        }
        read()
    }

    private func read() {
        Task { [weak self] in
            let name = await Self.readName()
            self?.set(name)
        }
    }

    /// The name Finder shows for `/`, or nil when it can't be read.
    @concurrent
    nonisolated static func readName() async -> String? {
        let values = try? URL(fileURLWithPath: "/").resourceValues(
            forKeys: [.volumeLocalizedNameKey, .volumeNameKey])
        return values?.volumeLocalizedName ?? values?.volumeName
    }

    /// A name read: a different one is kept and told to the windows (`nameChanged`).
    func set(_ name: String?) {
        guard let name, !name.isEmpty, name != self.name else { return }
        self.name = name
        NotificationCenter.default.post(name: Self.nameChanged, object: self)
    }
}
