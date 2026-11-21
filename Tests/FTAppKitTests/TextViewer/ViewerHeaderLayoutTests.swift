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
}
