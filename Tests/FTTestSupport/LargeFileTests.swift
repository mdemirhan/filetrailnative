// Port of the FILETRAIL_LARGE_FILE_TESTS gate in packages/core/src/fs/testDiskImage.ts
import Darwin
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

    @Test(.tags(.diskImage), .diskImages)
    func givesEachMountAVolumeNameOfItsOwn() async throws {
        var names: [String] = []
        for _ in 0..<2 {
            try await DiskImage.withVolume(.fat32Small) { volume in
                names.append(volume.lastPathComponent)
                #expect(volume.path == "/Volumes/" + volume.lastPathComponent)
            }
        }
        #expect(names.count == 2 && names[0] != names[1])
        #expect(names.allSatisfy { $0.hasPrefix("FTG\(getpid())-") && $0.count <= 11 })
    }

    @Test(.tags(.diskImage), .diskImages)
    func detachesWhatAProcessThatIsGoneLeftAttached() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
        let gone = try #require((90000...99_999).reversed().first { kill(pid_t($0), 0) != 0 && errno == ESRCH })
        let folder = base.appendingPathComponent("ft-disk-pid\(gone)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let image = folder.appendingPathComponent("volume.sparseimage")
        try DiskImage.makeImage(.fat32Small, at: image)
        let mount = folder.appendingPathComponent("mount")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: false)
        let attach = Process()
        attach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        attach.arguments = ["attach", "-nobrowse", "-noautoopen", "-mountpoint", mount.path, image.path]
        attach.standardOutput = FileHandle.nullDevice
        attach.standardError = FileHandle.nullDevice
        try attach.run()
        attach.waitUntilExit()
        try #require(attach.terminationStatus == 0)
        // Made a while ago, by a process that is gone.
        try FileManager.default.setAttributes(
            [.creationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: folder.path)

        DiskImage.detachLeftovers()

        var info = statfs()
        // f_mntonname is the realpath (/private/var/...), the folder's path is not.
        let stillMounted =
            statfs(mount.path, &info) == 0
            && withUnsafeBytes(of: &info.f_mntonname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
                .hasSuffix(mount.path)
        #expect(!stillMounted)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        if stillMounted {
            _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/hdiutil"), arguments: ["detach", "-force", mount.path])
        }
    }
}
