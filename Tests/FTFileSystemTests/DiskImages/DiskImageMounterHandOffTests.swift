import Foundation
import Testing

@testable import FTFileSystem

@Suite struct DiskImageMounterHandOffTests {
    // Launches DiskImageMounter, which puts a window on screen: only with FILETRAIL_GUI_TESTS=1.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["FILETRAIL_GUI_TESTS"] == "1"))
    func handsAnImageToTheRealDiskImageMounter() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = directory.appendingPathComponent("blank.dmg")
        try Data().write(to: image)
        try await HdiutilProcess.openWithDiskImageMounter(image.path)
    }
}
