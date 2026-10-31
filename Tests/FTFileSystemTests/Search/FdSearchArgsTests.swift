// Port of the buildFdSearchArgs cases of packages/core/src/search/fdSearch.test.ts
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTFileSystem

private func request(
    root: String = "/Users/demo/project", query: String = "cfg", mode: SearchPatternModePreference = .regex,
    scope: SearchMatchScopePreference = .name, recursive: Bool = true, hidden: Bool = false,
    gitFolders: Bool = false, gitIgnored: Bool = false
) -> SearchRequest {
    SearchRequest(
        rootPath: root, query: query, patternMode: mode, matchScope: scope, recursive: recursive, includeHidden: hidden,
        skipGitFolders: gitFolders, skipGitIgnored: gitIgnored)
}

@Suite struct FdSearchArgsTests {
    // T-43cff062
    // B-SRCH-170 B-SRCH-174
    @Test func buildsArgsForGlobPathSearchesWithDepthAndHiddenFlags() {
        let args = FdSearchArgs.build(
            request(query: "src/*.ts", mode: .glob, scope: .path, recursive: false, hidden: true))
        #expect(
            args == [
                "--type", "f", "--type", "d", "--print0", "--absolute-path", "--color", "never", "--no-ignore",
                "--glob",
                "--full-path", "--max-depth", "1", "--hidden", "--", "src/*.ts", "/Users/demo/project",
            ])
    }

    // T-4db03fbc
    // B-SRCH-171 B-SRCH-172
    @Test func skipsGitFoldersAndGitIgnoredFilesOnlyWhenAskedTo() {
        func flags(folders: Bool, ignored: Bool) -> [String] {
            let args = FdSearchArgs.build(request(hidden: true, gitFolders: folders, gitIgnored: ignored))
            return Array(args[8..<(args.count - 3)])
        }
        // Nothing skipped: fd is told not to read ignore files at all.
        #expect(flags(folders: false, ignored: false) == ["--no-ignore", "--hidden"])
        // `.git` is not in any ignore file; with hidden files included it needs its own exclude.
        #expect(flags(folders: true, ignored: false) == ["--no-ignore", "--exclude", ".git", "--hidden"])
        // Ignored files: fd's default behavior, so the flag that disables it is left out.
        #expect(flags(folders: false, ignored: true) == ["--hidden"])
        #expect(flags(folders: true, ignored: true) == ["--exclude", ".git", "--hidden"])
    }

    // T-d1d5f835
    // B-SRCH-173
    @Test func searchesMacintoshHDWithoutTheOtherDisksMountedAtVolumes() {
        func args(_ root: String) -> String {
            FdSearchArgs.build(request(root: root, query: "report", mode: .text, gitFolders: false)).joined(
                separator: " ")
        }
        #expect(args("/").contains("--exclude /Volumes"))
        // A disk, or a folder named Volumes deeper down, is searched as usual.
        #expect(!args("/Volumes/Backup").contains("--exclude"))
        #expect(!args("/Users/demo").contains("--exclude"))
    }

    // T-1fb059e6
    @Test func matchesTheQueryLiterallyInPlainTextModeAndAsAPatternOtherwise() {
        func args(_ mode: SearchPatternModePreference) -> [String] {
            FdSearchArgs.build(request(query: "report (1).pdf", mode: mode))
        }
        #expect(args(.text).contains("--fixed-strings"))
        #expect(!args(.text).contains("--glob"))
        #expect(args(.glob).contains("--glob"))
        #expect(!args(.glob).contains("--fixed-strings"))
        #expect(!args(.regex).contains("--fixed-strings"))
        #expect(!args(.regex).contains("--glob"))
        // The query itself is always passed through untouched.
        #expect(Array(args(.text).suffix(2)) == ["report (1).pdf", "/Users/demo/project"])
    }

    // T-d3ef54f8
    // B-SRCH-175
    @Test func endsOptionParsingBeforeTheQuerySoALeadingDashIsNotAnFdFlag() {
        let args = FdSearchArgs.build(request(query: "-xrm", scope: .path))
        #expect(Array(args.suffix(3)) == ["--", "-xrm", "/Users/demo/project"])
    }

    // The golden: every combination of the options, from the reference's own argument builder.
    @Test func matchesTheReferenceForEveryCombinationOfOptions() throws {
        let cases: [GoldenCase<SearchRequest, [String]>] = try Golden.load(suite: "search-args")
        #expect(cases.count > 300)
        Golden.expectMatches(cases) { FdSearchArgs.build($0) }
    }
}
