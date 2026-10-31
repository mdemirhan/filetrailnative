// Port of packages/core/src/fs/copyPastePolicy.test.ts
import FTFoundation
import Foundation
import Testing

@testable import FTOperations

func makeNode(
    id: String, sourcePath: String, destinationPath: String, sourceKind: CopyPasteNodeKind = .file,
    destinationKind: CopyPasteNodeKind = .missing, conflictClass: ConflictClass? = nil,
    children: [CopyPasteAnalysisNode] = []
) -> CopyPasteAnalysisNode {
    CopyPasteAnalysisNode(
        id: id, sourcePath: sourcePath, destinationPath: destinationPath, sourceKind: sourceKind,
        destinationKind: destinationKind, disposition: conflictClass == nil ? .new : .conflict,
        conflictClass: conflictClass,
        sourceFingerprint: NodeFingerprint(
            exists: true, kind: sourceKind, size: 1, mtimeMs: 1, mode: 0o644, ino: 1, dev: 1),
        destinationFingerprint: NodeFingerprint(exists: destinationKind != .missing, kind: destinationKind),
        children: children, totalNodeCount: 1, conflictNodeCount: conflictClass == nil ? 0 : 1)
}

func makeReport(_ nodes: [CopyPasteAnalysisNode]) -> CopyPasteAnalysisReport {
    CopyPasteAnalysisReport(
        analysisId: "analysis-1", mode: .copy, sourcePaths: nodes.map(\.sourcePath),
        destinationDirectoryPath: "/target",
        nodes: nodes, issues: [], warnings: [],
        summary: CopyPasteAnalysisSummary(
            topLevelItemCount: nodes.count, totalNodeCount: nodes.count, totalBytes: 1,
            fileConflictCount: nodes.filter { $0.conflictClass == .fileConflict }.count,
            directoryConflictCount: nodes.filter { $0.conflictClass == .directoryConflict }.count,
            mismatchConflictCount: nodes.filter { $0.conflictClass == .typeMismatch }.count, blockedCount: 0))
}

struct CopyPastePolicyTests {
    // T-0e982448 F-437 F-321 F-322
    @Test func resolvesFileConflictsWithOverwriteSkipAndKeepBothActions() throws {
        let fileSystem = MockAnalysisFileSystem([
            ("/target", .directory()), ("/target/report copy.txt", .file(size: 1)),
        ])
        let node = makeNode(
            id: "file", sourcePath: "/source/report.txt", destinationPath: "/target/report.txt",
            destinationKind: .file, conflictClass: .fileConflict)
        func resolve(_ file: CopyPasteChoice) throws -> ResolvedCopyPasteNode? {
            try resolveAnalysisWithPolicy(
                report: makeReport([node]), policy: CopyPastePolicy(file: file, directory: .merge, mismatch: .skip),
                fileSystem: fileSystem
            ).first
        }

        let overwrite = try resolve(.overwrite)
        #expect(overwrite?.action == .overwrite)
        #expect(overwrite?.destinationPath == "/target/report.txt")

        #expect(try resolve(.skip)?.action == .skip)

        let keepBoth = try resolve(.keepBoth)
        #expect(keepBoth?.action == .keepBoth)
        #expect(keepBoth?.destinationPath == "/target/report copy 2.txt")
    }

    // T-e5a3e87e F-438 F-323
    @Test func resolvesDirectoryConflictsAsMergeSkipOrKeepBothAndPropagatesChildActions() throws {
        let fileSystem = MockAnalysisFileSystem([("/target", .directory()), ("/target/Folder copy", .directory())])
        let directoryNode = makeNode(
            id: "dir", sourcePath: "/source/Folder", destinationPath: "/target/Folder", sourceKind: .directory,
            destinationKind: .directory, conflictClass: .directoryConflict,
            children: [
                makeNode(
                    id: "dir/a.txt", sourcePath: "/source/Folder/a.txt", destinationPath: "/target/Folder/a.txt",
                    destinationKind: .file, conflictClass: .fileConflict),
                makeNode(
                    id: "dir/nested", sourcePath: "/source/Folder/nested", destinationPath: "/target/Folder/nested",
                    sourceKind: .directory, destinationKind: .directory, conflictClass: .directoryConflict,
                    children: [
                        makeNode(
                            id: "dir/nested/deep.txt", sourcePath: "/source/Folder/nested/deep.txt",
                            destinationPath: "/target/Folder/nested/deep.txt", destinationKind: .file,
                            conflictClass: .fileConflict)
                    ]),
            ])
        func resolve(_ directory: CopyPasteChoice) throws -> ResolvedCopyPasteNode {
            try #require(
                try resolveAnalysisWithPolicy(
                    report: makeReport([directoryNode]),
                    policy: CopyPastePolicy(file: .overwrite, directory: directory, mismatch: .skip),
                    fileSystem: fileSystem
                ).first)
        }

        let merge = try resolve(.merge)
        #expect(merge.action == .merge)
        #expect(merge.children.first?.action == .overwrite)

        let skip = try resolve(.skip)
        #expect(skip.action == .skip)
        #expect(skip.children.first?.action == .skip)

        let keepBoth = try resolve(.keepBoth)
        #expect(keepBoth.action == .keepBoth)
        #expect(keepBoth.destinationPath == "/target/Folder copy 2")
        #expect(keepBoth.children.first?.action == .create)
        #expect(keepBoth.children.first?.destinationPath == "/target/Folder copy 2/a.txt")
        #expect(keepBoth.children.last?.action == .create)
        #expect(keepBoth.children.last?.destinationPath == "/target/Folder copy 2/nested")
        #expect(keepBoth.children.last?.children.first?.destinationPath == "/target/Folder copy 2/nested/deep.txt")

        let overwrite = try resolve(.overwrite)
        #expect(overwrite.action == .overwrite)
        #expect(overwrite.destinationPath == "/target/Folder")
        #expect(overwrite.children.first?.action == .create)
        #expect(overwrite.children.first?.destinationPath == "/target/Folder/a.txt")
    }

    // T-de732ae4 F-439
    @Test func usesMismatchPolicyForTypeConflicts() throws {
        let fileSystem = MockAnalysisFileSystem([("/target", .directory())])
        let node = makeNode(
            id: "mismatch", sourcePath: "/source/readme", destinationPath: "/target/readme",
            destinationKind: .directory,
            conflictClass: .typeMismatch)

        let resolved = try resolveAnalysisWithPolicy(
            report: makeReport([node]), policy: CopyPastePolicy(file: .skip, directory: .merge, mismatch: .overwrite),
            fileSystem: fileSystem)

        #expect(resolved.first?.action == .overwrite)
    }

    // A policy is a whole CopyPastePolicy here, so an incomplete one can't be given: the rule is reached as the
    // original reaches it while the paste runs, by a Merge answered with no policy to decide what is inside.
    // T-e505f05f F-440 F-321
    @Test(arguments: [
        (ConflictClass.directoryConflict, "Missing directory conflict policy."),
        (ConflictClass.typeMismatch, "Missing mismatch conflict policy."),
        (ConflictClass.fileConflict, "Missing file conflict policy."),
    ])
    func rejectsIncompleteConflictPolicy(_ conflictClass: ConflictClass, _ expectedMessage: String) throws {
        let fileSystem = MockAnalysisFileSystem([("/target", .directory())])
        let node = makeNode(
            id: "missing-\(conflictClass.rawValue)", sourcePath: "/source/folder/item",
            destinationPath: "/target/folder/item",
            sourceKind: conflictClass == .directoryConflict ? .directory : .file,
            destinationKind: conflictClass == .typeMismatch ? .directory : .file, conflictClass: conflictClass)
        let folder = makeNode(
            id: "folder", sourcePath: "/source/folder", destinationPath: "/target/folder", sourceKind: .directory,
            destinationKind: .directory, conflictClass: .directoryConflict, children: [node])

        let error = #expect(throws: (any Error).self) {
            try resolveSingleNodeWithAction(node: folder, action: .merge, policy: nil, fileSystem: fileSystem)
        }
        #expect(error.map(errorMessage) == expectedMessage)
    }

    // T-eb2b7cd5 F-441
    @Test func joinsChildDestinationsUnderFilesystemRootWithoutDuplicateSeparators() throws {
        let fileSystem = MockAnalysisFileSystem([("/Folder copy", .directory())])
        let directoryNode = makeNode(
            id: "root-dir", sourcePath: "/source/Folder", destinationPath: "/Folder", sourceKind: .directory,
            destinationKind: .directory, conflictClass: .directoryConflict,
            children: [
                makeNode(id: "root-dir/a.txt", sourcePath: "/source/Folder/a.txt", destinationPath: "/Folder/a.txt")
            ])

        let resolved = try #require(
            try resolveAnalysisWithPolicy(
                report: makeReport([directoryNode]),
                policy: CopyPastePolicy(file: .skip, directory: .keepBoth, mismatch: .skip), fileSystem: fileSystem
            ).first)

        #expect(resolved.destinationPath == "/Folder copy 2")
        #expect(resolved.children.first?.destinationPath == "/Folder copy 2/a.txt")
    }

    // T-117acdd0 F-442
    @Test func allowsExplicitRuntimeActionsToOverrideTheStoredPolicy() throws {
        let fileSystem = MockAnalysisFileSystem([("/target", .directory()), ("/target/file copy.txt", .file(size: 1))])
        let node = makeNode(
            id: "runtime", sourcePath: "/source/file.txt", destinationPath: "/target/file.txt", destinationKind: .file,
            conflictClass: .fileConflict)

        let resolved = try resolveSingleNodeWithAction(
            node: node, action: .keepBoth, policy: nil, fileSystem: fileSystem)

        #expect(resolved.action == .keepBoth)
        #expect(resolved.destinationPath == "/target/file copy 2.txt")
    }

    // T-1afed77f F-443
    @Test func treatsDirectoryOverwriteChildrenAsCreatesBecauseTheParentIsReplacedFresh() throws {
        let fileSystem = MockAnalysisFileSystem([("/target", .directory())])
        let node = makeNode(
            id: "runtime-dir", sourcePath: "/source/Folder", destinationPath: "/target/Folder", sourceKind: .directory,
            destinationKind: .file, conflictClass: .typeMismatch,
            children: [
                makeNode(
                    id: "runtime-dir/nested", sourcePath: "/source/Folder/nested",
                    destinationPath: "/target/Folder/nested", sourceKind: .directory, destinationKind: .directory,
                    conflictClass: .directoryConflict,
                    children: [
                        makeNode(
                            id: "runtime-dir/nested/deep.txt", sourcePath: "/source/Folder/nested/deep.txt",
                            destinationPath: "/target/Folder/nested/deep.txt", destinationKind: .file,
                            conflictClass: .fileConflict)
                    ])
            ])

        let resolved = try resolveSingleNodeWithAction(
            node: node, action: .overwrite, policy: nil, fileSystem: fileSystem)

        #expect(resolved.action == .overwrite)
        #expect(resolved.children.first?.action == .create)
        #expect(resolved.children.first?.children.first?.action == .create)
    }

    /// A Keep Both answered while the paste runs takes no name the paste has planned, and claims its own.
    @Test func aRuntimeKeepBothNameAvoidsNamesThePasteHasPlanned() throws {
        let fileSystem = MockAnalysisFileSystem([("/target", .directory()), ("/target/file.txt", .file(size: 1))])
        let node = makeNode(
            id: "runtime", sourcePath: "/source/file.txt", destinationPath: "/target/file.txt", destinationKind: .file,
            conflictClass: .fileConflict)
        var reserved: Set<NameKeys.Exact> = [NameKeys.exactDestinationKey("/target/file copy.txt")]

        let resolved = try resolveSingleNodeWithAction(
            node: node, action: .keepBoth, policy: nil, fileSystem: fileSystem, reservedPaths: &reserved)

        #expect(resolved.destinationPath == "/target/file copy 2.txt")
        #expect(reserved.contains(NameKeys.exactDestinationKey("/target/file copy 2.txt")))
    }
}
