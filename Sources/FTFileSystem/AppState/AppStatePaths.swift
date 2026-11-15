import Foundation

/// Where the app keeps its own files: one folder under Application Support, named for the bundle id.
public enum AppStatePaths {
    /// The same in every build, development and release.
    public static let bundleID = "com.filetrail.native"

    /// `~/Library/Application Support/<bundle id>`.
    public static func userDataDirectory(
        bundleID: String = bundleID, applicationSupport: URL? = nil
    ) -> URL {
        let base =
            applicationSupport
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent(bundleID, isDirectory: true)
    }

    /// `app-state.json` in the user data folder.
    public static func appState(in userData: URL) -> URL {
        userData.appendingPathComponent("app-state.json")
    }

    /// The opened folders for the Go To box, next to the state file.
    public static func visitedFolders(besideAppState appState: URL) -> URL {
        appState.deletingLastPathComponent().appendingPathComponent("visited-folders.json")
    }

    /// The folders chosen in Move To and Extract To, next to the state file.
    public static func destinationFolders(besideAppState appState: URL) -> URL {
        appState.deletingLastPathComponent().appendingPathComponent("destination-folders.json")
    }

    /// The commands run from the command palette, the last first, next to the state file.
    public static func recentCommands(besideAppState appState: URL) -> URL {
        appState.deletingLastPathComponent().appendingPathComponent("recent-commands.json")
    }

    /// `logs/app.log` in the user data folder.
    public static func appLog(in userData: URL) -> URL {
        userData.appendingPathComponent("logs", isDirectory: true).appendingPathComponent("app.log")
    }
}
