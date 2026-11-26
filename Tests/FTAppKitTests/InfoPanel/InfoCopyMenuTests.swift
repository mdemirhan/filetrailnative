// A right-click anywhere in the Info panel gives a Copy: every row's title and value, a dash too, the name and the line
// under it, and each section's title, on a window that is never shown
import AppKit
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

@MainActor
@Suite struct InfoCopyMenuTests {
    /// What a right-click at `point` in `root` shows, as AppKit looks for it: the view hit, then up its views.
    func menu(at point: NSPoint, in root: NSView, window: NSWindow) -> [String] {
        guard let hit = root.hitTest(point),
            let event = NSEvent.mouseEvent(
                with: .rightMouseDown, location: root.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        else { return [] }
        var view: NSView? = hit
        while let current = view {
            if let menu = current.menu(for: event) { return menu.items.filter(\.isEnabled).map(\.title) }
            view = current.superview
        }
        return []
    }

    @Test func everythingCopies() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 1400), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        let item = InfoItem(
            path: "/Users/demo/Pictures/photo.heic", name: "photo.heic", fileExtension: "heic", kind: .file,
            kindLabel: "HEIF Image", createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_000), sizeBytes: 2_000_000, sizeStatus: .ready,
            permissionMode: 0o644)
        // Details not read: most rows of Image show a dash.
        let content = InfoPanelModel.itemContent(
            item: item, pending: false, volume: nil, isVolumeRoot: false, hasFolderSize: false, folderSize: nil,
            opensWith: .available, tags: .read(InfoTags(tags: [], itemCount: 1, editable: true)))
        let panel = InfoPanelView(frame: NSRect(x: 0, y: 0, width: 320, height: 1400))
        panel.show(
            InfoPanelDisplay(
                body: .item(
                    .init(
                        item: item, content: content, folderSize: nil,
                        openApp: InfoOpenApp(path: "/System/Applications/Preview.app", name: "Preview"))),
                wantsSpinner: false))
        window.contentView?.addSubview(panel)
        panel.layoutSubtreeIfNeeded()
        let root = try #require(window.contentView)
        func center(_ view: NSView) -> NSPoint {
            let frame = view.convert(view.bounds, to: root)
            return NSPoint(x: frame.midX, y: frame.midY)
        }
        let labels = findViews("infoPanel.row.label", in: panel).compactMap { $0 as? NSTextField }
        #expect(labels.count > 10)
        for label in labels {
            let expected = ["Copy \(label.stringValue)"]
            #expect(menu(at: center(label), in: root, window: window) == expected, "title \(label.stringValue)")
            let value = NSPoint(x: root.bounds.width - 30, y: center(label).y)
            #expect(menu(at: value, in: root, window: window) == expected, "value \(label.stringValue)")
        }
        let name = try #require(findViews("infoPanel.name", in: panel).first)
        #expect(menu(at: center(name), in: root, window: window) == ["Copy Name"])
        let subtitle = try #require(findViews("infoPanel.subtitle", in: panel).first)
        #expect(menu(at: center(subtitle), in: root, window: window) == ["Copy Summary"])
        for title in findViews("infoPanel.section.title", in: panel) {
            #expect(menu(at: center(title), in: root, window: window) == ["Copy \(fieldText(title))"])
        }
        // What they copy: the app's name, a dash as it reads, a section's rows.
        let contents = panel.subviews.compactMap { ($0 as? NSScrollView)?.documentView as? InfoPanelContentView }
        let view = try #require(contents.first)
        #expect(view.copyText(forRow: "Opens with") == "Preview")
        #expect(view.copyText(forRow: "Camera")?.hasPrefix("—") == true)
    }
}
