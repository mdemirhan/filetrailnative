@testable import FTFileSystem
import FTTestSupport
import Foundation
import Testing

/// Tests/Golden/listing-sort.json: listDirectorySnapshot and listTreeChildren of the reference over a fake
/// file system.
struct ListingSortGoldenTests {
    struct Item: Codable, Sendable {
        var name: String
        var type: String
        var target: String?
        var size: Int64
        var linkSize: Int64?
        var mtimeMs: Int64
        var mode: UInt32
    }

    struct Input: Codable, Sendable {
        var items: [Item]
        var includeHidden: Bool
        var sortBy: String
        var sortDirection: String
        var foldersFirst: Bool
    }

    struct Entry: Codable, Sendable {
        var name: String
        var `extension`: String
        var kind: String
        var isHidden: Bool
        var isSymlink: Bool
        var isExecutable: Bool?
        var sizeBytes: Int64?
        var hasSize: Bool

        init(_ entry: DirectoryEntry, sized: Bool) {
            name = entry.name
            self.extension = entry.fileExtension
            kind = entry.kind.rawValue
            isHidden = entry.isHidden
            isSymlink = entry.isSymlink
            isExecutable = entry.isExecutable
            sizeBytes = entry.sizeBytes
            hasSize = sized
        }

        private enum Keys: String, CodingKey {
            case name, `extension`, kind, isHidden, isSymlink, isExecutable, sizeBytes
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: Keys.self)
            name = try values.decode(String.self, forKey: .name)
            self.extension = try values.decode(String.self, forKey: .extension)
            kind = try values.decode(String.self, forKey: .kind)
            isHidden = try values.decode(Bool.self, forKey: .isHidden)
            isSymlink = try values.decode(Bool.self, forKey: .isSymlink)
            isExecutable = try values.decodeIfPresent(Bool.self, forKey: .isExecutable)
            hasSize = values.contains(.sizeBytes)
            sizeBytes = try values.decodeIfPresent(Int64.self, forKey: .sizeBytes)
        }

        /// Like the reference's JSON: `sizeBytes` is null when sorted by size and the entry has none, and
        /// left out when not sorted by size.
        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: Keys.self)
            try values.encode(name, forKey: .name)
            try values.encode(self.extension, forKey: .extension)
            try values.encode(kind, forKey: .kind)
            try values.encode(isHidden, forKey: .isHidden)
            try values.encode(isSymlink, forKey: .isSymlink)
            try values.encodeIfPresent(isExecutable, forKey: .isExecutable)
            if hasSize { try values.encode(sizeBytes, forKey: .sizeBytes) }
        }
    }

    struct TreeEntry: Codable, Sendable {
        var name: String
        var kind: String
    }

    struct Output: Codable, Sendable {
        var entries: [Entry]
        var tree: [TreeEntry]
    }

    static let directory = "/golden"

    static func fileSystem(_ items: [Item]) -> FakeFileSystem {
        let fake = FakeFileSystem()
        let byPath = Dictionary(uniqueKeysWithValues: items.map { ("\(directory)/\($0.name)", $0) })
        @Sendable func stats(_ kind: String, _ item: Item, size: Int64) -> FileStats {
            let type: FileType = kind == "dir" ? .directory : kind == "file" ? .file : kind == "link" ? .symlink : .other
            return FileStats(
                type: type, size: size, birthtimeMs: 1_700_000_000_000, mtimeMs: item.mtimeMs,
                mode: type == .directory ? 0o755 : item.mode)
        }
        fake.directory = { _ in
            items.map { item in
                let type: FileType =
                    item.type == "dir" ? .directory : item.type == "file" || item.type == "unreadable" ? .file
                    : item.type == "link" ? .symlink : .other
                return DirectoryRecord(name: item.name, type: type)
            }
        }
        fake.statHandler = { path in
            if path == directory { return stats("dir", Item(name: "", type: "dir", size: 0, mtimeMs: 0, mode: 0o755), size: 0) }
            guard let item = byPath[path], item.type != "unreadable" else { throw FakeError() }
            if item.type == "link" {
                guard let target = item.target, target != "missing" else { throw FakeError() }
                return stats(target, item, size: item.size)
            }
            return stats(item.type, item, size: item.size)
        }
        fake.lstatHandler = { path in
            guard let item = byPath[path], item.type != "unreadable" else { throw FakeError() }
            if item.type == "link" { return stats("link", item, size: item.linkSize ?? 0) }
            return stats(item.type, item, size: item.size)
        }
        return fake
    }

    static func firstDifference(_ expected: Output, _ actual: Output) -> String {
        for (index, pair) in zip(expected.entries, actual.entries).enumerated()
        where Golden.render(pair.0) != Golden.render(pair.1) {
            return "entry \(index): expected \(Golden.render(pair.0)), got \(Golden.render(pair.1))"
        }
        for (index, pair) in zip(expected.tree, actual.tree).enumerated()
        where Golden.render(pair.0) != Golden.render(pair.1) {
            return "tree \(index): expected \(pair.0.name), got \(pair.1.name)"
        }
        return "counts \(expected.entries.count)/\(actual.entries.count) \(expected.tree.count)/\(actual.tree.count)"
    }

    @Test("Tests/Golden/listing-sort.json")
    func sortsAsTheReferenceDoes() async throws {
        let cases: [GoldenCase<Input, Output>] = try Golden.load(suite: "listing-sort")
        #expect(cases.count >= 300)
        var lines: [String] = []
        var failures = 0
        for testCase in cases {
            let input = testCase.input
            let service = DirectoryService(
                fileSystem: Self.fileSystem(input.items), cache: ResponseCache(),
                kinds: KindLabeler(describer: nil))
            let sortBy = try #require(DirectorySortKey(rawValue: input.sortBy))
            let direction = try #require(SortDirection(rawValue: input.sortDirection))
            let snapshot = try await service.snapshot(
                path: Self.directory, includeHidden: input.includeHidden, sortBy: sortBy, sortDirection: direction,
                foldersFirst: input.foldersFirst)
            let tree = try await service.treeChildren(path: Self.directory, includeHidden: input.includeHidden)
            let actual = Output(
                entries: snapshot.entries.map { Entry($0, sized: sortBy == .size) },
                tree: tree.children.map { TreeEntry(name: $0.name, kind: $0.kind.rawValue) })
            if Golden.render(actual) != Golden.render(testCase.output) {
                failures += 1
                if lines.count < 5 {
                    lines.append("\(testCase.name): \(Self.firstDifference(testCase.output, actual))")
                }
            }
        }
        #expect(failures == 0, "\(failures) of \(cases.count) cases differ: \(lines.joined(separator: " | "))")
    }
}
