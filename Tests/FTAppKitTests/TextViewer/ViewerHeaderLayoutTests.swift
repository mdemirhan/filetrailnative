import AppKit
import FTFoundation
import Testing

@testable import FTAppKit

/// The bar over a file shown in place of its folder.
@MainActor
struct ViewerHeaderLayoutTests {
    private func state(_ name: String, _ index: Int, of count: Int) -> ViewerHeaderView.State {
        ViewerHeaderView.State(
            name: name, mode: .inPlace, isText: true, isEditing: false, isDirty: false, hasPreview: false,
            showsPreview: false, languageID: "plain", position: .init(index: index, count: count),
            settings: .defaults)
    }

    private func frame(_ id: String, in header: ViewerHeaderView) throws -> NSRect {
        try #require(header.subviews.first { $0.accessibilityIdentifier() == id && !$0.isHidden }, "\(id) shown").frame
    }

    private func closeButton(in header: ViewerHeaderView) throws -> NSButton {
        try #require(header.subviews.first { $0.accessibilityIdentifier() == "textViewer.close" } as? NSButton)
    }

    // Previous and Next come first, before the count and the name, and stay where they are from file to file: a
    // longer name or a count of more digits moved them when they came after the name, so the next click missed.
    @Test func thePreviousAndNextButtonsStayPutFromFileToFile() throws {
        let header = ViewerHeaderView(frame: NSRect(x: 0, y: 0, width: 640, height: ViewerHeaderView.height))
        header.update(state("abc.txt", 8, of: 26))
        header.layoutSubtreeIfNeeded()
        let previous = try frame("textViewer.previous", in: header)
        let next = try frame("textViewer.next", in: header)
        let name = try frame("textViewer.name", in: header)
        let position = try frame("textViewer.position", in: header)
        #expect(previous.maxX <= next.minX && next.maxX <= position.minX && position.maxX <= name.minX)

        header.update(state("a much longer file name than the first.markdown", 9, of: 26))
        header.layoutSubtreeIfNeeded()
        #expect(try frame("textViewer.previous", in: header) == previous)
        #expect(try frame("textViewer.next", in: header) == next)
        #expect(try frame("textViewer.name", in: header).minX > name.minX, "the name moves on for the wider count")
    }

    // The button that closes the viewer is the last at the right end, where it stays when Save comes and goes, and it
    // is never left out of a narrow bar.
    @Test func theCloseButtonStaysAtTheRightEndAndIsNeverLeftOut() throws {
        let header = ViewerHeaderView(frame: NSRect(x: 0, y: 0, width: 640, height: ViewerHeaderView.height))
        var plain = state("abc.txt", 8, of: 26)
        header.update(plain)
        header.layoutSubtreeIfNeeded()
        let close = try frame("textViewer.close", in: header)
        #expect(abs(close.maxX - (640 - 12)) < 0.5, "\(close)")
        #expect(try frame("textViewer.menu", in: header).maxX <= close.minX)
        let button = try closeButton(in: header)
        #expect(button.toolTip == "Close Viewer (Esc)")
        #expect(button.accessibilityLabel() == "Close Viewer")

        plain.isDirty = true
        plain.isEditing = true
        header.update(plain)
        header.layoutSubtreeIfNeeded()
        #expect(try frame("textViewer.save", in: header).maxX <= close.minX)
        #expect(try frame("textViewer.close", in: header) == close)

        header.setFrameSize(NSSize(width: 260, height: ViewerHeaderView.height))
        header.layoutSubtreeIfNeeded()
        #expect(abs(try frame("textViewer.close", in: header).maxX - (260 - 12)) < 0.5)
    }

    @Test func theCloseButtonAsksTheViewerToClose() throws {
        let header = ViewerHeaderView(frame: NSRect(x: 0, y: 0, width: 640, height: ViewerHeaderView.height))
        header.update(state("abc.txt", 0, of: 1))
        var closed = false
        header.onAction = { if case .close = $0 { closed = true } }
        let button = try closeButton(in: header)
        button.performClick(nil)
        #expect(closed)
    }
}
