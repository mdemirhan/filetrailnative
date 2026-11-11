// Checks how the toolbar's saved items are sanitized, against the toolbar-sanitize golden
import FTTestSupport
import Foundation
import Testing

@testable import FTFoundation

struct ToolbarGoldenTests {
    struct Input: Codable, Sendable {
        let value: JSONNode
    }

    struct Output: Codable, Equatable, Sendable {
        let sanitized: [String]
        let palette: [String]
    }

    static func run(_ input: Input) -> Output {
        let sanitized = ToolbarItems.sanitizeTopItems(input.value)
        return Output(
            sanitized: sanitized.map(\.rawValue),
            palette: ToolbarItems.paletteItems(excluding: sanitized).map(\.rawValue))
    }

    @Test func toolbarOrdersAreSanitizedAsTheGoldenFileSays() throws {
        let cases: [GoldenCase<Input, Output>] = try Golden.load(suite: "toolbar-sanitize")
        #expect(cases.count >= 200)
        Golden.expectMatches(cases) { Self.run($0) }
    }
}
