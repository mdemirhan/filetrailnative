// Port of the FILETRAIL_LARGE_FILE_TESTS gate in packages/core/src/fs/testDiskImage.ts
import Foundation
import Testing

/// Tests that write files of 80 to 150 MB guard copy code that rarely changes: they run only when
/// `FILETRAIL_LARGE_FILE_TESTS=1`. Use as `@Test(.enabled(if: LargeFileTests.enabled))`.
public enum LargeFileTests {
    public static var enabled: Bool {
        ProcessInfo.processInfo.environment["FILETRAIL_LARGE_FILE_TESTS"] == "1"
    }
}

/// Self-tests of the disk image helper: each kind mounts, takes a file and reports its case rule.
struct DiskImageSelfTests {
    @Test(.tags(.diskImage), .diskImages, arguments: DiskImage.Kind.allCases)
    func mountsWritesAndDetaches(kind: DiskImage.Kind) async throws {
        var mounted: URL?
        try await DiskImage.withVolume(kind) { volume in
            mounted = volume
            let file = volume.appendingPathComponent("hello.txt")
            try Data("hi".utf8).write(to: file)
            #expect(FileManager.default.fileExists(atPath: file.path))
            let values = try volume.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
            #expect(values.volumeSupportsCaseSensitiveNames == kind.isCaseSensitive)
        }
        let path = try #require(mounted).path
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test(.tags(.diskImage), .diskImages)
    func detachesWhenTheBodyThrows() async throws {
        struct Boom: Error {}
        var mounted: URL?
        await #expect(throws: Boom.self) {
            try await DiskImage.withVolume(.apfs) { volume in
                mounted = volume
                throw Boom()
            }
        }
        let path = try #require(mounted).path
        #expect(!FileManager.default.fileExists(atPath: path))
    }
}
