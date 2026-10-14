// The write-engine differential (PLAN.md §5.3), Swift side: runs the scenarios the reference
// engine was recorded on (Tests/Golden/exec-*.json, analysis-*.json, made by tools/parity/exec)
// through a Swift engine in fresh folders, normalizes what it reports exactly as run.ts does,
// and names the first differences. Until the Swift engine exists, ReferenceReplayEngine stands in.
import Foundation

/// What an engine did with a scenario, as recorded: absolute paths, its own hidden names and ids.
/// ExecHarness normalizes it (ExecNormalize) before comparing. The shape is run.ts's ScenarioOutcome.
public struct ExecOutcome: Codable, Sendable {
    /// After a crash: the startup recovery's report and log, and the tree, Trash and journal after it.
    public struct Recovery: Codable, Sendable {
        public var notices: [String]
        public var finished: [String]
        /// [{ level: "info" | "error", message, details }], as the recovery logged them.
        public var log: [JSONValue]
        public var after: [TreeSnapshot.Entry]
        public var trash: [TreeSnapshot.Entry]
        public var journal: JSONValue

        public init(
            notices: [String], finished: [String], log: [JSONValue], after: [TreeSnapshot.Entry],
            trash: [TreeSnapshot.Entry], journal: JSONValue
        ) {
            self.notices = notices
            self.finished = finished
            self.log = log
            self.after = after
            self.trash = trash
            self.journal = journal
        }
    }

    public var before: [TreeSnapshot.Entry]
    public var after: [TreeSnapshot.Entry]
    public var trash: [TreeSnapshot.Entry]
    /// In order, each with a `kind`:
    /// - "event": a progress event (CopyPasteProgressEvent without `result`), as the write service
    ///   sends them: "queued" first, and its own "failed" (with a result) or "cancelled" when the
    ///   paste throws;
    /// - "answer": { conflictId, allowed, answer, applyToRemaining } after the question's event
    ///   (and its changes); a conflict a standing answer covers has no question and no answer;
    /// - "journal": { write: n, entries } after each write of the journal file;
    /// - "change": { ops } when a scenario change was made; "stop": the paste was stopped;
    /// - "crash": { afterJournalWrite }; "issues": { issues } when the review refused the paste;
    /// - "error": { message } when the engine threw.
    public var events: [JSONValue]
    /// The paste's result without its undo log; null when it never finished.
    public var result: JSONValue
    public var undoLog: JSONValue
    /// The journal file when the engine was done (or killed); [] when never written.
    public var journal: JSONValue
    public var recovery: Recovery?

    public init(
        before: [TreeSnapshot.Entry], after: [TreeSnapshot.Entry], trash: [TreeSnapshot.Entry], events: [JSONValue],
        result: JSONValue, undoLog: JSONValue, journal: JSONValue, recovery: Recovery?
    ) {
        self.before = before
        self.after = after
        self.trash = trash
        self.events = events
        self.result = result
        self.undoLog = undoLog
        self.journal = journal
        self.recovery = recovery
    }

    /// As JSON, every key present (a missing recovery is null), as run.ts writes it.
    public func json() throws -> JSONValue {
        let recoveryValue: JSONValue
        if let recovery {
            recoveryValue = .object([
                "notices": .array(recovery.notices.map { .string($0) }),
                "finished": .array(recovery.finished.map { .string($0) }),
                "log": .array(recovery.log),
                "after": try JSONValue.of(recovery.after),
                "trash": try JSONValue.of(recovery.trash),
                "journal": recovery.journal,
            ])
        } else {
            recoveryValue = .null
        }
        return .object([
            "before": try JSONValue.of(before),
            "after": try JSONValue.of(after),
            "trash": try JSONValue.of(trash),
            "events": .array(events),
            "result": result,
            "undoLog": undoLog,
            "journal": journal,
            "recovery": recoveryValue,
        ])
    }
}

/// The Swift write engine, as the differential drives it, through its write service as the app
/// does. `places` already holds the scenario's tree; the engine pastes `scenario.paste` with its
/// policy and overrides, uses `places.trashFor` as the Trash, failing as on a disk without one
/// where `places.hasTrash` is false (and has none when `scenario.trash == false`), and
/// `places.journal` as its journal file, makes `scenario.changes` at their points
/// (ExecScenario.applyChanges), answers runtime questions from `answers` in order ("skip" once
/// they run out), each "for the rest of this operation" where `scenario.applyToRemaining` says,
/// stops after event `stopAt` as the Stop button does (a question still open goes unanswered),
/// and at `crashAt` is killed right after that journal write and recovered. It reports with the
/// ids "analysis-test" and "op-test" (normalized either way).
public protocol ExecEngine: Sendable {
    func run(
        _ scenario: ExecScenario, answers: [String], stopAt: ExecScenario.StopPoint?, crashAt: ExecScenario.CrashPoint?,
        in places: ExecPlaces
    ) async throws -> ExecOutcome
}

/// The Swift paste analysis, as the differential drives it: returns, for the tree in `places`,
/// { before, report, allConflictsChoices, choices, resolved } as tools/parity/exec/analysis.ts does.
public protocol ExecAnalysisEngine: Sendable {
    func analyze(_ scenario: ExecScenario, in places: ExecPlaces) async throws -> JSONValue
}

/// Returns what the reference recorded, so the decode, normalize and compare path is proven
/// before the Swift engine exists.
public struct ReferenceReplayEngine: ExecEngine, ExecAnalysisEngine {
    public struct Unknown: Error, CustomStringConvertible {
        public let description: String
    }

    private let outputs: [String: JSONValue]

    public init(cases: [ExecHarness.Case]) {
        outputs = Dictionary(cases.map { ($0.name, $0.output) }, uniquingKeysWith: { first, _ in first })
    }

    public func run(
        _ scenario: ExecScenario, answers: [String], stopAt: ExecScenario.StopPoint?, crashAt: ExecScenario.CrashPoint?,
        in places: ExecPlaces
    ) async throws -> ExecOutcome {
        try recorded(scenario).decode(ExecOutcome.self)
    }

    public func analyze(_ scenario: ExecScenario, in places: ExecPlaces) async throws -> JSONValue {
        try recorded(scenario)
    }

    private func recorded(_ scenario: ExecScenario) throws -> JSONValue {
        guard let output = outputs[scenario.name] else {
            throw Unknown(description: "no recording of “\(scenario.name)”")
        }
        return output
    }
}

public enum ExecHarness {
    public typealias Case = GoldenCase<ExecScenario, JSONValue>

    public static let executionSuites = [
        "exec-copy", "exec-cut", "exec-runtime", "exec-stop", "exec-crash", "exec-volumes",
    ]
    public static let analysisSuites = ["analysis-cases", "analysis-random", "analysis-volumes"]

    public static func cases(suite: String, in filePath: String = #filePath) throws -> [Case] {
        try Golden.load(suite: suite, in: filePath)
    }

    /// Runs one execution case through `engine` in fresh folders. Nil when the normalized outcome
    /// matches the recording; else its first differences, one per line.
    public static func check(_ testCase: Case, with engine: some ExecEngine, limit: Int = 10) async throws -> [String]?
    {
        let scenario = testCase.input
        let places = try ExecPlaces.make(for: scenario)
        defer { places.remove() }
        try scenario.build(in: places)
        let outcome = try await engine.run(
            scenario, answers: scenario.answers ?? [], stopAt: scenario.stopAt, crashAt: scenario.crashAt, in: places)
        return compare(expected: testCase.output, raw: try outcome.json(), places: places, limit: limit)
    }

    /// Runs one analysis case through `engine` in fresh folders, as `check` does.
    public static func checkAnalysis(_ testCase: Case, with engine: some ExecAnalysisEngine, limit: Int = 10)
        async throws
        -> [String]?
    {
        let places = try ExecPlaces.make(for: testCase.input)
        defer { places.remove() }
        try testCase.input.build(in: places)
        let raw = try await engine.analyze(testCase.input, in: places)
        return compare(expected: testCase.output, raw: raw, places: places, limit: limit)
    }

    /// The differences between a recording and a raw outcome once normalized, or nil.
    public static func compare(expected: JSONValue, raw: JSONValue, places: ExecPlaces, limit: Int = 10) -> [String]? {
        let lines = ExecDiff.differences(
            expected: expected, actual: ExecNormalize.outcome(raw, places: places.tokens), limit: limit)
        return lines.isEmpty ? nil : lines
    }

    /// Every case of `suite` through `engine`: nil when all match, else a count and, for the first
    /// `limit` cases that differ, their name and first differences.
    public static func mismatchReport(
        suite: String, engine: some ExecEngine, limit: Int = 5, in filePath: String = #filePath
    ) async throws -> String? {
        let all = try cases(suite: suite, in: filePath)
        var reports: [String] = []
        var count = 0
        for testCase in all {
            guard let lines = try await check(testCase, with: engine, limit: 3) else { continue }
            count += 1
            if reports.count < limit {
                reports.append(([testCase.name] + lines.map { "  " + $0 }).joined(separator: "\n"))
            }
        }
        return count == 0
            ? nil : (["\(count) of \(all.count) \(suite) cases differ:"] + reports).joined(separator: "\n")
    }

    /// Builds the case's tree here and names how its snapshot differs from the recorded `before`.
    public static func builtTreeDifferences(_ testCase: Case, limit: Int = 5) throws -> [String] {
        let places = try ExecPlaces.make(for: testCase.input)
        defer { places.remove() }
        try testCase.input.build(in: places)
        let before = ExecNormalize.outcome(
            .object(["before": try JSONValue.of(try places.snapshotTree())]), places: places.tokens)["before"]
        return ExecDiff.differences(expected: testCase.output["before"] ?? .null, actual: before ?? .null, limit: limit)
    }
}
