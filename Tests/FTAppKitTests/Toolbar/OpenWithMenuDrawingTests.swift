// Checks the rows of the Open With menu as a system menu shows them (D-022), and the Info icon's pixels
import AppKit
import FTFileSystem
import FTFoundation
import Testing

@testable import FTAppKit

@MainActor
@Suite struct OpenWithMenuDrawingTests {
    private static let app = OpenWithAction.application(
        id: "zed", label: "Zed (default)", appPath: "/Applications/Zed.app", appName: "Zed", always: false)

    private func solidImage() -> NSImage {
        NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            NSColor.red.setFill()
            rect.fill()
            return true
        }
    }

    @Test func anAppRowHasItsIconAndOtherHasNone() throws {
        let other = OpenWithAction.other(id: "other", label: "Other…", appName: "", always: false)
        let rows = [Self.app, other].map(InfoController.openWithRow)
        #expect(rows[0].appPath == "/Applications/Zed.app")
        #expect(rows[1].appPath == nil)
        let menu = AppMenu(items: rows, identifier: "menu", rowIdentifier: "row", minWidth: 200)
        #expect(menu.nsMenu.items.map(\.title) == ["Zed (default)", "Other…"])
        #expect(menu.nsMenu.items[0].image?.size == NSSize(width: 16, height: 16))
        if #available(macOS 27, *) { #expect(menu.nsMenu.items[0].preferredImageVisibility == .visible) }
        #expect(menu.nsMenu.items[1].image == nil)
    }

    // T-8727f2e5
    @Test func theAlwaysOpenWithLineIsAHeadingAndNotARow() throws {
        let menu = AppMenu(
            items: [InfoController.alwaysOpenWithHeading, InfoController.openWithRow(Self.app)], identifier: "menu",
            rowIdentifier: "row", minWidth: 200)
        #expect(menu.rows.map(\.title) == ["Zed (default)"])
        let heading = try #require(menu.nsMenu.items.first)
        #expect(heading.isSectionHeader && heading.title == "Always Open With")
    }

    @Test func theInfoIconIsDrawnFromTheOriginalsPixels() throws {
        let image = NativeIconPixels.image(solidImage())
        let rep = try #require(image.representations.first)
        #expect(rep.pixelsWide == NativeIconPixels.side)
        #expect(rep.pixelsHigh == NativeIconPixels.side)
    }
}
