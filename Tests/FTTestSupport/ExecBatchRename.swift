// The batch-rename scenarios of tools/parity/exec/batch-rename.ts (suite exec-batch-rename): the
// scenario, its cases, and running one through an engine in fresh folders to compare with its
// recording.
import Foundation

public struct ExecBatchRenameScenario: Codable, Equatable, Sendable {
    public struct Request: Codable, Equatable, Sendable {
        public struct Item: Codable, Equatable, Sendable {
            /// Scenario-relative.
            public var path: String
            public var destinationName: String
            public var isFolder: Bool
        }

        public var items: [Item]
        /// "number", "skip" or "block".
        public var onConflict: String
        public var numberSeparator: String
    }

    /// Stop as the item with this many done starts, or right after this many renames (0: before anything).
    public struct StopPoint: Codable, Equatable, Sendable {
        public var itemStart: Int?
        public var afterMoves: Int?
    }

    /// Crash right after the n-th journal write, or the n-th rename.
    public struct CrashPoint: Codable, Equatable, Sendable {
        public var journalWrite: Int?
        public var afterMoves: Int?
    }

    public struct Inspect: Codable, Equatable, Sendable {
        public var paths: [String]
        public var includeDateTaken: Bool
    }

    public var name: String
    public var tree: [ExecScenario.Item]
    public var batchRename: Request
    public var stopAt: StopPoint?
    public var crashAt: CrashPoint?
    public var inspect: Inspect?
    public var volumes: [String: String]?

    /// The same tree and disks, as `ExecPlaces` and `ExecScenario.build` make them.
    public var placesScenario: ExecScenario {
        ExecScenario(
            name: name, tree: tree, paste: .init(mode: "copy", sources: [], destination: ""),
            policy: .init(file: "skip", directory: "skip", mismatch: "skip"), volumes: volumes)
    }

    /// `temporaryNames`: the hidden names items wait under, counted up so both engines give the same ones.
    public static func temporaryNames() -> () -> String {
        var count = 0
        return {
            count += 1
            let hex = String(count, radix: 16)
            return ".filetrail-rename-" + String(repeating: "0", count: max(0, 12 - hex.count)) + hex
        }
    }

    /// `maskInspection`: the dates the disk gives depend on when the tree was made, so only whether each is there
    /// counts; folder names in JavaScript's order.
    public static func maskInspection(_ answer: JSONValue) -> JSONValue {
        guard case .object(var members) = answer else { return answer }
        if case .array(let items) = members["items"] {
            members["items"] = .array(
                items.map { item in
                    guard case .object(var fields) = item else { return item }
                    for key in ["createdAt", "modifiedAt"] {
                        if let value = fields[key], value != .null {
                            fields[key] = .string("set")
                        }
                    }
                    return .object(fields)
                })
        }
        if case .array(let folders) = members["folders"] {
            members["folders"] = .array(
                folders.map { folder in
                    guard case .object(var fields) = folder, case .array(let names) = fields["names"] else {
                        return folder
                    }
                    fields["names"] = .array(
                        names.sorted {
                            ($0.stringValue ?? "").utf16.lexicographicallyPrecedes(($1.stringValue ?? "").utf16)
                        })
                    return .object(fields)
                })
        }
        return .object(members)
    }
}

public enum ExecBatchRenameHarness {
    public typealias Case = GoldenCase<ExecBatchRenameScenario, JSONValue>
    /// Runs a scenario in the places made for it, its tree built, and returns its raw outcome.
    public typealias Engine =
        @Sendable (_ scenario: ExecBatchRenameScenario, _ places: ExecPlaces) async throws -> JSONValue

    public static let suite = "exec-batch-rename"

    public static func cases(in filePath: String = #filePath) throws -> [Case] {
        try Golden.load(suite: suite, in: filePath)
    }

    /// Whether the case's disk images exist here (tools/fixtures/disk-images.sh).
    public static func isRunnable(_ testCase: Case) -> Bool {
        (testCase.input.volumes ?? [:]).values.allSatisfy(ExecDiskImages.isAvailable)
    }

    /// Runs one case through `engine` in fresh folders. Nil when the normalized outcome matches the recording; else
    /// its first differences, one per line.
    public static func check(_ testCase: Case, with engine: Engine, limit: Int = 10) async throws -> [String]? {
        let scenario = testCase.input.placesScenario
        let places = try ExecPlaces.make(for: scenario)
        defer { places.remove() }
        try scenario.build(in: places)
        let raw = try await engine(testCase.input, places)
        return ExecHarness.compare(expected: testCase.output, raw: raw, places: places, limit: limit)
    }
}
