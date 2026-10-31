// Port of the FdSearchRuntime cases of packages/core/src/search/fdSearch.test.ts
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

private func demo(_ query: String = "app", mode: SearchPatternModePreference = .text, hidden: Bool = false)
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

@Suite struct FdSearchRuntimeTests {
    private func make() -> (FdSearchRuntime, MockSearchProcess) {
        let process = MockSearchProcess()
        return (FdSearchRuntime(fdBinaryPath: "/tmp/fd", spawn: process.spawn), process)
    }

    // B-SRCH-175
    @Test func runsFdInTheSearchedFolderWithTheBuiltArguments() throws {
        let (runtime, process) = make()
        _ = runtime.startSearch(demo("a b"))
        let spawned = try #require(process.spawnedWith)
        #expect(spawned.file == "/tmp/fd")
        #expect(spawned.cwd == "/Users/demo/project")
        #expect(spawned.args == FdSearchArgs.build(demo("a b")))
    }

    // T-502a84b4
    // B-SRCH-113 B-SRCH-170 B-SRCH-176
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

    // T-c5416c0d F-141 F-197
    // B-SRCH-177 B-SRCH-179
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

    // T-f6427548 F-141 F-197
    // B-SRCH-180
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

    // T-850d45cb
    // B-SRCH-178
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
        let started = runtime.startSearch(demo("日"))
        let bytes = Array("/Users/demo/project/日本語.txt\0".utf8)
        let cut = bytes.firstIndex(of: 0xE6)! + 1
        process.events?.onStdout(Data(bytes[..<cut]))
        process.events?.onStdout(Data(bytes[cut...]))
        #expect(try runtime.getUpdate(jobId: started.jobId, cursor: 0).items.map(\.name) == ["日本語.txt"])
    }

    // T-b00e33ee F-141
    // B-SRCH-182
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

    // B-SRCH-182
    @Test func cancellingAnUnknownJobIsFine() {
        let (runtime, _) = make()
        runtime.cancelSearch(jobId: "search-99")
    }

    // T-68fe0d57
    // B-SRCH-184 B-SRCH-194
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

    // T-b3e43aa8
    // B-SRCH-185
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

    // T-bf72fb90
    // B-SRCH-116 B-SRCH-177 B-SRCH-178 B-SRCH-184
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

    // T-3af83ea8
    // B-SRCH-184
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

    // T-c942ad03
    // B-SRCH-184
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

    // B-SRCH-185
    @Test func reportsTheExitCodeWhenFdFailsWithoutSayingWhy() throws {
        let (runtime, process) = make()
        let started = runtime.startSearch(demo())
        process.close(code: 2)
        #expect(try runtime.getUpdate(jobId: started.jobId, cursor: 0).error == "fd exited with code 2")
    }

    // T-9db0e2f7
    // B-SRCH-181 B-SRCH-186
    @Test func cancelsRunningJobsAndClearsTheRegistryWhenTheRuntimeCloses() {
        let (runtime, process) = make()
        let started = runtime.startSearch(demo("*.ts", mode: .glob))
        runtime.close()
        #expect(process.terminateCount == 1)
        #expect(throws: UnknownSearchJob(jobId: started.jobId)) {
            try runtime.getUpdate(jobId: started.jobId, cursor: 0)
        }
    }

    @Test func stopsAtTwentyThousandResultsAndSaysTheyWereCutOff() throws {
        let (runtime, process) = make()
        let started = runtime.startSearch(demo("f"))
        let many = (0..<20_005).map { "/Users/demo/project/f\($0)" }.joined(separator: "\0") + "\0"
        process.write(many)
        #expect(process.terminateCount == 1)
        process.close(code: nil, signal: SIGTERM)
        let update = try runtime.getUpdate(jobId: started.jobId, cursor: 0)
        #expect(update.items.count == FdSearchRuntime.resultLimit)
        #expect(update.status == .truncated)
        #expect(update.truncated)
        #expect(update.done)
        #expect(update.error == nil)
    }

    // F-197
    // B-SRCH-180
    @Test func remembersAtMostSixtyFourFinishedJobs() throws {
        let runtime = FdSearchRuntime(fdBinaryPath: "/tmp/fd") { _, _, _, _ in MockSearchProcess() }
        let ids = (0..<70).map { _ in runtime.startSearch(demo()).jobId }
        for id in ids { runtime.cancelSearch(jobId: id) }
        #expect(throws: UnknownSearchJob.self) { try runtime.getUpdate(jobId: ids[0], cursor: 0) }
        #expect(try runtime.getUpdate(jobId: ids[69], cursor: 0).status == .cancelled)
    }

    // F-141
    @Test func streamsBatchesUntilTheJobIsDone() async throws {
        let (runtime, process) = make()
        let stream = runtime.results(for: demo(), interval: .milliseconds(5))
        Task {
            try? await Task.sleep(for: .milliseconds(20))
            process.write("/Users/demo/project/a1\0/Users/demo/project/a2\0")
            try? await Task.sleep(for: .milliseconds(30))
            process.write("/Users/demo/project/a3\0")
            process.close(code: 0)
        }
        var batches: [SearchUpdate] = []
        for await update in stream { batches.append(update) }
        #expect(batches.flatMap(\.items).map(\.name) == ["a1", "a2", "a3"])
        #expect(batches.last?.done == true)
        #expect(batches.last?.status == .complete)
    }

    @Test func droppingTheStreamCancelsTheSearch() async throws {
        let (runtime, process) = make()
        do {
            let stream = runtime.results(for: demo(), interval: .milliseconds(5))
            var iterator = stream.makeAsyncIterator()
            Task {
                try? await Task.sleep(for: .milliseconds(10))
                process.write("/Users/demo/project/a1\0")
            }
            _ = await iterator.next()
        }
        for _ in 0..<200 where process.terminateCount == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(process.terminateCount == 1)
    }
}
