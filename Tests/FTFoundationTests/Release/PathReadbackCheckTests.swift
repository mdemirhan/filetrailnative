// scripts/lib/path-readbacks.sh, the check scripts/ci.sh makes for a path read back from a file URL, over sources and
// an allow-list made for each test
import FTTestSupport
import Foundation
import Testing

@Suite struct PathReadbackCheckTests {
    private static let library = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("scripts/lib/path-readbacks.sh").path

    /// Runs the check over `sources` (each file's lines, by its name under Sources/) with `allowed` as the lines of
    /// its allow-list: what it printed, and whether it passed.
    private static func check(_ sources: [String: [String]], allowed: [String]) throws -> (
        output: String, passed: Bool
    ) {
        try withTemporaryDirectory(prefix: "filetrail-readbacks") { root in
            for (name, lines) in sources {
                let file = root.appending("Sources/" + name)
                try FileManager.default.createDirectory(
                    at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
            }
            try (allowed.joined(separator: "\n") + "\n").write(
                to: root.appending("allowed.txt"), atomically: true, encoding: .utf8)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            // As scripts/ci.sh runs it: a command that fails anywhere in a pipeline fails the pipeline.
            process.arguments = ["-c", "set -uo pipefail; source \"$0\"; path_readbacks Sources allowed.txt", library]
            process.currentDirectoryURL = root.url
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            return (output, process.terminationStatus == 0)
        }
    }

    @Test func aNewReadbackFailsWithItsPlaceAndTheRule() throws {
        let result = try Self.check(
            ["FTAppKit/Pane.swift": ["func f(x: String) {", "    let p = URL(fileURLWithPath: x).path", "}"]],
            allowed: ["# none yet"])
        #expect(!result.passed)
        #expect(
            result.output.contains(
                "Sources/FTAppKit/Pane.swift:2: a path read back from a URL: let p = URL(fileURLWithPath: x).path"))
        #expect(result.output.contains("never read back from a URL"))
        #expect(result.output.contains("docs/decisions/must-stay.md"))
        #expect(result.output.contains("add the line to allowed.txt with its reason"))
    }

    @Test func theWaysAReadbackIsWrittenAreFound() throws {
        let readbacks = [
            "let a = URL(filePath: x).path(percentEncoded: false)",
            "let b = volume?.standardizedFileURL.path",
            "let c = URL(fileURLWithPath: x).resolvingSymlinksInPath().path",
            "let d = base.appendingPathComponent(\"a\").path",
            "let e = FileManager.default.homeDirectoryForCurrentUser.path",
            "let f = fileURL.path",
            "let g = urls.first?.path",
            "let h = panel.urls.map(\\.path)",
            "let i = AppStatePaths.appState(in: folder).path",
            "let j = selectedContentFolder?.path",
            "let k = target.comparablePath == other.comparablePath",
            "let l = pane.folder.path",
        ]
        let result = try Self.check(["FTAppKit/Readbacks.swift": readbacks], allowed: [])
        #expect(!result.passed)
        for (index, line) in readbacks.enumerated() {
            #expect(
                result.output.contains("Sources/FTAppKit/Readbacks.swift:\(index + 1): a path read back from a URL: "),
                "\(line)")
        }
    }

    // A struct's own path, a URL that is only passed on, a comment, and `folder.path` outside FTAppKit.
    @Test func whatIsNotAReadbackPasses() throws {
        let result = try Self.check(
            [
                "FTAppKit/Rows.swift": [
                    "let a = entry.path", "pane.go(to: URL(fileURLWithPath: row.path))",
                    "// never `folder.path`, nor URL(fileURLWithPath: x).path",
                    "    /// `url.path` gives an accent decomposed", "let name = url.lastPathComponent",
                ],
                "FTFoundation/Places.swift": ["let key = ExactKey(folder.path)"],
            ], allowed: [])
        #expect(result.passed, "\(result.output)")
        #expect(result.output.isEmpty)
    }

    // A line is known by its file and its text: it may move, and a second one in the file is a new one.
    @Test func aListedLineMayMoveAndCoversOnlyItself() throws {
        let allowed = ["# The home folder.", "Sources/FTAppKit/Home.swift: let home = homeFolderURL.path"]
        let moved = try Self.check(
            [
                "FTAppKit/Home.swift": [
                    "import Foundation", "", "func f() {", "        let home = homeFolderURL.path", "}",
                ]
            ],
            allowed: allowed)
        #expect(moved.passed, "\(moved.output)")
        let twice = try Self.check(
            [
                "FTAppKit/Home.swift": [
                    "let home = homeFolderURL.path", "func g() {", "    let home = homeFolderURL.path", "}",
                ]
            ],
            allowed: allowed)
        #expect(!twice.passed)
        #expect(twice.output.contains("Sources/FTAppKit/Home.swift:3: a path read back from a URL"))
        #expect(!twice.output.contains("Home.swift:1:"))
        let elsewhere = try Self.check(
            ["FTAppKit/Other.swift": ["let home = homeFolderURL.path"]], allowed: allowed)
        #expect(!elsewhere.passed)
        #expect(elsewhere.output.contains("Sources/FTAppKit/Other.swift:1: a path read back from a URL"))
    }

    @Test func aListedLineThatIsGoneFails() throws {
        let result = try Self.check(
            ["FTAppKit/Home.swift": ["let home = NSHomeDirectory()"]],
            allowed: ["Sources/FTAppKit/Home.swift: let home = homeFolderURL.path"])
        #expect(!result.passed)
        #expect(
            result.output.contains(
                "allowed.txt: Sources/FTAppKit/Home.swift no longer has this line: let home = homeFolderURL.path"))
        #expect(result.output.contains("Take a line that is gone out of allowed.txt"))
    }
}
