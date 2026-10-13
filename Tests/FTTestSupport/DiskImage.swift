// Port of packages/core/src/fs/testDiskImage.ts (attach and detach approach)
import Foundation
import Testing

extension Tag {
    /// Tests that mount a disk image. Skipped when `FILETRAIL_NO_DISK_IMAGES=1`.
    @Tag public static var diskImage: Self
}

extension Trait where Self == ConditionTrait {
    /// Skips a test that mounts a disk image when `FILETRAIL_NO_DISK_IMAGES=1`.
    /// Use as `@Test(.tags(.diskImage), .diskImages)`.
    public static var diskImages: Self {
        .enabled(if: DiskImage.isEnabled, "disk images are disabled by FILETRAIL_NO_DISK_IMAGES=1")
    }
}

/// A small disk image mounted for the duration of a closure, for what one volume can't show:
/// other file systems, a case-sensitive disk, moving between disks.
public enum DiskImage {
    public enum Kind: String, CaseIterable, Sendable {
        case fat32
        case exfat
        case hfs
        case apfs
        case apfsCaseSensitive

        /// The blank image's name in `tools/fixtures/disk-images.sh`.
        var imageName: String { self == .apfsCaseSensitive ? "apfs-cs" : rawValue }

        public var isCaseSensitive: Bool { self == .apfsCaseSensitive }
    }

    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    public static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["FILETRAIL_NO_DISK_IMAGES"] != "1"
    }

    /// Mounts a fresh clone of the blank image of `kind`, runs `body` with the volume's folder, and
    /// detaches (with force) and deletes the clone afterwards, also when `body` throws.
    public static func withVolume<T>(
        _ kind: Kind, isolation: isolated (any Actor)? = #isolation,
        _ body: (URL) async throws -> T
    ) async throws -> T {
        let work = try TemporaryDirectory(prefix: "ft-disk")
        defer { work.remove() }
        let image = work.appending("volume.sparseimage")
        try clone(kind, to: image)
        let mount = try attach(image)
        defer { detach(mount) }
        return try await body(mount)
    }

    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static var cacheDirectory: URL {
        let base =
            ProcessInfo.processInfo.environment["FILETRAIL_PORT_CACHE"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
                "Library/Caches/filetrail-port")
        return base.appendingPathComponent("fixtures/disks")
    }

    private static func clone(_ kind: Kind, to destination: URL) throws {
        let source = cacheDirectory.appendingPathComponent("\(kind.imageName).sparseimage")
        if !FileManager.default.fileExists(atPath: source.path) {
            // First use on this machine: make the blank images.
            let script = repositoryRoot.appendingPathComponent("tools/fixtures/disk-images.sh")
            _ = try run("/bin/bash", [script.path])
        }
        // copyItem on APFS clones the file (copy on write), the same as `cp -c`.
        try FileManager.default.copyItem(at: source, to: destination)
    }

    private static func attach(_ image: URL) throws -> URL {
        let output = try run(
            "/usr/bin/hdiutil", ["attach", "-nobrowse", "-noautoopen", "-plist", image.path])
        guard
            let plist = try PropertyListSerialization.propertyList(from: output, format: nil) as? [String: Any],
            let entities = plist["system-entities"] as? [[String: Any]],
            let mountPoint = entities.compactMap({ $0["mount-point"] as? String }).first
        else { throw Failure(description: "hdiutil attach reported no mount point for \(image.path)") }
        // realpath'd, so paths the code under test reports match ours.
        return URL(fileURLWithPath: mountPoint).resolvingSymlinksInPath()
    }

    private static func detach(_ mount: URL) {
        for attempt in 0..<5 {
            if (try? run("/usr/bin/hdiutil", ["detach", "-force", mount.path])) != nil { return }
            Thread.sleep(forTimeInterval: 0.5 * Double(attempt + 1))
        }
    }

    private static func run(_ tool: String, _ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        // Read before waiting, so a full pipe can't stall the tool.
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errorData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errorData, as: UTF8.self)
            throw Failure(description: "\(tool) \(arguments.first ?? "") failed: \(message)")
        }
        return data
    }
}
