// Port of apps/desktop/src/main/bootstrap/systemHandlers.ts (open, Open With, Always Open With, Terminal, the pickers, Full Disk Access) and apps/desktop/src/main/bootstrap/diskIds.ts
import AppKit
import FTFoundation
import Foundation

/// The system calls behind the open actions, injectable so tests never open anything.
public struct SystemOpener: Sendable {
    /// Opens the item with its default app; returns the reason it could not, "" when it did (`shell.openPath`).
    public var openPath: @Sendable (String) async -> String
    /// Opens the items with the app (`open -a`).
    public var openWithApplication: @Sendable (_ applicationPath: String, _ paths: [String]) async throws -> Void
    /// Shows the items selected in their folders (`open -R`).
    public var reveal: @Sendable ([String]) async throws -> Void
    /// Opens a URL (`shell.openExternal`).
    public var openURL: @Sendable (URL) async throws -> Void

    public init(
        openPath: @escaping @Sendable (String) async -> String,
        openWithApplication: @escaping @Sendable (String, [String]) async throws -> Void,
        reveal: @escaping @Sendable ([String]) async throws -> Void,
        openURL: @escaping @Sendable (URL) async throws -> Void
    ) {
        self.openPath = openPath
        self.openWithApplication = openWithApplication
        self.reveal = reveal
        self.openURL = openURL
    }

    struct Failure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// `NSWorkspace`: the same results as the original's `shell.openPath`, `open -a`, `open -R` and `openExternal`.
    public static let workspace = SystemOpener(
        openPath: { path in
            do {
                _ = try await NSWorkspace.shared.open(
                    URL(fileURLWithPath: path), configuration: NSWorkspace.OpenConfiguration())
                return ""
            } catch {
                return errorMessage(error)
            }
        },
        openWithApplication: { applicationPath, paths in
            let appURL = URL(fileURLWithPath: applicationPath)
            guard FileManager.default.fileExists(atPath: applicationPath) else {
                throw Failure(
                    message: "Unable to find application named '\(ApplicationPaths.displayName(applicationPath))'")
            }
            _ = try await NSWorkspace.shared.open(
                paths.map { URL(fileURLWithPath: $0) }, withApplicationAt: appURL,
                configuration: NSWorkspace.OpenConfiguration())
        },
        reveal: { paths in
            await MainActor.run {
                NSWorkspace.shared.activateFileViewerSelecting(paths.map { URL(fileURLWithPath: $0) })
            }
        },
        openURL: { url in
            _ = try await NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration())
        })
}

public enum SystemActions {
    /// system:openPath
    public static func openPath(_ path: String, opener: SystemOpener = .workspace) async -> OperationResult {
        let error = await opener.openPath(path)
        return error.isEmpty ? .success : .failure(error)
    }

    static let fullDiskAccessSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    /// macOS lets an app list the Trash only with Full Disk Access, which no signature or entitlement grants and
    /// macOS never asks for: the person turns it on in System Settings.
    public static func openFullDiskAccessSettings(opener: SystemOpener = .workspace) async -> Bool {
        do {
            try await opener.openURL(fullDiskAccessSettingsURL)
            return true
        } catch {
            return false
        }
    }

    /// system:openPathsWithApplication
    public static func openPaths(
        _ paths: [String], withApplication applicationPath: String, opener: SystemOpener = .workspace
    ) async -> OperationResult {
        guard ApplicationPaths.isValidBundlePath(applicationPath) else {
            return .failure(ApplicationPaths.invalidPathMessage(applicationPath))
        }
        do {
            // Finder refuses to open a document handed to it, so choosing Finder shows the items selected in their
            // folder instead: files, folders and packages alike.
            if ApplicationPaths.normalize(ApplicationPaths.trimmed(applicationPath)) == ApplicationPaths.finderAppPath {
                try await opener.reveal(paths)
            } else {
                try await opener.openWithApplication(applicationPath, paths)
            }
            return .success
        } catch {
            return .failure(errorMessage(error))
        }
    }

    /// system:getOpenWithApplications. The apps Launch Services offers for the items, and the pinned apps that are
    /// still there. When it can't be asked, the menu still lists the pinned apps found on disk, and Other….
    public static func openWithApplications(
        paths: [String], pinnedAppPaths: [String],
        lookUp: @Sendable ([String], [String]) async throws -> LaunchServicesAnswer = { paths, appPaths in
            await Task.detached { OpenWithCatalog.shared.lookup(paths: paths, appPaths: appPaths) }.value
        },
        exists: @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) async -> OpenWithLookup {
        do {
            let result = try await lookUp(paths, pinnedAppPaths)
            return OpenWithLookup(
                defaultApp: result.defaultApp, apps: result.apps, kinds: result.kinds, pinnedApps: result.appInfo)
        } catch {
            return OpenWithLookup(
                pinnedApps: pinnedAppPaths.map { path in
                    ApplicationPaths.isValidBundlePath(path) && exists(path)
                        ? ApplicationInfo(path: path, name: ApplicationPaths.displayName(path)) : nil
                })
        }
    }

    /// system:setDefaultApplication. Always Open With: every file of the kind opens in the app from now on, in
    /// Finder too.
    public static func setDefaultApplication(
        applicationPath: String, contentType: String,
        setDefault: @Sendable (String, String) async throws -> Void = { appPath, type in
            try await OpenWithCatalog.shared.setDefaultApplication(appPath: appPath, contentType: type)
        }
    ) async -> OperationResult {
        guard ApplicationPaths.isValidBundlePath(applicationPath) else {
            return .failure(ApplicationPaths.invalidPathMessage(applicationPath))
        }
        do {
            try await setDefault(ApplicationPaths.trimmed(applicationPath), contentType)
            return .success
        } catch {
            return .failure(errorMessage(error))
        }
    }

    // MARK: Terminal and editor

    public struct TerminalResult: Equatable, Sendable {
        public var ok: Bool
        public var error: String?
        public var targetPath: String
        public var terminalName: String
    }

    static let defaultTerminalName = "Terminal"

    /// system:openInTerminal. Files open Terminal in their containing directory; directories open directly.
    public static func openInTerminal(
        path: String, terminalApp: ApplicationSelection?, opener: SystemOpener = .workspace
    ) async -> TerminalResult {
        let terminalName = terminalApplicationName(terminalApp)
        let launchApplicationPath = terminalApp.map { ApplicationPaths.trimmed($0.appPath) } ?? ""
        let targetPath = terminalTargetPath(path)
        if !launchApplicationPath.isEmpty && !ApplicationPaths.isValidBundlePath(launchApplicationPath) {
            return TerminalResult(
                ok: false, error: ApplicationPaths.invalidPathMessage(launchApplicationPath), targetPath: targetPath,
                terminalName: terminalName)
        }
        // The original asks `open -a` for the bundle path, falling back to the Terminal app by name.
        let application =
            launchApplicationPath.isEmpty
            ? ApplicationFallback.terminalPath : launchApplicationPath
        do {
            try await opener.openWithApplication(application, [targetPath])
            return TerminalResult(ok: true, error: nil, targetPath: targetPath, terminalName: terminalName)
        } catch {
            return TerminalResult(
                ok: false, error: errorMessage(error), targetPath: targetPath, terminalName: terminalName)
        }
    }

    /// Edit in the text editor: `openPathsWithApplication([path], defaultTextEditor.appPath)`.
    public static func editInTextEditor(
        path: String, editor: ApplicationSelection, opener: SystemOpener = .workspace
    ) async -> OperationResult {
        await openPaths([path], withApplication: editor.appPath, opener: opener)
    }

    static func terminalApplicationName(_ terminalApp: ApplicationSelection?) -> String {
        guard let terminalApp else { return defaultTerminalName }
        let appName = ApplicationPaths.trimmed(terminalApp.appName)
        if !appName.isEmpty { return appName }
        let appPath = ApplicationPaths.trimmed(terminalApp.appPath)
        return appPath.isEmpty ? defaultTerminalName : ApplicationPaths.displayName(appPath)
    }

    private static func terminalTargetPath(_ path: String) -> String {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
            return path
        }
        return ApplicationPaths.dirname(path)
    }

    // MARK: Disks

    /// system:getDiskIds. Which disk each path is on: the device number of what it names, followed through
    /// symlinks (a drop on a link to a folder lands in that folder). Nil where the path can't be read.
    public static func diskIds(
        paths: [String],
        stat statPath: @Sendable (String) -> Int64? = { path in
            var info = Darwin.stat()
            return fstatat(AT_FDCWD, path, &info, 0) == 0 ? Int64(info.st_dev) : nil
        }
    ) -> [Int64?] {
        paths.map { statPath($0) }
    }
}

enum ApplicationFallback {
    /// The app `open -a Terminal` finds by name.
    static let terminalPath = AppPreferenceLimits.defaultTerminalApplication.appPath
}
