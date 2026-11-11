import FTFoundation
import Foundation

/// What the build recorded in the app's `Info.plist`: the full version (`FTVersion`, "0.1.0+dev.4";
/// `CFBundleShortVersionString` has only its numbers) and the short git hash of the commit it was made from (`FTCommit`).
/// `scripts/build-app.sh` writes both.
public enum BuildInfo {
    public static let versionKey = "FTVersion"
    public static let commitKey = "FTCommit"
    /// The version of a run that has no `Info.plist` (`swift run`, tests): a placeholder.
    public static let fallbackVersion = "0.1.0"

    /// The commit the app was built from, as the build recorded it; nil when it didn't, or the value is no text.
    public static func commit(from info: [String: Any]?) -> String? {
        field(commitKey, in: info)
    }

    /// The app's version, as the build recorded it; nil when it didn't.
    public static func version(from info: [String: Any]?) -> String? {
        field(versionKey, in: info)
    }

    private static func field(_ key: String, in info: [String: Any]?) -> String? {
        guard let value = info?[key] as? String, !value.isEmpty else { return nil }
        return value
    }
}

public enum AboutInfoReader {
    /// The app ships for Apple silicon only.
    public static var currentArchitectureName: String { "Apple silicon" }

    /// `ProcessInfo`'s version as "27.0.0".
    public static func versionString(_ version: OperatingSystemVersion) -> String {
        "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    /// What the About window shows, from the app's `Info.plist`, the running macOS and the bundled `fd`.
    public static func read(
        info: [String: Any]? = Bundle.main.infoDictionary,
        systemVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion,
        architecture: String = currentArchitectureName, fdVersion: String = FdBinary.manifest.version
    ) -> AboutInfo {
        AboutInfo(
            version: BuildInfo.version(from: info) ?? BuildInfo.fallbackVersion, commit: BuildInfo.commit(from: info),
            macosVersion: AboutText.formatMacosVersion(versionString(systemVersion)), architecture: architecture,
            fdVersion: fdVersion)
    }
}
