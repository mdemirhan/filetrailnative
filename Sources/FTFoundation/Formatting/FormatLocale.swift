import Foundation

/// The locale dates, times, sizes and counts are written in for people to read: the system's (`Locale.current`),
/// which carries the region and the format settings of System Settings, such as 24-hour time. So a Mac set to the
/// United Kingdom shows "5 Oct 2026, 16:12" and one set to Germany "1.234 items" and "1,5 MB", as Finder does. The
/// app's own words stay English: "Today, 16:12". It is read once, at launch.
///
/// What a machine reads (file names the app writes, JSON, logs, `AppClock`) never goes through it.
///
/// A test process writes in US English whatever the Mac it runs on is set to, so expected texts and goldens hold on
/// any Mac; a test of another region passes its own locale.
public enum FormatLocale {
    public static let current: Locale = isTestProcess ? Locale(identifier: "en_US") : .current

    /// `swift test` runs the tests in a bundle whose path ends in `.xctest`; Xcode sets the configuration path.
    static var isTestProcess: Bool {
        ProcessInfo.processInfo.arguments.contains { $0.contains(".xctest") }
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    /// A count with its digits grouped as the region groups them: "1,234", "1.234" in Germany.
    public static func count<Value: BinaryInteger>(_ value: Value, locale: Locale = current) -> String {
        value.formatted(IntegerFormatStyle<Value>(locale: locale))
    }
}
