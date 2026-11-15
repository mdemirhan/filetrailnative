// Searches run by the real bundled fd: the golden results on the fixtures, and no fd left after quitting.
import Darwin
import FTFoundation
import FTTestSupport
import Foundation
import Testing
import os

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
    /// A `SearchJobStatus`, by its raw value.
    var status: String
    var truncated: Bool
    var error: String?
    var items: [ResultItem]
}

/// A result as the golden spells it.
private struct ResultItem: Codable {
    var path: String
    var name: String
    var `extension`: String
    var kind: FTFileSystem.EntryKind
    var isHidden: Bool
    var isSymlink: Bool
    var parentPath: String
    var relativeParentPath: String

    init(_ item: SearchResultItem) {
        path = item.path
        name = item.name
        `extension` = item.fileExtension
        kind = item.kind
        isHidden = item.isHidden
        isSymlink = item.isSymlink
        parentPath = item.parentPath
        relativeParentPath = item.relativeParentPath
    }
}

private let fixtures = URL(fileURLWithPath: Fixtures.root)

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

    @Test(.enabled(if: hasFd))
    func matchesTheGoldenFileOnTheScratchTreeAndTheLighthouseFixture() throws {
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

        @Sendable func search(_ input: ResultsInput) throws -> ResultsOutput {
            let top = input.tree == "lighthouse" ? lighthouse.path : scratchTop
            let root = input.root.isEmpty ? top : top + "/" + input.root
            let request = SearchRequest(
                rootPath: root, query: input.query, patternMode: input.patternMode, matchScope: input.matchScope,
                recursive: input.recursive, includeHidden: input.includeHidden, skipGitFolders: input.skipGitFolders,
                skipGitIgnored: input.skipGitIgnored)
            let (update, items) = try runToEnd(runtime, request)
            let masked = items.sorted { Array($0.path.utf16).lexicographicallyPrecedes(Array($1.path.utf16)) }.map {
                var item = ResultItem($0)
                item.path = item.path.replacingOccurrences(of: top, with: "$ROOT")
                item.parentPath = item.parentPath.replacingOccurrences(of: top, with: "$ROOT")
                return item
            }
            return ResultsOutput(
                status: update.status.rawValue, truncated: update.truncated,
                error: update.error?.replacingOccurrences(of: top, with: "$ROOT"), items: masked)
        }

        // The searches run side by side, each a job of its own in the one runtime, and are then compared with the golden.
        let outputs = OSAllocatedUnfairLock(initialState: [String: Result<ResultsOutput, any Error>]())
        DispatchQueue.concurrentPerform(iterations: usable.count) { index in
            let input = usable[index].input
            let output = Result { try search(input) }
            outputs.withLock { $0[Golden.render(input)] = output }
        }
        let searched = outputs.withLock { $0 }
        try Golden.expectMatches(usable) { input in try #require(searched[Golden.render(input)]).get() }
        runtime.close()
    }

    /// Made with POSIX calls, which keep a name's bytes as given: Foundation would write "é" decomposed, and fd (and the
    /// golden) would list it as such.
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
    func aRealSearchLeavesOutWhatHasTheHiddenFlagWhereverTheFolderIs() throws {
        let runtime = try makeRuntime()
        defer { runtime.close() }
        try withTemporaryDirectory { folder in
            // The temporary folder is really under the hidden /private: what is above the search doesn't count.
            try FileManager.default.createDirectory(
                atPath: folder.path + "/hidden/deep", withIntermediateDirectories: true)
            try Data().write(to: folder.appending("match-plain.txt"))
            try Data().write(to: folder.appending("match-flagged.txt"))
            try Data().write(to: folder.appending("hidden/deep/match-inside.txt"))
            #expect(chflags(folder.path + "/hidden", UInt32(UF_HIDDEN)) == 0)
            #expect(chflags(folder.path + "/match-flagged.txt", UInt32(UF_HIDDEN)) == 0)
            let (_, items) = try runToEnd(
                runtime, SearchRequest(rootPath: folder.path, query: "match-", patternMode: .text))
            #expect(items.map(\.name) == ["match-plain.txt"])
        }
    }

    // Plain Text search and the list filter find the same names: case aside, a plain letter finding its accented
    // forms, an accented one only itself, however each name stores its accents.
    @Test(.enabled(if: hasFd))
    func plainTextFindsWhatTheListFilterFinds() throws {
        struct Entry: ListFilterEntry { var name: String }
        let names = [
            "Cafe\u{301} decomposed.txt", "Caf\u{E9} composed.txt", "CAF\u{C9} upper.txt", "cafe plain.txt",
            "Stra\u{DF}e.txt", "STRASSE 2.txt", "\u{3A3}\u{3AF}\u{3C3}\u{3C5}\u{3C6}\u{3BF}\u{3C2}.txt",
            "\u{39F}\u{394}\u{39F}\u{3A3}.txt", "Sm\u{F8}rrebr\u{F8}d.txt", "\u{130}zmir.txt", "\u{131}sl\u{131}k.txt",
            "report (1).pdf", "c++ notes.txt", "Nai\u{308}ve.txt", "README.md",
            // A letter with a mark it has no composed form with, a digit with one, ligatures and full-width letters.
            "q\u{303}1x.txt", "7\u{301}up.txt", "\u{FB01}le.txt", "o\u{FB03}ce.txt", "wa\u{FB04}e.txt",
            "\u{FF21}\u{FF22}\u{FF23} \u{FF11}\u{FF12}.txt", "be\u{FB06} of.txt",
            // Kana and Hangul composed and decomposed: a kana and its mark, jamo, a syllable and a jamo.
            "\u{304B}\u{3099}\u{304F}.txt", "\u{304C}\u{304F} 2.txt", "\u{304B}\u{304F} 3.txt",
            "\u{1112}\u{1161}\u{11AB}\u{1100}\u{1173}\u{11AF}.txt", "\u{D55C}\u{AE00} 2.txt", "\u{D558}\u{11AB} 3.txt",
            "\u{D558} 4.txt",
        ]
        let queries = [
            "cafe", "caf\u{E9}", "CAF\u{C9}", "cafe\u{301}", "e", "\u{E9}", "ss", "\u{DF}",
            "\u{3C3}\u{3B9}\u{3C3}\u{3C5}\u{3C6}\u{3BF}\u{3C2}",
            "\u{3C2}", "\u{3BF}\u{3B4}\u{3BF}\u{3C3}", "smorrebrod", "sm\u{F8}rrebr\u{F8}d", "izmir", "\u{131}", "i",
            "(1)", "c++",
            "naive", "na\u{EF}ve", "readme", "README", "Rep", "2.t",
            "q1", "7u", "fi", "file", "ffi", "fic", "offic", "of", "ff", "fl", "affle", "st", "est o", "t",
            "abc", "ABC 12", "\u{FF41}\u{FF42}", "\u{FB01}", "1", ".",
            "\u{304C}", "\u{304C}\u{304F}", "\u{304B}\u{3099}", "\u{304B}", "\u{D55C}", "\u{D55C}\u{AE00}",
            "\u{1112}\u{1161}\u{11AB}", "\u{D558}", "\u{AE00}",
        ]
        let runtime = try makeRuntime()
        defer { runtime.close() }
        try withTemporaryDirectory { folder in
            for name in names {
                // Spelled exactly: Foundation would store some of these decomposed.
                let descriptor = open(folder.path + "/" + name, O_WRONLY | O_CREAT, 0o644)
                #expect(descriptor >= 0, "\(name)")
                close(descriptor)
            }
            let entries = names.map(Entry.init)
            for query in queries {
                let (_, items) = try runToEnd(
                    runtime, SearchRequest(rootPath: folder.path, query: query, patternMode: .text))
                let filtered = ListFilter.filterByName(entries, query: query, mode: .contains).map(\.name)
                #expect(Set(items.map(\.name)) == Set(filtered), "\(query)")
            }
        }
    }

    // The same over the names fd's regular expressions (Rust's) take otherwise than the system's: each name stored as
    // written, several spellings of one letter side by side, each a name of its own by the number it starts with (the
    // disk takes two spellings of one name as the same name).
    @Test(.enabled(if: hasFd))
    func plainTextFindsWhatTheListFilterFindsHoweverANameIsSpelled() throws {
        struct Entry: ListFilterEntry { var name: String }
        let spellings = [
            // Accents composed and decomposed, and marks in another order or partly composed (all of them "ậ").
            "Caf\u{E9}", "Cafe\u{301}", "CAF\u{C9}", "cafe", "\u{1EAD}", "a\u{323}\u{302}", "a\u{302}\u{323}",
            "\u{1EA1}\u{302}", "\u{E2}\u{323}", "A\u{323}\u{302}", "Vi\u{1EC7}t", "Vie\u{323}\u{302}t",
            "Vie\u{302}\u{323}t", "Vi\u{1EBF}t", "Vie\u{301}\u{302}t", "e\u{341}t\u{E9}",
            // Kana with and without their marks composed, Hangul as syllables, jamo, or a syllable and a jamo.
            "\u{304C}\u{304F}", "\u{304B}\u{3099}\u{304F}", "\u{304B}\u{304F}", "\u{30D1}\u{30EA}",
            "\u{30CF}\u{309A}\u{30EA}", "\u{D55C}\u{AE00}", "\u{1112}\u{1161}\u{11AB}\u{1100}\u{1173}\u{11AF}",
            "\u{D558}\u{11AB}\u{AE00}", "\u{1112}\u{1161}", "\u{D558}",
            // Case: ß and ss, dotted and dotless i, the long s, the final sigma, the Kelvin sign.
            "Stra\u{DF}e", "STRASSE", "GRO\u{1E9E}", "\u{130}stanbul", "i\u{307}stanbul", "Istanbul",
            "\u{131}s\u{131}k", "\u{17F}un", "SUN", "\u{3BB}\u{3CC}\u{3B3}\u{3BF}\u{3C2}",
            "\u{39B}\u{39F}\u{393}\u{39F}\u{3A3}",
            "\u{3BB}\u{3BF}\u{301}\u{3B3}\u{3BF}\u{3C2}", "\u{3BB}\u{1F79}\u{3B3}\u{3BF}\u{3C3}", "\u{3B9}\u{344}",
            "\u{390}", "\u{212A}elvin",
            // Ligatures, full-width letters, and characters stored as another: a compatibility ideograph, a Hebrew and
            // a Devanagari letter written as one character with their mark.
            "\u{FB01}le", "o\u{FB03}ce", "\u{FB01}\u{301}x", "\u{FF21}\u{FF22}\u{FF23}\u{FF11}", "\u{FF41}bc",
            "\u{F900}", "\u{8C48}", "\u{FB2E}", "\u{5D0}\u{5B7}", "\u{958}", "\u{915}\u{93C}",
        ]
        let names = spellings.enumerated().map { "\($0.offset + 10) \($0.element)" }
        let queries = [
            "cafe", "caf\u{E9}", "CAF\u{C9}", "cafe\u{301}", "e", "\u{E9}", "\u{1EAD}", "a\u{302}\u{323}", "a",
            "\u{1EA1}", "\u{E2}", "vi\u{1EC7}t", "viet", "vi\u{EA}t", "vi\u{1EBF}t", "\u{E9}\u{302}", "\u{E9}t\u{E9}",
            "\u{304C}", "\u{304B}", "\u{304C}\u{304F}", "\u{304B}\u{3099}", "\u{30D1}", "\u{30CF}", "\u{D55C}",
            "\u{D558}", "\u{D55C}\u{AE00}", "\u{1112}\u{1161}\u{11AB}", "\u{AE00}", "\u{1112}", "ss", "\u{DF}",
            "\u{1E9E}", "strasse", "stra\u{DF}e", "\u{130}", "\u{131}", "i", "istanbul", "\u{17F}", "s", "sun",
            "\u{3C3}", "\u{3C2}", "\u{3BB}\u{3BF}\u{3B3}\u{3BF}\u{3C2}", "\u{3BB}\u{3CC}\u{3B3}\u{3BF}\u{3C2}",
            "\u{3CC}", "\u{390}", "\u{3B9}", "k", "kelvin", "\u{FB01}", "fi", "file", "ffic", "\u{FF41}", "abc",
            "\u{FF21}\u{FF22}\u{FF23}", "1", "\u{8C48}", "\u{F900}", "\u{5D0}", "\u{FB2E}", "\u{915}", "\u{958}",
        ]
        let runtime = try makeRuntime()
        defer { runtime.close() }
        try withTemporaryDirectory { folder in
            for name in names {
                // Spelled exactly: Foundation would store some of these decomposed.
                let descriptor = open(folder.path + "/" + name, O_WRONLY | O_CREAT | O_EXCL, 0o644)
                #expect(descriptor >= 0, "\(Array(name.unicodeScalars))")
                close(descriptor)
            }
            let entries = names.map(Entry.init)
            var found = 0
            for query in queries {
                let (_, items) = try runToEnd(
                    runtime, SearchRequest(rootPath: folder.path, query: query, patternMode: .text))
                let filtered = ListFilter.filterByName(entries, query: query, mode: .contains).map(\.name)
                found += filtered.count
                let missing = Set(filtered).subtracting(items.map(\.name)).map { Array($0.unicodeScalars) }
                let extra = Set(items.map(\.name)).subtracting(filtered).map { Array($0.unicodeScalars) }
                #expect(
                    missing.isEmpty && extra.isEmpty,
                    "\(Array(query.unicodeScalars)): missing \(missing), extra \(extra)")
            }
            #expect(found > 200)
        }
    }

    @Test(.enabled(if: hasFd))
    func findsEveryResultOfARealSearch() throws {
        let runtime = try makeRuntime()
        defer { runtime.close() }
        try withTemporaryDirectory { folder in
            for index in 0..<50 {
                try Data().write(to: folder.appending("file-\(index).txt"))
            }
            let (last, items) = try runToEnd(
                runtime, SearchRequest(rootPath: folder.path, query: "file-", patternMode: .text))
            let names = items.map(\.name)
            #expect(names.count == 50)
            #expect(Set(names).count == 50)
            #expect(last.status == .complete)
        }
    }

    // fd refuses a regular expression that compiles to more than 10 MB, which a pasted path or sentence of some 500
    // characters came to: the search failed where it should find the item, or nothing.
    @Test(.enabled(if: hasFd))
    func aVeryLongPlainTextSearchRunsAndFindsWhatItNames() throws {
        let runtime = try makeRuntime()
        defer { runtime.close() }
        try withTemporaryDirectory { folder in
            let parts = ["a", "b", "c"].map { String(repeating: $0 + "ffi ", count: 44) + "end" }
            let inside = parts.joined(separator: "/")
            try FileManager.default.createDirectory(
                at: folder.appending(inside), withIntermediateDirectories: true)
            #expect(inside.count > 600)
            let (found, items) = try runToEnd(
                runtime,
                SearchRequest(rootPath: folder.path, query: inside, patternMode: .text, matchScope: .path))
            #expect(found.status == .complete)
            #expect(found.error == nil)
            #expect(items.map(\.name) == [parts[2]])
            // The same text with another end names nothing: what fd hands over for its start is judged whole.
            let (none, nothing) = try runToEnd(
                runtime,
                SearchRequest(rootPath: folder.path, query: inside + "x", patternMode: .text, matchScope: .path))
            #expect(none.status == .complete)
            #expect(nothing.isEmpty)
        }
    }

    @Test(.enabled(if: hasFd))
    func quittingWhileASearchRunsLeavesNoFdBehind() async throws {
        let runtime = try makeRuntime()
        // Matches nothing, so fd searches the system library (some seconds of work) without writing a line. Not all of
        // "/", which takes in every mounted disk, other tests' disk images too; nor /usr, which fd reads in 0.05 s.
        let query = "filetrail-quit-test-\(UInt64.random(in: 100_000_000_000...999_999_999_999))"
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
        let query = "filetrail-cancel-test-\(UInt64.random(in: 100_000_000_000...999_999_999_999))"
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

/// The ids of the fd processes searching for `query` in Plain Text, found by their command line. There the query is a
/// pattern of characters and their other forms; each of its last 12 characters, digits, opens a class of its own
/// ("[1…]\p{M}*"), and they are looked for in that order.
private func fdProcesses(for query: String) -> [String] {
    let marker = query.suffix(12).map { "\\[\($0)[^\\]]*\\]\\\\p\\{M\\}\\*" }.joined()
    guard let pattern = try? NSRegularExpression(pattern: marker) else { return [] }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = ["-axo", "pid=,command="]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return [] }
    let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    return text.split(separator: "\n").map(String.init).filter { line in
        line.contains("/fd ")
            && pattern.firstMatch(in: line, range: NSRange(location: 0, length: line.utf16.count)) != nil
    }
    .map { String($0.split(separator: " ").first ?? "") }
}
