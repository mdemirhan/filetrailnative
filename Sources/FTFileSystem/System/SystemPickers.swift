// Port of pickApplication, pickDirectory and getVolumeInfo (apps/desktop/src/main/bootstrap/systemHandlers.ts)
import AppKit
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
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
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
        if let defaultPath, !defaultPath.isEmpty { panel.directoryURL = URL(fileURLWithPath: defaultPath) }
        return panel
    }

    /// The Other… picker: an app in /Applications.
    public static func pickApplication(window: NSWindow?, present: PanelPresenter = SystemPickers.present) async
        -> ApplicationChoice
    {
        let urls = await present(applicationPanel(), window)
        guard let urls else { return ApplicationChoice(canceled: true, appPath: nil, appName: nil) }
        let appPath = urls.first?.path
        return ApplicationChoice(
            canceled: false, appPath: appPath, appName: appPath.map(ApplicationPaths.displayName))
    }

    public static func pickDirectory(
        defaultPath: String?, window: NSWindow?, present: PanelPresenter = SystemPickers.present
    ) async -> DirectoryChoice {
        let urls = await present(directoryPanel(defaultPath: defaultPath), window)
        guard let urls else { return DirectoryChoice(canceled: true, path: nil) }
        return DirectoryChoice(canceled: false, path: urls.first?.path)
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
