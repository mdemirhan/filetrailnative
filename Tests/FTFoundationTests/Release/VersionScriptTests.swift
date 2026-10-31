// Port of apps/desktop/scripts/lib/version.test.ts, against scripts/version.sh in a temporary repository
import FTTestSupport
import Foundation
import Testing

@Suite struct VersionScriptTests {
    private static let script = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("scripts/version.sh").path

    /// Runs a tool in the folder; its output, and whether it succeeded.
    @discardableResult
    private static func run(_ tool: String, _ arguments: [String], in folder: String) throws -> (
        output: String, succeeded: Bool
    ) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: folder)
        // Git's own variables, set when this runs inside a git hook, would point it at the real repository.
        process.environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        return (text.trimmingCharacters(in: .whitespacesAndNewlines), process.terminationStatus == 0)
    }

    private struct Repository {
        let path: String

        func git(_ arguments: String...) throws {
            let result = try VersionScriptTests.run("/usr/bin/git", arguments, in: path)
            #expect(result.succeeded, "git \(arguments.joined(separator: " "))")
        }

        func commit(_ message: String) throws {
            try message.write(toFile: path + "/file.txt", atomically: true, encoding: .utf8)
            try git("add", "file.txt")
            try git(
                "-c", "user.name=Test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false", "commit",
                "-qm", message)
        }

        func version() throws -> String? {
            let result = try VersionScriptTests.run("/bin/bash", [VersionScriptTests.script], in: path)
            return result.succeeded ? result.output : nil
        }

        func bundleVersion() throws -> String? {
            let result = try VersionScriptTests.run("/bin/bash", [VersionScriptTests.script, "--bundle"], in: path)
            return result.succeeded ? result.output : nil
        }
    }

    private func withRepository(_ body: (Repository) throws -> Void) throws {
        try withTemporaryDirectory(prefix: "filetrail-version") { root in
            let repository = Repository(path: root.path)
            try repository.git("init", "-q")
            try repository.commit("first")
            try body(repository)
        }
    }

    // T-e6301997
    @Test func releaseTagsAreVXYZAndATagWithASuffixIsNotARelease() throws {
        try withRepository { repository in
            try repository.git("tag", "v0.3.0-beta")
            try repository.git("tag", "0.2.0")
            #expect(try repository.version() == "0.0.0+dev.1")
            try repository.git("tag", "v0.2.0")
            #expect(try repository.version() == "0.2.0")
        }
    }

    // T-bfefc1a5
    @Test func releasesAreOrderedByVersionNotByWhenTheyWereMade() throws {
        try withRepository { repository in
            for tag in ["v0.1.0-beta", "v0.3.0-beta", "v0.1.0", "v0.1.10", "v0.1.9"] {
                try repository.git("tag", tag)
            }
            #expect(try repository.version() == "0.1.10")
            try repository.commit("second")
            #expect(try repository.version() == "0.1.10+dev.1")
        }
    }

    // T-0d03d8ba
    @Test func aBuildOfATaggedCommitIsThatRelease() throws {
        try withRepository { repository in
            try repository.git("tag", "v0.2.0")
            #expect(try repository.version() == "0.2.0")
            #expect(try repository.bundleVersion() == "0.2.0")
        }
    }

    // T-1edb5f23
    @Test func anyOtherBuildIsTheLastReleaseAndHowManyCommitsPastIt() throws {
        try withRepository { repository in
            try repository.git("tag", "v0.1.0")
            for number in 1...3 { try repository.commit("after \(number)") }
            try repository.git("tag", "v0.3.0-beta")
            try repository.commit("after 4")
            #expect(try repository.version() == "0.1.0+dev.4")
            #expect(try repository.bundleVersion() == "0.1.0")
        }
    }

    // T-01401fc4
    @Test func followsTheTagsAsReleasesAreMade() throws {
        try withRepository { repository in
            #expect(try repository.version() == "0.0.0+dev.1")
            #expect(try repository.bundleVersion() == "0.0.0")

            try repository.git("tag", "v0.1.0")
            #expect(try repository.version() == "0.1.0")

            try repository.commit("second")
            try repository.git("tag", "v0.3.0-beta")
            try repository.commit("third")
            #expect(try repository.version() == "0.1.0+dev.2")
        }
    }

    /// A release on a branch this commit isn't part of says nothing about it.
    @Test func aReleaseThatIsNotInTheHistoryDoesNotCount() throws {
        try withRepository { repository in
            try repository.git("checkout", "-q", "-b", "elsewhere")
            try repository.commit("on a branch")
            try repository.git("tag", "v9.0.0")
            try repository.git("checkout", "-q", "-")
            #expect(try repository.version() == "0.0.0+dev.1")
        }
    }

    // T-813c0bad
    @Test func isUnknownOutsideARepository() throws {
        try withTemporaryDirectory(prefix: "filetrail-version") { root throws in
            let folder = Repository(path: root.path)
            #expect(try folder.version() == nil)
            #expect(try folder.bundleVersion() == nil)
        }
    }
}
