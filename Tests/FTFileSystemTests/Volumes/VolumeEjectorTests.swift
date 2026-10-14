import Darwin
import FTTestSupport
import Foundation
import Testing

@testable import FTFileSystem

/// The `/dev/diskN` devices hdiutil has attached.
private func attachedDevices() throws -> Set<String> {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
    process.arguments = ["info", "-plist"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    let images = plist?["images"] as? [[String: Any]] ?? []
    var devices: Set<String> = []
    for image in images {
        for entity in image["system-entities"] as? [[String: Any]] ?? [] {
            if let entry = entity["dev-entry"] as? String { devices.insert(entry) }
        }
    }
    return devices
}

private func isMounted(_ path: String) -> Bool {
    VolumeListing.mounts().contains { $0.path == path }
}

/// The device node (`/dev/disk5s1`) mounted at `path`. After an eject a path alone says nothing: another
/// process attaching a clone of the same blank image can take the freed `/Volumes/<name>`, so tests ask
/// whether this device is still mounted.
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
    // T-cfcc0c26
    @Test(.tags(.diskImage), .diskImages) func unmountsTheVolumeAndEjectsItsDiskDetachingADiskImage() async throws {
        try await DiskImage.withVolume(.apfs) { folder in
            let device = try wholeDevice(of: folder.path)
            let source = try source(of: folder.path)
            #expect(isMounted(folder.path))
            #expect(try attachedDevices().contains(device))
            try await VolumeEjector.eject(path: folder.path, wholeDisk: true)
            #expect(!isMounted(source: source))
            #expect(try !attachedDevices().contains(device))
        }
    }

    // T-7e94f3e8
    @Test(.tags(.diskImage), .diskImages) func unmountsOnlyTheVolumeWithoutWholeDiskLeavingItsDiskAttached()
        async throws
    {
        try await DiskImage.withVolume(.apfs) { folder in
            let device = try wholeDevice(of: folder.path)
            let source = try source(of: folder.path)
            try await VolumeEjector.eject(path: folder.path)
            #expect(!isMounted(source: source))
            #expect(try attachedDevices().contains(device))
        }
    }

    // T-087a7de6
    @Test(.tags(.diskImage), .diskImages) func refusesWithEBUSYWhileAFileIsOpenOnTheVolumeAndForcesWhenAsked()
        async throws
    {
        try await DiskImage.withVolume(.apfs) { folder in
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
            let source = try source(of: folder.path)
            #expect(isMounted(source: source))
            try await VolumeEjector.eject(path: folder.path, force: true, wholeDisk: true)
            #expect(!isMounted(source: source))
        }
    }

    // T-49c761e5
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

    @Test(.tags(.diskImage), .diskImages) func aVolumeAlreadyEjectedCountsAsEjected() async throws {
        try await DiskImage.withVolume(.apfs) { folder in
            let source = try source(of: folder.path)
            let request = EjectRequest(path: folder.path, wholeDisk: true, force: false)
            #expect(await EjectOutcome.ejectVolume(request).status == .ejected)
            #expect(!isMounted(source: source))
            // The second press of the button finds nothing mounted.
            #expect(await EjectOutcome.ejectVolume(request).status == .ejected)
        }
    }
}
