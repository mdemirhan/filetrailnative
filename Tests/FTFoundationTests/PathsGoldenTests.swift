import FTTestSupport
import Testing

@testable import FTFoundation

struct PathsGoldenTests {
    struct TrashInput: Codable, Sendable {
        let path: String
        let homePath: String
    }

    struct TrashOutput: Codable, Equatable, Sendable {
        let insideTrash: Bool
        let trashFolder: Bool
    }

    @Test func withoutNestedPathsMatchesTheGoldenFile() throws {
        let cases: [GoldenCase<[String], [String]>] = try Golden.load(suite: "paths-nested")
        #expect(cases.count == 36)
        Golden.expectMatches(cases) { Paths.withoutNestedPaths($0) }
    }

    @Test func trashChecksMatchTheGoldenFile() throws {
        let cases: [GoldenCase<TrashInput, TrashOutput>] = try Golden.load(suite: "trash-paths")
        #expect(cases.count == 68)
        Golden.expectMatches(cases) {
            TrashOutput(
                insideTrash: Paths.isInsideTrash($0.path, homePath: $0.homePath),
                trashFolder: Paths.isTrashFolder($0.path, homePath: $0.homePath))
        }
    }

    // Over many paths made from a few names, the root and accents stored both ways: what is kept is the paths picked,
    // in their order, each once, none inside another picked, and every path left out repeats one or is inside one.
    @Test func withoutNestedPathsKeepsOnlyTheOutermostOverManyPaths() {
        var random = SeededGenerator(seed: 0x5EED_0001)
        let names = ["a", "b", "ab", "a b", "caf\u{E9}", "cafe\u{301}", ".x", "A"]
        func bytes(_ path: String) -> [UInt8] { Array(path.utf8) }
        func inside(_ path: String, _ folder: String) -> Bool {
            if folder == "/" { return path != "/" && path.hasPrefix("/") }
            return bytes(path).starts(with: bytes(folder) + [UInt8(ascii: "/")])
        }
        for _ in 0..<500 {
            let paths = (0..<Int.random(in: 0...8, using: &random)).map { _ -> String in
                let depth = Int.random(in: 0...3, using: &random)
                guard depth > 0 else { return "/" }
                return "/" + (0..<depth).map { _ in names.randomElement(using: &random)! }.joined(separator: "/")
            }
            let kept = Paths.withoutNestedPaths(paths)
            // In their order, each once.
            var rest = paths.map(bytes)[...]
            #expect(
                kept.allSatisfy { path in rest.firstIndex(of: bytes(path)).map { rest = rest[($0 + 1)...] } != nil })
            #expect(Set(kept.map(bytes)).count == kept.count, "\(paths)")
            for path in kept {
                #expect(!paths.contains { inside(path, $0) }, "\(path) is inside another of \(paths)")
            }
            for path in paths where !kept.contains(where: { bytes($0) == bytes(path) }) {
                #expect(paths.contains { inside(path, $0) }, "\(path) left out of \(paths)")
            }
        }
    }

    @Test func nfcAndNfdAreDifferentPaths() {
        #expect(Paths.withoutNestedPaths(["/Caf\u{E9}", "/Cafe\u{301}/x"]).count == 2)
        #expect(Paths.withoutNestedPaths(["/Caf\u{E9}", "/Cafe\u{301}"]).count == 2)
        #expect(Paths.withoutNestedPaths(["/a", "/a/\u{301}"]) == ["/a"])
    }

    @Test func mismatchReportListsOnlyTheFirstTen() throws {
        let cases = (0..<25).map { GoldenCase(name: "case \($0)", input: $0, output: $0) }
        let report = try #require(Golden.mismatchReport(cases) { $0 + 1 })
        let lines = report.split(separator: "\n")
        #expect(lines.count == 11)
        #expect(lines.first == "25 of 25 golden cases differ; the first 10:")
        #expect(lines.last == "case 9 | input: 9 | expected: 9 | actual: 10")
        #expect(Golden.mismatchReport(cases) { $0 } == nil)
    }

    @Test func mismatchReportTellsNfcFromNfd() {
        let cases = [GoldenCase(name: "nfd", input: 0, output: "e\u{301}")]
        #expect(Golden.mismatchReport(cases) { _ in "\u{E9}" } != nil)
    }
}
