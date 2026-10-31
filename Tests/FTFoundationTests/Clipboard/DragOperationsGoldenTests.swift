// The drop decisions of apps/desktop/src/renderer/lib/internalDragAndDrop.ts, checked against goldens recorded from
// the reference (tools/parity/golden/drag-operations.ts)
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

    // F-031 F-032 F-033 F-683 F-695 B-CLIP-157 B-CLIP-158 B-CLIP-159 B-CLIP-160 B-CLIP-161
    // B-SRCH-145
    @Test func dropDecisionsMatchTheReference() throws {
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
                sourcePaths: items.map(\.path), targetPath: target, option: input.altKey, command: input.metaKey,
                onSameDisk: same)
            let allowed = DragRules.allowedBySource(
                operation, offersMove: DragRules.offersMove(effectAllowed: input.effectAllowed))
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
}
