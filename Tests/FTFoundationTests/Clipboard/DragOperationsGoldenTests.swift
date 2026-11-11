// The drop decisions, checked against the drag-operations golden
import FTTestSupport
import Foundation
import Testing

@testable import FTFoundation

struct DragOperationsGoldenTests {
    struct Item: Codable, Sendable {
        let path: String
        let kind: String
    }

    struct Input: Codable, Sendable {
        let sourceSurface: String
        let items: [Item]
        let targetSurface: String
        let targetPath: String?
        let targetSupportsMove: Bool
        let targetIsSelected: Bool
        let blocked: Bool
        let altKey: Bool
        let metaKey: Bool
        let diskIds: [[DiskIdPart]]?
        let effectAllowed: String?
    }

    /// One half of a `[path, id]` pair.
    enum DiskIdPart: Codable, Sendable {
        case path(String)
        case id(Int64?)

        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let text = try? container.decode(String.self) {
                self = .path(text)
            } else if container.decodeNil() {
                self = .id(nil)
            } else {
                self = .id(try container.decode(Int64.self))
            }
        }

        func encode(to encoder: any Encoder) throws {}
    }

    struct Output: Codable, Equatable, Sendable {
        let folderPaths: [String]
        let onSameDisk: Bool?
        let operation: String
        let allowed: String
        let refusal: String?
    }

    @Test func dropDecisionsMatchTheGoldenFile() throws {
        let cases: [GoldenCase<Input, Output>] = try Golden.load(suite: "drag-operations")
        #expect(cases.count >= 400)
        Golden.expectMatches(cases) { input in
            let items = input.items.map { DragItem(path: $0.path, kind: EntryKind(rawValue: $0.kind) ?? .other) }
            let folders = DragRules.sourceFolderPaths(items)
            let target = input.targetPath ?? ""
            var same: Bool?
            if let pairs = input.diskIds {
                var ids: [NameKeys.Exact: Int64?] = [:]
                for pair in pairs {
                    guard case .path(let path) = pair[0], case .id(let id) = pair[1] else { continue }
                    ids[NameKeys.Exact(path)] = .some(id)
                }
                same = DragRules.onSameDisk(sourceFolderPaths: folders, targetPath: target) { ids[NameKeys.Exact($0)] }
            }
            let operation = DragRules.operation(
                DragFacts(items), targetPath: target, option: input.altKey, command: input.metaKey, onSameDisk: same)
            let allowed = DragRules.allowedBySource(operation, offersMove: Self.offersMove(input.effectAllowed))
            let session =
                items.first.map {
                    DragSession(
                        sourceSurface: DragSourceSurface(rawValue: input.sourceSurface) ?? .content, sourceItems: items,
                        leadPath: $0.path, leadKind: $0.kind)
                }
            let refusal = DragRules.validate(
                session: session, blocked: input.blocked,
                targetSurface: DropTargetSurface(rawValue: input.targetSurface) ?? .content,
                targetPath: input.targetPath, targetSupportsMove: input.targetSupportsMove,
                targetIsSelected: input.targetIsSelected, operation: allowed)
            return Output(
                folderPaths: folders, onSameDisk: same, operation: operation.rawValue, allowed: allowed.rawValue,
                refusal: refusal?.rawValue)
        }
    }

    /// Whether a page's drag (`effectAllowed`) offers a move, as the recordings say it: nil (not said) does.
    static func offersMove(_ effectAllowed: String?) -> Bool {
        guard let effectAllowed else { return true }
        return ["move", "copyMove", "linkMove", "all", "uninitialized"].contains(effectAllowed)
    }
}
