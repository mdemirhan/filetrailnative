// Execution goldens recorded from the reference copy engine (tools/parity/exec/run.ts). The Swift
// engine doesn't exist yet: this checks the golden decodes and that its "before" tree is what the
// scenario builds here, so TreeSnapshot and run.ts agree on the starting point.
import FTTestSupport
import Testing

struct ExecGoldenTests {
    @Test func copySingleGoldenDecodesAndItsTreeBuildsHere() throws {
        let cases: [GoldenCase<ExecScenario, ExecScenario.Outcome>] = try Golden.load(suite: "exec-copy-single")
        let testCase = try #require(cases.first)
        #expect(testCase.output.statuses.last == "completed")
        #expect(testCase.output.after.map(\.path).contains("destination/notes.txt"))
        let before = try withTemporaryDirectory { directory in
            try testCase.input.build(in: directory.path)
            return try TreeSnapshot.entries(of: directory.path)
        }
        #expect(before == testCase.output.before)
    }
}
