import FTTestSupport
import Foundation
import Testing

@testable import FTFileSystem

/// The goldens recorded on the fixture trees (`~/Library/Caches/filetrail-dev/fixtures`): skipped where
/// they aren't.
enum Fixtures {
    static var root: String {
        let cache =
            ProcessInfo.processInfo.environment["FILETRAIL_DEV_CACHE"]
            ?? NSHomeDirectory() + "/Library/Caches/filetrail-dev"
        return cache + "/fixtures"
    }

    static var available: Bool {
        FileManager.default.fileExists(atPath: root + "/names/.fixture-version")
            && FileManager.default.fileExists(atPath: root + "/lighthouse/.fixture-version")
    }

    /// The real path of the fixtures folder, as the listing reports paths.
    static var realRoot: String {
        (try? NativeFileSystem().realpath(root)) ?? root
    }

    static func relative(_ path: String) -> String {
        let prefix = realRoot + "/"
        if path == realRoot { return "" }
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : "OUTSIDE:" + path
    }
}

struct FixtureGoldenTests {
    struct ClassifyInput: Codable, Sendable { var directory: String }

    @Test("classify golden", .enabled(if: Fixtures.available, "needs the fixture trees"))
    func classifiesAsTheGoldenFileSays() async throws {
        let cases: [GoldenCase<ClassifyInput, JSONValue>] = try Golden.load(suite: "classify")
        #expect(cases.count > 30)
        let service = DirectoryService(kinds: KindLabeler(describer: nil))
        var failures: [String] = []
        for testCase in cases {
            let path = Fixtures.root + "/" + testCase.input.directory
            let byName = try await service.snapshot(path: path, includeHidden: true)
            let bySize = try await service.snapshot(
                path: path, includeHidden: true, sortBy: .size, sortDirection: .descending)
            let tree = try await service.treeChildren(path: path, includeHidden: true)
            var properties: [JSONValue] = []
            for entry in byName.entries {
                let item = await service.itemProperties(path: entry.path)
                properties.append(
                    .object([
                        "path": .string(Fixtures.relative(item.path)), "name": .string(item.name),
                        "extension": .string(item.fileExtension), "kind": .string(item.kind.rawValue),
                        "kindLabel": .string(item.kindLabel), "isHidden": .bool(item.isHidden),
                        "isSymlink": .bool(item.isSymlink), "sizeBytes": .optional(item.sizeBytes),
                        "sizeStatus": .string(item.sizeStatus.rawValue),
                    ]))
            }
            func entry(_ entry: DirectoryEntry, sized: Bool) -> JSONValue {
                var fields: [String: JSONValue] = [
                    "path": .string(Fixtures.relative(entry.path)), "name": .string(entry.name),
                    "extension": .string(entry.fileExtension), "kind": .string(entry.kind.rawValue),
                    "isHidden": .bool(entry.isHidden), "isSymlink": .bool(entry.isSymlink),
                ]
                if let executable = entry.isExecutable { fields["isExecutable"] = .bool(executable) }
                if sized { fields["sizeBytes"] = .optional(entry.sizeBytes) }
                return .object(fields)
            }
            let actual = JSONValue.object([
                "byName": .array(byName.entries.map { entry($0, sized: false) }),
                "bySize": .array(bySize.entries.map { entry($0, sized: true) }),
                "tree": .array(
                    tree.children.map {
                        .object([
                            "path": .string(Fixtures.relative($0.path)), "name": .string($0.name),
                            "kind": .string($0.kind.rawValue), "isHidden": .bool($0.isHidden),
                            "isSymlink": .bool($0.isSymlink),
                        ])
                    }),
                "properties": .array(properties),
            ])
            if Golden.render(actual) != Golden.render(testCase.output) {
                failures.append(testCase.name)
            }
        }
        #expect(failures.isEmpty, "\(failures.count) folders differ: \(failures.prefix(5).joined(separator: ", "))")
    }

    struct SuggestionInput: Codable, Sendable {
        var path: String
        var includeHidden: Bool
        var limit: Int
    }

    @Test("path-suggestions golden", .enabled(if: Fixtures.available, "needs the fixture trees"))
    func suggestsAsTheGoldenFileSays() async throws {
        let cases: [GoldenCase<SuggestionInput, JSONValue>] = try Golden.load(suite: "path-suggestions")
        #expect(cases.count == 200)
        let service = DirectoryService()
        var failures: [String] = []
        for testCase in cases {
            let input = Fixtures.root + "/" + testCase.input.path
            let response = try await service.pathSuggestions(
                inputPath: input, includeHidden: testCase.input.includeHidden, limit: testCase.input.limit)
            // Where the path really leads.
            let resolved = try? NativeFileSystem().realpath(ExplorerListing.resolve(input))
            let actual = JSONValue.object([
                "basePath": .optional(response.basePath.map(Fixtures.relative)),
                "suggestions": .array(
                    response.suggestions.map {
                        .object(["path": .string(Fixtures.relative($0.path)), "name": .string($0.name)])
                    }),
                "resolved": .optional(resolved.map(Fixtures.relative)),
            ])
            if Golden.render(actual) != Golden.render(testCase.output) {
                failures.append(
                    "\(testCase.name) expected \(Golden.render(testCase.output)) got \(Golden.render(actual))")
            }
        }
        #expect(failures.isEmpty, "\(failures.count) cases differ: \(failures.prefix(3).joined(separator: " | "))")
    }
}

extension JSONValue {
    fileprivate static func optional(_ value: String?) -> JSONValue { value.map(JSONValue.string) ?? .null }
    fileprivate static func optional(_ value: Int64?) -> JSONValue { value.map { .int(Int($0)) } ?? .null }
}
