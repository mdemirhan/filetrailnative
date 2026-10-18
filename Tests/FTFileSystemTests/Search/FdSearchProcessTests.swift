// Searches run by the real bundled fd: the reference's results on the fixtures, and no fd left after quitting.
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTFileSystem

private struct ResultsInput: Codable {
    struct Entry: Codable {
        var path: String
        var kind: String
        var content: String?
        var target: String?
    }
    var tree: String
    var entries: [Entry]?
    var root: String
    var query: String
    var patternMode: SearchPatternModePreference
    var matchScope: SearchMatchScopePreference
    var recursive: Bool
    var includeHidden: Bool
    var skipGitFolders: Bool
    var skipGitIgnored: Bool
}

private struct ResultsOutput: Codable {
    var status: SearchJobStatus
    var truncated: Bool
    var error: String?
    var items: [SearchResultItem]
}

private let fixtures: URL = {
    let cache =
        ProcessInfo.processInfo.environment["FILETRAIL_PORT_CACHE"]
        ?? NSHomeDirectory() + "/Library/Caches/filetrail-port"
    return URL(fileURLWithPath: cache).appendingPathComponent("fixtures")
}()

private let lighthouse = fixtures.appendingPathComponent("lighthouse/Lighthouse")
private let hasFixtures = FileManager.default.fileExists(atPath: lighthouse.path)
private let hasFd = FdBinary.currentArchitecture == "arm64"

/// Runs a search to its end, polling as the UI does.
private func runToEnd(_ runtime: FdSearchRuntime, _ request: SearchRequest) throws -> (SearchUpdate, [SearchResultItem])
{
    let started = runtime.startSearch(request)
    var items: [SearchResultItem] = []
    var cursor = 0
    let deadline = Date().addingTimeInterval(60)
    while Date() < deadline {
        let update = try runtime.getUpdate(jobId: started.jobId, cursor: cursor)
        items += update.items
        cursor = update.nextCursor
        if update.done { return (update, items) }
        Thread.sleep(forTimeInterval: 0.005)
    }
    throw CocoaError(.fileReadUnknown)
}

@Suite struct FdSearchProcessTests {
    private func makeRuntime() throws -> FdSearchRuntime {
        FdSearchRuntime(fdBinaryPath: try FdBinary.resolveBundledPath())
    }

    // F-193 F-194 F-195 F-196 F-199
    @Test(.enabled(if: hasFd))
    func matchesTheReferenceOnTheScratchTreeAndTheLighthouseFixture() throws {
        let cases: [GoldenCase<ResultsInput, ResultsOutput>] = try Golden.load(suite: "search-results")
        #expect(cases.count > 150)
        let usable = cases.filter { $0.input.tree == "scratch" || hasFixtures }
        let runtime = try makeRuntime()
        let scratch = try TemporaryDirectory(prefix: "ft-search")
        defer { scratch.remove() }
        // fd reports real paths, and the temporary folder is reached through a link (/var).
        let scratchTop = realPath(scratch.path)
        // The tree is the same in every scratch case.
        if let entries = cases.first(where: { $0.input.entries != nil })?.input.entries {
            try build(entries, in: scratch.url)
        }

        try Golden.expectMatches(usable) { input in
            let top = input.tree == "lighthouse" ? lighthouse.path : scratchTop
            let root = input.root.isEmpty ? top : top + "/" + input.root
            let request = SearchRequest(
                rootPath: root, query: input.query, patternMode: input.patternMode, matchScope: input.matchScope,
                recursive: input.recursive, includeHidden: input.includeHidden, skipGitFolders: input.skipGitFolders,
                skipGitIgnored: input.skipGitIgnored)
            let (update, items) = try runToEnd(runtime, request)
            let masked = items.sorted { Array($0.path.utf16).lexicographicallyPrecedes(Array($1.path.utf16)) }.map {
                var item = $0
                item.path = item.path.replacingOccurrences(of: top, with: "$ROOT")
                item.parentPath = item.parentPath.replacingOccurrences(of: top, with: "$ROOT")
                return item
            }
            return ResultsOutput(
                status: update.status, truncated: update.truncated,
                error: update.error?.replacingOccurrences(of: top, with: "$ROOT"), items: masked)
        }
        runtime.close()
    }

    /// Made with POSIX calls, which keep a name's bytes as given: Foundation would write "é" decomposed, and fd (and the
    /// reference, made with Node) would list it as such.
    private func build(_ entries: [ResultsInput.Entry], in top: URL) throws {
        for entry in entries {
            let path = top.path + "/" + entry.path
            switch entry.kind {
            case "dir":
                if mkdir(path, 0o755) != 0 && errno != EEXIST {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            case "symlink":
                if symlink(entry.target ?? "", path) != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            default:
                let descriptor = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
                if descriptor < 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                let bytes = Array((entry.content ?? "").utf8)
                _ = bytes.withUnsafeBytes { write(descriptor, $0.baseAddress, bytes.count) }
                close(descriptor)
            }
        }
    }

    @Test(.enabled(if: hasFd))
    func reportsABadRegexAsAnErrorWithoutFdsAdvice() throws {
        let runtime = try makeRuntime()
        defer { runtime.close() }
        try withTemporaryDirectory { folder in
            let (update, items) = try runToEnd(
                runtime, SearchRequest(rootPath: folder.path, query: "no(te", patternMode: .regex))
            #expect(items.isEmpty)
            #expect(update.status == .error)
            let message = try #require(update.error)
            #expect(message.hasPrefix("regex parse error"))
            #expect(!message.contains("Note:"))
        }
    }

    @Test(.enabled(if: hasFd))
    func reportsAFolderThatIsNotThereAsAnError() throws {
        let runtime = try makeRuntime()
        defer { runtime.close() }
        let (update, _) = try runToEnd(runtime, SearchRequest(rootPath: "/no/such/folder-\(UUID())", query: "x"))
        #expect(update.status == .error)
        #expect(update.done)
        #expect(update.error?.isEmpty == false)
    }

    @Test(.enabled(if: hasFd))
    func streamsResultsFromARealSearch() async throws {
        let runtime = try makeRuntime()
        defer { runtime.close() }
        try await withTemporaryDirectory { folder in
            for index in 0..<50 {
                try Data().write(to: folder.appending("file-\(index).txt"))
            }
            var names: [String] = []
            var last: SearchUpdate?
            for await update in runtime.results(
                for: SearchRequest(rootPath: folder.path, query: "file-", patternMode: .text))
            {
                names += update.items.map(\.name)
                last = update
            }
            #expect(names.count == 50)
            #expect(Set(names).count == 50)
            #expect(last?.status == .complete)
        }
    }

    // T-1481cd4f F-198
    @Test(.enabled(if: hasFd))
    func quittingWhileASearchRunsLeavesNoFdBehind() async throws {
        let runtime = try makeRuntime()
        // Matches nothing, so fd searches the system library (some seconds of work) without writing a line. Not all of
        // "/", which takes in every mounted disk, other tests' disk images too; nor /usr, which fd reads in 0.05 s.
        let query = "filetrail-quit-test-\(UUID().uuidString)"
        let started = runtime.startSearch(SearchRequest(rootPath: "/System/Library", query: query, patternMode: .text))
        #expect(try await waitUntil(seconds: 5) { !fdProcesses(for: query).isEmpty })
        #expect(try runtime.getUpdate(jobId: started.jobId, cursor: 0).done == false)

        runtime.close()
        #expect(try await waitUntil(seconds: 2) { fdProcesses(for: query).isEmpty })
    }

    @Test(.enabled(if: hasFd))
    func cancellingASearchEndsItsFd() async throws {
        let runtime = try makeRuntime()
        defer { runtime.close() }
        let query = "filetrail-cancel-test-\(UUID().uuidString)"
        let started = runtime.startSearch(SearchRequest(rootPath: "/System/Library", query: query, patternMode: .text))
        #expect(try await waitUntil(seconds: 5) { !fdProcesses(for: query).isEmpty })
        runtime.cancelSearch(jobId: started.jobId)
        #expect(try await waitUntil(seconds: 2) { fdProcesses(for: query).isEmpty })
        #expect(try runtime.getUpdate(jobId: started.jobId, cursor: 0).status == .cancelled)
    }
}

private func realPath(_ path: String) -> String {
    guard let resolved = realpath(path, nil) else { return path }
    defer { free(resolved) }
    return String(cString: resolved)
}

private func waitUntil(seconds: Double, _ condition: () -> Bool) async throws -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        try await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

/// The ids of the fd processes searching for `query` (found by their command line, as the original's test does).
private func fdProcesses(for query: String) -> [String] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = ["-axo", "pid=,command="]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return [] }
    let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    return text.split(separator: "\n").filter { $0.contains(query) && $0.contains("/fd ") }
        .map { String($0.split(separator: " ").first ?? "") }
}
