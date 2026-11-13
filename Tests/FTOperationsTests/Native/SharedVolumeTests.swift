// Self-test of FTTestSupport's DiskImage.withSharedVolume
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
    // Tests using a kind get folders of their own on one volume, which stays mounted for the tests after them.
    @Test(.tags(.diskImage), .diskImages, .enabled(if: ReleaseTests.enabled))
    func lendsAFolderEachOnOneVolumeAndKeepsItForTheNext() async throws {
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
        let kept = try #require(volume)
        #expect(try FileManager.default.contentsOfDirectory(atPath: kept).filter { !$0.hasPrefix(".") }.isEmpty)
        try await DiskImage.withSharedVolume(.hfs) { next in
            #expect(mountPoint(of: next.path) == kept)
        }
    }
}
