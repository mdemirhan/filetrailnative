import Testing

@testable import FTFoundation

@Suite struct VolumePathsTests {
    @Test func putsPathsUnderVolumesOnThatVolume() {
        #expect(VolumePaths.volumeRootPath("/Volumes/Backup") == "/Volumes/Backup")
        #expect(VolumePaths.volumeRootPath("/Volumes/Backup/") == "/Volumes/Backup")
        #expect(VolumePaths.volumeRootPath("/Volumes/Backup/Photos/2024") == "/Volumes/Backup")
        #expect(VolumePaths.volumeRootPath("/Volumes/My Disk/a.txt") == "/Volumes/My Disk")
        #expect(VolumePaths.volumeRootPath("/Volumes/Backup/Photos") == "/Volumes/Backup")
        #expect(VolumePaths.volumeRootPath("/Volumes/Backup/a/b") == "/Volumes/Backup")
    }

    @Test func putsEverythingElseOnTheStartupVolume() {
        #expect(VolumePaths.volumeRootPath("/") == "/")
        #expect(VolumePaths.volumeRootPath("/Users/demo/a.txt") == "/")
        #expect(VolumePaths.volumeRootPath("/Users/me") == "/")
        #expect(VolumePaths.volumeRootPath("/Volumes") == "/")
        #expect(VolumePaths.volumeRootPath("/Volumes/") == "/")
        // Only the top-level /Volumes folder holds mount points.
        #expect(VolumePaths.volumeRootPath("/Users/demo/Volumes/Backup") == "/")
        #expect(VolumePaths.volumeRootPath("/Users/x/Volumes/y") == "/")
        #expect(VolumePaths.volumeRootPath("/VolumesX/Backup") == "/")
        #expect(VolumePaths.volumeRootPath("/VolumesX/y") == "/")
    }

    @Test func rootPaths() {
        #expect(VolumePaths.isVolumeRootPath("/"))
        #expect(VolumePaths.isVolumeRootPath("/Volumes/Backup"))
        #expect(!VolumePaths.isVolumeRootPath("/Volumes/Backup/a"))
    }
}
