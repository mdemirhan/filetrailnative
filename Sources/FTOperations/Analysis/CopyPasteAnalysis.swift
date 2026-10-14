// Port of packages/core/src/fs/copyPasteAnalysis.ts
import FTFoundation
import Foundation

public struct CopyPasteThresholds: Sendable, Equatable {
    public var largeBatchItemThreshold: Int
    public var largeBatchByteThreshold: Int64

    public init(largeBatchItemThreshold: Int, largeBatchByteThreshold: Int64) {
        self.largeBatchItemThreshold = largeBatchItemThreshold
        self.largeBatchByteThreshold = largeBatchByteThreshold
    }

    /// The write service's: 100 items, 1 GiB.
    public static let writeService = CopyPasteThresholds(
        largeBatchItemThreshold: 100, largeBatchByteThreshold: 1024 * 1024 * 1024)
}

/// Every path resolved, repeats dropped, and any path inside another picked left out.
public func normalizeCopyPasteAnalysisRequest(_ request: CopyPasteAnalysisRequest) -> CopyPasteAnalysisRequest {
    var seen = Set<NameKeys.Exact>()
    var unique: [String] = []
    for path in request.sourcePaths.map(NodePath.resolve) where seen.insert(NameKeys.Exact(path)).inserted {
        unique.append(path)
    }
    return CopyPasteAnalysisRequest(
        mode: request.mode, sourcePaths: Paths.withoutNestedPaths(unique),
        destinationDirectoryPath: NodePath.resolve(request.destinationDirectoryPath))
}

/// The review of a paste: each item and what is in its way, the issues that refuse it, and the warnings. Reads
/// the disk on the calling thread; `signal` stops it with a `StopError`.
public func buildCopyPasteAnalysisReport(
    analysisId: String, request: CopyPasteAnalysisRequest, fileSystem: some AnalysisFileSystem,
    thresholds: CopyPasteThresholds, signal: StopSignal? = nil
) throws -> CopyPasteAnalysisReport {
    try ReportBuilder(request: request, fileSystem: fileSystem, signal: signal).build(
        analysisId: analysisId, thresholds: thresholds)
}

/// Reads one item again from disk, as the review would read it now: used when the item changed after the review
/// (a file saved as a package, a package saved anew) and the person chose to go on, so what is pasted is what is
/// there, not what was there. Throws when the item now holds two names the destination can't tell apart.
public func analyzeItemAgain(
    id: String, sourcePath: String, destinationPath: String, fileSystem: some AnalysisFileSystem, caseSensitive: Bool,
    signal: StopSignal? = nil
) throws -> CopyPasteAnalysisNode {
    let walker = NodeWalker(
        fileSystem: fileSystem, cache: DestinationScanCache(caseSensitive: caseSensitive), signal: signal)
    let node = try walker.analyzeNode(id: id, sourcePath: sourcePath, destinationPath: destinationPath)
    if let collision = walker.cache.nameCollisions.first {
        throw OperationError(
            "\u{201C}\(NodePath.basename(collision.sourcePath))\u{201D} and \u{201C}\(NodePath.basename(collision.otherSourcePath))\u{201D} would both be pasted as one item, because the destination doesn't tell upper and lower case apart."
        )
    }
    return node
}

/// What kind of clash an item has with what is at its destination. Two folders can be merged, unless either is a
/// package (an app, a Keynote document): those are replaced or kept beside each other whole, like files, since
/// mixing two versions breaks them.
public func classifyConflict(
    _ fileSystem: some AnalysisFileSystem, source: (path: String, kind: CopyPasteNodeKind),
    destination: (path: String, kind: CopyPasteNodeKind)
) -> ConflictClass? {
    if destination.kind == .missing {
        return nil
    }
    if source.kind == .directory && destination.kind == .directory {
        let packaged = isPackageFolder(fileSystem, source.path) || isPackageFolder(fileSystem, destination.path)
        return packaged ? .fileConflict : .directoryConflict
    }
    if source.kind != .directory && destination.kind == source.kind {
        return .fileConflict
    }
    return .typeMismatch
}

// MARK: The report

private struct ReportBuilder<FileSystem: AnalysisFileSystem> {
    let request: CopyPasteAnalysisRequest
    let fileSystem: FileSystem
    let signal: StopSignal?

    func build(analysisId: String, thresholds: CopyPasteThresholds) throws -> CopyPasteAnalysisReport {
        var issues: [CopyPasteAnalysisIssue] = []
        var warnings: [CopyPasteAnalysisWarning] = []
        var nodes: [CopyPasteAnalysisNode] = []
        let destinationDirectory = request.destinationDirectoryPath
        // A symlink to a folder is pasted into as that folder.
        let destinationFingerprint = captureFolderFingerprint(fileSystem, destinationDirectory)
        // Asked once per analysis: everything pasted lands on the destination folder's volume.
        let caseSensitive =
            destinationFingerprint.kind == .directory
            ? detectCaseSensitivity(fileSystem, in: destinationDirectory) : false
        let pathKey = { (path: String) in NameKeys.exactDestinationKey(path, caseSensitive: caseSensitive) }
        let walker = NodeWalker(
            fileSystem: fileSystem, cache: DestinationScanCache(caseSensitive: caseSensitive), signal: signal)
        // APFS is case- and normalization-insensitive by default, so "report.pdf" from one folder and
        // "Report.pdf" from another land on the same entry.
        var claimedDestinationNames: [NameKeys.Exact: String] = [:]
        // The same, as whole destination paths, for picking free names.
        var plannedDestinationKeys = Set<NameKeys.Exact>()

        if !destinationFingerprint.exists {
            issues.append(
                CopyPasteAnalysisIssue(
                    code: .destinationMissing, message: "Destination does not exist.", sourcePath: nil,
                    destinationPath: destinationDirectory))
        } else if destinationFingerprint.kind != .directory {
            issues.append(
                CopyPasteAnalysisIssue(
                    code: .destinationNotDirectory, message: "Destination must be an existing directory.",
                    sourcePath: nil, destinationPath: destinationDirectory))
        }

        // The destination folder may be reached through another path (a symlinked folder or a different letter
        // case), so "same folder" compares identities, not just strings.
        var sameDirectoryCache: [NameKeys.Exact: Bool] = [:]
        func isDestinationDirectory(_ directoryPath: String) -> Bool {
            if sameText(directoryPath, destinationDirectory) {
                return true
            }
            let key = NameKeys.Exact(directoryPath)
            if let cached = sameDirectoryCache[key] {
                return cached
            }
            let same = isSameExistingItem(captureFolderFingerprint(fileSystem, directoryPath), destinationFingerprint)
            sameDirectoryCache[key] = same
            return same
        }

        // The destination folder and each folder holding it, by identity, found once: a folder pasted into any
        // of them would be pasted into itself. Paths alone miss one reached by another spelling: the real path
        // of a folder in Home can still start with the firmlinked "/System/Volumes/Data", and the copied
        // folder's with "/Users".
        var destinationHolderIds: Set<String>?
        func holdsDestination(_ source: NodeFingerprint, _ destinationRealPath: String) -> Bool {
            guard let dev = source.dev, let ino = source.ino else { return false }
            let ids = destinationHolderIds ?? folderIdsHolding(fileSystem, destinationRealPath)
            destinationHolderIds = ids
            return ids.contains("\(dev):\(ino)")
        }

        // Items that keep their own name claim it first, so a " copy" name picked for an item copied into its
        // own folder never takes it, whatever order the items come in.
        if request.mode == .copy {
            for sourcePath in request.sourcePaths where !isDestinationDirectory(NodePath.dirname(sourcePath)) {
                plannedDestinationKeys.insert(
                    pathKey(NodePath.join(destinationDirectory, NodePath.basename(sourcePath))))
            }
        }

        for (index, sourcePath) in request.sourcePaths.enumerated() {
            try signal?.throwIfStopped()
            let sourceFingerprint = captureFingerprint(fileSystem, sourcePath)
            var destinationPath = NodePath.join(destinationDirectory, NodePath.basename(sourcePath))
            let pastingIntoSourceFolder = isDestinationDirectory(NodePath.dirname(sourcePath))

            if request.mode == .copy && pastingIntoSourceFolder {
                // Duplicating "a.txt" and "a copy.txt" together gives "a copy 2.txt" and "a copy 3.txt": a name
                // an earlier item took is skipped, like Finder.
                let isDirectory = sourceFingerprint.kind == .directory
                destinationPath = try resolveDuplicateName(
                    NodePath.basename(sourcePath), in: destinationDirectory, fileSystem,
                    reserved: plannedDestinationKeys,
                    options: .init(
                        isDirectory: isDirectory, isPackage: isDirectory && isPackageFolder(fileSystem, sourcePath),
                        caseSensitive: caseSensitive))
            }

            if !sourceFingerprint.exists || sourceFingerprint.kind == .missing {
                issues.append(
                    CopyPasteAnalysisIssue(
                        code: .sourceMissing, message: "Source does not exist: \(sourcePath)", sourcePath: sourcePath,
                        destinationPath: destinationPath))
                continue
            }

            if sameText(sourcePath, destinationPath) || (request.mode == .cut && pastingIntoSourceFolder)
                || isSameExistingItem(sourceFingerprint, captureFingerprint(fileSystem, destinationPath))
            {
                issues.append(
                    CopyPasteAnalysisIssue(
                        code: .samePath, message: "Cannot paste \(sourcePath) onto itself.", sourcePath: sourcePath,
                        destinationPath: destinationPath))
                continue
            }

            if destinationFingerprint.exists && destinationFingerprint.kind == .directory
                && sourceFingerprint.kind == .directory
            {
                do {
                    let sourceRealPath = try fileSystem.realpath(sourcePath)
                    let destinationRealPath = try fileSystem.realpath(destinationDirectory)
                    // "/" holds everything: its own path already ends with the separator.
                    let sourcePrefix =
                        sourceRealPath.unicodeScalars.last == "/" ? sourceRealPath : sourceRealPath + "/"
                    if sameText(destinationRealPath, sourceRealPath) || startsWith(destinationRealPath, sourcePrefix)
                        || holdsDestination(sourceFingerprint, destinationRealPath)
                    {
                        issues.append(
                            CopyPasteAnalysisIssue(
                                code: .parentIntoChild, message: "Cannot paste \(sourcePath) into its own descendant.",
                                sourcePath: sourcePath, destinationPath: destinationPath))
                        continue
                    }
                } catch {
                    issues.append(
                        CopyPasteAnalysisIssue(
                            code: .sourceMissing, message: "Source does not exist: \(sourcePath)",
                            sourcePath: sourcePath, destinationPath: destinationPath))
                    continue
                }
            }

            let destinationNameKey = pathKey(NodePath.basename(destinationPath))
            if let claimingSourcePath = claimedDestinationNames[destinationNameKey] {
                issues.append(
                    CopyPasteAnalysisIssue(
                        code: .duplicateDestinationName,
                        message:
                            "\(sourcePath) and \(claimingSourcePath) would both be pasted as \(NodePath.basename(destinationPath)).",
                        sourcePath: sourcePath, destinationPath: destinationPath))
                continue
            }
            claimedDestinationNames[destinationNameKey] = sourcePath
            plannedDestinationKeys.insert(pathKey(destinationPath))

            // A folder moved on its own disk is renamed whole when its name is free: reading all that is inside
            // it (a project with its node_modules) would only take time.
            let renameIfFree =
                request.mode == .cut && sourceFingerprint.dev != nil
                && sourceFingerprint.dev == destinationFingerprint.dev
            let node = try walker.analyzeNode(
                id: "item-\(index + 1)", sourcePath: sourcePath, destinationPath: destinationPath,
                renameIfFree: renameIfFree)
            // A disk mounted inside a folder being moved: a move that copies the folder would copy that disk's
            // items too, then remove them from it. Refused before anything is written.
            let mountPoint =
                request.mode == .cut
                ? findMountPointMovedByCopy(
                    node, toAnotherDisk: node.sourceFingerprint.dev != destinationFingerprint.dev) : nil
            if let mountPoint {
                issues.append(
                    CopyPasteAnalysisIssue(
                        code: .sourceUnreadable,
                        message:
                            "\u{201C}\(NodePath.basename(sourcePath))\u{201D} can't be moved because a disk is mounted inside it (\u{201C}\(NodePath.basename(mountPoint))\u{201D}).",
                        sourcePath: sourcePath, destinationPath: destinationPath))
                continue
            }
            nodes.append(node)
        }

        for collision in walker.cache.nameCollisions {
            issues.append(
                CopyPasteAnalysisIssue(
                    code: .duplicateDestinationName,
                    message:
                        "\(collision.sourcePath) and \(collision.otherSourcePath) would both be pasted as \(NodePath.basename(collision.destinationPath)), because the destination doesn't tell upper and lower case apart.",
                    sourcePath: collision.sourcePath, destinationPath: collision.destinationPath))
        }

        // Replacing an item that is, or holds, any item of this paste would destroy that item too. Items inside
        // merged folders are checked as well: a Replace offered there would only be refused when the paste
        // reaches it.
        let pasted = PastedItems(realPaths: realItemPaths(fileSystem, nodes.map(\.sourcePath)))
        func annotate(_ node: inout CopyPasteAnalysisNode) {
            node.replaceBlockedReason = findReplaceBlockedReason(node, fileSystem, pasted)
            if node.conflictClass == .directoryConflict {
                for index in node.children.indices {
                    annotate(&node.children[index])
                }
            }
        }
        for index in nodes.indices {
            annotate(&nodes[index])
        }

        try annotateKeepBothNames(&nodes, fileSystem, caseSensitive: caseSensitive, signal: signal)
        let summary = summarizeAnalysis(nodes)
        if summary.totalNodeCount > thresholds.largeBatchItemThreshold
            || (summary.totalBytes ?? 0) > thresholds.largeBatchByteThreshold
        {
            warnings.append(
                CopyPasteAnalysisWarning(
                    code: .largeBatch, message: "This operation will write \(summary.totalNodeCount) items."))
        }
        if request.mode == .cut {
            warnings.append(
                CopyPasteAnalysisWarning(
                    code: .cutRequiresDelete,
                    message: "Cut/Paste removes the original items after the copy succeeds."))
        }

        return CopyPasteAnalysisReport(
            analysisId: analysisId, mode: request.mode, sourcePaths: request.sourcePaths,
            destinationDirectoryPath: destinationDirectory, nodes: nodes, issues: issues, warnings: warnings,
            summary: summary, destinationCaseSensitive: caseSensitive)
    }
}

// MARK: Reading the items

/// Folders at the destination read once per analysis, and what the walk found that the destination can't hold.
final class DestinationScanCache {
    struct NameCollision {
        var sourcePath: String
        var otherSourcePath: String
        var destinationPath: String
    }

    let caseSensitive: Bool
    /// Item counts of existing folders (nil when unreadable).
    var counts: [NameKeys.Exact: Int?] = [:]
    /// Sorted folder listings, so each existing folder is read once per analysis.
    var entries: [NameKeys.Exact: [String]] = [:]
    /// Items inside pasted folders whose names the destination can't tell apart.
    var nameCollisions: [NameCollision] = []

    init(caseSensitive: Bool) {
        self.caseSensitive = caseSensitive
    }

    /// How names are compared on the destination volume (see `NameKeys.destinationPathKey`).
    func pathKey(_ path: String) -> NameKeys.Exact {
        NameKeys.exactDestinationKey(path, caseSensitive: caseSensitive)
    }
}

private struct NodeWalker<FileSystem: AnalysisFileSystem> {
    let fileSystem: FileSystem
    let cache: DestinationScanCache
    let signal: StopSignal?

    /// `insideWholePackage`: inside a package that replaces or sits beside another, everything in it is written
    /// anew, so nothing at the destination is looked at. `renameIfFree`: a folder that, with nothing at its
    /// destination, is renamed there, so it isn't read inside.
    func analyzeNode(
        id: String, sourcePath: String, destinationPath: String, insideWholePackage: Bool = false,
        renameIfFree: Bool = false
    ) throws -> CopyPasteAnalysisNode {
        try signal?.throwIfStopped()
        let sourceFingerprint = captureFingerprint(fileSystem, sourcePath)
        let destinationFingerprint =
            insideWholePackage ? NodeFingerprint.missing : captureFingerprint(fileSystem, destinationPath)
        let sourceKind = sourceFingerprint.kind
        let destinationKind = destinationFingerprint.kind
        let conflictClass = classifyConflict(
            fileSystem, source: (sourcePath, sourceKind), destination: (destinationPath, destinationKind))
        let wholePackage =
            insideWholePackage
            || (sourceKind == .directory && conflictClass != nil && conflictClass != .directoryConflict)
        let renameOnly = renameIfFree && sourceKind == .directory && conflictClass == nil
        var children: [CopyPasteAnalysisNode] = []
        var totalNodeCount = 1
        var conflictNodeCount = conflictClass == nil ? 0 : 1
        var unreadableReason: String?

        if sourceKind == .directory && !renameOnly {
            var sourceChildren: [String] = []
            do {
                let names = try fileSystem.readdir(sourcePath)
                sourceChildren = withoutAppleDoubleFiles(sourcePath, sortedJS(names))
            } catch {
                // One folder that can't be read (no permission, say) fails on its own when the paste runs; it
                // must not stop everything else from being pasted.
                unreadableReason = describeCopyPasteError(error)
            }
            // A folder from a disk that tells "A.txt" from "a.txt" may hold both; on a destination that doesn't,
            // they would land on one name and one would replace the other.
            var claimedChildNames: [NameKeys.Exact: String] = [:]
            for childName in sourceChildren {
                try signal?.throwIfStopped()
                let childSourcePath = NodePath.join(sourcePath, childName)
                let childDestinationPath = NodePath.join(destinationPath, childName)
                // Merging into a folder that has its own view settings (.DS_Store): they are kept, and the pasted
                // folder's are left out rather than asked about as a clash.
                if conflictClass == .directoryConflict && !wholePackage
                    && CopyPasteNames.isFolderViewFile(childName)
                    && captureFingerprint(fileSystem, childDestinationPath).exists
                {
                    continue
                }
                let childKey = cache.pathKey(childName)
                if let claimedBy = claimedChildNames[childKey] {
                    cache.nameCollisions.append(
                        .init(
                            sourcePath: childSourcePath, otherSourcePath: NodePath.join(sourcePath, claimedBy),
                            destinationPath: childDestinationPath))
                } else {
                    claimedChildNames[childKey] = childName
                }
                let childNode = try analyzeNode(
                    id: "\(id)/\(childName)", sourcePath: childSourcePath, destinationPath: childDestinationPath,
                    insideWholePackage: wholePackage)
                children.append(childNode)
                totalNodeCount += childNode.totalNodeCount
                conflictNodeCount += childNode.conflictNodeCount
            }
        }

        var destinationTotalNodeCount: Int?
        var destinationOnly: CopyPasteDestinationOnlySummary?
        // An existing folder in the way: what only it holds is kept by Merge and lost by Replace.
        if conflictClass != nil && destinationKind == .directory {
            destinationTotalNodeCount = try countDirectoryItems(destinationPath)
            // A package is replaced as one item: what is inside it isn't anyone's to list.
            destinationOnly =
                conflictClass == .fileConflict
                ? nil
                : try summarizeDestinationOnly(
                    destinationPath, sourceChildren: conflictClass == .directoryConflict ? children : [])
        }

        return CopyPasteAnalysisNode(
            id: id, sourcePath: sourcePath, destinationPath: destinationPath, sourceKind: sourceKind,
            destinationKind: destinationKind, disposition: conflictClass == nil ? .new : .conflict,
            conflictClass: conflictClass, sourceFingerprint: sourceFingerprint,
            destinationFingerprint: destinationFingerprint, children: children,
            issueCode: unreadableReason == nil ? nil : .sourceUnreadable, issueMessage: unreadableReason,
            totalNodeCount: totalNodeCount, conflictNodeCount: conflictNodeCount,
            destinationTotalNodeCount: destinationTotalNodeCount, keepBothDestinationPath: nil,
            destinationOnly: destinationOnly, replaceBlockedReason: nil, renameOnly: renameOnly)
    }

    /// A folder's items without the AppleDouble files kept beside them on FAT, exFAT and SMB disks: the copy of
    /// "name" carries its attributes, and "._name" copied as a file of its own would only be clutter (and counted
    /// as an item). On APFS a "._name" file is an item like any other (its contents go nowhere else), so it is
    /// kept (see `isAppleDouble`).
    private func withoutAppleDoubleFiles(_ folderPath: String, _ names: [String]) -> [String] {
        let siblings = Set(names.map(NameKeys.Exact.init))
        return names.filter { name in
            !(CopyPasteNames.isAppleDoubleCompanionName(name, hasSibling: { siblings.contains(NameKeys.Exact($0)) })
                && fileSystem.isAppleDouble(NodePath.join(folderPath, name)))
        }
    }

    private static var destinationOnlySampleLimit: Int { 5 }

    private func summarizeDestinationOnly(_ destinationPath: String, sourceChildren: [CopyPasteAnalysisNode]) throws
        -> CopyPasteDestinationOnlySummary?
    {
        var summary = CopyPasteDestinationOnlySummary(count: 0, samplePaths: [])
        let complete = try collectDestinationOnly(destinationPath, sourceChildren, prefix: "", into: &summary)
        return complete ? summary : nil
    }

    /// Walks the existing folder next to the pasted one. Entries with no pasted counterpart (or a pasted file
    /// standing in for a folder) exist only at the destination; folders present on both sides are compared
    /// recursively. Returns false when unreadable.
    private func collectDestinationOnly(
        _ destinationPath: String, _ sourceChildren: [CopyPasteAnalysisNode], prefix: String,
        into summary: inout CopyPasteDestinationOnlySummary
    ) throws -> Bool {
        let entries: [String]
        do {
            entries = try readDestinationEntries(destinationPath)
        } catch {
            return false
        }
        var sourceByName: [NameKeys.Exact: CopyPasteAnalysisNode] = [:]
        for child in sourceChildren {
            sourceByName[cache.pathKey(NodePath.basename(child.sourcePath))] = child
        }
        let limit = Self.destinationOnlySampleLimit
        for entry in entries {
            try signal?.throwIfStopped()
            if CopyPasteNames.isFolderViewFile(entry) {
                continue
            }
            let entryPath = NodePath.join(destinationPath, entry)
            let counterpart = sourceByName[cache.pathKey(entry)]
            if let counterpart, counterpart.sourceKind == .directory && counterpart.destinationKind == .directory {
                // Nested folders are analyzed first; reuse their summary instead of walking again.
                if let nested = counterpart.destinationOnly {
                    summary.count += nested.count
                    for samplePath in nested.samplePaths where summary.samplePaths.count < limit {
                        summary.samplePaths.append("\(prefix)\(entry)/\(samplePath)")
                    }
                    continue
                }
                if !(try collectDestinationOnly(
                    entryPath, counterpart.children, prefix: "\(prefix)\(entry)/", into: &summary))
                {
                    return false
                }
                continue
            }
            if let counterpart, counterpart.destinationKind != .directory {
                continue
            }
            summary.count += 1
            if summary.samplePaths.count < limit {
                summary.samplePaths.append("\(prefix)\(entry)")
            }
            do {
                if try fileSystem.lstat(entryPath).isDirectory {
                    guard let nestedCount = try countDirectoryItems(entryPath) else {
                        return false
                    }
                    summary.count += nestedCount
                }
            } catch let error as StopError {
                throw error
            } catch {
                return false
            }
        }
        return true
    }

    private func readDestinationEntries(_ directoryPath: String) throws -> [String] {
        let key = NameKeys.Exact(directoryPath)
        if let cached = cache.entries[key] {
            return cached
        }
        let names = try fileSystem.readdir(directoryPath)
        let entries = sortedJS(names)
        cache.entries[key] = entries
        return entries
    }

    /// Every item an existing folder holds, nested ones included, without Finder's ".DS_Store"; nil when any of
    /// it can't be read.
    func countDirectoryItems(_ directoryPath: String) throws -> Int? {
        let key = NameKeys.Exact(directoryPath)
        if let cached = cache.counts[key] {
            return cached
        }
        do {
            try signal?.throwIfStopped()
            let entries = try readDestinationEntries(directoryPath).filter { !CopyPasteNames.isFolderViewFile($0) }
            var count = entries.count
            for entry in entries {
                try signal?.throwIfStopped()
                let entryPath = NodePath.join(directoryPath, entry)
                if try fileSystem.lstat(entryPath).isDirectory {
                    guard let nestedCount = try countDirectoryItems(entryPath) else {
                        cache.counts[key] = .some(nil)
                        return nil
                    }
                    count += nestedCount
                }
            }
            cache.counts[key] = count
            return count
        } catch let error as StopError {
            throw error
        } catch {
            cache.counts[key] = .some(nil)
            return nil
        }
    }
}

/// `.sort()`: by UTF-16 code unit, as JavaScript sorts strings.
func sortedJS(_ names: [String]) -> [String] {
    names.sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) }
}

// MARK: Annotations

/// The names "Keep Both" would use, reserved across the items of each folder the same way the paste itself will
/// pick them.
private func annotateKeepBothNames(
    _ nodes: inout [CopyPasteAnalysisNode], _ fileSystem: some AnalysisFileSystem, caseSensitive: Bool,
    signal: StopSignal?
) throws {
    var reservedPaths = Set(
        nodes.map { NameKeys.exactDestinationKey($0.destinationPath, caseSensitive: caseSensitive) })
    for index in nodes.indices {
        try signal?.throwIfStopped()
        if nodes[index].conflictClass != nil {
            let node = nodes[index]
            let isDirectory = node.sourceKind == .directory
            let keepBoth = try resolveDuplicateName(
                NodePath.basename(node.sourcePath), in: NodePath.dirname(node.destinationPath), fileSystem,
                reserved: reservedPaths,
                options: .init(
                    isDirectory: isDirectory, isPackage: isDirectory && isPackageFolder(fileSystem, node.sourcePath),
                    caseSensitive: caseSensitive))
            nodes[index].keepBothDestinationPath = keepBoth
            reservedPaths.insert(NameKeys.exactDestinationKey(keepBoth, caseSensitive: caseSensitive))
        }
        if nodes[index].conflictClass == .directoryConflict {
            try annotateKeepBothNames(&nodes[index].children, fileSystem, caseSensitive: caseSensitive, signal: signal)
        }
    }
}

/// Replacing an item that is, or contains, the item being pasted would destroy the source; so would replacing a
/// folder that holds another item of the same paste.
private func findReplaceBlockedReason(
    _ node: CopyPasteAnalysisNode, _ fileSystem: some AnalysisFileSystem, _ pasted: PastedItems
) -> String? {
    if node.conflictClass == nil {
        return nil
    }
    let relation = findSourceRelation(
        fileSystem, sourcePath: node.sourcePath, destinationPath: node.destinationPath,
        destination: node.destinationFingerprint)
    if relation == .same {
        return "It is the item being pasted."
    }
    if relation == .contains {
        return "It contains the item being pasted."
    }
    if node.destinationKind == .directory && holdsAnyOf(fileSystem, node.destinationPath, pasted) {
        return "It contains another item being pasted."
    }
    // Pasting "/x/a.txt" over "/d/a.txt" while "/d/a.txt" is pasted too (search results), told by identity as
    // the paste itself tells it, so another spelling of its path counts.
    if isAnyOf(fileSystem, node.destinationPath, pasted) {
        return "It is another item being pasted."
    }
    return nil
}

/// A folder inside `node` that is on another disk than the folder holding it (a disk mounted there), when a move
/// would copy it rather than rename it along with its folder: always on the way to another disk, and on the same
/// disk inside folders merged into others, whose items are moved one by one (each folder that isn't merged is
/// renamed whole).
private func findMountPointMovedByCopy(_ node: CopyPasteAnalysisNode, toAnotherDisk: Bool) -> String? {
    if !toAnotherDisk && node.conflictClass != .directoryConflict {
        return nil
    }
    for child in node.children {
        if child.sourceKind == .directory, let childDev = child.sourceFingerprint.dev,
            let dev = node.sourceFingerprint.dev, childDev != dev
        {
            return child.sourcePath
        }
        if let found = findMountPointMovedByCopy(child, toAnotherDisk: toAnotherDisk) {
            return found
        }
    }
    return nil
}

/// The identities ("dev:ino") of the folder at `realPath` and of every folder holding it. A real path has no
/// symlinks left in it, so its ancestors are the folders that really hold it (as findSourceRelation walks them).
private func folderIdsHolding(_ fileSystem: some AnalysisFileSystem, _ realPath: String) -> Set<String> {
    var ids = Set<String>()
    var folder = realPath
    while true {
        let fingerprint = captureFingerprint(fileSystem, folder)
        if let dev = fingerprint.dev, let ino = fingerprint.ino {
            ids.insert("\(dev):\(ino)")
        }
        let parent = NodePath.dirname(folder)
        if sameText(parent, folder) {
            return ids
        }
        folder = parent
    }
}

/// The counts of the whole review, walked with a list rather than by recursion.
private func summarizeAnalysis(_ nodes: [CopyPasteAnalysisNode]) -> CopyPasteAnalysisSummary {
    var summary = CopyPasteAnalysisSummary(
        topLevelItemCount: nodes.count, totalNodeCount: 0, totalBytes: 0, fileConflictCount: 0,
        directoryConflictCount: 0, mismatchConflictCount: 0, blockedCount: 0)
    // What a folder renamed whole holds wasn't read: the size of the whole isn't known.
    var bytesKnown = true
    var totalBytes: Int64 = 0
    var stack: [CopyPasteAnalysisNode] = nodes
    while let node = stack.popLast() {
        summary.totalNodeCount += 1
        bytesKnown = bytesKnown && !node.renameOnly
        if let size = node.sourceFingerprint.size {
            totalBytes += size
        }
        switch node.conflictClass {
        case .fileConflict: summary.fileConflictCount += 1
        case .directoryConflict: summary.directoryConflictCount += 1
        case .typeMismatch: summary.mismatchConflictCount += 1
        case nil: break
        }
        stack.append(contentsOf: node.children)
    }
    summary.totalBytes = bytesKnown ? totalBytes : nil
    return summary
}
