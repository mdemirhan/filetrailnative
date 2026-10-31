// What VoiceOver hears of the sidebar's lists (B-TREE-015): AppKit's rows ask the outline for their level, disclosure and
// selection, and these outlines are flat and keep all three to themselves. So the rows are told here.
import AppKit

/// A row of a sidebar list as VoiceOver hears it: stays as long as its row, and reads the list each time. Not an
/// `NSAccessibilityElement`, which can't take `NSAccessibilityRow` in Swift: AppKit asks by selector either way.
@MainActor
final class SidebarAccessibilityRow: NSObject, @preconcurrency NSAccessibilityRow {
    private weak var list: SidebarListView?
    private weak var item: SidebarListItem?

    init(list: SidebarListView, item: SidebarListItem) {
        self.list = list
        self.item = item
        super.init()
    }

    private var row: SidebarListRow? { item?.row }
    private var index: Int? { item.flatMap { list?.index(of: $0) } }

    @objc func isAccessibilityElement() -> Bool { true }
    @objc func accessibilityRole() -> NSAccessibility.Role? { .row }
    @objc func accessibilitySubrole() -> NSAccessibility.Subrole? { .outlineRow }
    func accessibilityParent() -> Any? { list?.outline }
    func isAccessibilityFocused() -> Bool { false }
    func accessibilityIndex() -> Int { index ?? 0 }

    func accessibilityFrame() -> NSRect {
        guard let index, let outline = list?.outline, let window = outline.window else { return .zero }
        return window.convertToScreen(outline.convert(outline.rect(ofRow: index), to: nil))
    }

    func accessibilityLabel() -> String? {
        switch row {
        case .item(let state): state.item.label
        case .header(let state): state.title
        default: nil
        }
    }

    @objc func isAccessibilitySelected() -> Bool {
        if case .item(let state) = row { return state.selection != .none }
        return false
    }

    func accessibilityDisclosureLevel() -> Int {
        if case .item(let state) = row { return state.item.depth }
        return 0
    }

    @objc func isAccessibilityDisclosed() -> Bool {
        switch row {
        case .item(let state): state.item.expanded
        case .header(let state): state.expanded
        default: false
        }
    }

    @objc func setAccessibilityDisclosed(_ accessibilityDisclosed: Bool) {
        guard accessibilityDisclosed != isAccessibilityDisclosed(), let list else { return }
        switch row {
        case .item(let state) where state.item.canExpand: list.delegate?.sidebarList(list, toggle: state)
        case .header(let state): list.delegate?.sidebarList(list, toggleHeader: state)
        default: break
        }
    }

    /// The row's buttons, while the row is drawn.
    @objc func accessibilityChildren() -> [Any]? {
        guard let index, let cell = list?.outline.view(atColumn: 0, row: index, makeIfNecessary: false) else {
            return []
        }
        return (cell as? SidebarAccessibleCell)?.accessibilityButtons.filter { $0.isAccessibilityElement() } ?? []
    }

    /// What is at a point of the screen: a button of the row, or the row.
    func element(at point: NSPoint) -> Any {
        for case let button as NSView in accessibilityChildren() ?? []
        where button.accessibilityFrame().contains(point) {
            return button
        }
        return self
    }
}

/// A cell with buttons of its own, which VoiceOver reaches through its row.
@MainActor
protocol SidebarAccessibleCell {
    var accessibilityButtons: [NSView] { get }
}

extension SidebarOutlineView {
    /// The row a button of this list is in.
    func accessibilityRow(containing view: NSView) -> Any? {
        let index = row(for: view)
        return index >= 0 ? list?.accessibilityRow(at: index) : self
    }
}

/// The rows the lists keep to themselves stand in for AppKit's, which know nothing of them. A spacer is no row.
extension SidebarListView {
    func accessibilityRow(at index: Int) -> SidebarAccessibilityRow? {
        guard let item = item(at: index) else { return nil }
        if case .spacer = item.row { return nil }
        if let made = item.accessibilityRow { return made }
        let made = SidebarAccessibilityRow(list: self, item: item)
        item.accessibilityRow = made
        return made
    }

    var accessibilityRows: [SidebarAccessibilityRow] {
        (0..<rowCount).compactMap { accessibilityRow(at: $0) }
    }
}
