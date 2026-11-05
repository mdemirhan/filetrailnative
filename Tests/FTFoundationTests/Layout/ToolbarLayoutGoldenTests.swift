// Checks the toolbar's layout against the toolbar-layout golden
import FTTestSupport
import Foundation
import Testing

@testable import FTFoundation

struct ToolbarLayoutGoldenTests {
    struct Input: Codable, Sendable {
        let items: [String]?
        let widths: [String: Double]?
        let shown: [String]?
        let availableWidth: Double?
        let optionalCount: Int?
        let centers: [Double]?
        let pointerX: Double?
    }

    struct Edges: Codable, Equatable, Sendable {
        let start: Bool
        let end: Bool
    }

    struct Output: Codable, Equatable, Sendable {
        let slots: [String]?
        let capsules: [String: Edges]?
        let visibleCount: Int?
        let selected: [String]?
        let selectedForCount: [String]?
        let dropIndex: Int?
        let stylesheet: [String: Double]?
        let topToolbarLayout: [String: Double]?
        let explorerLayout: [String: Double]?
        let treeLayout: [String: Double]?
    }

    static func run(_ input: Input) -> Output {
        let items = ToolbarItems.sanitizeTopItems(.array((input.items ?? []).map { .string($0) }))
        let slots = TopToolbarLayout.slots(items)
        let shown = Set(input.shown ?? [])
        let capsules = TopToolbarLayout.capsules(slots) { shown.contains($0.key) }
        let visible = TopToolbarLayout.visibleOptionalCount(
            slots: slots, widths: input.widths ?? [:], availableWidth: input.availableWidth ?? 0)
        return Output(
            slots: slots.map(\.key), capsules: capsules.mapValues { Edges(start: $0.start, end: $0.end) },
            visibleCount: visible, selected: TopToolbarLayout.select(slots, optionalCount: visible).map(\.key),
            selectedForCount: TopToolbarLayout.select(slots, optionalCount: input.optionalCount ?? 0).map(\.key),
            dropIndex: TopToolbarLayout.dropIndex(centers: input.centers ?? [], pointerX: input.pointerX ?? 0),
            stylesheet: nil, topToolbarLayout: nil, explorerLayout: nil, treeLayout: nil)
    }

    // The sizes the golden lays the toolbar and the tree out from are the ones the app draws with.
    @Test func theStylesheetSizesAreTheTokens() throws {
        let cases: [GoldenCase<Input, Output>] = try Golden.load(suite: "toolbar-layout")
        let sheet = try #require(cases.first { $0.name == "stylesheet" }?.output)
        let toolbar = DesignTokens.toolbar
        let css = try #require(sheet.stylesheet)
        #expect(css["itemGap"] == toolbar.itemGap)
        #expect(css["edgedItemInset"] == toolbar.edgedItemInset)
        #expect(css["capsulePadding"] == toolbar.capsulePadding)
        #expect(css["titleMinWidth"] == toolbar.titleMinWidth)
        #expect(css["overflowButtonWidth"] == toolbar.overflowButtonWidth)
        #expect(css["searchWidth"] == toolbar.searchWidth)
        #expect(css["searchMinWidth"] == toolbar.searchMinWidth)
        #expect(css["controlHeight"] == toolbar.controlHeight)
        #expect(css["buttonWidth"] == toolbar.buttonWidth)
        #expect(css["treeRowHeight"] == DesignTokens.sidebar(density: .standard).rowHeight)
        let explorer = DesignTokens.explorer
        let constants = try #require(sheet.explorerLayout)
        #expect(constants["treeMinWidth"] == explorer.treeMinWidth)
        #expect(constants["treeMaxWidth"] == explorer.treeMaxWidth)
        #expect(constants["inspectorMinWidth"] == explorer.inspectorMinWidth)
        #expect(constants["inspectorMaxWidth"] == explorer.inspectorMaxWidth)
        #expect(constants["resizerWidth"] == explorer.resizerWidth)
        #expect(constants["paneResizeStep"] == explorer.paneResizeStep)
        #expect(constants["paneResizeStepLarge"] == explorer.paneResizeStepLarge)
        #expect(constants["minContentWidth"] == explorer.minContentWidth)
    }

    @Test func toolbarRowsFitAndOverflowLikeTheOriginal() throws {
        let cases: [GoldenCase<Input, Output>] = try Golden.load(suite: "toolbar-layout")
        let layoutCases = cases.filter { $0.name != "stylesheet" }
        #expect(layoutCases.count >= 200)
        Golden.expectMatches(layoutCases) { Self.run($0) }
    }
}
