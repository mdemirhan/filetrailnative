// What a release checks of the search's speed, on large folders every Mac has: each kind of search against the walk
// alone (a search that finds nothing), which tells what matching costs on any Mac, and loose ceilings against the walk
// itself going wrong. Run with FILETRAIL_RELEASE_TESTS=1 (`scripts/release.sh` sets it); the times are written to
// build/logs/search-speed.md for the release to show.
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTFileSystem

/// A large folder searched, and the longest a search of it may take.
private struct Folder {
    var path: String
    var ceiling: Double
}

/// Folders nothing writes to while the tests run (the system's are sealed), and the fixtures when they are there.
private let largeFolders: [Folder] = {
    var folders = [
        Folder(path: "/System/Library", ceiling: 3), Folder(path: "/Applications", ceiling: 3),
        Folder(path: "/usr", ceiling: 0.5),
    ]
    if FileManager.default.fileExists(atPath: Fixtures.root) {
        folders.append(Folder(path: Fixtures.root, ceiling: 0.3))
    }
    return folders
}()

/// A search of a large folder, as each kind of search a person makes.
private struct Scenario {
    var label: String
    var mode: SearchPatternModePreference
    var query: String
    var scope: SearchMatchScopePreference = .name
    var hidden = false
    var recursive = true

    func request(_ root: String) -> SearchRequest {
        SearchRequest(
            rootPath: root, query: query, patternMode: mode, matchScope: scope, recursive: recursive,
            includeHidden: hidden)
    }
}

/// The walk alone: a name nothing has.
private let walkAlone = Scenario(
    label: "Plain Text, nothing found", mode: .text, query: "filetrail-nothing-is-named-so")

private let scenarios: [Scenario] = [
    Scenario(label: "Plain Text, some found", mode: .text, query: "plist"),
    Scenario(label: "Plain Text, up to the limit", mode: .text, query: "e"),
    Scenario(label: "Plain Text, accented", mode: .text, query: "\u{E9}"),
    Scenario(label: "Plain Text, path", mode: .text, query: "Resources/en", scope: .path),
    Scenario(label: "Plain Text, long path", mode: .text, query: "Contents/Resources/en.lproj", scope: .path),
    Scenario(label: "Plain Text, hidden too", mode: .text, query: "plist", hidden: true),
    Scenario(label: "Plain Text, top folder only", mode: .text, query: "a", recursive: false),
    Scenario(label: "Glob", mode: .glob, query: "*.dylib"),
    Scenario(label: "Glob, path", mode: .glob, query: "**/Contents/Info.plist", scope: .path),
    Scenario(label: "Glob, alternatives", mode: .glob, query: "*.{plist,strings}"),
    Scenario(label: "Regex", mode: .regex, query: "\\.(png|jpe?g)$"),
    Scenario(label: "Regex, capitals", mode: .regex, query: "^[A-Z][a-z]+Kit$"),
    Scenario(label: "Regex, path", mode: .regex, query: "/Resources/[^/]+\\.lproj$", scope: .path),
    Scenario(label: "Regex, hidden too", mode: .regex, query: "\\.(png|jpe?g)$", hidden: true),
]

/// The longest a kind of search may take against the walk alone of the same folder: twice it, 50 ms more for a folder
/// walked in moments, and 5 µs for each result, which is made into an item and listed. A release runs a debug build:
/// there matching measured at most 1.59 times the walk alone (Regex of paths in /Applications), and making 31,898
/// results took 0.08 s.
private let matchingShare = 2.0
private let timePerResult = 0.000_005

private func repositoryRoot() -> URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
}

/// The best of three runs of a search, from its start to its last result.
private func bestTime(_ runtime: WalkSearchRuntime, _ request: SearchRequest) throws -> (Double, Int) {
    var best = Double.infinity
    var found = 0
    for _ in 0..<3 {
        let start = DispatchTime.now().uptimeNanoseconds
        let (_, items) = try runWalk(runtime, request)
        best = min(best, Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9)
        found = items.count
    }
    return (best, found)
}

@Suite(.serialized) struct WalkSearchReleaseTests {
    @Test(.enabled(if: ReleaseTests.enabled))
    func eachKindOfSearchCostsLittleMoreThanTheWalk() throws {
        let runtime = WalkSearchRuntime()
        defer { runtime.close() }
        var lines = [
            "# Search speed",
            "",
            "Best of three, on this Mac; written by `WalkSearchReleaseTests`. "
                + "Threads: \(WalkSearchRuntime.defaultThreads).",
            "",
            "| Folder | Search | Found | Time | Against the walk alone |",
            "|---|---|---|---|---|",
        ]
        for folder in largeFolders {
            // Once first, so the folders are read from memory.
            _ = try runWalk(runtime, walkAlone.request(folder.path))
            let (walk, _) = try bestTime(runtime, walkAlone.request(folder.path))
            lines.append("| \(folder.path) | \(walkAlone.label) | 0 | \(String(format: "%.3f", walk)) s | 1.00 |")
            #expect(walk <= folder.ceiling, "\(folder.path): the walk alone took \(walk) s")
            for scenario in scenarios {
                let (time, found) = try bestTime(runtime, scenario.request(folder.path))
                lines.append(
                    "| \(folder.path) | \(scenario.label) | \(found) | \(String(format: "%.3f", time)) s | "
                        + "\(String(format: "%.2f", time / walk)) |")
                #expect(time <= folder.ceiling, "\(folder.path) \(scenario.label): \(time) s")
                #expect(
                    time <= max(walk * matchingShare, walk + 0.05) + Double(found) * timePerResult,
                    "\(folder.path) \(scenario.label): \(time) s, the walk alone \(walk) s")
            }
        }
        let logs = repositoryRoot().appendingPathComponent("build/logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try lines.joined(separator: "\n").appending("\n").write(
            to: logs.appendingPathComponent("search-speed.md"), atomically: true, encoding: .utf8)
        print(lines.joined(separator: "\n"))
    }
}
