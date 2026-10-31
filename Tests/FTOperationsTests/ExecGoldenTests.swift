// The write-engine differential (tools/parity/exec, FTTestSupport.ExecHarness). The analysis suites
// run through the Swift review (Exec/SwiftAnalysisEngine.swift), the execution suites through the
// Swift paste engine (Exec/SwiftExecEngine.swift), but for the stop and crash suites, which
// aren't injected (decided 2026-10-14). ReferenceReplayEngine replays every execution recording, which proves the decode,
// normalize and compare path, and each scenario's tree is built here and checked against the
// recorded "before".
import FTTestSupport
import Foundation
import Testing

struct ExecGoldenTests {
    /// Cases whose disk images exist here (tools/fixtures/disk-images.sh).
    private func runnable(_ cases: [ExecHarness.Case]) -> [ExecHarness.Case] {
        cases.filter { ($0.input.volumes ?? [:]).values.allSatisfy(ExecDiskImages.isAvailable) }
    }

    /// The suites the Swift engine runs: not stops or crashes, which aren't injected.
    static let engineSuites = ExecHarness.executionSuites.filter { $0 != "exec-stop" && $0 != "exec-crash" }

    /// The Swift paste engine against the reference's, case by case; the disk-image cases where the images exist.
    // F-242 F-257 F-258 F-259 F-260 F-261 F-263 F-269 F-270 F-271 F-272 F-273 F-276 F-277 F-278 F-279 F-280
    // F-282 F-283 F-284 F-285 F-286
    @Test(arguments: engineSuites)
    func executionMatchesItsRecording(suite: String) async throws {
        let cases = try ExecHarness.cases(suite: suite)
        #expect(!cases.isEmpty)
        let engine = SwiftExecEngine()
        for testCase in runnable(cases) {
            let lines = try await ExecHarness.check(testCase, with: engine)
            #expect(lines == nil, Comment(rawValue: "\(testCase.name): \(lines?.joined(separator: "; ") ?? "")"))
        }
    }

    @Test(arguments: ExecHarness.executionSuites)
    func replayedExecutionMatchesItsRecording(suite: String) async throws {
        let cases = try ExecHarness.cases(suite: suite)
        #expect(!cases.isEmpty)
        let report = try await ExecHarness.mismatchReport(suite: suite, engine: ReferenceReplayEngine(cases: cases))
        #expect(report == nil, Comment(rawValue: report ?? ""))
    }

    /// The Swift review (SwiftAnalysisEngine) against the reference's, case by case; the disk-image cases where
    /// the images exist.
    // F-241 F-309 F-310 F-311 F-312 F-314 F-315 F-316 F-317 F-318 F-319 F-320 F-321 F-322 F-323 F-926
    @Test(arguments: ExecHarness.analysisSuites)
    func analysisMatchesItsRecording(suite: String) async throws {
        let cases = try ExecHarness.cases(suite: suite)
        #expect(!cases.isEmpty)
        let engine = SwiftAnalysisEngine()
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

    /// The Undo differential (exec-undo): at least 30 cases of copies and moves undone and redone through the
    /// coordinator, with changes made outside the app before each, both answers to both questions, the Can't Undo of
    /// merges and of copies without a Trash, and Undos that left items as they were.
    // F-246 F-249 F-372 F-386 F-389 F-550 F-551 F-552
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

    /// The Swift batch rename (Exec/SwiftBatchRenameRun.swift) against the reference's (exec-batch-rename), case by
    /// case: each item as it starts, each rename on the disk, each journal write, the results, the undo record, the
    /// Rename sheet's checks, and after a crash what recovery made of it; the disk-image cases where the images exist.
    // F-119 F-245 F-356 F-396 F-397 F-398 F-399 F-400 F-401 F-402 F-403 F-562 F-563 F-564 F-565 F-566 F-567 F-569
    // F-570
    @Test func batchRenameMatchesItsRecording() async throws {
        let cases = try ExecBatchRenameHarness.cases()
        #expect(cases.count >= 60)
        for testCase in cases where ExecBatchRenameHarness.isRunnable(testCase) {
            let lines = try await ExecBatchRenameHarness.check(testCase, with: SwiftBatchRenameRun.engine)
            #expect(lines == nil, Comment(rawValue: "\(testCase.name): \(lines?.joined(separator: "; ") ?? "")"))
        }
    }

    /// exec-batch-rename holds what the brief asks: swaps, cycles, case-only changes on disks that ignore case and on
    /// one that minds it, stops, crashes with recovery, and the Rename sheet's checks.
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
