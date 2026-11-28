// The items of the folder's views: icons and names drawn once into pictures, parts there only while they show, and
// items that come and go put in and taken out in place
import AppKit
import FTFileSystem
import FTFoundation
import Testing

@testable import FTAppKit

@MainActor
struct LighterItemsTests {
    private static let icon: NSImage = {
        let image = NSImage(size: NSSize(width: 64, height: 64))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: 64, height: 64)).fill()
        image.unlockFocus()
        return image
    }()

    // An icon is drawn once at its size: two views of it at that size show the same picture, another size another.
    @Test func anIconIsDrawnOnceForEachSize() throws {
        IconPictures.forget()
        let one = IconPictureView(frame: NSRect(x: 0, y: 0, width: 32, height: 32))
        let two = IconPictureView(frame: NSRect(x: 0, y: 0, width: 32, height: 32))
        let large = IconPictureView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
        for view in [one, two, large] { view.image = Self.icon }
        let picture = try #require(one.picture)
        #expect(two.picture === picture)
        #expect(IconPictures.count == 2)
        #expect(one.layer?.contents as AnyObject? === picture)
        let scale = Int(one.layer?.contentsScale ?? 0)
        #expect(picture.width == 32 * scale && picture.height == 32 * scale)
        #expect(try #require(large.picture).width == 64 * scale)
        // Taken away, the layer shows nothing.
        one.image = nil
        #expect(one.picture == nil && one.layer?.contents == nil)
        IconPictures.forget()
    }

    // A picture in another's proportions is fitted into the view and centred, as an image view scales it.
    @Test func anIconOfAnotherShapeIsFittedInTheMiddle() throws {
        let wide = NSImage(size: NSSize(width: 64, height: 32))
        wide.lockFocus()
        NSColor.black.setFill()
        NSRect(x: 0, y: 0, width: 64, height: 32).fill()
        wide.unlockFocus()
        let view = IconPictureView(frame: NSRect(x: 0, y: 0, width: 32, height: 32))
        view.image = wide
        let picture = try #require(view.picture)
        let bitmap = NSBitmapImageRep(cgImage: picture)
        let middle = bitmap.colorAt(x: picture.width / 2, y: picture.height / 2)
        let top = bitmap.colorAt(x: picture.width / 2, y: 1)
        #expect((middle?.alphaComponent ?? 0) > 0.9)
        #expect((top?.alphaComponent ?? 1) < 0.1)
    }

    // A name is drawn whole, once, into the picture its layer shows, at the window's scale, and again only when what it
    // shows changes. It is a view of its own, not a text field, which AppKit would give a label of its own on screen.
    @Test func aNameIsDrawnWholeOnceIntoItsLayersPicture() throws {
        let label = CountingLabel()
        label.font = NSFont.systemFont(ofSize: 13)
        label.textColor = .labelColor
        label.stringValue = "Quarterly Report.pdf"
        label.frame = NSRect(x: 0, y: 0, width: 160, height: 18)
        #expect(label.wantsUpdateLayer)
        #expect(!(label as NSView is NSTextField))
        let layer = try #require(label.layer)
        // In a window (never shown), the whole name is drawn once.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 40), styleMask: [.borderless], backing: .buffered,
            defer: true)
        window.contentView?.wantsLayer = true
        window.contentView?.addSubview(label)
        label.displayIfNeeded()
        #expect(label.draws == [label.bounds])
        let picture = try #require(layer.contents) as! CGImage
        let scale = window.backingScaleFactor
        #expect(layer.contentsScale == scale)
        #expect(picture.width == Int(160 * scale) && picture.height == Int(18 * scale))
        // Something is drawn: the text.
        let bitmap = NSBitmapImageRep(cgImage: picture)
        var inked = 0
        for x in stride(from: 0, to: picture.width, by: 2) {
            for y in stride(from: 0, to: picture.height, by: 2) {
                if (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 { inked += 1 }
            }
        }
        #expect(inked > 20)
        // Drawn again only when what it shows changes.
        label.displayIfNeeded()
        #expect(label.draws.count == 1)
        label.stringValue = "Quarterly Report.pdf"
        label.displayIfNeeded()
        #expect(label.draws.count == 1)
        label.stringValue = "Quarterly Report (2).pdf"
        label.displayIfNeeded()
        #expect(label.draws.count == 2)
        label.removeFromSuperview()
        // With no size, nothing.
        label.frame = .zero
        label.updateLayer()
        #expect(layer.contents == nil)
    }

    // VoiceOver reads a name as static text, and automation reads it, and the markers over its item, as it reads a text
    // field.
    @Test func aNameIsReadAsText() {
        let label = CompactNameLabel()
        label.stringValue = "Quarterly Report.pdf"
        #expect(label.isAccessibilityElement())
        #expect(label.accessibilityRole() == .staticText)
        #expect(label.accessibilityValue() as? String == "Quarterly Report.pdf")
        #expect(ElementFinder.ownText(of: label) == "Quarterly Report.pdf")
        let marker = GridMarkerView(id: "compactList.item.selected")
        marker.source = label
        #expect(ElementFinder.ownText(of: marker) == "Quarterly Report.pdf")
        // A marker over a text field still reads the field.
        let field = NSTextField(labelWithString: "Notes.txt")
        marker.source = field
        #expect(ElementFinder.ownText(of: marker) == "Notes.txt")
    }

    // A line of text in a row is placed on whole pixels, at 1x and 2x, with the rows and fonts the List and the Compact
    // List have: whole pixels high and wide, the line centred in it as in the row, so its picture is its size exactly.
    @Test func aLineIsPlacedOnWholePixels() {
        for scale in [1.0, 2.0] {
            for (row, size) in [(28.0, 14.0), (24.0, 13.0), (18.0, 12.0)] {
                let font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular)
                let lineHeight = font.ascender - font.descender + font.leading
                let frame = RowTextLabel.lineFrame(
                    x: 10.3, width: 71.6, height: row, lineHeight: lineHeight, scale: scale)
                for edge in [frame.minX, frame.minY, frame.width, frame.height] {
                    #expect((edge * scale).rounded() == edge * scale, "\(scale)x, \(row)/\(size): \(frame)")
                }
                #expect(frame.height >= lineHeight)
                // Centred as in the row: the same room above the line as below it, to within a pixel.
                let centredTop = (row - lineHeight) / 2
                #expect(frame.minY <= centredTop && centredTop - frame.minY < 1 / scale)
                #expect(abs(frame.minY - (row - frame.maxY)) < 0.001)
                // Never narrower than given, and moved by under a pixel.
                #expect(frame.width >= 71.6 && frame.width - 71.6 < 1 / scale + 0.001)
                #expect(abs(frame.minX - 10.3) <= 0.5 / scale + 0.001)
            }
        }
    }

    // A part that shows now and then is in its item only while it shows.
    @Test func aPartIsInItsItemOnlyWhileItShows() {
        let parent = NSView()
        let part = NSView()
        part.isHidden = true
        part.keep(in: parent)
        #expect(part.superview == nil)
        part.isHidden = false
        part.keep(in: parent)
        #expect(part.superview === parent)
        part.keep(in: parent)
        #expect(parent.subviews.count == 1)
        part.isHidden = true
        part.keep(in: parent)
        #expect(part.superview == nil)
    }

    private func pane(_ mode: ExplorerViewMode, _ names: [String]) -> ContentPaneController {
        _ = NSApplication.shared
        let content = ContentPaneController(
            mode: mode, folderSizes: FolderSizeService.shared.sizes(for: 9_010), loaders: .placeholder)
        content.view.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        content.show(
            folder: "/f", entries: names.map { ContentModelTests.entry($0) }, selecting: nil, keepingScroll: false)
        return content
    }

    /// How many of the items and rows made show the entry now at their place (the List's striped by it), and how many
    /// were looked at.
    private func madeRight(_ content: ContentPaneController) -> (right: Int, made: Int) {
        var right = 0
        var made = 0
        if let list = content.pane as? ListViewController {
            for row in 0..<list.table.numberOfRows {
                guard let bar = list.bar(atRow: row) else { continue }
                made += 1
                if bar.entry?.path == content.entries[row].path, bar.row == row { right += 1 }
            }
        } else if let grid = content.pane as? ItemGridPane {
            for index in grid.collection.indexPathsForVisibleItems().map(\.item) {
                made += 1
                let item = grid.collection.item(at: IndexPath(item: index, section: 0))
                let path = (item as? IconItem)?.path ?? (item as? CompactListItem)?.path
                let frame = grid.collection.layoutAttributesForItem(at: IndexPath(item: index, section: 0))?.frame
                // AppKit puts an item on whole points.
                let placed = zip([item?.view.frame.minX, item?.view.frame.minY], [frame?.minX, frame?.minY])
                    .allSatisfy { abs(($0 ?? -9) - ($1 ?? 9)) <= 0.5 }
                if path == content.entries[index].path, placed { right += 1 }
            }
        }
        return (right, made)
    }

    private func shown(_ content: ContentPaneController) -> Int {
        if let list = content.pane as? ListViewController { return list.table.numberOfRows }
        if let grid = content.pane as? ItemGridPane { return grid.collection.numberOfItems(inSection: 0) }
        return -1
    }

    // Items added and removed on disk are put in and taken out in place in every view but Previews; the selection
    // stays, and a new order is drawn again whole.
    @Test func itemsThatComeAndGoArePutInAndTakenOutInPlace() {
        let names = (0..<300).map { String(format: "item-%03d.txt", $0) }
        for mode in [ExplorerViewMode.details, .icons, .list] {
            let content = pane(mode, names)
            content.select(paths: ["/f/item-010.txt"])
            let before = content.wholeRedraws
            var next = names.filter { $0 != "item-005.txt" } + ["item-150b.txt"]
            next.sort()
            content.show(
                folder: "/f", entries: next.map { ContentModelTests.entry($0) }, selecting: nil, keepingScroll: true,
                changedPaths: ["/f/item-005.txt", "/f/item-150b.txt"])
            #expect(content.wholeRedraws == before, "\(mode)")
            #expect(shown(content) == next.count, "\(mode)")
            #expect(content.entries.map(\.name) == next, "\(mode)")
            #expect(content.selection.paths == ["/f/item-010.txt"], "\(mode)")
            content.view.layoutSubtreeIfNeeded()
            let made = madeRight(content)
            #expect(made.made > 0 && made.right == made.made, "\(mode): \(made)")
            // Another order: every row again.
            content.show(
                folder: "/f", entries: next.reversed().map { ContentModelTests.entry($0) }, selecting: nil,
                keepingScroll: true, changedPaths: nil)
            #expect(content.wholeRedraws == before + 1, "\(mode)")
            #expect(shown(content) == next.count, "\(mode)")
        }
    }

    // A folder emptied, and an empty one given its first items, are changed in place too.
    @Test func aListEmptiedAndFilledAgainIsChangedInPlace() {
        let names = (0..<5).map { "item-\($0).txt" }
        for mode in [ExplorerViewMode.details, .icons, .list] {
            let content = pane(mode, names)
            let before = content.wholeRedraws
            content.show(folder: "/f", entries: [], selecting: nil, keepingScroll: true, changedPaths: nil)
            #expect(shown(content) == 0, "\(mode)")
            content.show(
                folder: "/f", entries: names.map { ContentModelTests.entry($0) }, selecting: nil, keepingScroll: true,
                changedPaths: nil)
            #expect(shown(content) == names.count, "\(mode)")
            #expect(content.wholeRedraws == before, "\(mode)")
        }
    }
}

/// A name drawn as a picture, which counts what it draws.
private final class CountingLabel: PictureLabel {
    var draws: [NSRect] = []

    override func draw(_ dirtyRect: NSRect) {
        draws.append(dirtyRect)
        (stringValue as NSString).draw(at: .zero, withAttributes: [.font: font as Any])
    }
}
