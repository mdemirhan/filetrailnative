// Port of packages/core/src/fs/copyPasteScenarioMatrix.test.ts, with snapshotMockFileSystem
// (packages/core/src/fs/testUtils.ts)
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTOperations

/// One item as `snapshotMockFileSystem` describes it.
struct MockSnapshotEntry: Equatable, CustomStringConvertible {
    var kind: MockWriteServiceFileSystem.Kind
    var size: Int64?
    var mode: UInt32
    var target: String?

    var description: String {
        "\(kind) \(size.map(String.init) ?? "-") \(String(mode, radix: 8)) \(target ?? "")"
    }
}

extension MockWriteServiceFileSystem {
    /// `snapshotMockFileSystem`: every item, by path.
    func snapshot() -> [String: MockSnapshotEntry] {
        var entries: [String: MockSnapshotEntry] = [:]
        for path in paths {
            guard let node = readNode(path) else { continue }
            switch node.kind {
            case .file: entries[path] = MockSnapshotEntry(kind: .file, size: node.size, mode: node.mode)
            case .directory: entries[path] = MockSnapshotEntry(kind: .directory, mode: node.mode)
            case .symlink:
                entries[path] = MockSnapshotEntry(kind: .symlink, mode: node.mode, target: node.target ?? "")
            }
        }
        return entries
    }
}

private func dir(_ mode: UInt32 = 0o755) -> MockSnapshotEntry {
    MockSnapshotEntry(kind: .directory, mode: mode)
}

private func file(_ size: Int64, _ mode: UInt32 = 0o644) -> MockSnapshotEntry {
    MockSnapshotEntry(kind: .file, size: size, mode: mode)
}

private typealias Seed = [(String, MockWriteServiceFileSystem.Seed)]

private struct MatrixScenario {
    var name: String
    var mode: CopyPasteMode
    var seed: Seed
    var sources: [String]
    var policy: CopyPastePolicy
    var expectedStatus: CopyPasteOperationStatus
    var expectedSnapshot: [String: MockSnapshotEntry]
}

private struct ScenarioRun {
    var fileSystem: MockWriteServiceFileSystem
    var runtimeConflicts: [CopyPasteRuntimeConflict]
    var result: CopyPasteOperationResult?
}

private func runScenario(
    mode: CopyPasteMode, seed: Seed, sources: [String], into destination: String = "/target",
    policy: CopyPastePolicy, runtimeResolution: CopyPasteChoice? = nil,
    mutateAfterResolve: ((MockWriteServiceFileSystem) -> Void)? = nil
) async throws -> ScenarioRun {
    let fileSystem = MockWriteServiceFileSystem(seed)
    // As in the app: items replaced by a paste go to the Trash.
    fileSystem.enableTrash()
    let operation = try createResolvedOperation(
        fileSystem, mode: mode, sources: sources, into: destination, policy: policy)
    mutateAfterResolve?(fileSystem)
    let recorder = PasteRecorder()
    let events = await execute(
        fileSystem, operation, policy: policy, recorder: recorder,
        requestResolution: { _ in .immediate(runtimeResolution ?? .skip) })
    return ScenarioRun(
        fileSystem: fileSystem, runtimeConflicts: recorder.conflicts,
        result: events.reversed().first { $0.result != nil }?.result)
}

private func relevantTree(_ fileSystem: MockWriteServiceFileSystem) -> [String: MockSnapshotEntry] {
    fileSystem.snapshot().filter { path, _ in
        path == "/source" || path.hasPrefix("/source/") || path == "/target" || path.hasPrefix("/target/")
    }
}

private func merged(_ parts: [String: MockSnapshotEntry]...) -> [String: MockSnapshotEntry] {
    parts.reduce(into: [:]) { result, part in result.merge(part) { _, new in new } }
}

struct ScenarioMatrixTests {
    private func check(_ scenarios: [MatrixScenario]) async throws {
        for scenario in scenarios {
            let run = try await runScenario(
                mode: scenario.mode, seed: scenario.seed, sources: scenario.sources, policy: scenario.policy)
            let name = Comment(rawValue: scenario.name)
            #expect(run.runtimeConflicts.isEmpty, name)
            #expect(run.result?.status == scenario.expectedStatus, name)
            #expect(relevantTree(run.fileSystem) == scenario.expectedSnapshot, name)
        }
    }

    // T-a67327a8 F-506
    @Test func keepBothRegressions() async throws {
        try await check(Self.keepBothRegressionScenarios())
    }

    // T-8483d2b5 F-506
    @Test func directoryPolicies() async throws {
        try await check(Self.directoryPolicyScenarios())
    }

    // T-06fe2b2e F-506
    @Test func filePolicies() async throws {
        try await check(Self.filePolicyScenarios())
    }

    // T-e1436157 F-506
    @Test func mismatchPolicies() async throws {
        try await check(Self.mismatchPolicyScenarios())
    }

    // T-0d4cc0d5 F-506
    @Test func promptsOnceWhenTheResolvedKeepBothDestinationIsActuallyCreatedAfterPlanning() async throws {
        let run = try await runScenario(
            mode: .copy,
            seed: [
                ("/source", .directory()), ("/source/report.txt", .file(size: 5)), ("/target", .directory()),
                ("/target/report.txt", .file(size: 3)),
            ], sources: ["/source/report.txt"],
            policy: CopyPastePolicy(file: .keepBoth, directory: .merge, mismatch: .overwrite),
            runtimeResolution: .keepBoth,
            mutateAfterResolve: { $0.addFile("/target/report copy.txt", .file(size: 4)) })

        #expect(run.runtimeConflicts.count == 1)
        #expect(run.runtimeConflicts.first?.reason == .destinationCreated)
        #expect(run.result?.status == .completed)
        #expect(
            relevantTree(run.fileSystem) == [
                "/source": dir(), "/source/report.txt": file(5), "/target": dir(),
                "/target/report copy.txt": file(4), "/target/report copy 2.txt": file(5),
                "/target/report.txt": file(3),
            ])
    }

    private static let folderGainedItemSeed: Seed = [
        ("/source", .directory()), ("/source/Folder", .directory()), ("/source/Folder/a.txt", .file(size: 7)),
        ("/target", .directory()), ("/target/Folder", .directory()), ("/target/Folder/stale.txt", .file(size: 1)),
    ]

    // A folder is known by its identity: an item added to it after the review goes to the Trash with it, where it
    // can be got back, without asking.
    // T-802dd144 F-506 F-342
    @Test func sendsAFolderThatGainedAnItemAfterTheReviewToTheTrashWithIt() async throws {
        let run = try await runScenario(
            mode: .copy, seed: Self.folderGainedItemSeed, sources: ["/source/Folder"], policy: NativePaste.replaceAll,
            mutateAfterResolve: { $0.addFile("/target/Folder/late-change.txt", .file(size: 5)) })

        #expect(run.runtimeConflicts.isEmpty)
        #expect(run.result?.status == .completed)
        #expect(run.fileSystem.trashed == ["/target/Folder"])
        #expect(
            relevantTree(run.fileSystem) == [
                "/source": dir(), "/source/Folder": dir(), "/source/Folder/a.txt": file(7), "/target": dir(),
                "/target/Folder": dir(), "/target/Folder/a.txt": file(7),
            ])
    }

    // Finder writes .DS_Store into a folder just by showing it: that is no reason to ask.
    // T-485aa719 F-506
    @Test func doesntAskAgainWhenOnlyFindersDSStoreAppearedInTheFolder() async throws {
        let run = try await runScenario(
            mode: .copy, seed: Self.folderGainedItemSeed, sources: ["/source/Folder"], policy: NativePaste.replaceAll,
            mutateAfterResolve: { $0.addFile("/target/Folder/.DS_Store", .file(size: 5)) })

        #expect(run.runtimeConflicts.isEmpty)
        #expect(run.result?.status == .completed)
        #expect(relevantTree(run.fileSystem)["/target/Folder/a.txt"] == file(7))
    }

    // MARK: Scenarios

    private static func keepBothRegressionScenarios() -> [MatrixScenario] {
        let fullFolderSeed: Seed = [
            ("/source", .directory()), ("/source/x", .directory()), ("/source/x/a.txt", .file(size: 1)),
            ("/source/x/nested", .directory()), ("/source/x/nested/b.txt", .file(size: 2)), ("/target", .directory()),
        ]
        let identical =
            fullFolderSeed + [
                ("/target/x", .directory()), ("/target/x/a.txt", .file(size: 1)), ("/target/x/nested", .directory()),
                ("/target/x/nested/b.txt", .file(size: 2)),
            ]
        let empty = fullFolderSeed + [("/target/x", .directory())]
        return [
            keepBothScenario(
                "copies an identical folder tree into a duplicate folder without false live-change prompts", .copy,
                identical, full: true),
            keepBothScenario(
                "cuts an identical folder tree into a duplicate folder without false live-change prompts", .cut,
                identical, full: true),
            keepBothScenario(
                "copies a full folder into a sibling of an existing empty same-name folder", .copy, empty, full: false),
            keepBothScenario(
                "cuts a full folder into a sibling of an existing empty same-name folder", .cut, empty, full: false),
        ]
    }

    private static func keepBothScenario(_ name: String, _ mode: CopyPasteMode, _ seed: Seed, full: Bool)
        -> MatrixScenario
    {
        let source: [String: MockSnapshotEntry] =
            mode == .copy
            ? [
                "/source": dir(), "/source/x": dir(), "/source/x/a.txt": file(1), "/source/x/nested": dir(),
                "/source/x/nested/b.txt": file(2),
            ] : ["/source": dir()]
        var target: [String: MockSnapshotEntry] = [
            "/target": dir(), "/target/x": dir(), "/target/x copy": dir(), "/target/x copy/a.txt": file(1),
            "/target/x copy/nested": dir(), "/target/x copy/nested/b.txt": file(2),
        ]
        if full {
            target["/target/x/a.txt"] = file(1)
            target["/target/x/nested"] = dir()
            target["/target/x/nested/b.txt"] = file(2)
        }
        return MatrixScenario(
            name: name, mode: mode, seed: seed, sources: ["/source/x"],
            policy: CopyPastePolicy(file: .overwrite, directory: .keepBoth, mismatch: .overwrite),
            expectedStatus: .completed, expectedSnapshot: merged(source, target))
    }

    private static func directoryPolicyScenarios() -> [MatrixScenario] {
        [CopyPasteMode.copy, .cut].flatMap { mode in
            [CopyPasteChoice.merge, .overwrite, .skip, .keepBoth].map { directoryPolicyScenario(mode, $0) }
        }
    }

    private static func directoryPolicyScenario(_ mode: CopyPasteMode, _ policy: CopyPasteChoice)
        -> MatrixScenario
    {
        let seed: Seed = [
            ("/source", .directory()), ("/source/Folder", .directory()), ("/source/Folder/new.txt", .file(size: 1)),
            ("/source/Folder/shared.txt", .file(size: 8, mode: 0o755)), ("/source/Folder/nested", .directory()),
            ("/source/Folder/nested/inside.txt", .file(size: 4)), ("/target", .directory()),
            ("/target/Folder", .directory()), ("/target/Folder/shared.txt", .file(size: 2, mode: 0o600)),
            ("/target/Folder/target-only.txt", .file(size: 3)), ("/target/Folder/nested", .directory()),
            ("/target/Folder/nested/inside.txt", .file(size: 1)),
            ("/target/Folder/nested/target-only-nested.txt", .file(size: 9)),
        ]
        let fullSource: [String: MockSnapshotEntry] = [
            "/source": dir(), "/source/Folder": dir(), "/source/Folder/new.txt": file(1),
            "/source/Folder/shared.txt": file(8, 0o755), "/source/Folder/nested": dir(),
            "/source/Folder/nested/inside.txt": file(4),
        ]
        let source = mode == .copy || policy == .skip ? fullSource : ["/source": dir()]
        let untouchedTarget: [String: MockSnapshotEntry] = [
            "/target": dir(), "/target/Folder": dir(), "/target/Folder/shared.txt": file(2, 0o600),
            "/target/Folder/target-only.txt": file(3), "/target/Folder/nested": dir(),
            "/target/Folder/nested/inside.txt": file(1), "/target/Folder/nested/target-only-nested.txt": file(9),
        ]
        let target: [String: MockSnapshotEntry]
        switch policy {
        case .merge:
            target = [
                "/target": dir(), "/target/Folder": dir(), "/target/Folder/new.txt": file(1),
                "/target/Folder/shared.txt": file(8, 0o755), "/target/Folder/target-only.txt": file(3),
                "/target/Folder/nested": dir(), "/target/Folder/nested/inside.txt": file(4),
                "/target/Folder/nested/target-only-nested.txt": file(9),
            ]
        case .overwrite:
            target = [
                "/target": dir(), "/target/Folder": dir(), "/target/Folder/new.txt": file(1),
                "/target/Folder/shared.txt": file(8, 0o755), "/target/Folder/nested": dir(),
                "/target/Folder/nested/inside.txt": file(4),
            ]
        case .skip:
            target = untouchedTarget
        case .keepBoth:
            target = merged(
                untouchedTarget,
                [
                    "/target/Folder copy": dir(), "/target/Folder copy/new.txt": file(1),
                    "/target/Folder copy/shared.txt": file(8, 0o755), "/target/Folder copy/nested": dir(),
                    "/target/Folder copy/nested/inside.txt": file(4),
                ])
        }
        return MatrixScenario(
            name: "\(mode.rawValue) applies directory policy \(policy.rawValue) to the full subtree consistently",
            mode: mode, seed: seed, sources: ["/source/Folder"],
            policy: CopyPastePolicy(file: .overwrite, directory: policy, mismatch: .overwrite),
            expectedStatus: policy == .skip ? .partial : .completed, expectedSnapshot: merged(source, target))
    }

    private static func filePolicyScenarios() -> [MatrixScenario] {
        [CopyPasteMode.copy, .cut].flatMap { mode in
            [CopyPasteChoice.overwrite, .skip, .keepBoth].map { filePolicyScenario(mode, $0) }
        }
    }

    private static func filePolicyScenario(_ mode: CopyPasteMode, _ policy: CopyPasteChoice) -> MatrixScenario {
        let source: [String: MockSnapshotEntry] =
            mode == .copy || policy == .skip
            ? ["/source": dir(), "/source/report.txt": file(5, 0o755)] : ["/source": dir()]
        let target: [String: MockSnapshotEntry] =
            switch policy {
            case .overwrite: ["/target": dir(), "/target/report.txt": file(5, 0o755)]
            case .skip: ["/target": dir(), "/target/report.txt": file(2, 0o600)]
            case .keepBoth, .merge:
                [
                    "/target": dir(), "/target/report copy.txt": file(5, 0o755),
                    "/target/report.txt": file(2, 0o600),
                ]
            }
        return MatrixScenario(
            name: "\(mode.rawValue) applies file policy \(policy.rawValue) deterministically", mode: mode,
            seed: [
                ("/source", .directory()), ("/source/report.txt", .file(size: 5, mode: 0o755)),
                ("/target", .directory()), ("/target/report.txt", .file(size: 2, mode: 0o600)),
            ], sources: ["/source/report.txt"],
            policy: CopyPastePolicy(file: policy, directory: .merge, mismatch: .overwrite),
            expectedStatus: policy == .skip ? .partial : .completed, expectedSnapshot: merged(source, target))
    }

    private static func mismatchPolicyScenarios() -> [MatrixScenario] {
        [CopyPasteMode.copy, .cut].flatMap { mode in
            let policies: [CopyPasteChoice] = [.overwrite, .skip, .keepBoth]
            return policies.map { fileOverDirectoryScenario(mode, $0) }
                + policies.map { directoryOverFileScenario(mode, $0) }
        }
    }

    private static func fileOverDirectoryScenario(_ mode: CopyPasteMode, _ policy: CopyPasteChoice)
        -> MatrixScenario
    {
        let source: [String: MockSnapshotEntry] =
            mode == .copy || policy == .skip ? ["/source": dir(), "/source/item": file(7)] : ["/source": dir()]
        let target: [String: MockSnapshotEntry] =
            switch policy {
            case .overwrite: ["/target": dir(), "/target/item": file(7)]
            case .skip: ["/target": dir(), "/target/item": dir()]
            case .keepBoth, .merge: ["/target": dir(), "/target/item": dir(), "/target/item copy": file(7)]
            }
        return MatrixScenario(
            name: "\(mode.rawValue) applies mismatch policy \(policy.rawValue) when a file collides with a directory",
            mode: mode,
            seed: [
                ("/source", .directory()), ("/source/item", .file(size: 7)), ("/target", .directory()),
                ("/target/item", .directory()),
            ], sources: ["/source/item"],
            policy: CopyPastePolicy(file: .overwrite, directory: .merge, mismatch: policy),
            expectedStatus: policy == .skip ? .partial : .completed, expectedSnapshot: merged(source, target))
    }

    private static func directoryOverFileScenario(_ mode: CopyPasteMode, _ policy: CopyPasteChoice)
        -> MatrixScenario
    {
        let source: [String: MockSnapshotEntry] =
            mode == .copy || policy == .skip
            ? ["/source": dir(), "/source/item": dir(), "/source/item/inside.txt": file(6)] : ["/source": dir()]
        let target: [String: MockSnapshotEntry] =
            switch policy {
            case .overwrite: ["/target": dir(), "/target/item": dir(), "/target/item/inside.txt": file(6)]
            case .skip: ["/target": dir(), "/target/item": file(2)]
            case .keepBoth, .merge:
                [
                    "/target": dir(), "/target/item": file(2), "/target/item copy": dir(),
                    "/target/item copy/inside.txt": file(6),
                ]
            }
        return MatrixScenario(
            name: "\(mode.rawValue) applies mismatch policy \(policy.rawValue) when a directory collides with a file",
            mode: mode,
            seed: [
                ("/source", .directory()), ("/source/item", .directory()), ("/source/item/inside.txt", .file(size: 6)),
                ("/target", .directory()), ("/target/item", .file(size: 2)),
            ], sources: ["/source/item"],
            policy: CopyPastePolicy(file: .overwrite, directory: .merge, mismatch: policy),
            expectedStatus: policy == .skip ? .partial : .completed, expectedSnapshot: merged(source, target))
    }
}
