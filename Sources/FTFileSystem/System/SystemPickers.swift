import AppKit
import FTFoundation
import Foundation
import UniformTypeIdentifiers

/// What a panel returned: nil when it was cancelled.
public typealias PanelPresenter = @MainActor (NSOpenPanel, NSWindow?) async -> [URL]?

@MainActor
public enum SystemPickers {
    public struct ApplicationChoice: Equatable, Sendable {
        public var canceled: Bool
        public var appPath: String?
        public var appName: String?
    }

    public struct DirectoryChoice: Equatable, Sendable {
        public var canceled: Bool
        public var path: String?
    }

    /// Runs the panel as a sheet on the window, or on its own without one.
    public static let present: PanelPresenter = { panel, window in
        let response: NSApplication.ModalResponse
        if let window {
            response = await withCheckedContinuation { continuation in
                panel.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            }
        } else {
            response = panel.runModal()
        }
        return response == .OK ? panel.urls : nil
    }

    static func applicationPanel() -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.title = "Choose Application"
        panel.prompt = "Choose App"
        panel.directoryURL = DiskPath("/Applications").url(isDirectory: true)
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        return panel
    }

    static func directoryPanel(defaultPath: String?) -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.title = "Choose Folder"
        panel.prompt = "Choose Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if let defaultPath, !defaultPath.isEmpty { panel.directoryURL = DiskPath(defaultPath).url(isDirectory: true) }
        return panel
    }

    /// The Other… picker: an app in /Applications, named as its disk has it.
    public static func pickApplication(window: NSWindow?, present: PanelPresenter = SystemPickers.present) async
        -> ApplicationChoice
    {
        let urls = await present(applicationPanel(), window)
        guard let urls else { return ApplicationChoice(canceled: true, appPath: nil, appName: nil) }
        let appPath = await chosenPath(urls.first, isPlace: false)
        return ApplicationChoice(
            canceled: false, appPath: appPath, appName: appPath.map(ApplicationPaths.displayName))
    }

    /// The path a panel's URL stands for, respelled as its disk has it, since a panel's URL may spell an accent its
    /// own way and the path is kept beside paths from listings (a destination, a favorite, an app in Settings). A
    /// folder is a place to go to, so a link is followed; an app is the item chosen, link or not. The disk is asked
    /// off the main thread, by the URL's own `path`: the file-system representation of a URL the system made from
    /// text spells every accent decomposed, whatever the URL holds.
    static func chosenPath(_ url: URL?, isPlace: Bool) async -> String? {
        guard let url, url.isFileURL else { return nil }
        let spelled = DiskPath(url.path)
        return await BlockingWork.run { (isPlace ? spelled.asOnDisk() : spelled.itemAsOnDisk()).string }
    }

    public static func pickDirectory(
        defaultPath: String?, window: NSWindow?, present: PanelPresenter = SystemPickers.present
    ) async -> DirectoryChoice {
        let urls = await present(directoryPanel(defaultPath: defaultPath), window)
        guard let urls else { return DirectoryChoice(canceled: true, path: nil) }
        return DirectoryChoice(canceled: false, path: await chosenPath(urls.first, isPlace: true))
    }
}

public enum VolumeInfo {
    public struct Sizes: Equatable, Sendable {
        public var availableBytes: Int64?
        public var totalBytes: Int64?
    }

    /// The capacity of the volume holding `path` and its free space, as `statfs` says (`bavail * bsize`).
    public static func sizes(atPath path: String) -> Sizes {
        // Foundation answers from `statfs` too: NSFileSystemFreeSize is f_bavail * f_bsize.
        guard let attributes = try? FileManager.default.attributesOfFileSystem(forPath: path),
            let free = (attributes[.systemFreeSize] as? NSNumber)?.int64Value,
            let total = (attributes[.systemSize] as? NSNumber)?.int64Value
        else { return Sizes(availableBytes: nil, totalBytes: nil) }
        return Sizes(availableBytes: free, totalBytes: total)
    }
}
