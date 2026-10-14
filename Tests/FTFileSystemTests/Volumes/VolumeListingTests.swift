import Darwin
import FTTestSupport
import Foundation
import Testing

@testable import FTFileSystem

private func mount(
    _ path: String, source: String = "/dev/disk5s1", fileSystem: String = "apfs", local: Bool = true,
    readOnly: Bool = false, dontBrowse: Bool = false
) -> MountRecord {
    var flags: UInt32 = 0
    if local { flags |= UInt32(MNT_LOCAL) }
    if readOnly { flags |= UInt32(MNT_RDONLY) }
    if dontBrowse { flags |= UInt32(MNT_DONTBROWSE) }
    return MountRecord(path: path, source: source, fileSystem: fileSystem, flags: flags)
}

@Suite struct VolumeListingTests {
    private let lookup: (String) -> PhysicalDisk? = { name in
        switch name {
        case "disk5s1", "disk5s2": PhysicalDisk(whole: "disk4", ejectable: true)
        case "disk1s1": PhysicalDisk(whole: "disk0", ejectable: false)
        default: nil
        }
    }

    // F-144 F-205 B-TREE-022
    @Test func listsOnlyBrowsableMountsDirectlyUnderVolumes() {
        let mounts = [
            mount("/", source: "/dev/disk1s1"),
            mount("/System/Volumes/Data", source: "/dev/disk1s1"),
            mount("/Volumes/Backup", source: "/dev/disk5s1", readOnly: true),
            mount("/Volumes/Backup 2", source: "/dev/disk5s2", fileSystem: "hfs"),
            mount("/Volumes/.hidden"),
            mount("/Volumes/Backup/nested"),
            mount("/Volumes/"),
            mount("/Volumes/com.apple.TimeMachine.localsnapshots", dontBrowse: true),
            mount("/Volumes/Shared", source: "//user@server/share", fileSystem: "smbfs", local: false),
            mount("/Volumes/Macintosh HD", source: "/dev/disk1s1"),
        ]
        let volumes = VolumeListing.volumes(from: mounts, physicalDisk: lookup)
        #expect(
            volumes
                == [
                    Volume(
                        path: "/Volumes/Backup", name: "Backup", isLocal: true, isReadOnly: true, fileSystem: "apfs",
                        canEject: true, disk: "disk4"),
                    Volume(
                        path: "/Volumes/Backup 2", name: "Backup 2", isLocal: true, isReadOnly: false,
                        fileSystem: "hfs", canEject: true, disk: "disk4"),
                    // A network share has no disk and can always be ejected.
                    Volume(
                        path: "/Volumes/Shared", name: "Shared", isLocal: false, isReadOnly: false,
                        fileSystem: "smbfs", canEject: true, disk: nil),
                    Volume(
                        path: "/Volumes/Macintosh HD", name: "Macintosh HD", isLocal: true, isReadOnly: false,
                        fileSystem: "apfs", canEject: false, disk: "disk0"),
                ])
    }

    // F-206 F-207 B-TREE-023
    @Test func aDeviceTheRegistryDoesNotKnowIsEjectedLikeAShare() {
        let volumes = VolumeListing.volumes(from: [mount("/Volumes/X", source: "/dev/disk99s1")], physicalDisk: lookup)
        #expect(volumes.first?.canEject == true)
        #expect(volumes.first?.disk == nil)
    }

    // F-205
    @Test func theMountTableHoldsTheRoot() {
        let mounts = VolumeListing.mounts()
        let root = mounts.first { $0.path == "/" }
        #expect(root != nil)
        #expect(root?.isLocal == true)
        #expect(VolumeListing.listMounts().contains(MountPoint(path: "/", isLocal: true)))
    }

    // A real image, mounted without a Finder window (-nobrowse): the registry finds its physical disk. Not
    // listed, since a -nobrowse mount is marked MNT_DONTBROWSE.
    // F-206 F-207 B-TREE-023
    @Test(.tags(.diskImage), .diskImages) func theRegistryFindsThePhysicalDiskOfAMountedImage() async throws {
        try await DiskImage.withVolume(.apfs) { folder in
            let record = try #require(VolumeListing.mounts().first { $0.path == folder.path })
            #expect(record.isDontBrowse)
            #expect(VolumeListing.volumes(from: [record], physicalDisk: PhysicalDisk.lookup(bsdName:)).isEmpty)
            let disk = try #require(VolumeListing.deviceDisk(of: record, PhysicalDisk.lookup(bsdName:)))
            #expect(disk.whole.hasPrefix("disk"))
            // A disk image is not inside the Mac.
            #expect(disk.ejectable)
            // An APFS volume is on a synthesized container disk (disk6); the physical disk is the store under
            // it (disk5).
            let own = try #require(record.source.range(of: #"disk[0-9]+"#, options: .regularExpression))
            #expect(disk.whole != String(record.source[own]))
        }
    }

    // F-144 F-208 B-TREE-024
    @Test func theLiveListIsReadableAndSortsNaturally() {
        let volumes = Volume.sorted(VolumeListing.listVolumes())
        for volume in volumes { #expect(volume.path == "/Volumes/\(volume.name)") }
    }
}
