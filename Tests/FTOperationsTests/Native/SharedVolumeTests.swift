// Self-test of FTTestSupport's DiskImage.withSharedVolume (no TypeScript source: the original mounted one disk per
// test file in beforeAll)
import Darwin
import FTTestSupport
import Foundation
import Testing

/// The volume a path is on: where it is mounted.
private func mountPoint(of path: String) -> String? {
    var info = statfs()
    guard statfs(path, &info) == 0 else { return nil }
    return withUnsafeBytes(of: info.f_mntonname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
}

struct SharedVolumeTests {
    // Tests using a kind at the same time get folders of their own on one volume, which goes once the last is done.
    // HFS+, which no other test of this target uses, so nothing else keeps it mounted.
    @Test(.tags(.diskImage), .diskImages)
    func lendsAFolderEachOnOneVolumeAndDetachesItAfterTheLastUser() async throws {
        var volume: String?
        try await DiskImage.withSharedVolume(.hfs) { first in
            let firstMount = try #require(mountPoint(of: first.path))
            #expect(firstMount != mountPoint(of: NSTemporaryDirectory()))
            volume = firstMount
            try await DiskImage.withSharedVolume(.hfs) { second in
                #expect(second != first)
                #expect(mountPoint(of: second.path) == firstMount)
                try Data("b".utf8).write(to: second.appendingPathComponent("b.txt"))
            }
            // The second folder is gone, the volume still there for the first.
            let names = try FileManager.default.contentsOfDirectory(atPath: firstMount).filter { !$0.hasPrefix(".") }
            #expect(names == [first.lastPathComponent])
            #expect(mountPoint(of: first.path) == firstMount)
        }
        #expect(!FileManager.default.fileExists(atPath: try #require(volume)))
    }
}
