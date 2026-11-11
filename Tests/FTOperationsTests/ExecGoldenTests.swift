// The write-engine scenario checks. The analysis suites run through the Swift review (Exec/SwiftAnalysisEngine.swift),
// every execution suite through the Swift paste engine (Exec/SwiftExecEngine.swift): stopped as the Stop button does,
// and crashed right after a write of the journal, then recovered as the app does at start. RecordedReplayEngine
// replays every execution recording, which proves the decode, normalize and compare path, and each scenario's tree is
// built once for each engine check, which compares it with the recorded "before" with the rest.
import FTTestSupport
import Foundation
import Testing

struct ExecGoldenTests {

    /// The suites the Swift engine runs: every execution suite, stops and crashes included.
    static let engineSuites = ExecHarness.executionSuites

    /// The Swift paste engine against its recordings, case by case.
    @Test(arguments: engineSuites)
    func executionMatchesItsRecording(suite: String) async throws {
        let cases = try ExecHarness.cases(suite: suite)
        #expect(!cases.isEmpty)
        let engine = SwiftExecEngine()
        for testCase in cases {
            let lines = try await ExecHarness.check(testCase, with: engine)
            #expect(lines == nil, Comment(rawValue: "\(testCase.name): \(lines?.joined(separator: "; ") ?? "")"))
        }
    }

    @Test(arguments: ExecHarness.executionSuites)
    func replayedExecutionMatchesItsRecording(suite: String) async throws {
        let cases = try ExecHarness.cases(suite: suite)
        #expect(!cases.isEmpty)
        // A replay never looks at the disk: no tree is built for it, and no disk image mounted.
        let report = try await ExecHarness.mismatchReport(
            suite: suite, engine: RecordedReplayEngine(cases: cases), buildsTree: false)
        #expect(report == nil, Comment(rawValue: report ?? ""))
    }

    /// The Swift review (SwiftAnalysisEngine) against its recordings, case by case; the disk-image cases where the
    /// images exist.
    @Test(arguments: ExecHarness.analysisSuites)
    func analysisMatchesItsRecording(suite: String) async throws {
        let cases = try ExecHarness.cases(suite: suite)
        #expect(!cases.isEmpty)
        let engine = SwiftAnalysisEngine()
        for testCase in cases {
            let lines = try await ExecHarness.checkAnalysis(testCase, with: engine)
            #expect(lines == nil, Comment(rawValue: "\(testCase.name): \(lines?.joined(separator: "; ") ?? "")"))
        }
    }

    // Guards the shape of the recordings, not the engine.
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

    /// The Undo suite (exec-undo): at least 30 cases of copies and moves undone and redone through the
    /// coordinator, with changes made outside the app before each, both answers to both questions, the Can't Undo of
    /// merges and of copies without a Trash, and Undos that left items as they were. Guards the shape of the
    /// recordings, not the engine.
    @Test func undoSuiteCoversWhatTheBriefAsks() throws {
        let cases = try ExecHarness.cases(suite: "exec-undo")
        #expect(cases.count >= 30)
        let steps = cases.flatMap { $0.output["undo"]?["steps"]?.arrayValue ?? [] }
        #expect(cases.allSatisfy { ($0.output["undo"]?["steps"]?.arrayValue ?? []).count >= 1 })
        #expect(Set(cases.map { $0.input.paste.mode }) == ["copy", "cut"])
        #expect(cases.contains { !($0.input.undo?.changes ?? []).isEmpty })
        #expect(cases.contains { !($0.input.undo?.redoChanges ?? []).isEmpty })
        let asked = steps.flatMap { $0["asked"]?.arrayValue ?? [] }
        for kind in ["nameTaken", "changed"] {
            for answer in [true, false] {
                #expect(
                    asked.contains { $0["kind"]?.stringValue == kind && $0["answer"] == .bool(answer) },
                    Comment(rawValue: "\(kind) answered \(answer)"))
            }
        }
        #expect(steps.contains { $0["prepared"]?["refusal"]?.stringValue == "cant_undo" })
        let statuses = Set(steps.compactMap { $0["start"]?["status"]?.stringValue })
        #expect(statuses.isSuperset(of: ["completed", "partial", "failed"]))
        #expect(steps.contains { $0["direction"]?.stringValue == "redo" && $0["start"]?["status"] != nil })
    }

    /// "Apply to remaining" answers: a later conflict of the same kind is answered without a
    /// question, one the standing answer doesn't suit is asked again,
    /// and one of another kind is asked. Guards the shape of the recordings, not the engine.
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
    /// and the "failed" event and result it makes when the paste throws. Guards the shape of the recordings, not the
    /// engine.
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

    /// The Trash is the app's: on a disk without one, a Replace asks before
    /// deleting for good. Guards the shape of the recordings, not the engine.
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

    @Test func onlyASidecarsContentsMayDiffer() {
        func file(_ path: String, _ sha256: String, size: Int = 4096) -> JSONValue {
            .object(["path": .string(path), "sha256": .string(sha256), "size": .int(size)])
        }
        #expect(ExecDiff.differences(expected: file("d/._a", "1"), actual: file("d/._a", "2")).isEmpty)
        #expect(ExecDiff.differences(expected: file("._a", "1"), actual: file("._a", "1", size: 1)).count == 1)
        #expect(ExecDiff.differences(expected: file("d/a", "1"), actual: file("d/a", "2")).count == 1)
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

    /// The Swift batch rename (Exec/SwiftBatchRenameRun.swift) against its recordings (exec-batch-rename), case by
    /// case: each item as it starts, each rename on the disk, each journal write, the results, the undo record, the
    /// Rename sheet's checks, and after a crash what recovery made of it; the disk-image cases where the images exist.
    @Test func batchRenameMatchesItsRecording() async throws {
        let cases = try ExecBatchRenameHarness.cases()
        #expect(cases.count >= 60)
        for testCase in cases {
            let lines = try await ExecBatchRenameHarness.check(testCase, with: SwiftBatchRenameRun.engine)
            #expect(lines == nil, Comment(rawValue: "\(testCase.name): \(lines?.joined(separator: "; ") ?? "")"))
        }
    }

    /// exec-batch-rename holds the cases a batch rename is checked on: swaps, cycles, case-only changes on disks that
    /// ignore case and on one that minds it, stops, crashes with recovery, and the Rename sheet's checks. Guards the
    /// shape of the recordings, not the engine.
    @Test func batchRenameSuiteCoversWhatTheBriefAsks() throws {
        let cases = try ExecBatchRenameHarness.cases()
        let names = cases.map(\.name)
        for needed in [
            "a swap", "a cycle", "only the case of names changes",
            "two names that differ only in case swapped on apfs-cs",
        ] {
            #expect(names.contains(needed))
        }
        #expect(cases.contains { $0.input.volumes?.values.contains("fat32") == true })
        #expect(cases.contains { $0.input.stopAt != nil })
        let crashes = cases.filter { $0.input.crashAt != nil }
        #expect(crashes.count >= 10)
        #expect(crashes.allSatisfy { $0.output["recovery"] != .null })
        #expect(crashes.contains { ($0.output["recovery"]?["notices"]?.arrayValue ?? []).count > 0 })
        #expect(cases.contains { $0.output["inspect"] != .null })
    }

    private var emptyScenario: ExecScenario {
        ExecScenario(
            name: "empty", tree: [], paste: .init(mode: "copy", sources: [], destination: "d"),
            policy: .init(file: "skip", directory: "skip", mismatch: "skip"))
    }
}
