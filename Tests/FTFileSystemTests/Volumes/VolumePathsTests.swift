import Testing

@testable import FTFileSystem

@Suite struct VolumePathsTests {
    // T-9bf1446e B-TREE-027
    @Test func putsPathsUnderVolumesOnThatVolume() {
        #expect(VolumePaths.volumeRootPath("/Volumes/Backup") == "/Volumes/Backup")
        #expect(VolumePaths.volumeRootPath("/Volumes/Backup/") == "/Volumes/Backup")
        #expect(VolumePaths.volumeRootPath("/Volumes/Backup/Photos/2024") == "/Volumes/Backup")
        #expect(VolumePaths.volumeRootPath("/Volumes/My Disk/a.txt") == "/Volumes/My Disk")
    }

    // T-14c47ad4 B-TREE-027
    @Test func putsEverythingElseOnTheStartupVolume() {
        #expect(VolumePaths.volumeRootPath("/") == "/")
        #expect(VolumePaths.volumeRootPath("/Users/demo/a.txt") == "/")
        #expect(VolumePaths.volumeRootPath("/Volumes") == "/")
        #expect(VolumePaths.volumeRootPath("/Volumes/") == "/")
        // Only the top-level /Volumes folder holds mount points.
        #expect(VolumePaths.volumeRootPath("/Users/demo/Volumes/Backup") == "/")
        #expect(VolumePaths.volumeRootPath("/VolumesX/Backup") == "/")
    }

    // T-8a4a06aa B-TREE-027
    @Test func comparesTheVolumesOfTwoPaths() {
        #expect(VolumePaths.isOnSameVolume("/Users/demo/a.txt", "/Applications"))
        #expect(VolumePaths.isOnSameVolume("/Volumes/Backup/a", "/Volumes/Backup/b/c"))
        #expect(!VolumePaths.isOnSameVolume("/Users/demo/a.txt", "/Volumes/Backup"))
        #expect(!VolumePaths.isOnSameVolume("/Volumes/Backup/a", "/Volumes/Other/a"))
    }

    @Test func rootPaths() {
        #expect(VolumePaths.isVolumeRootPath("/"))
        #expect(VolumePaths.isVolumeRootPath("/Volumes/Backup"))
        #expect(!VolumePaths.isVolumeRootPath("/Volumes/Backup/a"))
    }
}
