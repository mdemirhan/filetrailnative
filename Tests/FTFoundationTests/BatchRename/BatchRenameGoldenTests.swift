// Checks the batch-rename port against tools/parity/golden/batch-rename-propose.ts and batch-rename-plan.ts
import FTTestSupport
import Foundation
import Testing

@testable import FTFoundation

struct BatchRenameGoldenTests {
    // MARK: Wire shapes of the recordings

    struct WireItem: Codable {
        var path: String?
        var name: String
        var isFolder: Bool
        var createdAt: String?
        var modifiedAt: String?
        var takenAt: String?

        var item: BatchRenameItem {
            BatchRenameItem(
                path: path ?? "/trip/\(name)", name: name, isFolder: isFolder, createdAt: createdAt,
                modifiedAt: modifiedAt, takenAt: takenAt)
        }
    }

    struct WireSegment: Codable {
        var text: String
        var changed: Bool

        init(_ segment: NameSegment) {
            text = segment.text
            changed = segment.changed
        }
    }

    /// The part of an error message that is the same on every JavaScript engine.
    static func normalizedError(_ error: String?) -> String? {
        guard let error else { return nil }
        let prefix = "The pattern isn\u{2019}t valid:"
        return error.hasPrefix(prefix + " ") ? prefix : error
    }

    // MARK: proposeNames

    struct ProposeInput: Codable {
        var settings: BatchRenameSettings
        var items: [WireItem]
        var now: String
    }

    struct WireName: Codable {
        var kind: String
        var name: String?
        var segments: [WireSegment]?
        var usedCreatedForTaken: Bool?
        var emptyName: Bool?
    }

    struct ProposeOutput: Codable {
        var settingsError: String?
        var names: [WireName]
    }

    static func propose(_ input: ProposeInput) -> ProposeOutput {
        let result = BatchRename.proposeNames(settings: input.settings, items: input.items.map(\.item), now: input.now)
        let names = result.names.map { proposed -> WireName in
            switch proposed {
            case .unchanged:
                return WireName(kind: "unchanged")
            case .renamed(let name, let segments, let usedCreated, let emptyName):
                return WireName(
                    kind: "renamed", name: name, segments: segments.map(WireSegment.init),
                    usedCreatedForTaken: usedCreated ? true : nil, emptyName: emptyName ? true : nil)
            }
        }
        return ProposeOutput(settingsError: normalizedError(result.settingsError), names: names)
    }

    @Test func proposeNamesMatchesTheReference() throws {
        let cases: [GoldenCase<ProposeInput, ProposeOutput>] = try Golden.load(suite: "batch-rename-propose")
        #expect(cases.count == 600)
        Golden.expectMatches(cases, actual: Self.propose)
    }

    // MARK: planBatchRename

    struct PlanInput: Codable {
        var settings: BatchRenameSettings
        var items: [WireItem]
        var folders: [String: WireFolder]
        var cannotRename: [String: String]
        var now: String
    }

    struct WireFolder: Codable {
        var names: [String]
        var caseSensitive: Bool
    }

    struct WireProblem: Codable {
        var kind: String
        var message: String?
        var byItemInBatch: Bool?
    }

    struct WirePlanItem: Codable {
        var status: String
        var name: String?
        var proposedName: String?
        var segments: [WireSegment]?
        var addedNumber: Int?
        var numberedForItemInBatch: Bool?
        var usedCreatedForTaken: Bool?
        var becomesHidden: Bool?
        var problem: WireProblem?
    }

    struct PlanOutput: Codable {
        var settingsError: String?
        var items: [WirePlanItem]
        var renameCount: Int
        var unchangedCount: Int
        var skippedCount: Int
        var blockingCount: Int
    }

    static func plan(_ input: PlanInput) -> PlanOutput {
        let result = BatchRename.planBatchRename(
            BatchRenamePlanInput(
                settings: input.settings, items: input.items.map(\.item),
                folders: input.folders.mapValues {
                    BatchRenameFolder(names: $0.names, caseSensitive: $0.caseSensitive)
                },
                cannotRename: input.cannotRename, now: input.now))
        let items = result.items.map { planItem -> WirePlanItem in
            switch planItem {
            case .unchanged:
                return WirePlanItem(status: "unchanged")
            case .rename(let name, let segments, let added, let inBatch, let usedCreated, let hidden):
                return WirePlanItem(
                    status: "rename", name: name, segments: segments.map(WireSegment.init), addedNumber: added,
                    numberedForItemInBatch: inBatch, usedCreatedForTaken: usedCreated, becomesHidden: hidden)
            case .problem(let proposedName, let segments, let problem):
                let wire: WireProblem
                switch problem {
                case .invalid(let message): wire = WireProblem(kind: "invalid", message: message)
                case .cannotRename(let message): wire = WireProblem(kind: "cannotRename", message: message)
                case .taken(let byItem): wire = WireProblem(kind: "taken", byItemInBatch: byItem)
                case .skippedTaken(let byItem): wire = WireProblem(kind: "skippedTaken", byItemInBatch: byItem)
                }
                return WirePlanItem(
                    status: "problem", proposedName: proposedName, segments: segments.map(WireSegment.init),
                    problem: wire)
            }
        }
        return PlanOutput(
            settingsError: normalizedError(result.settingsError), items: items, renameCount: result.renameCount,
            unchangedCount: result.unchangedCount, skippedCount: result.skippedCount,
            blockingCount: result.blockingCount)
    }

    @Test func planMatchesTheReference() throws {
        let cases: [GoldenCase<PlanInput, PlanOutput>] = try Golden.load(suite: "batch-rename-plan")
        #expect(cases.count == 300)
        Golden.expectMatches(cases, actual: Self.plan)
    }
}
