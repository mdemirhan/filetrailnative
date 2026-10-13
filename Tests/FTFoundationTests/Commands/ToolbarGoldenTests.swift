// Checks the port against goldens recorded from the reference: tools/parity/golden/toolbar-sanitize.ts
import FTTestSupport
import Foundation
import Testing

@testable import FTFoundation

struct ToolbarGoldenTests {
    struct Op: Codable, Sendable {
        let op: String
        let item: String?
        let index: Int?
        let from: Int?
        let to: Int?
    }

    struct Input: Codable, Sendable {
        let value: JSONNode
        let ops: [Op]
    }

    struct Output: Codable, Equatable, Sendable {
        let sanitized: [String]
        let palette: [String]
        let edited: [String]
    }

    static func run(_ input: Input) -> Output {
        let sanitized = ToolbarItems.sanitizeTopItems(input.value)
        var edited = sanitized
        for op in input.ops {
            switch op.op {
            case "add":
                edited = ToolbarItems.addTopItem(edited, ToolbarItemID(rawValue: op.item ?? "") ?? .back)
            case "insert":
                edited = ToolbarItems.insertTopItem(
                    edited, ToolbarItemID(rawValue: op.item ?? "") ?? .back, at: op.index ?? 0)
            case "move":
                edited = ToolbarItems.moveTopItem(edited, from: op.from ?? 0, to: op.to ?? 0)
            default:
                edited = ToolbarItems.removeTopItem(edited, at: op.index ?? 0)
            }
        }
        return Output(
            sanitized: sanitized.map(\.rawValue),
            palette: ToolbarItems.paletteItems(excluding: sanitized).map(\.rawValue),
            edited: edited.map(\.rawValue))
    }

    @Test func toolbarOrdersAreSanitizedAndEditedLikeTheOriginal() throws {
        let cases: [GoldenCase<Input, Output>] = try Golden.load(suite: "toolbar-sanitize")
        #expect(cases.count >= 200)
        Golden.expectMatches(cases) { Self.run($0) }
    }
}
