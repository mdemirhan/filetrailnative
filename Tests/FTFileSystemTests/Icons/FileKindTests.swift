import FTTestSupport
import Foundation
import Testing

@testable import FTFileSystem

private struct KindInput: Codable {
    var path: String
}

private let fixtures: URL = {
    let cache =
        ProcessInfo.processInfo.environment["FILETRAIL_DEV_CACHE"]
        ?? NSHomeDirectory() + "/Library/Caches/filetrail-dev"
    return URL(fileURLWithPath: cache).appendingPathComponent("fixtures")
}()

/// The golden reads kinds in the names and lighthouse trees.
private let hasFixtures = ["names", "lighthouse"].allSatisfy {
    FileManager.default.fileExists(atPath: fixtures.appendingPathComponent("\($0)/.fixture-version").path)
}

@Suite struct FileKindTests {
    // Machine-local: Spotlight's kind strings depend on the macOS version, language and installed apps, so the golden
    // holds only on the machine that recorded it.
    @Test(.enabled(if: hasFixtures, "needs the shared fixtures"))
    func kindStringsMatchTheGoldenFileOnTheFixtures() throws {
        let cases: [GoldenCase<KindInput, String?>] = try Golden.load(suite: "kind-strings")
        #expect(!cases.isEmpty)
        Golden.expectMatches(cases) { input in
            FileKind.kind(forPath: input.path.hasPrefix("/") ? input.path : fixtures.path + "/" + input.path)
        }
    }

    @Test func namesTheKindOfAFileAndAFolder() throws {
        try withTemporaryDirectory { directory in
            let file = directory.appending("notes.txt")
            try Data("hi".utf8).write(to: file)
            #expect(FileKind.kind(forPath: file.path) == "Plain Text Document")
            #expect(FileKind.kind(forPath: directory.path) == "Folder")
        }
    }

    @Test func hasNoKindForNothingOrAMissingFile() {
        #expect(FileKind.kind(forPath: "") == nil)
        #expect(FileKind.kind(forPath: "/nonexistent-filetrail-path") == nil)
    }
}
