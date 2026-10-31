// The content-selection golden recorded from the reference (tools/parity/golden/content-selection.ts): gestures, arrow
// keys, page moves and list changes over random lists, layouts and modifier sequences, and the marquee's boxes.
import FTTestSupport
import Foundation
import Testing

@testable import FTFoundation

struct ContentSelectionGoldenTests {
    struct Box: Codable, Equatable {
        var left: Double
        var top: Double
        var right: Double
        var bottom: Double
    }

    struct Hit: Codable, Equatable {
        var path: String
        var rect: Box
    }

    struct Size: Codable, Equatable {
        var width: Double
        var height: Double
    }

    struct Flow: Codable {
        var rowHeight: Double
        var itemWidth: Double
        var columnGap: Double
    }

    struct Step: Codable {
        var op: String
        var path: String?
        var paths: [String]?
        var other: [String]?
        var meta: Bool?
        var shift: Bool?
        var control: Bool?
        var additive: Bool?
        var entries: [String]?
        var key: String?
        var viewMode: String?
        var columns: Int?
        var size: String?
        var direction: String?
        var viewport: Double?
        var extent: Double?
        var itemsPerLine: Int?
        var selectedCount: Int?
        var isSelected: Bool?
        var detail: Int?
        var button: Int?
        var overshoot: Double?
        var box: Box?
        var rowHeight: Double?
        var rowsPerColumn: Int?
        var flow: Flow?
        var icons: [String: Double]?
        var gridWidth: Double?
        var sizes: [String: Size]?
        var mode: String?
        var start: [String]?
    }

    struct Input: Codable {
        var entries: [String]
        var steps: [Step]
    }

    struct Result: Codable, Equatable {
        var selection: ContentSelection?
        var index: Int?
        var movedLines: Int?
        var paths: [String]?
        var hits: [Hit]?
        var mode: String?
        var box: Box?
        var step: Double?
        var flag: Bool?
    }

    struct Output: Codable, Equatable {
        var results: [Result]
    }

    private static func hits(_ found: [DragSelectionHit]) -> [Hit] {
        found.map {
            Hit(
                path: $0.path,
                rect: Box(left: $0.rect.left, top: $0.rect.top, right: $0.rect.right, bottom: $0.rect.bottom))
        }
    }

    private static func box(_ box: Box?) -> DragSelectionBox {
        let box = box ?? Box(left: 0, top: 0, right: 0, bottom: 0)
        return DragSelectionBox(left: box.left, top: box.top, right: box.right, bottom: box.bottom)
    }

    private static func sizes(_ sizes: [String: Size]?) -> [String: DragSelectionSize] {
        (sizes ?? [:]).mapValues { DragSelectionSize(width: $0.width, height: $0.height) }
    }

    /// The icon layout the reference recorded, which is ours: compared token by token.
    private static func iconLayout(_ recorded: [String: Double]) -> IconGridLayout {
        let compact = recorded["rowHeight"] == DesignTokens.iconGrid(density: .compact).rowHeight
        let layout = DesignTokens.iconGrid(density: compact ? .compact : .comfortable)
        #expect(recorded["rowHeight"] == layout.rowHeight)
        #expect(recorded["itemPaddingTop"] == layout.itemPaddingTop)
        #expect(recorded["iconBoxSize"] == layout.iconBoxSize)
        #expect(recorded["labelGap"] == layout.labelGap)
        #expect(recorded["labelWidth"] == layout.labelWidth)
        return layout
    }

    private static func replay(_ input: Input) -> Output {
        var entries = input.entries
        var state = ContentSelection.empty
        var results: [Result] = []
        for step in input.steps {
            var result = Result()
            switch step.op {
            case "single":
                state = .single(step.path ?? "")
                result.selection = state
            case "toggle":
                state = state.toggled(entryPaths: entries, path: step.path ?? "")
                result.selection = state
            case "extend":
                state = state.extended(entryPaths: entries, to: step.path ?? "", additive: step.additive == true)
                result.selection = state
            case "gesture":
                let path = step.path ?? ""
                let held = ContentSelection.Modifiers(meta: step.meta == true, shift: step.shift == true)
                if let next = state.afterPress(
                    entryPaths: entries, path: path, selected: state.paths.contains(path), modifiers: held)
                {
                    state = next
                }
                result.selection = state
            case "selectAll":
                state = .all(entryPaths: entries)
                result.selection = state
            case "clear":
                state = .empty
                result.selection = state
            case "setEntries":
                let previous = entries
                entries = step.entries ?? []
                state = state.sanitized(entryPaths: entries, previousPaths: previous)
                result.selection = state
            case "sanitizeWithout":
                state = state.sanitized(entryPaths: entries)
                result.selection = state
            case "move":
                let current = entries.firstIndex { $0 == state.leadPath } ?? -1
                let mode = ExplorerViewMode(rawValue: step.viewMode ?? "details") ?? .details
                let index = SelectionNavigation.nextIndex(
                    itemCount: entries.count, currentIndex: current,
                    key: SelectionKey(rawValue: step.key ?? "") ?? .down,
                    columns: mode == .details ? 1 : step.columns ?? 1, viewMode: mode, gapIndex: state.gapIndex)
                result.index = index
                if entries.indices.contains(index) {
                    state =
                        step.shift == true
                        ? state.extended(entryPaths: entries, to: entries[index]) : .single(entries[index])
                }
                result.selection = state
            case "page":
                let current = entries.firstIndex { $0 == state.leadPath } ?? -1
                let size = SelectionNavigation.PageSize(rawValue: step.size ?? "full") ?? .full
                let direction = SelectionNavigation.PageDirection(rawValue: step.direction ?? "forward") ?? .forward
                let lines = SelectionNavigation.pageStepLineCount(
                    viewportSize: step.viewport ?? 0, lineExtent: step.extent ?? 1, size: size)
                let move = SelectionNavigation.pagedLineMove(
                    itemCount: entries.count, currentIndex: current, lines: lines, itemsPerLine: step.itemsPerLine ?? 1,
                    direction: direction)
                let next =
                    current < 0
                    ? SelectionNavigation.nextIndex(
                        itemCount: entries.count, currentIndex: current, key: direction == .forward ? .down : .up,
                        columns: 1, viewMode: .details, gapIndex: state.gapIndex)
                    : move.index
                result.index = next
                result.movedLines = move.movedLines
                result.step = Double(lines)
                if entries.indices.contains(next), !(next == current && state.paths.count == 1) {
                    state =
                        step.shift == true
                        ? state.extended(entryPaths: entries, to: entries[next]) : .single(entries[next])
                    result.flag = true
                } else {
                    result.flag = false
                }
                result.selection = state
            case "range":
                result.paths = ContentSelection.rangePaths(
                    entryPaths: entries, anchor: step.path ?? "", target: step.other?.first ?? "")
            case "merge":
                result.paths = ContentSelection.merged(
                    entryPaths: entries, current: step.paths ?? [], next: step.other ?? [])
            case "narrowing":
                result.flag = ContentSelection.isNarrowingClick(
                    button: step.button ?? 0, detail: step.detail ?? 0,
                    modifiers: .init(meta: step.meta == true, shift: step.shift == true, control: step.control == true),
                    selectedCount: step.selectedCount ?? 0, isSelected: step.isSelected == true)
            case "dragMode":
                result.mode = DragSelection.mode(meta: step.meta == true, shift: step.shift == true).rawValue
            case "dragCombine":
                result.paths = DragSelection.combine(
                    startPaths: step.start ?? [], hitPaths: step.paths ?? [],
                    mode: DragSelection.Mode(rawValue: step.mode ?? "replace") ?? .replace)
            case "autoScroll":
                result.step = DragSelection.autoScrollStep(overshoot: step.overshoot ?? 0)
            case "detailsBox":
                result.hits = hits(
                    DragSelection.detailsItems(
                        box: box(step.box), entryPaths: entries, rowHeight: step.rowHeight ?? 28))
            case "flowBox":
                let flow = step.flow ?? Flow(rowHeight: 28, itemWidth: 292, columnGap: 18)
                result.hits = hits(
                    DragSelection.flowListItems(
                        box: box(step.box), entryPaths: entries, rowsPerColumn: step.rowsPerColumn ?? 1,
                        rowHeight: flow.rowHeight, itemWidth: flow.itemWidth, columnGap: flow.columnGap,
                        sizes: sizes(step.sizes)))
            case "iconBox":
                result.hits = hits(
                    DragSelection.iconGridItems(
                        box: box(step.box), entryPaths: entries, columns: step.columns ?? 1,
                        gridWidth: step.gridWidth ?? 0, layout: iconLayout(step.icons ?? [:]), sizes: sizes(step.sizes))
                )
            default:
                Issue.record("unknown step \(step.op)")
            }
            results.append(result)
        }
        return Output(results: results)
    }

    // F-779 F-780 F-781 F-784 F-785 F-786 B-SEL-001 B-SEL-009 B-SEL-024 B-SEL-025 B-SEL-044 B-SEL-049 B-SEL-149 B-SEL-156
    @Test func theSelectionModelAndMovesMatchTheReference() throws {
        let cases: [GoldenCase<Input, Output>] = try Golden.load(suite: "content-selection")
        #expect(cases.count > 100)
        Golden.expectMatches(cases) { Self.replay($0) }
    }
}
