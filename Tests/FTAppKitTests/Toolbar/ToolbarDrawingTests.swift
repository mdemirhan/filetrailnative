// Checks the toolbar's drawing against the rules of apps/desktop/src/renderer/styles.css (.window-toolbar
// .tb-btn-icon.active, .toolbar-customize-label, .toolbar-menu, .history-menu-item, .toolbar-title, .toolbar-search)
import AppKit
import FTFoundation
import Testing

@testable import FTAppKit

/// Where a view's drawing puts ink, in points from its top left.
struct Ink {
    var minX: Double
    var maxX: Double
    var minY: Double
    var maxY: Double
}

@MainActor
enum InkScan {
    /// The ink of `view` drawn alone (light appearance), within `region` (points from the top left) when given: the
    /// pixels `isInk` picks, by default those mostly opaque.
    static func ink(
        _ view: NSView, in region: NSRect? = nil, isInk: (NSColor) -> Bool = { $0.alphaComponent > 0.3 }
    ) -> Ink? {
        view.appearance = NSAppearance(named: .aqua)
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        let scale = Double(rep.pixelsWide) / view.bounds.width
        let area = region ?? view.bounds
        var ink: Ink?
        for px in 0..<rep.pixelsWide {
            for py in 0..<rep.pixelsHigh {
                let x = Double(px) / scale
                let y = Double(py) / scale
                guard area.contains(NSPoint(x: x, y: y)), let color = rep.colorAt(x: px, y: py), isInk(color)
                else { continue }
                let right = x + 1 / scale
                let bottom = y + 1 / scale
                if var found = ink {
                    found.minX = min(found.minX, x)
                    found.maxX = max(found.maxX, right)
                    found.minY = min(found.minY, y)
                    found.maxY = max(found.maxY, bottom)
                    ink = found
                } else {
                    ink = Ink(minX: x, maxX: right, minY: y, maxY: bottom)
                }
            }
        }
        return ink
    }

    /// The ink of `text` drawn from x = 0 as the original's text box draws it.
    static func ink(of text: String, font: NSFont) -> Ink? {
        let width = (text as NSString).size(withAttributes: [.font: font]).width
        let view = TextBox(frame: NSRect(x: 0, y: 0, width: width + 20, height: 30))
        view.text = text
        view.font = font
        return ink(view)
    }

    final class TextBox: NSView {
        var text = ""
        var font = NSFont.systemFont(ofSize: 13)
        override var isFlipped: Bool { true }
        override func draw(_ dirtyRect: NSRect) {
            (text as NSString).draw(at: .zero, withAttributes: [.font: font, .foregroundColor: NSColor.black])
        }
    }
}

@MainActor
struct ToolbarDrawingTests {
    func hover(_ button: ToolbarButton, _ entered: Bool) throws {
        let event = try #require(
            NSEvent.enterExitEvent(
                with: entered ? .mouseEntered : .mouseExited, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        if entered { button.mouseEntered(with: event) } else { button.mouseExited(with: event) }
    }

    // B-VIEW-122: a toggle that is on, or a button whose menu is open, has no fill (the shipped stylesheet leaves
    // `--toolbar-toggle-on-bg` undefined), hovered or not; only its icon turns the primary text color.
    @Test func drawsNoFillBehindAButtonThatIsOn() throws {
        let button = ToolbarButton(icon: .sidebar, label: "Folder Tree", identifier: "toolbar.folderTree")
        button.appearance = NSAppearance(named: .aqua)
        let palette = ChromeColors.palette(for: button)
        #expect(button.backgroundFill == nil)
        try hover(button, true)
        #expect(button.backgroundFill == palette.bgHover)
        button.isOn = true
        #expect(button.backgroundFill == nil)
        try hover(button, false)
        #expect(button.backgroundFill == nil)
        button.isOn = false
        button.menuOpen = true
        #expect(button.backgroundFill == nil)
    }

    // F-719: a palette label laid out on two lines wraps at its box's width.
    @Test func wrapsAPaletteLabelThatIsWiderThanItsBox() throws {
        let label = PaletteLabelView(frame: .zero)
        label.field.stringValue = "Calculate Size"
        let font = label.font
        let room = 72.89
        #expect(ToolbarCustomizePanel.lineCount("Calculate Size", font: font, width: room) == 2)
        let line = font.pointSize * ToolbarCustomizePanel.labelLineHeight
        label.frame = NSRect(x: 0, y: 0, width: room, height: 2 * line)
        let ink = try #require(InkScan.ink(label))
        #expect(ink.maxY - ink.minY > line)
        #expect(ink.minX >= 0 && ink.maxX <= room)
    }

    // B-NAV-033: the history menu's folder starts 10 after the name and is shown in full when the menu is as wide as
    // the row needs.
    @Test func laysTheHistoryMenuDetailOutAsTheOriginalsRow() throws {
        let item = AppMenuItem(
            title: "src", detail: "~/Library/Caches/filetrail-port/fixtures/lighthouse/Lighthouse/app")
        let menu = AppMenuView(items: [item], style: .keyboard, identifier: "historyMenu", rowIdentifier: "row")
        let size = menu.fittingMenuSize
        menu.frame = NSRect(origin: .zero, size: size)
        menu.layoutSubtreeIfNeeded()
        // No row marked: only the text is drawn.
        menu.activeIndex = nil
        let row = try #require(menu.rows.first)
        let nameWidth = (item.title as NSString).size(withAttributes: [.font: row.label.font as Any]).width
        let detailFont = try #require(row.detail.font)
        let expected = try #require(InkScan.ink(of: item.detail ?? "", font: detailFont))
        let detailX = 10 + nameWidth + 10
        let ink = try #require(
            InkScan.ink(row, in: NSRect(x: detailX - 4, y: 0, width: row.bounds.width, height: row.bounds.height)))
        #expect(abs(ink.minX - (detailX + expected.minX)) < 0.6)
        #expect(abs((ink.maxX - ink.minX) - (expected.maxX - expected.minX)) < 0.6)
    }

    // A menu's label starts 30 from the row's edge, the toolbar's title at the block's padding: no inset of a text
    // field's own on top.
    @Test func drawsMenuLabelsAndTheTitleFromTheirBoxesEdge() throws {
        let row = AppMenuRow(item: AppMenuItem(title: "as Icons", checked: false), keyboard: false)
        row.frame = NSRect(x: 0, y: 0, width: 210, height: AppMenuView.rowHeight)
        let font = try #require(row.label.font)
        let expected = try #require(InkScan.ink(of: "as Icons", font: font))
        let ink = try #require(InkScan.ink(row))
        let start = AppMenuView.rowPaddingLeading + AppMenuView.checkColumn + AppMenuView.rowGap
        #expect(abs(ink.minX - (start + expected.minX)) < 0.6)

        let title = ToolbarTitleView(frame: NSRect(x: 0, y: 0, width: 260, height: ToolbarTitleView.height))
        title.field.stringValue = "components"
        title.field.textColor = .black
        let titleFont = try #require(title.field.font)
        let titleExpected = try #require(InkScan.ink(of: "components", font: titleFont))
        let titleInk = try #require(InkScan.ink(title))
        #expect(abs(titleInk.minX - (DesignTokens.toolbar.titlePaddingLeading + titleExpected.minX)) < 0.6)
    }

    // B-VIEW-127: a menu's shortcut ends at the row's padding, every glyph shown.
    @Test func drawsAMenuShortcutInFull() throws {
        for shortcut in ["⇧⌘.", "⌘I"] {
            let row = AppMenuRow(item: AppMenuItem(title: "", shortcut: shortcut, checked: false), keyboard: false)
            row.frame = NSRect(x: 0, y: 0, width: 220, height: AppMenuView.rowHeight)
            let font = try #require(row.shortcut.font)
            let width = (shortcut as NSString).size(withAttributes: [.font: font]).width
            let expected = try #require(InkScan.ink(of: shortcut, font: font))
            let ink = try #require(InkScan.ink(row))
            let start = row.bounds.width - AppMenuView.rowPaddingTrailing - width
            #expect(abs(ink.minX - (start + expected.minX)) < 0.6, "\(shortcut)")
            #expect(abs(ink.maxX - (start + expected.maxX)) < 0.6, "\(shortcut)")
        }
    }

    // B-VIEW-129: the magnifier is a 17 pt toolbar icon, and the placeholder starts 6 after the options button.
    @Test func drawsTheSearchMagnifierAsAToolbarIconAndThePlaceholderAfterIt() throws {
        let field = ToolbarSearchField(frame: NSRect(x: 0, y: 0, width: 200, height: 32))
        field.appearance = NSAppearance(named: .aqua)
        field.applyColors()
        let surface = try #require(
            ChromeColors.color(ChromeColors.palette(for: field).searchSurface).usingColorSpace(.deviceRGB))
        let differs: (NSColor) -> Bool = { color in
            guard let color = color.usingColorSpace(.deviceRGB) else { return false }
            return abs(color.redComponent - surface.redComponent) + abs(color.greenComponent - surface.greenComponent)
                + abs(color.blueComponent - surface.blueComponent) > 0.25
        }
        let magnifier = try #require(InkScan.ink(field, in: NSRect(x: 8, y: 4, width: 18, height: 24), isInk: differs))
        #expect(magnifier.maxY - magnifier.minY > 12.5)
        let leading = 1 + 8 + (DesignTokens.toolbar.iconSize + 1 + 8) + 6
        let font = try #require(field.font)
        let expected = try #require(InkScan.ink(of: "Search", font: font))
        let placeholder = try #require(
            InkScan.ink(field, in: NSRect(x: leading - 4, y: 4, width: 80, height: 24), isInk: differs))
        #expect(abs(placeholder.minX - (leading + expected.minX)) < 0.6)
    }
}
