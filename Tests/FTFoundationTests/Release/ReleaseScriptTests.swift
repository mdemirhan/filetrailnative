// Port of apps/desktop/scripts/lib/releaseNotes.test.ts, releaseState.test.ts and the nextVersion cases of version.test.ts,
// against scripts/lib/release-lib.sh, and of what scripts/release.sh decides, by --dry-run in a temporary repository
import FTTestSupport
import Foundation
import Testing

@Suite struct ReleaseScriptTests {
    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    private static let library = repositoryRoot.appendingPathComponent("scripts/lib/release-lib.sh").path
    private static let script = repositoryRoot.appendingPathComponent("scripts/release.sh").path

    private struct Outcome {
        let output: String
        let succeeded: Bool
    }

    private static func run(
        _ tool: String, _ arguments: [String], in folder: String? = nil, path: String? = nil, input: String? = nil
    ) throws -> Outcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        if let folder { process.currentDirectoryURL = URL(fileURLWithPath: folder) }
        // Git's own variables, set when this runs inside a git hook, would point it at the real repository.
        // The large-file switch too: a run under a release has it set, and what the script itself sets is under test.
        var environment = ProcessInfo.processInfo.environment.filter {
            !$0.key.hasPrefix("GIT_") && $0.key != "FILETRAIL_LARGE_FILE_TESTS"
        }
        if let path { environment["PATH"] = path + ":" + (environment["PATH"] ?? "") }
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        let stdin = Pipe()
        process.standardInput = stdin
        try process.run()
        if let input { stdin.fileHandleForWriting.write(Data(input.utf8)) }
        stdin.fileHandleForWriting.closeFile()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Outcome(output: String(data: data, encoding: .utf8) ?? "", succeeded: process.terminationStatus == 0)
    }

    /// Calls a function of the library; its arguments are the shell's positional ones.
    private static func call(_ function: String, _ arguments: [String] = [], input: String? = nil) throws -> Outcome {
        try run(
            "/bin/bash", ["-c", "source \"$0\"; \(function) \"$@\"", library] + arguments, input: input)
    }

    private static func nextVersion(_ latest: String, _ request: String) throws -> String {
        try call("next_version", [latest, request]).output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func unfinished(
        local: [String], remote: [String], latest: String = "", state: String = ""
    ) throws -> [String] {
        let output = try call(
            "find_unfinished_releases",
            [local.joined(separator: "\n"), remote.joined(separator: "\n"), latest, state]
        ).output
        return output.split(separator: "\n").map(String.init)
    }

    // T-65616c71
    @Test func listsTheCommitsSinceTheLastReleaseUnderWhatsNew() throws {
        let subjects = """
            Spring into folders in the content pane under a held drag
            Merge branch 'claude/spring-loaded-folders'

            Gather dragged items into a stack under the pointer

            """
        #expect(
            try Self.call("draft_release_notes", input: subjects).output == """
                <!-- Draft: one line per commit since the last release. Rewrite it for people, then publish. -->
                ### What's new
                - Spring into folders in the content pane under a held drag
                - Gather dragged items into a stack under the pointer

                """)
    }

    // T-c5cdfd37
    @Test func leavesALineToFillInWhenThereIsNothingToList() throws {
        #expect(try Self.call("draft_release_notes", input: "\n").output.contains("### What's new\n- \n"))
    }

    // T-f885ffd5
    @Test func hasNothingToSayWhenEveryReleaseTagIsOnGitHubAndReleased() throws {
        #expect(
            try Self.unfinished(
                local: ["v0.1.0", "v0.2.0"], remote: ["v0.1.0", "v0.2.0"], latest: "v0.2.0", state: "published"
            ).isEmpty)
        #expect(try Self.unfinished(local: [], remote: []).isEmpty)
    }

    // T-2c904d8a
    @Test func stopsAtATagLeftOnThisMacByAReleaseThatStoppedBeforePushingIt() throws {
        let problems = try Self.unfinished(
            local: ["v0.1.0", "v0.2.0"], remote: ["v0.1.0"], latest: "v0.1.0", state: "published")
        #expect(problems.count == 1)
        #expect(problems.first?.hasPrefix("v0.2.0 is only on this Mac") == true)
        #expect(problems.first?.contains("git tag -d v0.2.0") == true)
    }

    // T-43af9fe1
    @Test func stopsAtAReleaseStillADraftOrATagOnGitHubWithNoRelease() throws {
        let draft = try Self.unfinished(local: ["v0.2.0"], remote: ["v0.2.0"], latest: "v0.2.0", state: "draft")
        #expect(draft.count == 1)
        #expect(draft.first?.hasPrefix("v0.2.0's release is still a draft") == true)
        let missing = try Self.unfinished(local: ["v0.2.0"], remote: ["v0.2.0"], latest: "v0.2.0", state: "missing")
        #expect(missing.count == 1)
        #expect(missing.first?.hasPrefix("v0.2.0 is on GitHub without a release") == true)
    }

    // T-077e3bf1
    @Test func bumpsTheLastRelease() throws {
        #expect(try Self.nextVersion("0.1.3", "patch") == "0.1.4")
        #expect(try Self.nextVersion("0.1.3", "minor") == "0.2.0")
        #expect(try Self.nextVersion("0.1.3", "major") == "1.0.0")
        #expect(try Self.nextVersion("", "minor") == "0.1.0")
    }

    // T-3cd0af0d
    @Test func takesAnExactVersionOnlyAfterTheLastRelease() throws {
        #expect(try Self.nextVersion("0.1.3", "0.2.0") == "0.2.0")
        let same = try Self.call("next_version", ["0.1.3", "0.1.3"])
        #expect(!same.succeeded)
        #expect(same.output.contains("not after the last release, 0.1.3"))
        let earlier = try Self.call("next_version", ["1.2.3", "1.1.9"])
        #expect(!earlier.succeeded)
        let tagLike = try Self.call("next_version", ["0.1.3", "v0.2.0"])
        #expect(!tagLike.succeeded)
        #expect(tagLike.output.contains("not major, minor, patch"))
    }

    /// A first release takes any exact version, and leading zeros don't turn a number into octal.
    @Test func anExactVersionIsReadAsDecimal() throws {
        #expect(try Self.nextVersion("", "0.1.0") == "0.1.0")
        #expect(try Self.nextVersion("0.8.9", "0.09.0") == "0.9.0")
    }

    @Test func releaseTagsAreOrderedByVersion() throws {
        let tags = "v0.1.0-beta\nv0.3.0-beta\nv0.1.0\nv0.1.10\nv0.1.9\n"
        #expect(try Self.call("latest_release", input: tags).output == "0.1.10\n")
        #expect(try Self.call("latest_release", input: "v0.3.0-beta\n").output.isEmpty)
    }

    // MARK: - scripts/release.sh --dry-run

    /// A repository with a local bare `origin`, holding a copy of the script, with a stand-in for `gh` on the path that
    /// answers from a file and records how it was called. Nothing here can reach GitHub.
    private struct Checkout {
        let root: URL
        var path: String { root.appendingPathComponent("work").path }
        var bin: String { root.appendingPathComponent("bin").path }
        var ghState: URL { root.appendingPathComponent("gh-state") }
        var ghCalls: URL { root.appendingPathComponent("gh-calls") }

        init(root: URL) throws {
            self.root = root
            let origin = root.appendingPathComponent("origin.git").path
            try Self.check(ReleaseScriptTests.run("/usr/bin/git", ["init", "-q", "--bare", "-b", "main", origin]))
            try Self.check(ReleaseScriptTests.run("/usr/bin/git", ["init", "-q", "-b", "main", path]))
            try git("remote", "add", "origin", origin)
            try git("config", "user.email", "test@example.com")
            try git("config", "user.name", "Test")
            let scripts = root.appendingPathComponent("work/scripts/lib")
            try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
            try FileManager.default.copyItem(
                atPath: ReleaseScriptTests.script, toPath: root.appendingPathComponent("work/scripts/release.sh").path)
            try FileManager.default.copyItem(
                atPath: ReleaseScriptTests.library, toPath: scripts.appendingPathComponent("release-lib.sh").path)
            try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
            let gh = """
                #!/bin/bash
                echo "$*" >>"\(ghCalls.path)"
                [ "$1" = auth ] && exit 0
                case "$(cat "\(ghState.path)" 2>/dev/null)" in
                    draft) echo true ;;
                    missing) echo "release not found" >&2; exit 1 ;;
                    *) echo false ;;
                esac
                """
            let ghPath = bin + "/gh"
            try gh.write(toFile: ghPath, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ghPath)
            try git("add", ".")
            try git("commit", "-q", "-m", "first")
            try git("push", "-q", "origin", "main")
        }

        private static func check(_ outcome: Outcome) throws {
            if !outcome.succeeded { throw CocoaError(.fileWriteUnknown) }
        }

        @discardableResult
        func git(_ arguments: String...) throws -> String {
            let outcome = try ReleaseScriptTests.run("/usr/bin/git", arguments, in: path)
            try Self.check(outcome)
            return outcome.output
        }

        func commit(_ message: String) throws {
            try git("commit", "-q", "--allow-empty", "-m", message)
        }

        func release(_ arguments: String...) throws -> Outcome {
            try ReleaseScriptTests.run(path + "/scripts/release.sh", arguments, in: path, path: bin)
        }

        func setRelease(state: String) throws {
            try state.write(to: ghState, atomically: true, encoding: .utf8)
        }

        /// A dry run leaves tags and GitHub alone, whatever it found.
        func expectNothingDone(tagsBefore: String, remoteBefore: String) throws {
            #expect(try git("tag", "--list") == tagsBefore)
            #expect(try git("ls-remote", "origin") == remoteBefore)
            let calls = (try? String(contentsOf: ghCalls, encoding: .utf8)) ?? ""
            #expect(!calls.contains("create"))
        }
    }

    private func withCheckout(_ body: (Checkout) throws -> Void) throws {
        try withTemporaryDirectory(prefix: "filetrail-release") { root throws in
            try body(Checkout(root: URL(fileURLWithPath: root.path)))
        }
    }

    @Test func aFirstReleaseIsAskedForByExactVersion() throws {
        try withCheckout { checkout throws in
            let tags = try checkout.git("tag", "--list")
            let remote = try checkout.git("ls-remote", "origin")
            let exact = try checkout.release("0.3.0", "--dry-run")
            #expect(exact.succeeded)
            #expect(exact.output.contains("File Trail 0.3.0, from "))
            #expect(exact.output.contains("1 commits."))
            #expect(!exact.output.contains("Would stop"))
            #expect(exact.output.contains("nothing was checked, tagged, built or pushed"))

            let bump = try checkout.release("minor", "--dry-run")
            #expect(!bump.succeeded)
            #expect(bump.output.contains("ask for the first one by exact version"))
            try checkout.expectNothingDone(tagsBefore: tags, remoteBefore: remote)
        }
    }

    // The original's release runs `bun run ci`, which includes the tests that write large files. A stand-in for
    // scripts/ci.sh records what it was given and fails, so the release stops there: nothing is tagged or pushed.
    @Test func theReleaseCheckIncludesTheLargeFileTests() throws {
        try withCheckout { checkout throws in
            let seen = checkout.root.appendingPathComponent("ci-saw")
            let stub = checkout.path + "/scripts/ci.sh"
            let body = """
                #!/bin/bash
                echo "large=${FILETRAIL_LARGE_FILE_TESTS:-} args=$*" >"\(seen.path)"
                exit 1
                """
            try body.write(toFile: stub, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub)
            try checkout.git("add", ".")
            try checkout.commit("a stand-in for the checks")
            try checkout.git("push", "-q", "origin", "main")
            let tags = try checkout.git("tag", "--list")
            let remote = try checkout.git("ls-remote", "origin")

            let outcome = try checkout.release("0.3.0", "--yes")
            #expect(!outcome.succeeded)
            #expect(try String(contentsOf: seen, encoding: .utf8) == "large=1 args=\n")
            try checkout.expectNothingDone(tagsBefore: tags, remoteBefore: remote)
        }
    }

    @Test func aReleaseAfterAPublishedOneCountsFromIt() throws {
        try withCheckout { checkout throws in
            try checkout.git("tag", "-a", "v0.1.3", "-m", "File Trail 0.1.3")
            try checkout.git("push", "-q", "origin", "v0.1.3")
            try checkout.commit("second")
            try checkout.commit("third")
            try checkout.git("push", "-q", "origin", "main")
            try checkout.setRelease(state: "published")
            let tags = try checkout.git("tag", "--list")
            let remote = try checkout.git("ls-remote", "origin")

            let outcome = try checkout.release("patch", "--dry-run")
            #expect(outcome.succeeded)
            #expect(outcome.output.contains("File Trail 0.1.4 (after 0.1.3), from "))
            #expect(outcome.output.contains("2 commits."))
            #expect(!outcome.output.contains("Would stop"))

            let earlier = try checkout.release("0.1.3", "--dry-run")
            #expect(!earlier.succeeded)
            #expect(earlier.output.contains("not after the last release"))
            try checkout.expectNothingDone(tagsBefore: tags, remoteBefore: remote)
        }
    }

    @Test func saysWhatWouldStopAnUnfinishedRelease() throws {
        try withCheckout { checkout throws in
            try checkout.git("tag", "-a", "v0.2.0", "-m", "File Trail 0.2.0")
            try checkout.git("push", "-q", "origin", "v0.2.0")
            let remote = try checkout.git("ls-remote", "origin")

            try checkout.setRelease(state: "draft")
            #expect(try checkout.release("patch", "--dry-run").output.contains("v0.2.0's release is still a draft"))
            try checkout.setRelease(state: "missing")
            #expect(try checkout.release("patch", "--dry-run").output.contains("v0.2.0 is on GitHub without a release"))

            try checkout.setRelease(state: "published")
            try checkout.git("tag", "-a", "v0.3.0", "-m", "left behind")
            let tags = try checkout.git("tag", "--list")
            #expect(try checkout.release("patch", "--dry-run").output.contains("v0.3.0 is only on this Mac"))
            // This commit carries both tags.
            #expect(
                try checkout.release("minor", "--dry-run").output.contains(
                    "This commit is already released as v0.2.0, v0.3.0."))
            try checkout.expectNothingDone(tagsBefore: tags, remoteBefore: remote)
        }
    }

    @Test func saysWhatWouldStopACheckoutThatIsNotCleanMainOnGitHub() throws {
        try withCheckout { checkout throws in
            let remote = try checkout.git("ls-remote", "origin")
            try "edit".write(
                to: checkout.root.appendingPathComponent("work/edit.txt"), atomically: true, encoding: .utf8)
            #expect(try checkout.release("0.1.0", "--dry-run").output.contains("There are uncommitted changes"))
            try FileManager.default.removeItem(at: checkout.root.appendingPathComponent("work/edit.txt"))

            try checkout.commit("not pushed")
            #expect(try checkout.release("0.1.0", "--dry-run").output.contains("This commit isn't main on GitHub"))

            try checkout.git("checkout", "-q", "-b", "elsewhere")
            #expect(try checkout.release("0.1.0", "--dry-run").output.contains("Releases are made from main"))
            try checkout.expectNothingDone(tagsBefore: "", remoteBefore: remote)
        }
    }

    @Test func refusesAnythingElseOnTheCommandLine() throws {
        try withCheckout { checkout throws in
            #expect(try checkout.release("--dry-run").output.contains("Usage: scripts/release.sh"))
            #expect(try !checkout.release("--dry-run").succeeded)
            #expect(
                try checkout.release("0.1.0", "--dry-run", "--publish").output.contains("Usage: scripts/release.sh"))
            #expect(try checkout.release("soon", "--dry-run").output.contains("not major, minor, patch"))
        }
    }
}
