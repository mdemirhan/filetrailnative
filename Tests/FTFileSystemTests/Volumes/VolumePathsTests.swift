import Testing

@testable import FTFileSystem

@Suite struct VolumePathsTests {
    @Test func putsPathsUnderVolumesOnThatVolume() {
        #expect(VolumePaths.volumeRootPath("/Volumes/Backup") == "/Volumes/Backup")
        #expect(VolumePaths.volumeRootPath("/Volumes/Backup/") == "/Volumes/Backup")
        #expect(VolumePaths.volumeRootPath("/Volumes/Backup/Photos/2024") == "/Volumes/Backup")
        #expect(VolumePaths.volumeRootPath("/Volumes/My Disk/a.txt") == "/Volumes/My Disk")
    }

    @Test func putsEverythingElseOnTheStartupVolume() {
        #expect(VolumePaths.volumeRootPath("/") == "/")
        #expect(VolumePaths.volumeRootPath("/Users/demo/a.txt") == "/")
        #expect(VolumePaths.volumeRootPath("/Volumes") == "/")
        #expect(VolumePaths.volumeRootPath("/Volumes/") == "/")
        // Only the top-level /Volumes folder holds mount points.
        #expect(VolumePaths.volumeRootPath("/Users/demo/Volumes/Backup") == "/")
        #expect(VolumePaths.volumeRootPath("/VolumesX/Backup") == "/")
    }

    @Test func rootPaths() {
        #expect(VolumePaths.isVolumeRootPath("/"))
        #expect(VolumePaths.isVolumeRootPath("/Volumes/Backup"))
        #expect(!VolumePaths.isVolumeRootPath("/Volumes/Backup/a"))
    }
}
