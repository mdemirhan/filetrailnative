import AppKit
import Foundation
import Testing

@testable import FTFileSystem

@Suite struct DiskImageMounterHandOffTests {
    private static let mounterBundleID = "com.apple.DiskImageMounter"

    // Launches DiskImageMounter, which puts a window on screen: only with FILETRAIL_GUI_TESTS=1, and the
    // test quits the one it started so none is left running (it stays if one was already running).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["FILETRAIL_GUI_TESTS"] == "1"))
    func handsAnImageToTheRealDiskImageMounter() async throws {
        let wasRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: Self.mounterBundleID).isEmpty
        defer {
            if !wasRunning {
                for app in NSRunningApplication.runningApplications(withBundleIdentifier: Self.mounterBundleID) {
                    app.forceTerminate()
                }
            }
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = directory.appendingPathComponent("blank.dmg")
        try Data().write(to: image)
        try await HdiutilProcess.openWithDiskImageMounter(image.path)
        try await Task.sleep(for: .milliseconds(500))
    }
}
