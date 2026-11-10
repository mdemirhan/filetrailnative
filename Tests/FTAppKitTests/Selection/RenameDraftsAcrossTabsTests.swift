import AppKit
import FTFileSystem
import FTFoundation
import Testing

@testable import FTAppKit

/// What is typed into a rename is kept apart for each rename, whichever tab it is in: each tab is a window of its own,
/// so a rename left open in one stays open while another tab starts its own.
@MainActor
struct RenameDraftsAcrossTabsTests {
    private func pane(_ names: [String]) -> ContentPaneController {
        _ = NSApplication.shared
        let content = ContentPaneController(
            mode: .details, folderSizes: FolderSizeService.shared.sizes(for: 9_003), loaders: .placeholder)
        content.view.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        content.show(
            folder: "/f", entries: names.map { ContentModelTests.entry($0) }, selecting: nil, keepingScroll: false)
        content.view.layoutSubtreeIfNeeded()
        return content
    }

    @Test func aRenameInAnotherTabStartsFromItsOwnItemsName() throws {
        let first = pane(["a.txt", "b.txt"])
        let second = pane(["c.txt", "d.txt"])

        #expect(first.beginRename(path: "/f/a.txt"))
        let firstSession = try #require(first.inlineRename?.sessionID)
        // Typed in the first tab, and left open there.
        RenameDrafts.keep(RenameDrafts.Draft(value: "typed in the first tab", selection: NSRange()), for: firstSession)
        defer { RenameDrafts.forget(firstSession) }

        #expect(second.beginRename(path: "/f/c.txt"))
        second.view.layoutSubtreeIfNeeded()

        let secondSession = try #require(second.inlineRename?.sessionID)
        #expect(secondSession != firstSession)
        #expect(RenameDrafts.draft(for: secondSession) == nil)
        let field = try #require((second.pane as? ListViewController)?.renameField)
        #expect(field.stringValue == "c.txt")
    }
}
