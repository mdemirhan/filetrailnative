import Foundation

/// Tests that only a release runs (`scripts/release.sh` sets `FILETRAIL_RELEASE_TESTS=1`): the self-tests of the
/// test helpers, and tests that are slow or that change the whole test process. Use as
/// `@Test(.enabled(if: ReleaseTests.enabled))`.
public enum ReleaseTests {
    public static var enabled: Bool {
        ProcessInfo.processInfo.environment["FILETRAIL_RELEASE_TESTS"] == "1"
    }
}
