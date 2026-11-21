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
    // Other tests of the run may hold folders of their own on the same volume meanwhile: only this test's two are
    // looked for.
    @Test(.tags(.diskImage), .diskImages, .enabled(if: ReleaseTests.enabled))
    func lendsAFolderEachOnOneVolumeAndKeepsItForTheNext() async throws {
        var volume: String?
        var lent: [String] = []
        try await DiskImage.withSharedVolume(.hfs) { first in
            let firstMount = try #require(mountPoint(of: first.path))
            #expect(firstMount != mountPoint(of: NSTemporaryDirectory()))
            volume = firstMount
            lent.append(first.lastPathComponent)
            try await DiskImage.withSharedVolume(.hfs) { second in
                #expect(second != first)
                #expect(mountPoint(of: second.path) == firstMount)
                lent.append(second.lastPathComponent)
                try Data("b".utf8).write(to: second.appendingPathComponent("b.txt"))
            }
            // The second folder is gone, the volume still there for the first.
            let names = try FileManager.default.contentsOfDirectory(atPath: firstMount)
            #expect(names.contains(first.lastPathComponent))
            #expect(!names.contains(lent[1]))
            #expect(mountPoint(of: first.path) == firstMount)
        }
        let kept = try #require(volume)
        let left = try FileManager.default.contentsOfDirectory(atPath: kept)
        #expect(lent.count == 2 && lent.allSatisfy { !left.contains($0) })
        try await DiskImage.withSharedVolume(.hfs) { next in
            #expect(mountPoint(of: next.path) == kept)
        }
    }
}
