// Port of apps/desktop/src/shared/aboutInfo.ts (no Electron row: the app has no runtime to name)
import Foundation

/// What the About window shows and Copy Details copies (`app:getAboutInfo`).
public struct AboutInfo: Equatable, Sendable {
    public var version: String
    /// The short git hash the build was made from; nil when the build doesn't know it.
    public var commit: String?
    /// "27.0", as macOS names its versions.
    public var macosVersion: String
    /// "Apple silicon" or "Intel".
    public var architecture: String
    public var fdVersion: String

    public init(version: String, commit: String?, macosVersion: String, architecture: String, fdVersion: String) {
        self.version = version
        self.commit = commit
        self.macosVersion = macosVersion
        self.architecture = architecture
        self.fdVersion = fdVersion
    }
}

public enum AboutText {
    public static let appName = "File Trail"
    public static let tagline = "A file browser that stays out of your way."
    public static let copyright = "© 2026 Mustafa Demirhan"
    public static let repositoryURL = "https://github.com/mdemirhan/filetrail"
    public static let issuesURL = repositoryURL + "/issues"

    /// The version as the About window shows it: "0.1.0 (df11088)", or "0.1.0" when the build does not know its commit.
    public static func formatAppVersion(_ info: AboutInfo) -> String {
        guard let commit = info.commit, !commit.isEmpty else { return info.version }
        return "\(info.version) (\(commit))"
    }

    /// What Copy Details puts on the clipboard: the lines a bug report needs.
    public static func formatAboutDetails(_ info: AboutInfo) -> String {
        [
            "\(appName) \(formatAppVersion(info))",
            "macOS \(info.macosVersion), \(info.architecture)",
            "fd \(info.fdVersion)",
        ].joined(separator: "\n")
    }

    /// The rows of the About window, label and value.
    public static func rows(_ info: AboutInfo) -> [(label: String, value: String)] {
        [
            (label: "Version", value: formatAppVersion(info)),
            (label: "macOS", value: "\(info.macosVersion), \(info.architecture)"),
            (label: "Search", value: "fd \(info.fdVersion)"),
        ]
    }

    /// macOS names its versions without a last zero: "27.0", then "27.0.1".
    public static func formatMacosVersion(_ systemVersion: String) -> String {
        let parts = systemVersion.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[2] == "0", parts[0].allSatisfy(\.isASCIIDigit), !parts[0].isEmpty,
            parts[1].allSatisfy(\.isASCIIDigit), !parts[1].isEmpty
        else { return systemVersion }
        return "\(parts[0]).\(parts[1])"
    }
}

extension Character {
    fileprivate var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}
