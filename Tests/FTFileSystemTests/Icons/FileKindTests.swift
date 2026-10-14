import FTTestSupport
import Foundation
import Testing

@testable import FTFileSystem

private struct KindInput: Codable {
    var path: String
}

private let fixtures: URL = {
    let cache =
        ProcessInfo.processInfo.environment["FILETRAIL_PORT_CACHE"]
        ?? NSHomeDirectory() + "/Library/Caches/filetrail-port"
    return URL(fileURLWithPath: cache).appendingPathComponent("fixtures")
}()

private let hasFixtures = FileManager.default.fileExists(atPath: fixtures.appendingPathComponent("names").path)

@Suite struct FileKindTests {
    // Machine-local: Spotlight's kind strings depend on the macOS version, language and installed apps, so this
    // checks the port against what the reference addon said on the machine that recorded the golden.
    // F-156
    @Test(.enabled(if: hasFixtures, "needs the shared fixtures"))
    func kindStringsMatchTheReferenceOnTheFixtures() throws {
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
