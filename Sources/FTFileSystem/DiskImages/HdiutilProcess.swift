// Port of runHdiutilProcess and openWithDiskImageMounterApp in apps/desktop/src/main/diskImages.ts
import AppKit
import Foundation

public enum HdiutilProcess {
    static let hdiutilPath = "/usr/bin/hdiutil"
    static let diskImageMounterPath = "/System/Library/CoreServices/DiskImageMounter.app"

    private final class Collected: @unchecked Sendable {
        var data = Data()
    }

    /// Runs hdiutil with nothing to read from.
    @Sendable public static func run(_ arguments: [String]) async -> HdiutilResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: hdiutilPath)
                process.arguments = arguments
                process.standardInput = FileHandle.nullDevice
                let out = Pipe()
                let err = Pipe()
                process.standardOutput = out
                process.standardError = err
                do {
                    try process.run()
                } catch {
                    continuation.resume(
                        returning: HdiutilResult(ok: false, stdout: "", stderr: String(describing: error)))
                    return
                }
                // Both pipes are read at once, so a full one can't stall the tool.
                let errors = Collected()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async {
                    errors.data = err.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                let output = out.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                process.waitUntilExit()
                continuation.resume(
                    returning: HdiutilResult(
                        ok: process.terminationStatus == 0, stdout: String(decoding: output, as: UTF8.self),
                        stderr: String(decoding: errors.data, as: UTF8.self)))
            }
        }
    }

    /// Opens the image with DiskImageMounter.app, which asks for a password or a licence in its own windows.
    @Sendable public static func openWithDiskImageMounter(_ imagePath: String) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        _ = try await NSWorkspace.shared.open(
            [URL(fileURLWithPath: imagePath)], withApplicationAt: URL(fileURLWithPath: diskImageMounterPath),
            configuration: configuration)
    }
}
