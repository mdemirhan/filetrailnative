import Foundation

/// Tests that write files of 80 to 150 MB guard copy code that rarely changes: they run only when
/// `FILETRAIL_LARGE_FILE_TESTS=1`. Use as `@Test(.enabled(if: LargeFileTests.enabled))`.
public enum LargeFileTests {
    public static var enabled: Bool {
        ProcessInfo.processInfo.environment["FILETRAIL_LARGE_FILE_TESTS"] == "1"
    }
}
