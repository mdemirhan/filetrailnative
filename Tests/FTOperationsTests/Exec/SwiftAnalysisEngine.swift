// The Swift paste review, as the scenario checks drive it: the tree before, the report, the choices offered and
// taken for each conflict under each "For all conflicts" button, and the items resolved with the scenario's policy.
import Darwin
import FTFoundation
import FTTestSupport
import Foundation

@testable import FTOperations

struct SwiftAnalysisEngine: ExecAnalysisEngine {
    func analyze(_ scenario: ExecScenario, in places: ExecPlaces) async throws -> JSONValue {
        let fileSystem = RecordedFileSystem()
        let before = try JSONValue.of(try places.snapshotTree())
        let request = normalizeCopyPasteAnalysisRequest(
            CopyPasteAnalysisRequest(
                mode: try Self.mode(scenario.paste.mode), sourcePaths: scenario.paste.sources.map(places.resolve),
                destinationDirectoryPath: places.resolve(scenario.paste.destination)))
        let report = try buildCopyPasteAnalysisReport(
            analysisId: "analysis-test", request: request, fileSystem: fileSystem)
        var overrideChoices: [String: CopyPasteChoice] = [:]
        let overrides = try (scenario.overrides ?? []).map { item in
            CopyPasteNodeOverride(nodeId: item.nodeId, action: try Self.choice(item.action))
        }
        for override in overrides {
            overrideChoices[override.nodeId] = override.action
        }

        // The review sheet's own answers, from the report as the sheet reads it.
        let review = try JSONDecoder().decode(ReviewReport.self, from: JSONEncoder().encode(report))
        var choices: [String: JSONValue] = [:]
        for node in Self.conflictNodes(review.nodes) {
            var effective: [String: JSONValue] = [:]
            for button in AllConflictsChoice.allCases {
                guard
                    let choice = CopyPasteReview.effectiveChoice(
                        node, CopyPasteReview.policy(for: button), overrideChoices)
                else { continue }
                effective[button.rawValue] = .string(choice.rawValue)
            }
            choices[node.id] = .object([
                "offered": .array(CopyPasteReview.choices(for: node).map { .string($0.rawValue) }),
                "effective": .object(effective),
            ])
        }

        var resolved: JSONValue = .null
        if report.issues.isEmpty {
            do {
                let policy = CopyPastePolicy(
                    file: try Self.choice(scenario.policy.file), directory: try Self.choice(scenario.policy.directory),
                    mismatch: try Self.choice(scenario.policy.mismatch))
                resolved = .array(
                    try resolveAnalysisWithPolicy(
                        report: report, policy: policy, overrides: overrides, fileSystem: fileSystem
                    ).map(Self.compact))
            } catch {
                resolved = .object(["error": .string(errorMessage(error))])
            }
        }
        return .object([
            "before": before,
            "report": Self.json(report),
            "allConflictsChoices": .array(CopyPasteReview.allConflictsChoices(review).map { .string($0.rawValue) }),
            "choices": .object(choices),
            "resolved": resolved,
        ])
    }

    // MARK: The review sheet

    private static func conflictNodes(_ nodes: [ReviewNode]) -> [ReviewNode] {
        nodes.flatMap { node in (node.conflictClass == nil ? [] : [node]) + conflictNodes(node.children) }
    }

    // MARK: Values

    struct UnknownValue: Error, CustomStringConvertible {
        let description: String
    }

    private static func mode(_ text: String) throws -> CopyPasteMode {
        guard let mode = CopyPasteMode(rawValue: text) else { throw UnknownValue(description: "mode \(text)") }
        return mode
    }

    private static func choice(_ text: String) throws -> CopyPasteChoice {
        guard let choice = CopyPasteChoice(rawValue: text) else { throw UnknownValue(description: "choice \(text)") }
        return choice
    }

    // MARK: JSON, every key present

    private static func compact(_ node: ResolvedCopyPasteNode) -> JSONValue {
        .object([
            "id": .string(node.node.id),
            "action": .string(node.action.rawValue),
            "destinationPath": .string(node.destinationPath),
            "children": .array(node.children.map(compact)),
        ])
    }

    private static func optional(_ text: String?) -> JSONValue {
        text.map { .string($0) } ?? .null
    }

    private static func optional(_ number: Int?) -> JSONValue {
        number.map { .int($0) } ?? .null
    }

    private static func optional(_ number: Int64?) -> JSONValue {
        number.map { .int(Int($0)) } ?? .null
    }

    static func json(_ report: CopyPasteAnalysisReport) -> JSONValue {
        .object([
            "analysisId": .string(report.analysisId),
            "mode": .string(report.mode.rawValue),
            "sourcePaths": .array(report.sourcePaths.map { .string($0) }),
            "destinationDirectoryPath": .string(report.destinationDirectoryPath),
            "nodes": .array(report.nodes.map(json)),
            "issues": .array(
                report.issues.map {
                    .object([
                        "code": .string($0.code.rawValue), "message": .string($0.message),
                        "sourcePath": optional($0.sourcePath), "destinationPath": optional($0.destinationPath),
                    ])
                }),
            "warnings": .array(warnings(report)),
            "summary": .object([
                "topLevelItemCount": .int(report.summary.topLevelItemCount),
                "totalNodeCount": .int(report.summary.totalNodeCount),
                "totalBytes": optional(report.summary.totalBytes),
                "fileConflictCount": .int(report.summary.fileConflictCount),
                "directoryConflictCount": .int(report.summary.directoryConflictCount),
                "mismatchConflictCount": .int(report.summary.mismatchConflictCount),
                // Nothing was ever counted as blocked.
                "blockedCount": .int(0),
            ]),
            "destinationCaseSensitive": .bool(report.destinationCaseSensitive),
        ])
    }

    /// The warnings the recordings carry, which the app never showed: a paste of more than 100 items or 1 GiB, and a
    /// cut.
    private static func warnings(_ report: CopyPasteAnalysisReport) -> [JSONValue] {
        var warnings: [JSONValue] = []
        if report.summary.totalNodeCount > 100 || (report.summary.totalBytes ?? 0) > 1024 * 1024 * 1024 {
            warnings.append(
                .object([
                    "code": .string("large_batch"),
                    "message": .string("This operation will write \(report.summary.totalNodeCount) items."),
                ]))
        }
        if report.mode == .cut {
            warnings.append(
                .object([
                    "code": .string("cut_requires_delete"),
                    "message": .string("Cut/Paste removes the original items after the copy succeeds."),
                ]))
        }
        return warnings
    }

    static func json(_ node: CopyPasteAnalysisNode) -> JSONValue {
        .object([
            "id": .string(node.id),
            "sourcePath": .string(node.sourcePath),
            "destinationPath": .string(node.destinationPath),
            "sourceKind": .string(node.sourceKind.rawValue),
            "destinationKind": .string(node.destinationKind.rawValue),
            // New, or in conflict with what is at the destination.
            "disposition": .string(node.conflictClass == nil ? "new" : "conflict"),
            "conflictClass": optional(node.conflictClass?.rawValue),
            "sourceFingerprint": json(node.sourceFingerprint),
            "destinationFingerprint": json(node.destinationFingerprint),
            "children": .array(node.children.map(json)),
            "issueCode": optional(node.issueCode?.rawValue),
            "issueMessage": optional(node.issueMessage),
            "totalNodeCount": .int(node.totalNodeCount),
            "conflictNodeCount": .int(node.conflictNodeCount),
            "destinationTotalNodeCount": optional(node.destinationTotalNodeCount),
            "keepBothDestinationPath": optional(node.keepBothDestinationPath),
            "destinationOnly": node.destinationOnly.map {
                .object(["count": .int($0.count), "samplePaths": .array($0.samplePaths.map { .string($0) })])
            } ?? .null,
            "replaceBlockedReason": optional(node.replaceBlockedReason),
            "renameOnly": .bool(node.renameOnly),
        ])
    }

    static func json(_ fingerprint: NodeFingerprint) -> JSONValue {
        .object([
            "exists": .bool(fingerprint.exists),
            "kind": .string(fingerprint.kind.rawValue),
            "size": optional(fingerprint.size),
            "mtimeMs": fingerprint.mtimeMs.map { .double($0) } ?? .null,
            "mode": fingerprint.mode.map { .int(Int($0)) } ?? .null,
            "ino": fingerprint.ino.map { .int(Int($0)) } ?? .null,
            "dev": optional(fingerprint.dev),
            "symlinkTarget": optional(fingerprint.symlinkTarget),
        ])
    }
}

/// The disk as the recordings expect it: its realpath opens the item, so it fails (EACCES) on an item its owner
/// can't read, where realpath(3) and `PosixFileSystem`'s succeed. The review is compared on the same answers; the
/// app keeps realpath(3).
struct RecordedFileSystem: AnalysisFileSystem {
    private let disk = PosixFileSystem()

    func lstat(_ path: String) throws -> WriteServiceStats { try disk.lstat(path) }
    func stat(_ path: String) throws -> WriteServiceStats { try disk.stat(path) }
    func readdir(_ path: String) throws -> [String] { try disk.readdir(path) }
    func readlink(_ path: String) throws -> String { try disk.readlink(path) }
    func isCaseSensitive(_ path: String) throws -> Bool? { try disk.isCaseSensitive(path) }
    func isPackage(_ path: String) throws -> Bool? { try disk.isPackage(path) }
    func isAppleDouble(_ path: String) -> Bool { disk.isAppleDouble(path) }

    func realpath(_ path: String) throws -> String {
        let descriptor = open(path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw NativeError.errno(errno, syscall: "realpath", path: path)
        }
        close(descriptor)
        return try disk.realpath(path)
    }
}
