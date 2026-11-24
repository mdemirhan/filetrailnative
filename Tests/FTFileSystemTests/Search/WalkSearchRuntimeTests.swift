// Searches run by File Trail's own walk of the disk, on real folders: the golden results on the scratch tree and the
// fixtures, hidden items, Plain Text as the filters match, the limit, Stop, quitting, and what a search says when it
// can't run.
import Darwin
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTFileSystem

/// A search to its end, polled as the UI polls (more often, so the time measured is the search's own).
func runWalk(_ runtime: WalkSearchRuntime, _ request: SearchRequest, timeout: Double = 120) throws -> (
    SearchUpdate, [SearchResultItem]
) {
    let started = runtime.startSearch(request)
    var items: [SearchResultItem] = []
    var cursor = 0
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        let update = try runtime.getUpdate(jobId: started.jobId, cursor: cursor)
        items += update.items
        cursor = update.nextCursor
        if update.done { return (update, items) }
        Thread.sleep(forTimeInterval: 0.002)
    }
    throw CocoaError(.fileReadUnknown)
}

/// Made with POSIX calls, which keep a name's bytes as given: Foundation would write "é" decomposed.
func makeSearchFile(_ path: String, _ content: String = "") throws {
    let descriptor = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    let bytes = Array(content.utf8)
    _ = bytes.withUnsafeBytes { write(descriptor, $0.baseAddress, bytes.count) }
    close(descriptor)
}

func makeSearchFolder(_ path: String) throws {
    guard mkdir(path, 0o755) == 0 || errno == EEXIST else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

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

private let lighthouse = URL(fileURLWithPath: Fixtures.root).appendingPathComponent("lighthouse/Lighthouse")
private let hasFixtures = FileManager.default.fileExists(atPath: lighthouse.path)

private func realPath(_ path: String) -> String {
    guard let resolved = realpath(path, nil) else { return path }
    defer { free(resolved) }
    return String(cString: resolved)
}

private func waitUntil(seconds: Double, _ condition: () -> Bool) async throws -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        try await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

@Suite struct WalkSearchRuntimeTests {
    @Test func matchesTheGoldenFileOnTheScratchTreeAndTheLighthouseFixture() throws {
        let cases: [GoldenCase<ResultsInput, ResultsOutput>] = try Golden.load(suite: "search-results")
        #expect(cases.count > 130)
        let usable = cases.filter { $0.input.tree == "scratch" || hasFixtures }
        let runtime = WalkSearchRuntime()
        defer { runtime.close() }
        let scratch = try TemporaryDirectory(prefix: "ft-search")
        defer { scratch.remove() }
        // The temporary folder is reached through a link (/var): results are under its real path.
        let scratchTop = realPath(scratch.path)
        // The tree is the same in every scratch case.
        if let entries = cases.first(where: { $0.input.entries != nil })?.input.entries {
            for entry in entries {
                let path = scratchTop + "/" + entry.path
                switch entry.kind {
                case "dir": try makeSearchFolder(path)
                case "symlink": #expect(symlink(entry.target ?? "", path) == 0)
                default: try makeSearchFile(path, entry.content ?? "")
                }
            }
        }
        try Golden.expectMatches(usable) { input in
            let top = input.tree == "lighthouse" ? lighthouse.path : scratchTop
            let root = input.root.isEmpty ? top : top + "/" + input.root
            let request = SearchRequest(
                rootPath: root, query: input.query, patternMode: input.patternMode, matchScope: input.matchScope,
                recursive: input.recursive, includeHidden: input.includeHidden, skipGitFolders: input.skipGitFolders)
            let (update, items) = try runWalk(runtime, request)
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
    }

    // MARK: What a search says when it can't run

    @Test func aPatternThatIsntValidIsAnErrorAndSearchesNothing() throws {
        let runtime = WalkSearchRuntime()
        defer { runtime.close() }
        try withTemporaryDirectory { folder in
            for (mode, query) in [(SearchPatternModePreference.regex, "no(te"), (.glob, "[abc"), (.glob, "{a,b")] {
                let (update, items) = try runWalk(
                    runtime, SearchRequest(rootPath: folder.path, query: query, patternMode: mode))
                #expect(items.isEmpty)
                #expect(update.status == .error)
                #expect(update.done)
                #expect(update.error == SearchPatternError.invalid.message, "\(mode) \(query)")
            }
        }
    }

    @Test func aFolderThatIsntThereIsAnError() throws {
        let runtime = WalkSearchRuntime()
        defer { runtime.close() }
        let missing = "/no/such/folder-\(UUID())"
        let (update, _) = try runWalk(runtime, SearchRequest(rootPath: missing, query: "x"))
        #expect(update.status == .error)
        #expect(update.done)
        #expect(update.error == "Can’t search “\(missing)”: \(Errno.description(of: ENOENT))")
    }

    // A name never holds a slash, and only hidden items' names start with a dot: such a search says so rather than
    // finding nothing. A path search may have a slash.
    @Test func aSearchThatCouldFindNothingSaysWhy() throws {
        let runtime = WalkSearchRuntime()
        defer { runtime.close() }
        try withTemporaryDirectory { folder in
            try makeSearchFolder(folder.path + "/lib")
            try makeSearchFile(folder.path + "/lib/deep.txt")
            for mode in [SearchPatternModePreference.text, .glob, .regex] {
                let (update, _) = try runWalk(
                    runtime, SearchRequest(rootPath: folder.path, query: "lib/deep", patternMode: mode))
                #expect(update.error == SearchPatternError.slashInName.message, "\(mode)")
            }
            let (path, found) = try runWalk(
                runtime, SearchRequest(rootPath: folder.path, query: "lib/deep", matchScope: .path))
            #expect(path.status == .complete)
            #expect(found.map(\.name) == ["deep.txt"])
            for (mode, query) in [(SearchPatternModePreference.glob, ".env"), (.regex, "^\\.env")] {
                let (update, _) = try runWalk(
                    runtime, SearchRequest(rootPath: folder.path, query: query, patternMode: mode))
                #expect(update.error == SearchPatternError.onlyHidden.message, "\(mode) \(query)")
                let (hidden, _) = try runWalk(
                    runtime,
                    SearchRequest(rootPath: folder.path, query: query, patternMode: mode, includeHidden: true))
                #expect(hidden.status == .complete)
            }
        }
    }

    // A pattern that tries alternatives in turn can take minutes on one name: the search ends and says so.
    @Test func aRegularExpressionThatTakesTooLongEndsTheSearch() throws {
        let runtime = WalkSearchRuntime()
        defer { runtime.close() }
        try withTemporaryDirectory { folder in
            try makeSearchFile(folder.path + "/" + String(repeating: "a", count: 40) + "b")
            let started = Date()
            let (update, _) = try runWalk(
                runtime, SearchRequest(rootPath: folder.path, query: "^(a+)+$", patternMode: .regex))
            #expect(update.status == .error)
            #expect(update.error == SearchPatternError.tooSlow.message)
            #expect(Date().timeIntervalSince(started) < 5)
        }
    }

    // MARK: Hidden items

    @Test func leavesOutWhatHasTheHiddenFlagWhereverTheFolderIs() throws {
        let runtime = WalkSearchRuntime()
        defer { runtime.close() }
        try withTemporaryDirectory { folder in
            // The temporary folder is really under the hidden /private: what is above the search doesn't count.
            try FileManager.default.createDirectory(
                atPath: folder.path + "/hidden/deep", withIntermediateDirectories: true)
            try makeSearchFile(folder.path + "/match-plain.txt")
            try makeSearchFile(folder.path + "/match-flagged.txt")
            try makeSearchFile(folder.path + "/.match-dotted.txt")
            try makeSearchFile(folder.path + "/hidden/deep/match-inside.txt")
            #expect(chflags(folder.path + "/hidden", UInt32(UF_HIDDEN)) == 0)
            #expect(chflags(folder.path + "/match-flagged.txt", UInt32(UF_HIDDEN)) == 0)
            let (_, shown) = try runWalk(runtime, SearchRequest(rootPath: folder.path, query: "match-"))
            #expect(shown.map(\.name) == ["match-plain.txt"])
            // With hidden items: all of them, those with the flag or a dot marked hidden.
            let (_, all) = try runWalk(
                runtime, SearchRequest(rootPath: folder.path, query: "match-", includeHidden: true))
            let hidden = Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0.isHidden) })
            #expect(
                hidden == [
                    "match-plain.txt": false, "match-flagged.txt": true, ".match-dotted.txt": true,
                    "match-inside.txt": false,
                ])
            // Searching inside the hidden folder finds what is there.
            let (_, inside) = try runWalk(runtime, SearchRequest(rootPath: folder.path + "/hidden", query: "match-"))
            #expect(inside.map(\.name) == ["match-inside.txt"])
        }
    }

    // MARK: Plain Text

    // Plain Text search and the list filter find the same names: case aside, a plain letter finding its accented
    // forms, an accented one only itself, however each name stores its accents.
    @Test func plainTextFindsWhatTheListFilterFinds() throws {
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
        let runtime = WalkSearchRuntime()
        defer { runtime.close() }
        try withTemporaryDirectory { folder in
            for name in names { try makeSearchFile(folder.path + "/" + name) }
            let entries = names.map(Entry.init)
            for query in queries {
                let (_, items) = try runWalk(runtime, SearchRequest(rootPath: folder.path, query: query))
                let filtered = ListFilter.filterByName(entries, query: query, mode: .contains).map(\.name)
                #expect(Set(items.map(\.name)) == Set(filtered), "\(query)")
            }
        }
    }

    // The same over names that hold one letter in many spellings side by side, each a name of its own by the number it
    // starts with (the disk takes two spellings of one name as the same name).
    @Test func plainTextFindsWhatTheListFilterFindsHoweverANameIsSpelled() throws {
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
        let runtime = WalkSearchRuntime()
        defer { runtime.close() }
        try withTemporaryDirectory { folder in
            for name in names {
                let descriptor = open(folder.path + "/" + name, O_WRONLY | O_CREAT | O_EXCL, 0o644)
                #expect(descriptor >= 0, "\(Array(name.unicodeScalars))")
                close(descriptor)
            }
            let entries = names.map(Entry.init)
            var found = 0
            for query in queries {
                let (_, items) = try runWalk(runtime, SearchRequest(rootPath: folder.path, query: query))
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

    // A pasted path or sentence of hundreds of characters is matched whole.
    @Test func aVeryLongPlainTextSearchFindsWhatItNames() throws {
        let runtime = WalkSearchRuntime()
        defer { runtime.close() }
        try withTemporaryDirectory { folder in
            let parts = ["a", "b", "c"].map { String(repeating: $0 + "ffi ", count: 44) + "end" }
            let inside = parts.joined(separator: "/")
            try FileManager.default.createDirectory(at: folder.appending(inside), withIntermediateDirectories: true)
            #expect(inside.count > 600)
            let (found, items) = try runWalk(
                runtime, SearchRequest(rootPath: folder.path, query: inside, matchScope: .path))
            #expect(found.status == .complete)
            #expect(items.map(\.name) == [parts[2]])
            let (none, nothing) = try runWalk(
                runtime, SearchRequest(rootPath: folder.path, query: inside + "x", matchScope: .path))
            #expect(none.status == .complete)
            #expect(nothing.isEmpty)
        }
    }

    // MARK: How a search goes

    @Test func findsEveryResultAndAnswersTheSameAfterItsEnd() throws {
        let runtime = WalkSearchRuntime()
        defer { runtime.close() }
        try withTemporaryDirectory { folder in
            for index in 0..<50 { try makeSearchFile(folder.path + "/file-\(index).txt") }
            let started = runtime.startSearch(SearchRequest(rootPath: folder.path, query: "file-"))
            var items: [SearchResultItem] = []
            var cursor = 0
            var last: SearchUpdate?
            while last?.done != true {
                let update = try runtime.getUpdate(jobId: started.jobId, cursor: cursor)
                items += update.items
                cursor = update.nextCursor
                last = update
                Thread.sleep(forTimeInterval: 0.002)
            }
            #expect(Set(items.map(\.name)).count == 50)
            #expect(last?.status == .complete)
            #expect(last?.unreadableFolders == false)
            // Asked again once it ended: the same end, and nothing more.
            let again = try runtime.getUpdate(jobId: started.jobId, cursor: cursor)
            #expect(again.done && again.status == .complete && again.items.isEmpty && again.nextCursor == 50)
            #expect(throws: UnknownSearchJob.self) { try runtime.getUpdate(jobId: "search-0", cursor: 0) }
        }
    }

    @Test func stopsAtTheLimitAndSaysTheResultsWereCutOff() throws {
        let runtime = WalkSearchRuntime(limit: 10)
        defer { runtime.close() }
        try withTemporaryDirectory { folder in
            for index in 0..<30 { try makeSearchFile(folder.path + "/file-\(index).txt") }
            let (update, items) = try runWalk(runtime, SearchRequest(rootPath: folder.path, query: "file-"))
            #expect(items.count == 10)
            #expect(update.status == .truncated)
            #expect(update.truncated)
        }
    }

    @Test func saysWhenAFolderInsideCouldntBeReadAndIsStillComplete() throws {
        let runtime = WalkSearchRuntime()
        defer { runtime.close() }
        try withTemporaryDirectory { folder in
            try makeSearchFolder(folder.path + "/closed")
            try makeSearchFile(folder.path + "/closed/inside.txt")
            try makeSearchFile(folder.path + "/outside.txt")
            #expect(chmod(folder.path + "/closed", 0) == 0)
            defer { chmod(folder.path + "/closed", 0o755) }
            let (update, items) = try runWalk(runtime, SearchRequest(rootPath: folder.path, query: "side"))
            #expect(update.status == .complete)
            #expect(update.unreadableFolders)
            #expect(items.map(\.name) == ["outside.txt"])
            // The folder searched itself can't be read: the search fails.
            let (closed, _) = try runWalk(runtime, SearchRequest(rootPath: folder.path + "/closed", query: "side"))
            #expect(closed.status == .error)
        }
    }

    // A search of the startup disk leaves out other disks, searched from their own top, and the data volume, which
    // the firmlinks already reach.
    @Test func aSearchOfTheStartupDiskLeavesOutTheOtherVolumes() throws {
        let runtime = WalkSearchRuntime()
        defer { runtime.close() }
        let (update, items) = try runWalk(
            runtime, SearchRequest(rootPath: "/", query: "", recursive: false, includeHidden: true))
        #expect(update.status == .complete)
        let names = Set(items.map(\.name))
        #expect(names.contains("Users") && names.contains("System") && names.contains("Applications"))
        #expect(!names.contains("Volumes"))
        #expect(items.allSatisfy { $0.parentPath == "/" && $0.relativeParentPath == "." })
    }

    @Test func stoppingASearchEndsItsWalk() async throws {
        let runtime = WalkSearchRuntime()
        defer { runtime.close() }
        // Matches nothing, so the walk goes through the system library, some tenths of a second of work.
        let started = runtime.startSearch(
            SearchRequest(rootPath: "/System/Library", query: "filetrail-stop-test-\(UUID())"))
        #expect(runtime.walksRunning == 1)
        runtime.cancelSearch(jobId: started.jobId)
        #expect(try runtime.getUpdate(jobId: started.jobId, cursor: 0).status == .cancelled)
        #expect(try await waitUntil(seconds: 2) { runtime.walksRunning == 0 })
        // Stopping one unknown or already ended is fine.
        runtime.cancelSearch(jobId: started.jobId)
        runtime.cancelSearch(jobId: "search-999")
    }

    @Test func quittingStopsEverySearchAndForgetsThem() async throws {
        let runtime = WalkSearchRuntime()
        let jobs = (0..<3).map { _ in
            runtime.startSearch(SearchRequest(rootPath: "/System/Library", query: "filetrail-quit-test-\(UUID())"))
        }
        #expect(runtime.walksRunning == 3)
        runtime.close()
        #expect(try await waitUntil(seconds: 2) { runtime.walksRunning == 0 })
        for job in jobs {
            #expect(throws: UnknownSearchJob.self) { try runtime.getUpdate(jobId: job.jobId, cursor: 0) }
        }
    }

    @Test func remembersAtMostSixtyFourFinishedSearches() throws {
        let runtime = WalkSearchRuntime()
        defer { runtime.close() }
        try withTemporaryDirectory { folder in
            var ids: [String] = []
            for _ in 0..<70 {
                let (update, _) = try runWalk(runtime, SearchRequest(rootPath: folder.path, query: "x"))
                ids.append(update.jobId)
            }
            #expect(throws: UnknownSearchJob.self) { try runtime.getUpdate(jobId: ids[0], cursor: 0) }
            #expect(try runtime.getUpdate(jobId: ids[69], cursor: 0).done)
        }
    }
}
