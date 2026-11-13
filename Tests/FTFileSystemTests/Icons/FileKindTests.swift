import FTTestSupport
import Foundation
import Testing

@testable import FTFileSystem

private struct KindInput: Codable {
    var path: String
}

private let fixtures = URL(fileURLWithPath: Fixtures.root)

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
        #expect(FileKind.ByContentType().kind(forPath: "") == nil)
        #expect(FileKind.ByContentType().kind(forPath: "/nonexistent-filetrail-path") == nil)
    }

    /// Files without an extension are typed by name, permissions and Finder's type code; asking Spotlight once per
    /// type names each the same as asking it for every file.
    @Test func kindsKeptByContentTypeAreTheOnesEachFileGets() throws {
        try withTemporaryDirectory { directory in
            func make(_ name: String, mode: Int16 = 0o644, typeCode: String? = nil) throws -> String {
                let path = directory.appending(name).path
                try Data("hi\n".utf8).write(to: URL(fileURLWithPath: path))
                if let typeCode {
                    var info = [UInt8](repeating: 0, count: 32)
                    info.replaceSubrange(0..<4, with: Array(typeCode.utf8))
                    #expect(setxattr(path, "com.apple.FinderInfo", info, info.count, 0, 0) == 0)
                }
                #expect(chmod(path, mode_t(mode)) == 0)
                return path
            }
            let paths = [
                try make("0a1b2c"), try make("README"), try make("tool", mode: 0o755), try make("3d4e5f"),
                try make("Makefile"), try make("LICENSE"), try make("run", mode: 0o755),
                try make("typed", typeCode: "TEXT"), try make("picture", typeCode: "JPEG"),
                try make("unreadable", mode: 0o000), try make("COPYING", mode: 0o000),
            ]
            let byContentType = FileKind.ByContentType()
            for path in paths + paths {
                #expect(byContentType.kind(forPath: path) == FileKind.kind(forPath: path), "\(path)")
            }
            #expect(byContentType.kind(forPath: paths[0]) == "Document")
            #expect(byContentType.kind(forPath: paths[2]) == "Unix Executable File")
        }
    }
}
