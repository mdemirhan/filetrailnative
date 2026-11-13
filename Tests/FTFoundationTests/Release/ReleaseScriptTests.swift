import FTTestSupport
import Foundation
import Testing

@Suite struct ReleaseScriptTests {
    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    private static let library = repositoryRoot.appendingPathComponent("scripts/lib/release-lib.sh").path
    private static let limits = repositoryRoot.appendingPathComponent("scripts/lib/frame-timing-limits.sh").path
    private static let testRuns = repositoryRoot.appendingPathComponent("scripts/lib/test-runs.sh").path
    private static let script = repositoryRoot.appendingPathComponent("scripts/release.sh").path

    private struct Outcome {
        let output: String
        let succeeded: Bool
    }

    private static func run(
        _ tool: String, _ arguments: [String], in folder: String? = nil, path: String? = nil, input: String? = nil,
        devCache: String? = nil, extra: [String: String] = [:]
    ) throws -> Outcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        if let folder { process.currentDirectoryURL = URL(fileURLWithPath: folder) }
        // Git's own variables, set when this runs inside a git hook, would point it at the real repository.
        // The release's switches too: a run under a release has them set, and what the script itself sets is under test.
        let releaseSwitches: Set = [
            "FILETRAIL_LARGE_FILE_TESTS", "FILETRAIL_RELEASE_TESTS", "UNDO_FUZZ_CASES", "UNDO_FUZZ_SEED",
            "BATCH_RENAME_FUZZ_CASES", "BATCH_RENAME_FUZZ_SEED", "FILETRAIL_NO_DISK_IMAGES", "FILETRAIL_GUI_TESTS",
            "FILETRAIL_FRAME_TIMINGS_OUT", "FILETRAIL_MACHINE_MODEL",
        ]
        var environment = ProcessInfo.processInfo.environment.filter {
            !$0.key.hasPrefix("GIT_") && !releaseSwitches.contains($0.key)
        }
        if let path { environment["PATH"] = path + ":" + (environment["PATH"] ?? "") }
        if let devCache { environment["FILETRAIL_DEV_CACHE"] = devCache }
        environment.merge(extra) { $1 }
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

    @Test func leavesALineToFillInWhenThereIsNothingToList() throws {
        #expect(try Self.call("draft_release_notes", input: "\n").output.contains("### What's new\n- \n"))
    }

    @Test func hasNothingToSayWhenEveryReleaseTagIsOnGitHubAndReleased() throws {
        #expect(
            try Self.unfinished(
                local: ["v0.1.0", "v0.2.0"], remote: ["v0.1.0", "v0.2.0"], latest: "v0.2.0", state: "published"
            ).isEmpty)
        #expect(try Self.unfinished(local: [], remote: []).isEmpty)
    }

    @Test func stopsAtATagLeftOnThisMacByAReleaseThatStoppedBeforePushingIt() throws {
        let problems = try Self.unfinished(
            local: ["v0.1.0", "v0.2.0"], remote: ["v0.1.0"], latest: "v0.1.0", state: "published")
        #expect(problems.count == 1)
        #expect(problems.first?.hasPrefix("v0.2.0 is only on this Mac") == true)
        #expect(problems.first?.contains("git tag -d v0.2.0") == true)
    }

    @Test func stopsAtAReleaseStillADraftOrATagOnGitHubWithNoRelease() throws {
        let draft = try Self.unfinished(local: ["v0.2.0"], remote: ["v0.2.0"], latest: "v0.2.0", state: "draft")
        #expect(draft.count == 1)
        #expect(draft.first?.hasPrefix("v0.2.0's release is still a draft") == true)
        let missing = try Self.unfinished(local: ["v0.2.0"], remote: ["v0.2.0"], latest: "v0.2.0", state: "missing")
        #expect(missing.count == 1)
        #expect(missing.first?.hasPrefix("v0.2.0 is on GitHub without a release") == true)
    }

    @Test func bumpsTheLastRelease() throws {
        #expect(try Self.nextVersion("0.1.3", "patch") == "0.1.4")
        #expect(try Self.nextVersion("0.1.3", "minor") == "0.2.0")
        #expect(try Self.nextVersion("0.1.3", "major") == "1.0.0")
        #expect(try Self.nextVersion("", "minor") == "0.1.0")
    }

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

    // MARK: - Frame times

    /// A release's frame times: the List and the Icons view at their default size.
    private static func timings(list: Double, icons: Double, late: Double = 0.1) -> String {
        """
        {"timings": [
          {"view": "list", "size": "default", "medianMs": \(list), "lateShare": \(late), "slowestMs": 18.2},
          {"view": "icons", "size": "default", "medianMs": \(icons), "lateShare": \(late), "slowestMs": 20.4}
        ]}
        """
    }

    /// `frame_timings_report` of `now` against the history `history` (nil: none) for `machine`.
    private static func report(_ now: String, history: String?, machine: String = "Mac16,5") throws -> Outcome {
        try withTemporaryDirectory(prefix: "filetrail-frames") { folder throws in
            let timings = folder.appending("now.json").path
            try now.write(toFile: timings, atomically: true, encoding: .utf8)
            let file = folder.appending("history.json").path
            if let history { try history.write(toFile: file, atomically: true, encoding: .utf8) }
            return try run(
                "/bin/bash",
                [
                    "-c",
                    "source \"$0\"; frame_timings_report \"$1\" \"$(frame_timings_previous \"$2\" \"$3\")\" \"$3\"",
                    library, timings, file, machine,
                ])
        }
    }

    private static func history(_ records: [(version: String, machine: String, timings: String)]) -> String {
        let releases = records.map { record in
            let timings = record.timings.trimmingCharacters(in: .whitespacesAndNewlines).dropFirst().dropLast()
            return """
                {"version": "\(record.version)", "date": "2026-11-01", "machine": "\(record.machine)", \
                "macOS": "27.0.1", \(timings)}
                """
        }
        return "{\"releases\": [\(releases.joined(separator: ","))]}"
    }

    // With no earlier release from this Mac model, only the ceilings apply; the table has the numbers alone.
    @Test func framesWithNoEarlierRecordMeetOnlyTheCeilings() throws {
        let fine = try Self.report(Self.timings(list: 6.6, icons: 5.6), history: nil)
        #expect(fine.succeeded)
        #expect(fine.output.contains("No earlier release was measured on this Mac model (Mac16,5)"))
        #expect(fine.output.contains("list     default   6.60 ms"))
        // A record from another Mac model is no comparison.
        let elsewhere = try Self.report(
            Self.timings(list: 6.6, icons: 5.6),
            history: Self.history([("0.16.0", "Mac14,2", Self.timings(list: 2, icons: 2))]))
        #expect(elsewhere.succeeded)
        #expect(elsewhere.output.contains("only the ceilings apply"))
        let ceiling = try Self.report(Self.timings(list: 40, icons: 5.6), history: nil)
        #expect(!ceiling.succeeded)
        #expect(ceiling.output.contains("list at the default size: the median frame took 40 ms"))
        let late = try Self.report(Self.timings(list: 6.6, icons: 5.6, late: 0.9), history: nil)
        #expect(!late.succeeded)
        #expect(late.output.contains("of frames were late"))
    }

    // Against the last release made on this Mac model: the table says each number before and the change, and a clear
    // slowdown of a median or of the late frames fails; the slowest frame fails nothing.
    @Test func framesAreComparedWithTheLastReleaseOnTheSameMacModel() throws {
        let history = Self.history([
            ("0.15.0", "Mac16,5", Self.timings(list: 1, icons: 1)),
            ("0.16.0", "Mac16,5", Self.timings(list: 6.0, icons: 5.0)),
            ("0.16.1", "Mac14,2", Self.timings(list: 9, icons: 9)),
        ])
        let fine = try Self.report(Self.timings(list: 6.6, icons: 5.0), history: history)
        #expect(fine.succeeded)
        #expect(fine.output.contains("against 0.16.0 (2026-11-01) on the same Mac model (Mac16,5)"))
        #expect(fine.output.contains("list     default   6.60 ms  6.00 ms     +10%"))
        let slower = try Self.report(Self.timings(list: 12, icons: 5.0), history: history)
        #expect(!slower.succeeded)
        #expect(slower.output.contains("list at the default size: the median frame took 12 ms, 6 ms before"))
        #expect(!slower.output.contains("icons at the default size"))
        let late = try Self.report(Self.timings(list: 6.0, icons: 5.0, late: 0.5), history: history)
        #expect(!late.succeeded)
        #expect(late.output.contains("50 % of frames were late, 10 % before"))
    }

    // scripts/ci.sh --scope and the release's tests of real windows: a run that matched no test fails.
    @Test func aTestRunThatRanNothingIsTold() throws {
        try withTemporaryDirectory(prefix: "filetrail-runs") { folder throws in
            let log = folder.appending("log").path
            func ran(_ text: String) throws -> Bool {
                try text.write(toFile: log, atomically: true, encoding: .utf8)
                return try Self.call("ran_some_tests", [log]).succeeded
            }
            #expect(try ran("✔ Test run with 12 tests in 3 suites passed after 1.0 seconds.\n"))
            #expect(try ran("warning: No matching test cases were run\n") == false)
            #expect(try ran("✔ Test run with 0 tests in 0 suites passed after 0.0 seconds.\n") == false)
        }
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
        /// The checkout's own fixture cache, with every tree marked built, so what is built on this Mac doesn't count.
        var devCache: URL { root.appendingPathComponent("dev-cache") }

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
            try FileManager.default.copyItem(
                atPath: ReleaseScriptTests.limits, toPath: scripts.appendingPathComponent("frame-timing-limits.sh").path
            )
            try FileManager.default.copyItem(
                atPath: ReleaseScriptTests.testRuns, toPath: scripts.appendingPathComponent("test-runs.sh").path)
            try "/build/\n".write(
                to: root.appendingPathComponent("work/.gitignore"), atomically: true, encoding: .utf8)
            for tree in ["names", "lighthouse", "large"] {
                let folder = devCache.appendingPathComponent("fixtures/\(tree)")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try "1".write(to: folder.appendingPathComponent(".fixture-version"), atomically: true, encoding: .utf8)
            }
            try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
            let gh = """
                #!/bin/bash
                echo "$*" >>"\(ghCalls.path)"
                if [ "$(cat "\(ghState.path)" 2>/dev/null)" = signed-out ]; then
                    echo "To get started with GitHub CLI, please run:  gh auth login" >&2
                    exit 4
                fi
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

        func release(_ arguments: String..., extra: [String: String] = [:]) throws -> Outcome {
            try ReleaseScriptTests.run(
                path + "/scripts/release.sh", arguments, in: path, path: bin, devCache: devCache.path,
                extra: ["FILETRAIL_MACHINE_MODEL": "Mac16,5"].merging(extra) { $1 })
        }

        /// A stand-in at `relative` (in the checkout) or in the bin folder, running `body`.
        func stub(_ name: String, inBin: Bool = false, _ body: String) throws {
            let file = inBin ? bin + "/" + name : path + "/" + name
            try ("#!/bin/bash\n" + body + "\n").write(toFile: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file)
        }

        /// Stand-ins for the checks that pass, a swift whose tests of real windows write `timings` as the frame times,
        /// and a release build that makes the app and its files for the version tagged.
        func passingChecks(timings: String) throws {
            try stub("scripts/ci.sh", "exit 0")
            let timingsFile = root.appendingPathComponent("timings.json").path
            try timings.write(toFile: timingsFile, atomically: true, encoding: .utf8)
            try stub(
                "swift", inBin: true,
                """
                echo "◇ Test run started."
                cp "\(timingsFile)" "$FILETRAIL_FRAME_TIMINGS_OUT"
                echo "✔ Test run with 3 tests in 2 suites passed after 1.0 seconds."
                """)
            try stub(
                "scripts/make-release-app.sh",
                """
                version="$(git tag --points-at HEAD | sed 's/^v//')"
                app="build/release/File Trail.app/Contents"
                mkdir -p "$app"
                plutil -create xml1 "$app/Info.plist"
                plutil -insert CFBundleShortVersionString -string "$version" "$app/Info.plist"
                plutil -insert FTVersion -string "$version" "$app/Info.plist"
                touch build/release/FileTrail-arm64.dmg build/release/FileTrail-arm64.zip
                """)
            try git("add", ".")
            try commit("stand-ins for the checks and the build")
            try git("push", "-q", "origin", "main")
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

    // Without the fixture trees their tests would be skipped: the release names the command that builds them, and
    // stops before anything is checked or tagged.
    @Test func aReleaseNeedsTheFixtureTrees() throws {
        try withCheckout { checkout throws in
            try FileManager.default.removeItem(at: checkout.devCache.appendingPathComponent("fixtures/large"))
            let tags = try checkout.git("tag", "--list")
            let remote = try checkout.git("ls-remote", "origin")

            let dryRun = try checkout.release("0.3.0", "--dry-run")
            #expect(dryRun.output.contains("Would stop: The test fixtures aren't built"))
            #expect(dryRun.output.contains("run bun tools/fixtures/generate.ts first"))
            let outcome = try checkout.release("0.3.0", "--yes")
            #expect(!outcome.succeeded)
            #expect(outcome.output.contains("The test fixtures aren't built"))
            try checkout.expectNothingDone(tagsBefore: tags, remoteBefore: remote)
        }
    }

    // The release's check is the full one (a clean build, the release app) and includes the tests that write large
    // files and those only a release runs, with the fuzz tests at more cases from the day's seed. A stand-in for
    // scripts/ci.sh records what it was given and fails, so the release stops there: nothing is tagged or pushed.
    @Test func theReleaseCheckIncludesTheLargeFileAndReleaseOnlyTests() throws {
        try withCheckout { checkout throws in
            let seen = checkout.root.appendingPathComponent("ci-saw")
            let stub = checkout.path + "/scripts/ci.sh"
            let body = """
                #!/bin/bash
                echo "large=${FILETRAIL_LARGE_FILE_TESTS:-} release=${FILETRAIL_RELEASE_TESTS:-}" \\
                    "undo=${UNDO_FUZZ_CASES:-}@${UNDO_FUZZ_SEED:-}" \\
                    "rename=${BATCH_RENAME_FUZZ_CASES:-}@${BATCH_RENAME_FUZZ_SEED:-} args=$*" >"\(seen.path)"
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
            let seed = try #require(
                try String(contentsOf: seen, encoding: .utf8).firstMatch(of: #/undo=1000@(\d{8}) /#)?.1)
            #expect(
                try String(contentsOf: seen, encoding: .utf8)
                    == "large=1 release=1 undo=1000@\(seed) rename=4000@\(seed) args=--full\n")
            try checkout.expectNothingDone(tagsBefore: tags, remoteBefore: remote)
        }
    }

    // After the checks, the release runs the tests that drive real windows; when they fail it stops there, with
    // nothing tagged or pushed. Stand-ins for scripts/ci.sh (passing) and swift (failing) record what they were given.
    @Test func theReleaseRunsTheTestsOfRealWindowsAfterTheChecks() throws {
        try withCheckout { checkout throws in
            let seen = checkout.root.appendingPathComponent("swift-saw")
            let ci = checkout.path + "/scripts/ci.sh"
            try "#!/bin/bash\nexit 0\n".write(toFile: ci, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ci)
            let swift = checkout.bin + "/swift"
            let body = """
                #!/bin/bash
                echo "gui=${FILETRAIL_GUI_TESTS:-} args=$*" >"\(seen.path)"
                exit 1
                """
            try body.write(toFile: swift, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: swift)
            try checkout.git("add", ".")
            try checkout.commit("stand-ins for the checks")
            try checkout.git("push", "-q", "origin", "main")
            let tags = try checkout.git("tag", "--list")
            let remote = try checkout.git("ls-remote", "origin")

            let outcome = try checkout.release("0.3.0", "--yes")
            #expect(!outcome.succeeded)
            #expect(outcome.output.contains("The tests that drive real windows failed."))
            #expect(try String(contentsOf: seen, encoding: .utf8) == "gui=1 args=test --filter GUITests\n")
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

    // gh signed out can't say whether the last release is out: the release names the problem with the others instead.
    @Test func saysWhatWouldStopARunWithGhSignedOut() throws {
        try withCheckout { checkout throws in
            try checkout.git("tag", "-a", "v0.2.0", "-m", "File Trail 0.2.0")
            try checkout.git("push", "-q", "origin", "v0.2.0")
            try checkout.commit("second")
            try checkout.git("push", "-q", "origin", "main")
            try checkout.setRelease(state: "signed-out")
            let tags = try checkout.git("tag", "--list")
            let remote = try checkout.git("ls-remote", "origin")

            let dryRun = try checkout.release("patch", "--dry-run")
            #expect(dryRun.output.contains("Would stop: gh isn't signed in to GitHub"))
            let outcome = try checkout.release("patch", "--yes")
            #expect(!outcome.succeeded)
            #expect(outcome.output.contains("gh isn't signed in to GitHub"))
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

    // The frame times are compared with the last release on this Mac model: one clearly slower stops the release before
    // anything is committed or tagged.
    @Test func aReleaseWhoseScrollingGotSlowerStops() throws {
        try withCheckout { checkout throws in
            let history = Self.history([("0.2.0", "Mac16,5", Self.timings(list: 6, icons: 5))])
            try FileManager.default.createDirectory(
                at: checkout.root.appendingPathComponent("work/docs"), withIntermediateDirectories: true)
            try history.write(
                to: checkout.root.appendingPathComponent("work/docs/frame-timings.json"), atomically: true,
                encoding: .utf8)
            try checkout.passingChecks(timings: Self.timings(list: 12, icons: 5))
            let head = try checkout.git("rev-parse", "HEAD")
            let remote = try checkout.git("ls-remote", "origin")

            let outcome = try checkout.release("0.3.0", "--yes")
            #expect(!outcome.succeeded)
            #expect(outcome.output.contains("against 0.2.0"))
            #expect(outcome.output.contains("list at the default size: the median frame took 12 ms, 6 ms before"))
            #expect(outcome.output.contains("Scrolling got slower than the frame-time limits allow"))
            #expect(try checkout.git("rev-parse", "HEAD") == head)
            try checkout.expectNothingDone(tagsBefore: "", remoteBefore: remote)
        }
    }

    // A release that stops after the frame times were committed and tagged takes both back.
    @Test func aReleaseThatStopsAfterRecordingTheFrameTimesTakesThemBack() throws {
        try withCheckout { checkout throws in
            try checkout.passingChecks(timings: Self.timings(list: 6, icons: 5))
            try checkout.stub("scripts/make-release-app.sh", "exit 1")
            try checkout.git("add", ".")
            try checkout.commit("a build that fails")
            try checkout.git("push", "-q", "origin", "main")
            let head = try checkout.git("rev-parse", "HEAD")
            let remote = try checkout.git("ls-remote", "origin")

            let outcome = try checkout.release("0.3.0", "--yes")
            #expect(!outcome.succeeded)
            #expect(outcome.output.contains("only the ceilings apply"))
            #expect(outcome.output.contains("v0.3.0 and its frame times were taken back"))
            #expect(try checkout.git("rev-parse", "HEAD") == head)
            #expect(try checkout.git("status", "--porcelain").isEmpty)
            try checkout.expectNothingDone(tagsBefore: "", remoteBefore: remote)
        }
    }

    // A release adds its frame times to the history in a commit of its own on the checked one, tags that commit, pushes
    // main and the tag together, and shows the frame times again once the draft is made.
    @Test func aReleaseKeepsItsFrameTimesInTheCommitItTags() throws {
        try withCheckout { checkout throws in
            try checkout.passingChecks(timings: Self.timings(list: 6, icons: 5))
            let checked = try checkout.git("rev-parse", "HEAD").trimmingCharacters(in: .newlines)

            let outcome = try checkout.release("0.3.0", "--yes")
            #expect(outcome.succeeded, "\(outcome.output)")
            let tagged = try checkout.git("rev-list", "-n", "1", "v0.3.0").trimmingCharacters(in: .newlines)
            #expect(try checkout.git("rev-parse", "HEAD").trimmingCharacters(in: .newlines) == tagged)
            #expect(try checkout.git("rev-parse", "\(tagged)^").trimmingCharacters(in: .newlines) == checked)
            #expect(try checkout.git("diff", "--name-only", checked, tagged) == "docs/frame-timings.json\n")
            #expect(try checkout.git("ls-remote", "origin", "refs/heads/main").hasPrefix(tagged))
            #expect(try checkout.git("ls-remote", "origin", "refs/tags/v0.3.0^{}").hasPrefix(tagged))
            let history = try checkout.git("show", "\(tagged):docs/frame-timings.json")
            #expect(history.contains("\"version\": \"0.3.0\""))
            #expect(history.contains("\"machine\": \"Mac16,5\""))
            let afterDraft = try #require(outcome.output.components(separatedBy: "Draft release v0.3.0 is ready").last)
            #expect(afterDraft.contains("list     default   6.00 ms"))
            #expect(afterDraft.contains("Rewrite the notes for people, then press Publish release."))
        }
    }

    // Tests of real windows that matched none would pass with nothing checked: the release stops.
    @Test func aReleaseWhoseTestsOfRealWindowsRanNoneStops() throws {
        try withCheckout { checkout throws in
            try checkout.passingChecks(timings: Self.timings(list: 6, icons: 5))
            try checkout.stub("swift", inBin: true, "echo 'warning: No matching test cases were run'")
            let remote = try checkout.git("ls-remote", "origin")
            let outcome = try checkout.release("0.3.0", "--yes")
            #expect(!outcome.succeeded)
            #expect(outcome.output.contains("ran no test: --filter GUITests matched none"))
            try checkout.expectNothingDone(tagsBefore: "", remoteBefore: remote)
        }
    }

    // The disk image tests are part of a release's check.
    @Test func aReleaseRefusesToSkipTheDiskImageTests() throws {
        try withCheckout { checkout throws in
            let outcome = try checkout.release("0.3.0", "--dry-run", extra: ["FILETRAIL_NO_DISK_IMAGES": "1"])
            #expect(outcome.output.contains("Would stop: FILETRAIL_NO_DISK_IMAGES is set"))
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
