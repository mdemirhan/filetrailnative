import FTTestSupport
import Foundation
import Testing

@testable import FTFileSystem

@Suite struct FdBinaryTests {
    @Test func resolvesTheMatchingBundledFdBinaryFromTheHelpersFolder() throws {
        try withTemporaryDirectory { root in
            let helpers = root.appending("File Trail.app/Contents/Helpers")
            try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
            let binary = helpers.appendingPathComponent("fd")
            try Data().write(to: binary)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)

            let path = try FdBinary.resolveBundledPath(locations: .init(helpers: helpers, sourceTree: nil))
            #expect(path == binary.path)
        }
    }

    @Test func fallsBackToTheSourceTree() throws {
        let found = { (path: String) in path.hasSuffix("/src/darwin-arm64/fd") }
        let locations = FdBinary.Locations(
            helpers: URL(fileURLWithPath: "/app/Helpers"), sourceTree: URL(fileURLWithPath: "/src"))
        #expect(try FdBinary.resolveBundledPath(locations: locations, fileExists: found) == "/src/darwin-arm64/fd")
    }

    @Test func refusesMissingBinaries() {
        let locations = FdBinary.Locations(helpers: nil, sourceTree: URL(fileURLWithPath: "/nowhere"))
        #expect(throws: FdBinary.NotFound(description: "Bundled fd binary not found for arm64.")) {
            try FdBinary.resolveBundledPath(locations: locations)
        }
    }

    @Test func theManifestInTheRepositoryIsTheOneCompiledIn() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/fd/manifest.json")
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let arm64 = try #require(((json["macos"] as? [String: Any])?["arm64"]) as? [String: Any])
        #expect(json["tool"] as? String == FdBinary.manifest.tool)
        #expect(json["version"] as? String == FdBinary.manifest.version)
        #expect((arm64["relativeBinaryPath"] as? String)?.hasSuffix(FdBinary.manifest.relativeBinaryPath) == true)
    }

    @Test(.enabled(if: FdBinary.currentArchitecture == "arm64"))
    func executesTheVendoredFdBinary() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try FdBinary.resolveBundledPath())
        process.arguments = ["--version"]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        #expect(text.contains("fd 10.5.0"))
    }
}
