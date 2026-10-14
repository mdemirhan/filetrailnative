// Checks the walker against the golden tools/parity/golden/folder-size-trees.ts recorded from the reference's native walker
import FTTestSupport
import Foundation
import Testing

@testable import FTFileSystem

private struct TreeEntry: Codable {
    var path: String
    var type: String
    var size: Int?
    var target: String?
    var mode: Int?
}

private struct TreeInput: Codable {
    var kind: String
    var path: String?
    var entries: [TreeEntry]?
}

private struct TreeOutput: Codable, Equatable {
    var total: Int64
    var diskTotal: Int64
    var fileCount: Int
    var folderCount: Int
    var dirs: [String: [Int64]]
}

private let fixtures: URL = {
    let cache =
        ProcessInfo.processInfo.environment["FILETRAIL_PORT_CACHE"]
        ?? NSHomeDirectory() + "/Library/Caches/filetrail-port"
    return URL(fileURLWithPath: cache).appendingPathComponent("fixtures")
}()

private let hasFixtures = FileManager.default.fileExists(atPath: fixtures.appendingPathComponent("names").path)

/// Builds `entries` in `root`, in order, and locks the locked folders last (deepest first); returns those.
private func build(_ entries: [TreeEntry], in root: String) throws -> [TreeEntry] {
    for entry in entries {
        let path = "\(root)/\(entry.path)"
        switch entry.type {
        case "dir":
            try makeFolder(path)
        case "file":
            try write(path, entry.size ?? 0)
        case "symlink":
            // Not through Foundation, which would spell a non-ASCII target another way: a link's size is its length.
            #expect(symlink(entry.target ?? "", path) == 0)
        default:
            break
        }
    }
    let locked = entries.filter { $0.type == "locked" }.sorted {
        $0.path.split(separator: "/").count > $1.path.split(separator: "/").count
    }
    for entry in locked {
        chmod("\(root)/\(entry.path)", mode_t(entry.mode ?? 0))
    }
    return locked
}

@MainActor
private func measureTree(_ root: String) async throws -> TreeOutput {
    let walk = try await measure(NativeFolderSize(), root)
    let prefix = root.hasSuffix("/") ? root : root + "/"
    var dirs: [String: [Int64]] = [:]
    for (path, totals) in walk.dirs {
        #expect(path.hasPrefix(prefix))
        dirs[String(path.dropFirst(prefix.count))] = [
            totals.sizeBytes, totals.diskBytes, Int64(totals.fileCount), Int64(totals.folderCount),
        ]
    }
    return TreeOutput(
        total: walk.result.total, diskTotal: walk.result.diskTotal, fileCount: walk.result.fileCount,
        folderCount: walk.result.folderCount, dirs: dirs)
}

extension RealWalks {
    @MainActor @Suite struct FolderSizeGoldenTests {
        // Machine-local: disk sizes (allocated blocks) depend on the volume, so this checks the port against what the
        // reference's walker said on the machine that recorded the golden.
        // F-179 F-180 F-181 F-182
        @Test(.enabled(if: hasFixtures, "needs the shared fixtures"))
        func theWalkerMatchesTheReferencesOnTheFixtureAndGeneratedTrees() async throws {
            let cases: [GoldenCase<TreeInput, TreeOutput>] = try Golden.load(suite: "folder-size-trees")
            #expect(!cases.isEmpty)
            var measured: [String: TreeOutput] = [:]
            for testCase in cases {
                let key = Golden.render(testCase.input)
                if testCase.input.kind == "fixture" {
                    measured[key] = try await measureTree(fixtures.path + "/" + (testCase.input.path ?? ""))
                    continue
                }
                let directory = try TemporaryDirectory(prefix: "ft-golden-sizes")
                defer { directory.remove() }
                let locked = try build(testCase.input.entries ?? [], in: directory.path)
                measured[key] = try await measureTree(directory.path)
                for entry in locked.reversed() {
                    chmod("\(directory.path)/\(entry.path)", 0o755)
                }
            }
            Golden.expectMatches(cases) { input in
                measured[Golden.render(input)]
                    ?? TreeOutput(total: -1, diskTotal: -1, fileCount: -1, folderCount: -1, dirs: [:])
            }
        }
    }
}
