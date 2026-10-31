// Port of packages/contracts/src/paths.test.ts and trash.test.ts, checked against goldens recorded
// from the reference (tools/parity/golden/paths-nested.ts and trash-paths.ts).
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

    @Test func withoutNestedPathsMatchesTheReference() throws {
        let cases: [GoldenCase<[String], [String]>] = try Golden.load(suite: "paths-nested")
        #expect(cases.count >= 300)
        Golden.expectMatches(cases) { Paths.withoutNestedPaths($0) }
    }

    @Test func trashChecksMatchTheReference() throws {
        let cases: [GoldenCase<TrashInput, TrashOutput>] = try Golden.load(suite: "trash-paths")
        #expect(cases.count >= 300)
        Golden.expectMatches(cases) {
            TrashOutput(
                insideTrash: Paths.isInsideTrash($0.path, homePath: $0.homePath),
                trashFolder: Paths.isTrashFolder($0.path, homePath: $0.homePath))
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
