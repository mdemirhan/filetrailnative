import Darwin
import FTTestSupport
import Foundation
import Testing

@testable import FTFileSystem

/// A disk image hdiutil has attached. Its image file is a test's own; the `/dev/diskN` it had, and the
/// `/Volumes/<name>` its volume had, go to the next disk attached anywhere on the Mac once it is gone
/// (other test processes attach and detach clones all the time), so a test asks after the image.
private struct AttachedImage {
    let path: String
    let devices: Set<String>
    let mountPoints: Set<String>
}

private func attachedImages() throws -> [AttachedImage] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
    process.arguments = ["info", "-plist"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    try #require(process.terminationStatus == 0, "hdiutil info failed")
    let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    return (plist?["images"] as? [[String: Any]] ?? []).compactMap { image in
        guard let path = image["image-path"] as? String else { return nil }
        let entities = image["system-entities"] as? [[String: Any]] ?? []
        let mountPoints = entities.compactMap { $0["mount-point"] as? String }
        return AttachedImage(
            path: realPath(path), devices: Set(entities.compactMap { $0["dev-entry"] as? String }),
            mountPoints: Set(mountPoints.map(realPath)))
    }
}

/// realpath(3): resolvingSymlinksInPath would take /private off a mount point in a temporary folder.
private func realPath(_ path: String) -> String {
    guard let resolved = realpath(path, nil) else { return path }
    defer { free(resolved) }
    return String(cString: resolved)
}

/// The image whose volume is mounted at `path`.
private func image(mountedAt path: String) throws -> AttachedImage {
    try #require(attachedImages().first { $0.mountPoints.contains(path) })
}

/// `image` as attached now; nil once it is detached.
private func attached(_ image: AttachedImage) throws -> AttachedImage? {
    try attachedImages().first { $0.path == image.path }
}

private func isMounted(_ path: String) -> Bool {
    VolumeListing.mounts().contains { $0.path == path }
}

/// The device node (`/dev/disk5s1`) mounted at `path`. It names this volume only while its image is
/// attached.
private func source(of path: String) throws -> String {
    try #require(VolumeListing.mounts().first { $0.path == path }).source
}

private func isMounted(source: String) -> Bool {
    VolumeListing.mounts().contains { $0.source == source }
}

private func wholeDevice(of path: String) throws -> String {
    let record = try #require(VolumeListing.mounts().first { $0.path == path })
    let disk = try #require(VolumeListing.deviceDisk(of: record, PhysicalDisk.lookup(bsdName:)))
    return "/dev/\(disk.whole)"
}

@Suite(.serialized) struct VolumeEjectorTests {
    // T-cfcc0c26 F-144 F-211 F-212
    @Test(.tags(.diskImage), .diskImages) func unmountsTheVolumeAndEjectsItsDiskDetachingADiskImage() async throws {
        try await DiskImage.withVolume(.apfs) { folder in
            let image = try image(mountedAt: folder.path)
            #expect(isMounted(folder.path))
            // The disk the eject is to take away is this image's.
            #expect(try image.devices.contains(wholeDevice(of: folder.path)))
            try await VolumeEjector.eject(path: folder.path, wholeDisk: true)
            // Detached, so none of its volumes is mounted either.
            #expect(try attached(image) == nil)
        }
    }

    // T-7e94f3e8 F-211
    @Test(.tags(.diskImage), .diskImages) func unmountsOnlyTheVolumeWithoutWholeDiskLeavingItsDiskAttached()
        async throws
    {
        try await DiskImage.withVolume(.apfs) { folder in
            let image = try image(mountedAt: folder.path)
            let device = try wholeDevice(of: folder.path)
            let source = try source(of: folder.path)
            try await VolumeEjector.eject(path: folder.path)
            // Still attached, the image keeps its devices, so what is mounted from them would be its own.
            let still = try #require(try attached(image))
            #expect(still.devices.contains(device) && still.devices.contains(source))
            #expect(still.mountPoints.isEmpty)
            #expect(!isMounted(source: source))
        }
    }

    // T-087a7de6 F-211
    @Test(.tags(.diskImage), .diskImages) func refusesWithEBUSYWhileAFileIsOpenOnTheVolumeAndForcesWhenAsked()
        async throws
    {
        try await DiskImage.withVolume(.apfs) { folder in
            let image = try image(mountedAt: folder.path)
            let file = folder.appendingPathComponent("open.txt")
            try Data("held".utf8).write(to: file)
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            do {
                try await VolumeEjector.eject(path: folder.path, wholeDisk: true)
                Issue.record("the eject should have been refused")
            } catch let error as EjectError {
                #expect(error.code == "EBUSY")
                #expect(error.path == folder.path)
            }
            #expect(try attached(image)?.mountPoints.contains(folder.path) == true)
            try await VolumeEjector.eject(path: folder.path, force: true, wholeDisk: true)
            #expect(try attached(image) == nil)
        }
    }

    // T-49c761e5 F-211 F-215
    @Test func failsWithENOENTWhereNothingIsMounted() async throws {
        let folder = try TemporaryDirectory(prefix: "native-eject")
        defer { folder.remove() }
        do {
            try await VolumeEjector.eject(path: folder.path)
            Issue.record("nothing is mounted there")
        } catch let error as EjectError {
            #expect(error.code == "ENOENT")
            #expect(error.path == folder.path)
        }
        let response = await EjectOutcome.ejectVolume(
            EjectRequest(path: folder.path, wholeDisk: false, force: false))
        #expect(response.status == .ejected)
    }
}
