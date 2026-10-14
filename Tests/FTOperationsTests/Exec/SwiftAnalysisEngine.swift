// The Swift paste review, as the differential drives it: what tools/parity/exec/analysis.ts records of the
// reference, made by the Swift analysis and policy. The review sheet's helpers (choicesForNode, effectiveChoice,
// policyForAllConflicts, allConflictsChoicesFor) are those of apps/desktop/src/renderer/lib/copyPasteReview.ts.
import Darwin
import FTFoundation
import FTTestSupport
import Foundation

@testable import FTOperations

struct SwiftAnalysisEngine: ExecAnalysisEngine {
    /// The "For all conflicts" buttons, in the order analysis.ts asks about them.
    private static let allConflicts = ["skip", "add_missing", "keep_all", "overwrite"]

    func analyze(_ scenario: ExecScenario, in places: ExecPlaces) async throws -> JSONValue {
        let fileSystem = RecordedFileSystem()
        let before = try JSONValue.of(try places.snapshotTree())
        let request = normalizeCopyPasteAnalysisRequest(
            CopyPasteAnalysisRequest(
                mode: try Self.mode(scenario.paste.mode), sourcePaths: scenario.paste.sources.map(places.resolve),
                destinationDirectoryPath: places.resolve(scenario.paste.destination)))
        let report = try buildCopyPasteAnalysisReport(
            analysisId: "analysis-test", request: request, fileSystem: fileSystem, thresholds: .writeService)
        var overrideChoices: [String: CopyPasteChoice] = [:]
        let overrides = try (scenario.overrides ?? []).map { item in
            CopyPasteNodeOverride(nodeId: item.nodeId, action: try Self.choice(item.action))
        }
        for override in overrides {
            overrideChoices[override.nodeId] = override.action
        }

        var choices: [String: JSONValue] = [:]
        for node in Self.conflictNodes(report.nodes) {
            guard let conflictClass = node.conflictClass else { continue }
            var effective: [String: JSONValue] = [:]
            for button in Self.allConflicts {
                let choice = CopyPasteChoices.choiceForConflict(
                    conflictClass: conflictClass, replaceBlockedReason: node.replaceBlockedReason,
                    policy: Self.policyForAllConflicts(button), override: overrideChoices[node.id])
                effective[button] = .string(choice.rawValue)
            }
            choices[node.id] = .object([
                "offered": .array(Self.choicesFor(conflictClass).map { .string($0) }),
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
            "allConflictsChoices": .array(Self.allConflictsChoices(report).map { .string($0) }),
            "choices": .object(choices),
            "resolved": resolved,
        ])
    }

    // MARK: The review sheet

    private static func choicesFor(_ conflictClass: ConflictClass) -> [String] {
        conflictClass == .directoryConflict ? ["merge", "keep_both", "overwrite", "skip"] : ["keep_both", "overwrite", "skip"]
    }

    private static func policyForAllConflicts(_ button: String) -> CopyPastePolicy {
        switch button {
        case "add_missing": CopyPastePolicy(file: .skip, directory: .merge, mismatch: .skip)
        case "keep_all": CopyPastePolicy(file: .keepBoth, directory: .merge, mismatch: .keepBoth)
        case "overwrite": CopyPastePolicy(file: .overwrite, directory: .overwrite, mismatch: .overwrite)
        default: CopyPastePolicy(file: .skip, directory: .skip, mismatch: .skip)
        }
    }

    private static func allConflictsChoices(_ report: CopyPasteAnalysisReport) -> [String] {
        report.mode == .cut || report.summary.directoryConflictCount == 0
            ? ["skip", "keep_all", "overwrite"] : ["skip", "add_missing", "keep_all", "overwrite"]
    }

    private static func conflictNodes(_ nodes: [CopyPasteAnalysisNode]) -> [CopyPasteAnalysisNode] {
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

    // MARK: JSON, every key present as the reference writes it

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
            "warnings": .array(
                report.warnings.map { .object(["code": .string($0.code.rawValue), "message": .string($0.message)]) }),
            "summary": .object([
                "topLevelItemCount": .int(report.summary.topLevelItemCount),
                "totalNodeCount": .int(report.summary.totalNodeCount),
                "totalBytes": optional(report.summary.totalBytes),
                "fileConflictCount": .int(report.summary.fileConflictCount),
                "directoryConflictCount": .int(report.summary.directoryConflictCount),
                "mismatchConflictCount": .int(report.summary.mismatchConflictCount),
                "blockedCount": .int(report.summary.blockedCount),
            ]),
            "destinationCaseSensitive": .bool(report.destinationCaseSensitive),
        ])
    }

    static func json(_ node: CopyPasteAnalysisNode) -> JSONValue {
        .object([
            "id": .string(node.id),
            "sourcePath": .string(node.sourcePath),
            "destinationPath": .string(node.destinationPath),
            "sourceKind": .string(node.sourceKind.rawValue),
            "destinationKind": .string(node.destinationKind.rawValue),
            "disposition": .string(node.disposition.rawValue),
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

/// The disk as the recordings' file system saw it. They were made under Bun, whose `fs.promises.realpath` opens
/// the item, so it fails (EACCES) on an item its owner can't read, where the app's (Node's realpath(3)) and
/// `PosixFileSystem`'s succeed. The review is compared on the same answers; the app keeps realpath(3).
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
