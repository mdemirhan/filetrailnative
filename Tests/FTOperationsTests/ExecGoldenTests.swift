// The write-engine differential (tools/parity/exec, FTTestSupport.ExecHarness). The Swift engine
// doesn't exist yet: ReferenceReplayEngine replays the recordings, which proves the decode,
// normalize and compare path, and each scenario's tree is built here and checked against the
// recorded "before", so the Swift engine will start where the reference did.
import FTTestSupport
import Foundation
import Testing

struct ExecGoldenTests {
    /// Cases whose disk images exist here (tools/fixtures/disk-images.sh).
    private func runnable(_ cases: [ExecHarness.Case]) -> [ExecHarness.Case] {
        cases.filter { ($0.input.volumes ?? [:]).values.allSatisfy(ExecDiskImages.isAvailable) }
    }

    @Test(arguments: ExecHarness.executionSuites)
    func replayedExecutionMatchesItsRecording(suite: String) async throws {
        let cases = try ExecHarness.cases(suite: suite)
        #expect(!cases.isEmpty)
        let report = try await ExecHarness.mismatchReport(suite: suite, engine: ReferenceReplayEngine(cases: cases))
        #expect(report == nil, Comment(rawValue: report ?? ""))
    }

    @Test(arguments: ExecHarness.analysisSuites)
    func replayedAnalysisMatchesItsRecording(suite: String) async throws {
        let cases = try ExecHarness.cases(suite: suite)
        let engine = ReferenceReplayEngine(cases: cases)
        for testCase in runnable(cases) {
            let lines = try await ExecHarness.checkAnalysis(testCase, with: engine)
            #expect(lines == nil, Comment(rawValue: "\(testCase.name): \(lines?.joined(separator: "; ") ?? "")"))
        }
    }

    @Test(arguments: ExecHarness.executionSuites + ExecHarness.analysisSuites)
    func scenarioTreesBuildHereAsRecorded(suite: String) throws {
        for testCase in runnable(try ExecHarness.cases(suite: suite)) {
            let lines = try ExecHarness.builtTreeDifferences(testCase)
            #expect(lines.isEmpty, Comment(rawValue: "\(testCase.name): \(lines.joined(separator: "; "))"))
        }
    }

    @Test func suitesCoverWhatTheBriefAsks() throws {
        let execution = try ExecHarness.executionSuites.flatMap { try ExecHarness.cases(suite: $0) }
        let analysis = try ExecHarness.analysisSuites.flatMap { try ExecHarness.cases(suite: $0) }
        #expect(execution.count >= 40)
        #expect(analysis.count >= 150)
        let crashes = execution.filter { $0.input.crashAt != nil }
        #expect(!crashes.isEmpty)
        #expect(crashes.allSatisfy { $0.output["recovery"] != JSONValue.null })
        #expect(execution.contains { $0.input.stopAt != nil })
        let answers = execution.flatMap { $0.output["events"]?.arrayValue ?? [] }
            .filter { $0["kind"]?.stringValue == "answer" }.compactMap { $0["answer"]?.stringValue }
        #expect(Set(answers) == ["overwrite", "merge", "keep_both", "skip"])
    }

    /// "Apply to remaining" answers: a later conflict of the same kind is answered without a
    /// question (writeService.ts autoResolve), one the standing answer doesn't suit is asked again,
    /// and one of another kind is asked.
    @Test func recordingsPinStandingAnswers() throws {
        let cases = try ExecHarness.cases(suite: "exec-runtime")
        func events(_ name: String) throws -> [JSONValue] {
            let found = try #require(cases.first { $0.name == name }, Comment(rawValue: name))
            #expect(found.input.applyToRemaining?.contains(true) == true)
            return found.output["events"]?.arrayValue ?? []
        }
        func questions(_ events: [JSONValue]) -> Int {
            events.filter { $0["status"]?.stringValue == "awaiting_resolution" }.count
        }
        let reused = try events("two files appear, Keep Both for the rest: the second isn't asked")
        #expect(questions(reused) == 1)
        #expect(reused.contains { $0["kind"]?.stringValue == "answer" && $0["applyToRemaining"] == .bool(true) })
        #expect(
            questions(try events("Overwrite for the rest, then a deleted source: asked again, as only Skip suits")) == 2
        )
        #expect(questions(try events("Merge for the rest, then a file inside: a file is asked about")) == 2)
    }

    /// The paste runs through the write service, whose own events are recorded: "queued" first,
    /// and the "failed" event and result it makes when the paste throws.
    @Test func recordingsHoldTheWriteServiceEvents() throws {
        let execution = try ExecHarness.executionSuites.flatMap { try ExecHarness.cases(suite: $0) }
        for testCase in execution {
            let first = (testCase.output["events"]?.arrayValue ?? []).first { $0["kind"]?.stringValue == "event" }
            if let first {
                #expect(first["status"]?.stringValue == "queued", Comment(rawValue: testCase.name))
            }
        }
        let failed = execution.filter { $0.output["result"]?["status"]?.stringValue == "failed" }
            .filter { $0.output["result"]?["summary"]?["completedItemCount"] == .int(0) }
            .filter { ($0.output["events"]?.arrayValue ?? []).last?["status"]?.stringValue == "failed" }
        #expect(!failed.isEmpty)
        #expect(execution.contains { ($0.input.stopAt?.afterEvent ?? 0) == 1 })
    }

    /// The Trash is the app's (createTrashItem): on a disk without one, a Replace asks before
    /// deleting for good.
    @Test func recordingsCoverADiskWithoutATrash() throws {
        let execution = try ExecHarness.executionSuites.flatMap { try ExecHarness.cases(suite: $0) }
        let trashless = execution.filter { !($0.input.volumesWithoutTrash ?? []).isEmpty }
        #expect(
            trashless.contains { testCase in
                (testCase.output["events"]?.arrayValue ?? []).contains {
                    $0["runtimeConflict"]?["reason"]?.stringValue == "trash_unavailable"
                }
            })
    }

    @Test func normalizationMapsPlacesHiddenNamesIdsAndDates() throws {
        let places = try ExecPlaces.make(for: emptyScenario)
        defer { places.remove() }
        let staging = places.root + "/d/.f.filetrail-0a1b2c3d"
        let raw: JSONValue = .object([
            "events": .array([
                .object([
                    "kind": .string("journal"),
                    "entries": .array([
                        .object([
                            "id": .string("00112233aabbccdd"), "stagingPath": .string(staging),
                            "finalPath": .string(places.root + "/d/f"),
                        ])
                    ]),
                ]),
                .object([
                    "kind": .string("event"), "operationId": .string("op-test"), "analysisId": .string("analysis-test"),
                    "runtimeConflict": .object([
                        "conflictId": .string("runtime-item-1-destination-7"),
                        "sourceFingerprint": .object([
                            "dev": .int(16_777_234), "ino": .int(99), "mtimeMs": .double(1.5),
                        ]),
                    ]),
                ]),
            ]),
            "result": .object([
                "startedAt": .string("2026-10-13T10:00:00Z"), "trashedPaths": .array([.string(places.trash + "/1-f")]),
                "error": .string(
                    "“f” is still in “\(places.root.replacingOccurrences(of: "/private/var/", with: "/var/"))/d”."),
            ]),
            "after": .array([
                .object(["path": .string("d/.f.filetrail-0a1b2c3d")]), .object(["path": .string("d/a")]),
            ]),
        ])
        let normalized = ExecNormalize.outcome(raw, places: places.tokens)
        let expected: JSONValue = .object([
            "after": .array([.object(["path": .string("d/.f.filetrail-~1")]), .object(["path": .string("d/a")])]),
            "events": .array([
                .object([
                    "kind": .string("journal"),
                    "entries": .array([
                        .object([
                            "id": .string("journal-1"), "stagingPath": .string("$ROOT/d/.f.filetrail-~1"),
                            "finalPath": .string("$ROOT/d/f"),
                        ])
                    ]),
                ]),
                .object([
                    "kind": .string("event"), "operationId": .string("operation"), "analysisId": .string("analysis"),
                    "runtimeConflict": .object([
                        "conflictId": .string("runtime-item-1-destination-q1"),
                        "sourceFingerprint": .object([
                            "dev": .string("dev-1"), "ino": .string("ino-1"), "mtimeMs": .string("set"),
                        ]),
                    ]),
                ]),
            ]),
            "result": .object([
                "trashedPaths": .array([.string("$TRASH/1-f")]), "error": .string("“f” is still in “$ROOT/d”."),
            ]),
        ])
        #expect(ExecDiff.differences(expected: expected, actual: normalized).isEmpty)
        // Normalizing twice changes nothing: a recording replayed comes out as recorded.
        #expect(ExecNormalize.outcome(normalized, places: places.tokens) == normalized)
    }

    @Test func differencesNameThePathAndBothValues() {
        let expected: JSONValue = .object([
            "events": .array([.object(["status": .string("running")]), .object(["status": .string("completed")])]),
            "name": .string("Cafe\u{301}"),
        ])
        let actual: JSONValue = .object([
            "events": .array([.object(["status": .string("running")])]), "name": .string("Caf\u{E9}"),
        ])
        let lines = ExecDiff.differences(expected: expected, actual: actual)
        #expect(
            lines == [
                #"events: expected 2 items, got 1; first missing {"status":"completed"}"#,
                "name: expected \"Cafe\u{301}\", got \"Caf\u{E9}\"",
            ])
    }

    private var emptyScenario: ExecScenario {
        ExecScenario(
            name: "empty", tree: [], paste: .init(mode: "copy", sources: [], destination: "d"),
            policy: .init(file: "skip", directory: "skip", mismatch: "skip"))
    }
}
