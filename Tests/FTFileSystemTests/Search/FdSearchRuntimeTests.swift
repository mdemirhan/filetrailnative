import FTFoundation
import Foundation
import Testing

@testable import FTFileSystem

/// A stand-in for `fd` whose output the test writes.
final class MockSearchProcess: SearchProcess, @unchecked Sendable {
    private let lock = NSLock()
    private var terminated = 0
    private(set) var events: SearchProcessEvents?
    private(set) var spawnedWith: (file: String, args: [String], cwd: String)?

    var terminateCount: Int { lock.withLock { terminated } }

    func terminate() {
        lock.withLock { terminated += 1 }
    }

    /// The `spawn` to give a runtime: it hands out this process and keeps the events.
    var spawn: SearchSpawn {
        { [self] file, args, cwd, events in
            lock.withLock {
                self.events = events
                spawnedWith = (file, args, cwd)
            }
            return self
        }
    }

    func write(_ text: String) { events?.onStdout(Data(text.utf8)) }
    func writeError(_ text: String) { events?.onStderr(Data(text.utf8)) }
    func close(code: Int32?, signal: Int32? = nil) { events?.onClose(code, signal) }
}

/// A search whose stand-in fd writes what the test says. Regex by default: a Plain Text search also judges what fd
/// found by its own matching, which tests of something else shouldn't have to satisfy.
private func demo(_ query: String = "app", mode: SearchPatternModePreference = .regex, hidden: Bool = false)
    -> SearchRequest
{
    SearchRequest(
        rootPath: "/Users/demo/project", query: query, patternMode: mode, matchScope: .name, recursive: true,
        includeHidden: hidden, skipGitFolders: false, skipGitIgnored: false)
}

private func item(
    _ path: String, name: String, ext: String = "", kind: FTFileSystem.EntryKind = .file, hidden: Bool = false,
    parent: String,
    relative: String
) -> SearchResultItem {
    SearchResultItem(
        path: path, name: name, fileExtension: ext, kind: kind, isHidden: hidden, isSymlink: false, parentPath: parent,
        relativeParentPath: relative)
}

/// The paths a search asked about.
private final class LookedAt: @unchecked Sendable {
    private let lock = NSLock()
    private var asked: [String] = []
    var paths: [String] { lock.withLock { asked } }
    func add(_ path: String) { lock.withLock { asked.append(path) } }
}

/// Asks how a search is doing from another thread while the search looks at the disk, and keeps whether it was told.
private final class AskedWhileLooking: @unchecked Sendable {
    private let lock = NSLock()
    private weak var runtime: FdSearchRuntime?
    private var jobId = ""
    private var answers: [Bool] = []
    var answered: [Bool] { lock.withLock { answers } }

    func watch(_ runtime: FdSearchRuntime, _ jobId: String) {
        lock.withLock { (self.runtime, self.jobId) = (runtime, jobId) }
    }

    func ask() {
        let (runtime, jobId) = lock.withLock { (self.runtime, self.jobId) }
        let told = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            _ = try? runtime?.getUpdate(jobId: jobId, cursor: 0)
            told.signal()
        }
        let answered = told.wait(timeout: .now() + 10) == .success
        lock.withLock { answers.append(answered) }
    }
}

@Suite struct FdSearchRuntimeTests {
    private func make() -> (FdSearchRuntime, MockSearchProcess) {
        let process = MockSearchProcess()
        return (FdSearchRuntime(fdBinaryPath: "/tmp/fd", spawn: process.spawn), process)
    }

    /// A runtime that counts what it looks at; `flagged` are the paths with the flag that hides an item.
    private func make(flagged: Set<String>) -> (FdSearchRuntime, MockSearchProcess, LookedAt) {
        let process = MockSearchProcess()
        let looked = LookedAt()
        let runtime = FdSearchRuntime(
            fdBinaryPath: "/tmp/fd", spawn: process.spawn,
            hasHiddenFlag: { path in
                looked.add(path)
                return flagged.contains(path)
            })
        return (runtime, process, looked)
    }

    private func paths(_ runtime: FdSearchRuntime, _ jobId: String) throws -> [SearchResultItem] {
        try runtime.getUpdate(jobId: jobId, cursor: 0).items
    }

    @Test func dropsWhatHasTheFlagAndWhatIsInAFolderThatHasItWithHiddenFilesOff() throws {
        let root = "/Users/demo/project"
        let (runtime, process, looked) = make(flagged: [root + "/hidden", root + "/secret.txt"])
        let job = runtime.startSearch(demo()).jobId
        process.write(
            [
                root + "/kept.txt", root + "/secret.txt", root + "/hidden/", root + "/hidden/a/b.txt",
                root + "/hidden/a/c.txt", root + "/hidden/a/d.txt", root + "/src/kept.swift",
            ].map { $0 + "\0" }.joined())
        #expect(try paths(runtime, job).map(\.path) == [root + "/kept.txt", root + "/src/kept.swift"])
        // Each folder is looked at once, and what is in a hidden one isn't looked at itself.
        #expect(looked.paths.filter { $0.hasSuffix("/a/c.txt") || $0.hasSuffix("/a/d.txt") }.isEmpty)
        #expect(looked.paths.filter { $0 == root + "/hidden" }.count == 2)  // as a result, and as a folder
        #expect(!looked.paths.contains(root))
    }

    @Test func aSearchOfMacintoshHDDropsWhatIsInItsHiddenFolders() throws {
        var search = demo()
        search.rootPath = "/"
        let (runtime, process, _) = make(flagged: ["/usr"])
        let job = runtime.startSearch(search).jobId
        process.write("/usr/\0/usr/local/bin/tool\0/Users/demo/kept.txt\0/kept.txt\0")
        #expect(try paths(runtime, job).map(\.path) == ["/Users/demo/kept.txt", "/kept.txt"])
    }

    @Test func looksAtTheDiskWithoutHoldingUpTheQuestionsOfTheWindow() throws {
        let process = MockSearchProcess()
        let asked = AskedWhileLooking()
        let runtime = FdSearchRuntime(
            fdBinaryPath: "/tmp/fd", spawn: process.spawn,
            hasHiddenFlag: { _ in
                asked.ask()
                return false
            })
        let job = runtime.startSearch(demo()).jobId
        asked.watch(runtime, job)
        // The second record has no NUL after it: it is read when fd ends.
        process.write("/Users/demo/project/a.txt\0/Users/demo/project/b.txt")
        process.close(code: 0)
        #expect(asked.answered == [true, true])
        #expect(try paths(runtime, job).map(\.name) == ["a.txt", "b.txt"])
    }

    // The search's folder is followed to its real path as the search starts: a disk slow to answer then doesn't hold
    // up the window asking how another search is doing.
    @Test func followsItsFolderWithoutHoldingUpTheQuestionsOfTheWindow() throws {
        let process = MockSearchProcess()
        let asked = AskedWhileLooking()
        let runtime = FdSearchRuntime(
            fdBinaryPath: "/tmp/fd", spawn: process.spawn, hasHiddenFlag: { _ in false },
            realPath: { path in
                asked.ask()
                return path
            })
        let first = runtime.startSearch(demo()).jobId
        asked.watch(runtime, first)
        _ = runtime.startSearch(demo())
        #expect(asked.answered.count == 2)
        #expect(asked.answered.last == true)
    }

    @Test func whatIsDroppedDoesNotCountTowardsTheLimit() throws {
        let root = "/Users/demo/project"
        let (runtime, process, _) = make(flagged: [root + "/hidden"])
        let job = runtime.startSearch(demo()).jobId
        let dropped = (0..<SearchLimits.resultLimit).map { root + "/hidden/\($0)\0" }.joined()
        process.write(dropped)
        let update = try runtime.getUpdate(jobId: job, cursor: 0)
        #expect(update.items.isEmpty)
        #expect(!update.truncated)
        #expect(process.terminateCount == 0)
    }

    @Test func searchingInsideAHiddenFolderFindsWhatIsThere() throws {
        let root = "/Users/demo/project"
        let (runtime, process, _) = make(flagged: [root, "/Users/demo"])
        let job = runtime.startSearch(demo()).jobId
        process.write(root + "/a.txt\0" + root + "/sub/b.txt\0")
        #expect(try paths(runtime, job).map(\.name) == ["a.txt", "b.txt"])
    }

    @Test func withHiddenFilesOnNothingIsDroppedAndFlaggedResultsLookHidden() throws {
        let root = "/Users/demo/project"
        let (runtime, process, _) = make(flagged: [root + "/hidden", root + "/secret.txt"])
        let job = runtime.startSearch(demo(hidden: true)).jobId
        process.write(root + "/secret.txt\0" + root + "/hidden/inside.txt\0" + root + "/plain.txt\0")
        let items = try paths(runtime, job)
        #expect(items.map(\.name) == ["secret.txt", "inside.txt", "plain.txt"])
        // What is in a hidden folder isn't hidden itself, as with a folder hidden by a dot.
        #expect(items.map(\.isHidden) == [true, false, false])
    }

    @Test func runsFdInTheSearchedFolderWithTheBuiltArguments() throws {
        let (runtime, process) = make()
        _ = runtime.startSearch(demo("a b"))
        let spawned = try #require(process.spawnedWith)
        #expect(spawned.file == "/tmp/fd")
        #expect(spawned.cwd == "/Users/demo/project")
        #expect(spawned.args == FdSearchArgs.build(demo("a b")))
    }

    @Test func reportsFoldersAndPackagesWhichFdMarksWithATrailingSlash() throws {
        let (runtime, process) = make()
        let started = runtime.startSearch(
            SearchRequest(rootPath: "/Users/demo", query: "app", skipGitFolders: false))
        process.write("/Users/demo/apps/\0/Users/demo/Notes.app/\0/Users/demo/apps/app.v2/\0/Users/demo/app.ts\0")
        let items = try runtime.getUpdate(jobId: started.jobId, cursor: 0).items
        #expect(
            items == [
                item("/Users/demo/apps", name: "apps", kind: .directory, parent: "/Users/demo", relative: "."),
                item(
                    "/Users/demo/Notes.app", name: "Notes.app", ext: "app", kind: .bundle, parent: "/Users/demo",
                    relative: "."),
                item(
                    "/Users/demo/apps/app.v2", name: "app.v2", ext: "v2", kind: .directory, parent: "/Users/demo/apps",
                    relative: "apps"),
                item("/Users/demo/app.ts", name: "app.ts", ext: "ts", parent: "/Users/demo", relative: "."),
            ])
    }

    @Test func streamsNullDelimitedResultsInIncrementalBatches() throws {
        let (runtime, process) = make()
        let started = runtime.startSearch(demo("*.tsx", mode: .glob))
        process.write("/Users/demo/project/src/App.tsx\0/Users/demo/project/src/lib/utils.tsx\0")

        let first = try runtime.getUpdate(jobId: started.jobId, cursor: 0)
        #expect(
            first
                == SearchUpdate(
                    jobId: started.jobId, status: .running,
                    items: [
                        item(
                            "/Users/demo/project/src/App.tsx", name: "App.tsx", ext: "tsx",
                            parent: "/Users/demo/project/src", relative: "src"),
                        item(
                            "/Users/demo/project/src/lib/utils.tsx", name: "utils.tsx", ext: "tsx",
                            parent: "/Users/demo/project/src/lib", relative: "src/lib"),
                    ], nextCursor: 2, done: false, truncated: false, error: nil))

        process.close(code: 0)
        let last = try runtime.getUpdate(jobId: started.jobId, cursor: 2)
        #expect(
            last
                == SearchUpdate(
                    jobId: started.jobId, status: .complete, items: [], nextCursor: 2, done: true, truncated: false,
                    error: nil))
    }

    @Test func keepsGetUpdateIdempotentAfterACompletedJobHasBeenDrained() throws {
        let (runtime, process) = make()
        let started = runtime.startSearch(demo("*.tsx", mode: .glob))
        process.write("/Users/demo/project/src/App.tsx\0/Users/demo/project/src/lib/utils.tsx\0")
        process.close(code: 0)

        // The first poll after completion returns every remaining item with done.
        let final = try runtime.getUpdate(jobId: started.jobId, cursor: 0)
        #expect(final.done)
        #expect(final.items.count == 2)
        #expect(final.nextCursor == 2)

        // Later polls do not throw "Unknown search job".
        let done = { (cursor: Int) in
            SearchUpdate(
                jobId: started.jobId, status: .complete, items: [], nextCursor: cursor, done: true, truncated: false,
                error: nil)
        }
        #expect(try runtime.getUpdate(jobId: started.jobId, cursor: final.nextCursor) == done(2))
        #expect(try runtime.getUpdate(jobId: started.jobId, cursor: 0) == done(0))
    }

    @Test func reassemblesEntriesThatAreSplitAcrossStdoutChunks() throws {
        let (runtime, process) = make()
        let started = runtime.startSearch(demo("*.tsx", mode: .glob))
        process.write("/Users/demo/project/src/Ap")
        process.write("p.tsx\0/Users/demo/project/src/lib/uti")
        process.write("ls.tsx\0")
        let paths = try runtime.getUpdate(jobId: started.jobId, cursor: 0).items.map(\.path)
        #expect(paths == ["/Users/demo/project/src/App.tsx", "/Users/demo/project/src/lib/utils.tsx"])
    }

    @Test func keepsAMultiByteCharacterSplitBetweenChunks() throws {
        let (runtime, process) = make()
        let started = runtime.startSearch(demo("日", mode: .text))
        let bytes = Array("/Users/demo/project/日本語.txt\0".utf8)
        let cut = bytes.firstIndex(of: 0xE6)! + 1
        process.events?.onStdout(Data(bytes[..<cut]))
        process.events?.onStdout(Data(bytes[cut...]))
        #expect(try runtime.getUpdate(jobId: started.jobId, cursor: 0).items.map(\.name) == ["日本語.txt"])
    }

    // Plain Text keeps what its own matching finds among what fd wrote: the name, case aside, a plain letter finding an
    // accented one. What it drops doesn't count toward the limit.
    @Test func plainTextKeepsWhatItsOwnMatchingFindsInWhatFdWrote() throws {
        let (runtime, process) = make()
        let started = runtime.startSearch(demo("resume", mode: .text))
        let root = "/Users/demo/project"
        process.write(
            "\(root)/R\u{E9}sum\u{E9}.pdf\0\(root)/RESUME.txt\0\(root)/resume/notes.txt\0\(root)/res-ume.txt\0")
        let names = try runtime.getUpdate(jobId: started.jobId, cursor: 0).items.map(\.name)
        #expect(names == ["R\u{E9}sum\u{E9}.pdf", "RESUME.txt"])
    }

    @Test func plainTextOfFullPathsJudgesTheWholePath() throws {
        let (runtime, process) = make()
        var search = demo("project/re", mode: .text)
        search.matchScope = .path
        let started = runtime.startSearch(search)
        process.write("/Users/demo/project/report.txt\0/Users/demo/other/report.txt\0")
        let paths = try runtime.getUpdate(jobId: started.jobId, cursor: 0).items.map(\.path)
        #expect(paths == ["/Users/demo/project/report.txt"])
    }

    @Test func terminatesCancelledJobsAndAnswersLaterPollsWithACancelledTerminalState() throws {
        let (runtime, process) = make()
        let started = runtime.startSearch(demo("*.ts", mode: .glob))
        runtime.cancelSearch(jobId: started.jobId)
        #expect(process.terminateCount == 1)
        let update = try runtime.getUpdate(jobId: started.jobId, cursor: 0)
        #expect(update.status == .cancelled)
        #expect(update.items.isEmpty)
        #expect(update.done)
        runtime.cancelSearch(jobId: started.jobId)
        #expect(process.terminateCount == 1)
        // fd ending after it was stopped changes nothing.
        process.close(code: nil, signal: SIGTERM)
        #expect(try runtime.getUpdate(jobId: started.jobId, cursor: 0).status == .cancelled)
    }

    @Test func cancellingAnUnknownJobIsFine() {
        let (runtime, _) = make()
        runtime.cancelSearch(jobId: "search-99")
    }

    @Test func surfacesStderrContentForFailedSearches() throws {
        let (runtime, process) = make()
        let started = runtime.startSearch(demo("(", mode: .regex))
        process.writeError("regex parse error")
        process.close(code: 1)
        #expect(
            try runtime.getUpdate(jobId: started.jobId, cursor: 0)
                == SearchUpdate(
                    jobId: started.jobId, status: .error, items: [], nextCursor: 0, done: true, truncated: false,
                    error: "regex parse error"))
    }

    @Test func reportsWhatFdSaidAboutABadPatternWithoutItsCommandLineAdvice() throws {
        let (runtime, process) = make()
        let started = runtime.startSearch(demo("no(te", mode: .regex))
        process.writeError(
            "[fd error]: regex parse error:\n    no(te\n      ^\nerror: unclosed group\n\nNote: You can search for literal substrings with '--fixed-strings' or literal strings with '--exact' options."
        )
        process.close(code: 1)
        #expect(
            try runtime.getUpdate(jobId: started.jobId, cursor: 0).error
                == "regex parse error:\n    no(te\n      ^\nerror: unclosed group")
    }

    @Test func flushesATrailingStdoutBufferOnCloseAndPreservesRootRelativeParents() throws {
        let (runtime, process) = make()
        let started = runtime.startSearch(demo(".env", mode: .glob, hidden: true))
        process.write("/Users/demo/project/.env")
        process.close(code: 0)
        #expect(
            try runtime.getUpdate(jobId: started.jobId, cursor: 0)
                == SearchUpdate(
                    jobId: started.jobId, status: .complete,
                    items: [
                        item(
                            "/Users/demo/project/.env", name: ".env", hidden: true, parent: "/Users/demo/project",
                            relative: ".")
                    ], nextCursor: 1, done: true, truncated: false, error: nil))
    }

    @Test func surfacesProcessErrorEventsAsSearchFailures() throws {
        let (runtime, process) = make()
        let started = runtime.startSearch(demo("*.ts", mode: .glob))
        process.events?.onError("spawn failed")
        #expect(
            try runtime.getUpdate(jobId: started.jobId, cursor: 0)
                == SearchUpdate(
                    jobId: started.jobId, status: .error, items: [], nextCursor: 0, done: true, truncated: false,
                    error: "spawn failed"))
    }

    @Test func reportsUnexpectedExitSignalsWhenFdIsTerminatedExternally() throws {
        let (runtime, process) = make()
        let started = runtime.startSearch(demo("*.ts", mode: .glob))
        process.close(code: nil, signal: SIGKILL)
        #expect(
            try runtime.getUpdate(jobId: started.jobId, cursor: 0)
                == SearchUpdate(
                    jobId: started.jobId, status: .error, items: [], nextCursor: 0, done: true, truncated: false,
                    error: "fd exited via signal SIGKILL"))
    }

    @Test func reportsTheExitCodeWhenFdFailsWithoutSayingWhy() throws {
        let (runtime, process) = make()
        let started = runtime.startSearch(demo())
        process.close(code: 2)
        #expect(try runtime.getUpdate(jobId: started.jobId, cursor: 0).error == "fd exited with code 2")
    }

    @Test func cancelsRunningJobsAndClearsTheRegistryWhenTheRuntimeCloses() {
        let (runtime, process) = make()
        let started = runtime.startSearch(demo("*.ts", mode: .glob))
        runtime.close()
        #expect(process.terminateCount == 1)
        #expect(throws: UnknownSearchJob(jobId: started.jobId)) {
            try runtime.getUpdate(jobId: started.jobId, cursor: 0)
        }
    }

    @Test func stopsAtTheResultLimitAndSaysTheResultsWereCutOff() throws {
        #expect(SearchLimits.resultLimit == 50_000)
        let (runtime, process) = make()
        let started = runtime.startSearch(demo("f"))
        let many =
            (0..<(SearchLimits.resultLimit + 5)).map { "/Users/demo/project/f\($0)" }.joined(separator: "\0") + "\0"
        process.write(many)
        #expect(process.terminateCount == 1)
        process.close(code: nil, signal: SIGTERM)
        let update = try runtime.getUpdate(jobId: started.jobId, cursor: 0)
        #expect(update.items.count == SearchLimits.resultLimit)
        #expect(update.status == .truncated)
        #expect(update.truncated)
        #expect(update.done)
        #expect(update.error == nil)
    }

    @Test func remembersAtMostSixtyFourFinishedJobs() throws {
        let runtime = FdSearchRuntime(fdBinaryPath: "/tmp/fd") { _, _, _, _ in MockSearchProcess() }
        let ids = (0..<70).map { _ in runtime.startSearch(demo()).jobId }
        for id in ids { runtime.cancelSearch(jobId: id) }
        #expect(throws: UnknownSearchJob.self) { try runtime.getUpdate(jobId: ids[0], cursor: 0) }
        #expect(try runtime.getUpdate(jobId: ids[69], cursor: 0).status == .cancelled)
    }
}
