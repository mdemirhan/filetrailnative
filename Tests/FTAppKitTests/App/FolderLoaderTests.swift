// Ports the nativeIsPackage case of packages/native-fs/src/native-fs.test.ts (FolderLoader reads it from the content type)
import Foundation
import Testing

@testable import FTAppKit

@Suite struct FolderLoaderTests {
    // T-3056a773
    @Test func tellsAPackageFromAPlainFolderAndFailsForAMissingFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("folder-loader-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Tool.app"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("plain"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let items = try FolderLoader.load(root).items
        let tool = try #require(items.first { $0.url.lastPathComponent == "Tool.app" })
        let plain = try #require(items.first { $0.url.lastPathComponent == "plain" })
        #expect(tool.isPackage)
        #expect(!tool.opensAsFolder)
        #expect(!plain.isPackage)
        #expect(plain.opensAsFolder)
        #expect(throws: (any Error).self) { try FolderLoader.load(root.appendingPathComponent("missing.app")) }
    }
}
