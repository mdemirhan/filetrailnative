// scripts/build-app.sh refusing an Intel Mac, and saying why vtool failed, with stand-ins for the tools it runs
import FTTestSupport
import Foundation
import Testing

@Suite struct BuildAppScriptTests {
    private static let script = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("scripts/build-app.sh").path

    /// Runs the script with the stand-ins in `bin` ahead of the system's tools: its output, and whether it succeeded.
    private static func build(_ arguments: [String], bin: String) throws -> (output: String, succeeded: Bool) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: script)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = bin + ":" + (environment["PATH"] ?? "")
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (output, process.terminationStatus == 0)
    }

    private static func stub(_ name: String, in bin: String, _ body: String) throws {
        let path = bin + "/" + name
        try ("#!/bin/bash\n" + body + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    }

    @Test func refusesAnIntelMacAtOnce() throws {
        try withTemporaryDirectory(prefix: "filetrail-build-app") { folder throws in
            try Self.stub("uname", in: folder.path, "echo x86_64")
            try Self.stub("swift", in: folder.path, "echo 'swift was run' >&2; exit 1")
            let outcome = try Self.build(["debug", "--out", folder.appending("out").path], bin: folder.path)
            #expect(!outcome.succeeded)
            #expect(outcome.output.contains("File Trail builds on Apple silicon only; this Mac is x86_64."))
            #expect(!outcome.output.contains("swift was run"))
        }
    }

    // vtool's own message is shown when it can't stamp the binary, not only written to the log.
    @Test func saysWhyVtoolFailed() throws {
        try withTemporaryDirectory(prefix: "filetrail-build-app") { folder throws in
            let products = folder.appending("products").path
            try FileManager.default.createDirectory(atPath: products, withIntermediateDirectories: true)
            try "binary".write(toFile: products + "/FileTrail", atomically: true, encoding: .utf8)
            try Self.stub(
                "swift", in: folder.path,
                """
                for argument in "$@"; do [ "$argument" = --show-bin-path ] && { echo "\(products)"; exit 0; }; done
                exit 0
                """)
            try Self.stub("vtool", in: folder.path, "echo 'vtool: not a Mach-O file' >&2; exit 1")
            let outcome = try Self.build(["debug", "--out", folder.appending("out").path], bin: folder.path)
            #expect(!outcome.succeeded)
            #expect(outcome.output.contains("vtool: not a Mach-O file"))
            #expect(outcome.output.contains("vtool couldn't stamp the SDK on the app's binary"))
        }
    }
}
