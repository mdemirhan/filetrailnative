// Port of apps/desktop/src/main/aboutInfo.ts (build-info.json, formatMacosVersion) and the app:getAboutInfo handler
import FTFoundation
import Foundation

/// What the build recorded in the app's `Info.plist`: the version (`CFBundleShortVersionString`) and the short git hash
/// of the commit it was made from (`FTCommit`, written by `scripts/build-app.sh`).
public enum BuildInfo {
    public static let versionKey = "CFBundleShortVersionString"
    public static let commitKey = "FTCommit"
    /// The version of a run that has no `Info.plist` (`swift run`, tests): `app.getVersion()`'s placeholder.
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
    /// "Apple silicon" or "Intel".
    public static var currentArchitectureName: String {
        #if arch(arm64)
            "Apple silicon"
        #else
            "Intel"
        #endif
    }

    /// `ProcessInfo`'s version as "27.0.0".
    public static func versionString(_ version: OperatingSystemVersion) -> String {
        "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    /// `app:getAboutInfo`.
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
