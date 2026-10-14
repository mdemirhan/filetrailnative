// Port of packages/core/src/fs/copyPastePolicy.ts
import FTFoundation
import Foundation

/// What the paste does with one item.
public enum ResolvedCopyPasteAction: String, Codable, Equatable, Sendable {
    case create, overwrite, merge
    case keepBoth = "keep_both"
    case skip

    public init(_ choice: CopyPasteChoice) {
        switch choice {
        case .overwrite: self = .overwrite
        case .merge: self = .merge
        case .keepBoth: self = .keepBoth
        case .skip: self = .skip
        }
    }
}

public struct ResolvedCopyPasteNode: Equatable, Sendable {
    public var node: CopyPasteAnalysisNode
    public var action: ResolvedCopyPasteAction
    public var destinationPath: String
    public var children: [ResolvedCopyPasteNode]

    public init(
        node: CopyPasteAnalysisNode, action: ResolvedCopyPasteAction, destinationPath: String,
        children: [ResolvedCopyPasteNode]
    ) {
        self.node = node
        self.action = action
        self.destinationPath = destinationPath
        self.children = children
    }
}

/// The review's tree with the policy and the per-item choices (`overrides`; items without one follow the policy
/// for their kind) made into actions and destinations.
public func resolveAnalysisWithPolicy(
    report: CopyPasteAnalysisReport, policy: CopyPastePolicy, overrides: [CopyPasteNodeOverride] = [],
    fileSystem: some AnalysisFileSystem
) throws -> [ResolvedCopyPasteNode] {
    let resolver = PolicyResolver(
        policy: policy, overrides: overrideMap(overrides), fileSystem: fileSystem,
        caseSensitive: report.destinationCaseSensitive, operationReservedPaths: nil)
    return try resolver.resolveSiblings(report.nodes, explicitAction: nil, parentDestinationPath: nil)
}

/// Re-resolves one item with the answer given while the paste runs. `policy` (the paste's) decides nested
/// conflicts when the answer is "merge", and the review's per-item choices still apply inside a merged folder.
/// `reservedPaths` holds every name this paste has planned or already written (keyed by
/// `NameKeys.exactDestinationKey`), so a Keep Both copy never takes a name another item will use; new names are
/// added to it.
public func resolveSingleNodeWithAction(
    node: CopyPasteAnalysisNode, action: CopyPasteChoice, policy: CopyPastePolicy?,
    overrides: [CopyPasteNodeOverride] = [], fileSystem: some AnalysisFileSystem, caseSensitive: Bool = false,
    reservedPaths: inout Set<NameKeys.Exact>
) throws -> ResolvedCopyPasteNode {
    let reserved = ReservedPaths(reservedPaths)
    defer { reservedPaths = reserved.keys }
    let resolver = PolicyResolver(
        policy: policy, overrides: overrideMap(overrides), fileSystem: fileSystem, caseSensitive: caseSensitive,
        operationReservedPaths: reserved)
    return try resolver.resolveNode(node, reservedPaths: reserved, explicitAction: ResolvedCopyPasteAction(action))
}

/// `resolveSingleNodeWithAction` with no names reserved yet.
public func resolveSingleNodeWithAction(
    node: CopyPasteAnalysisNode, action: CopyPasteChoice, policy: CopyPastePolicy?,
    overrides: [CopyPasteNodeOverride] = [], fileSystem: some AnalysisFileSystem, caseSensitive: Bool = false
) throws -> ResolvedCopyPasteNode {
    var reservedPaths = Set<NameKeys.Exact>()
    return try resolveSingleNodeWithAction(
        node: node, action: action, policy: policy, overrides: overrides, fileSystem: fileSystem,
        caseSensitive: caseSensitive, reservedPaths: &reservedPaths)
}

/// The keys of every destination a resolved paste will write to.
public func collectDestinationPathKeys(
    _ nodes: [ResolvedCopyPasteNode], caseSensitive: Bool, into keys: inout Set<NameKeys.Exact>
) {
    var stack = nodes
    while let node = stack.popLast() {
        keys.insert(NameKeys.exactDestinationKey(node.destinationPath, caseSensitive: caseSensitive))
        stack.append(contentsOf: node.children)
    }
}

/// Names claimed while resolving, shared by every folder that adds to them.
private final class ReservedPaths {
    var keys: Set<NameKeys.Exact>

    init(_ keys: Set<NameKeys.Exact> = []) {
        self.keys = keys
    }
}

private func overrideMap(_ overrides: [CopyPasteNodeOverride]) -> [NameKeys.Exact: CopyPasteChoice] {
    var map: [NameKeys.Exact: CopyPasteChoice] = [:]
    for override in overrides {
        map[NameKeys.Exact(override.nodeId)] = override.action
    }
    return map
}

private struct PolicyResolver<FileSystem: AnalysisFileSystem> {
    let policy: CopyPastePolicy?
    let overrides: [NameKeys.Exact: CopyPasteChoice]
    let fileSystem: FileSystem
    let caseSensitive: Bool
    /// Names claimed across the whole paste, when resolving one item while the paste is running; nil resolves
    /// each folder's items on their own.
    let operationReservedPaths: ReservedPaths?

    private func key(_ path: String) -> NameKeys.Exact {
        NameKeys.exactDestinationKey(path, caseSensitive: caseSensitive)
    }

    /// Resolves the items of one destination folder. Items keeping their own name claim it first, so a Keep Both
    /// copy never picks a name another item of this paste will use.
    func resolveSiblings(
        _ nodes: [CopyPasteAnalysisNode], explicitAction: ResolvedCopyPasteAction?, parentDestinationPath: String?
    ) throws -> [ResolvedCopyPasteNode] {
        func destinationPathFor(_ node: CopyPasteAnalysisNode) -> String {
            guard let parentDestinationPath else { return node.destinationPath }
            return joinChildDestinationPath(parentDestinationPath, node.sourcePath)
        }
        // Keys are whole paths, so one set can serve every folder of a running paste.
        let reservedPaths = operationReservedPaths ?? ReservedPaths()
        for node in nodes {
            reservedPaths.keys.insert(key(destinationPathFor(node)))
        }
        return try nodes.map { node in
            try resolveNode(
                node, reservedPaths: reservedPaths, explicitAction: explicitAction,
                destinationPathOverride: parentDestinationPath == nil ? nil : destinationPathFor(node))
        }
    }

    func resolveNode(
        _ node: CopyPasteAnalysisNode, reservedPaths: ReservedPaths, explicitAction: ResolvedCopyPasteAction?,
        destinationPathOverride: String? = nil
    ) throws -> ResolvedCopyPasteNode {
        let baseDestinationPath = destinationPathOverride ?? node.destinationPath
        let action: ResolvedCopyPasteAction
        if let explicitAction {
            action = explicitAction
        } else if let conflictClass = node.conflictClass {
            let override = overrides[NameKeys.Exact(node.id)]
            let usesOverride = override.map { CopyPasteChoices.isChoiceAllowed(for: conflictClass, $0) } ?? false
            if !usesOverride && policy == nil {
                throw OperationError("Missing \(Self.kindName(conflictClass)) conflict policy.")
            }
            // As the review sheet decides it (an item Replace can't take gets the safe choice).
            action = ResolvedCopyPasteAction(
                CopyPasteChoices.choiceForConflict(
                    conflictClass: conflictClass, replaceBlockedReason: node.replaceBlockedReason,
                    policy: policy ?? .defaultCopyPaste, override: override))
        } else {
            action = .create
        }
        var destinationPath = baseDestinationPath
        if action == .keepBoth {
            let isDirectory = node.sourceKind == .directory
            destinationPath = try resolveDuplicateName(
                NodePath.basename(node.sourcePath), in: NodePath.dirname(baseDestinationPath), fileSystem,
                reserved: reservedPaths.keys,
                options: .init(
                    isDirectory: isDirectory, isPackage: isDirectory && isPackageFolder(fileSystem, node.sourcePath),
                    caseSensitive: caseSensitive))
            reservedPaths.keys.insert(key(destinationPath))
        }

        // "overwrite" keeps the destination state seen at review time so execution can notice if it changed
        // before anything is replaced.
        let shouldNormalizeDestination =
            action == .create || action == .keepBoth
            || (action != .overwrite && !sameText(destinationPath, node.destinationPath))
        var normalizedNode = node
        normalizedNode.destinationPath = destinationPath
        if shouldNormalizeDestination {
            normalizedNode.disposition = .new
            normalizedNode.conflictClass = nil
            normalizedNode.destinationKind = .missing
            normalizedNode.destinationFingerprint = .missing
        }

        let childAction: ResolvedCopyPasteAction? =
            if explicitAction == .create || action == .keepBoth || action == .overwrite {
                .create
            } else if action == .merge || action == .create {
                nil
            } else {
                action
            }
        let children = try resolveSiblings(
            node.children, explicitAction: childAction, parentDestinationPath: destinationPath)

        return ResolvedCopyPasteNode(
            node: normalizedNode, action: action, destinationPath: destinationPath, children: children)
    }

    private static func kindName(_ conflictClass: ConflictClass) -> String {
        switch conflictClass {
        case .fileConflict: "file"
        case .directoryConflict: "directory"
        case .typeMismatch: "mismatch"
        }
    }
}

private func joinChildDestinationPath(_ parentDestinationPath: String, _ childSourcePath: String) -> String {
    sameText(parentDestinationPath, "/")
        ? "/" + NodePath.basename(childSourcePath)
        : parentDestinationPath + "/" + NodePath.basename(childSourcePath)
}
