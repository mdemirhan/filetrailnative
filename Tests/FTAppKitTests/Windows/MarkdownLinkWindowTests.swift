import AppKit
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    /// A link clicked in Markdown's Preview: a heading of the file, a file or a folder on the disk, one that isn't
    /// there, and a web page.
    @MainActor
    @Suite struct MarkdownLinkWindowTests {
        private func real(_ harness: ExplorerHarness, _ name: String) -> String {
            let path = harness.folder.path + "/" + name
            guard let resolved = realpath(path, nil) else { return path }
            defer { free(resolved) }
            return String(cString: resolved)
        }

        /// `notes.md` with `markdown` beside `b.json` and the folder Alpha, shown in place of the folder, read.
        private func notesInPlace(
            _ harness: ExplorerHarness, _ markdown: String
        ) async throws -> (MainWindowController, TextViewerController) {
            try markdown.write(to: harness.folder.appending("notes.md"), atomically: true, encoding: .utf8)
            try "{\"b\": 2}\n".write(to: harness.folder.appending("b.json"), atomically: true, encoding: .utf8)
            let tab = try await harness.open()
            tab.perform(.refreshOrApplySearchSort)
            let notes = real(harness, "notes.md")
            #expect(await waitUntil { tab.activePane.content.listedEntry(at: notes) != nil })
            tab.activePane.content.select(paths: [notes])
            tab.perform(.viewFile)
            let viewer = try #require(tab.activePane.viewer)
            #expect(await waitUntil { viewer.isText && viewer.previewText.length > 0 })
            return (tab, viewer)
        }

        /// Clicks the link whose text is `text` in the Preview.
        private func click(_ text: String, in viewer: TextViewerController) throws {
            let shown = viewer.previewText
            let range = (shown.string as NSString).range(of: text)
            try #require(range.location != NSNotFound, "\(text) is in the Preview")
            let link = try #require(shown.attribute(.link, at: range.location, effectiveRange: nil))
            viewer.previewView.clicked(onLink: link, at: range.location)
        }

        // A file in the same folder shows in place of the one read, a step of Back: Back shows the file the link was
        // in, then the folder; Forward goes over them again. Esc shows the folder, and Back from there the file.
        @Test func aLinkToAFileShowsItInTheViewerAsAStepOfBack() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let (tab, viewer) = try await notesInPlace(harness, "# Notes\n\nSee [the data](b.json).\n")
            let pane = tab.activePane
            let notes = real(harness, "notes.md")
            let data = real(harness, "b.json")

            try click("the data", in: viewer)
            #expect(await waitUntil { viewer.path == data && viewer.isText })
            #expect(pane.viewer === viewer)
            #expect(viewer.textView.string == "{\"b\": 2}\n")
            #expect(pane.navigationHistory.current == data)
            #expect(pane.content.selection.paths == [data])

            tab.perform(.goBack)
            #expect(await waitUntil { pane.viewer?.path == notes && pane.viewer?.isText == true })
            #expect(pane.navigationHistory.current == notes)
            tab.perform(.goBack)
            #expect(await waitUntil { pane.viewer == nil })
            #expect(pane.content.selection.paths == [notes])

            tab.perform(.goForward)
            #expect(await waitUntil { pane.viewer?.path == notes && pane.viewer?.isText == true })
            tab.perform(.goForward)
            #expect(await waitUntil { pane.viewer?.path == data && pane.viewer?.isText == true })

            // Esc: the folder, as a step of its own after the file, so Back comes back to it.
            try #require(pane.viewer).previewView.cancelOperation(nil)
            #expect(await waitUntil { pane.viewer == nil })
            #expect(pane.content.selection.paths == [data])
            #expect(pane.navigationHistory.backTarget == data)
            tab.perform(.goBack)
            #expect(await waitUntil { pane.viewer?.path == data })
        }

        // A link to a heading of the file brings it to the top of the Preview, whatever its letter case; one to a
        // file in another folder opens that folder first, then the file at the heading the link names, and Back goes
        // back through the folder to the file the link was in.
        @Test func aLinkToAHeadingGoesThereInThisFileOrTheOneItNames() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let filler = (0..<200).map { "Paragraph \($0)." }.joined(separator: "\n\n")
            // Each heading has a page after it, so it can come to the top.
            let guideText = "# Guide\n\n\(filler)\n\n## Usage `now`\n\nRun it.\n\n\(filler)\n"
            try guideText.write(to: harness.folder.appending("Alpha/guide.md"), atomically: true, encoding: .utf8)
            let markdown =
                "# Notes\n\n[Later](#The-End) and [the guide](Alpha/guide.md#usage-now)\n\n\(filler)\n\n## The End\n\nDone.\n\n\(filler)\n"
            let (tab, viewer) = try await notesInPlace(harness, markdown)
            let pane = tab.activePane
            let clip = try #require(viewer.previewView.enclosingScrollView).contentView
            func topLine(_ viewer: TextViewerController) -> Int? {
                MarkdownRendering.sourceLine(
                    at: viewer.previewView.firstCharacterShown, in: viewer.previewView.attributedString())
            }
            let endLine = try #require(MarkdownLink.headingLine("the-end", in: markdown))

            try click("Later", in: viewer)
            #expect(clip.bounds.origin.y > 0)
            #expect(topLine(viewer) == endLine)
            #expect(pane.navigationHistory.current == real(harness, "notes.md"), "a heading is no step of Back")

            clip.scroll(to: .zero)
            try click("the guide", in: viewer)
            let guide = real(harness, "Alpha/guide.md")
            #expect(await waitUntil { pane.viewer?.path == guide && pane.viewer?.isText == true })
            let opened = try #require(pane.viewer)
            #expect(samePath(pane.shownFolderPath, real(harness, "Alpha")))
            let usage = try #require(MarkdownLink.headingLine("usage-now", in: guideText))
            #expect(await waitUntil { topLine(opened) == usage }, "\(String(describing: topLine(opened)))")

            tab.perform(.goBack)
            #expect(await waitUntil { pane.viewer == nil })
            #expect(samePath(pane.shownFolderPath, real(harness, "Alpha")))
            tab.perform(.goBack)
            #expect(await waitUntil { pane.viewer?.path == real(harness, "notes.md") })
            #expect(samePath(pane.shownFolderPath, real(harness, ".")))
        }

        // Another file starts at its top, by a link or by Next File, wherever the Preview of the one before was
        // scrolled to.
        @Test func anotherFileShownStartsAtItsTop() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let filler = (0..<200).map { "Paragraph \($0)." }.joined(separator: "\n\n")
            try "# Other\n\n\(filler)\n".write(
                to: harness.folder.appending("other.md"), atomically: true, encoding: .utf8)
            let (tab, viewer) = try await notesInPlace(harness, "# Notes\n\n\(filler)\n\n[The other](other.md)\n")
            let clip = try #require(viewer.previewView.enclosingScrollView).contentView
            func scrollDown() {
                clip.scroll(to: NSPoint(x: 0, y: 2000))
                clip.enclosingScrollView?.reflectScrolledClipView(clip)
            }
            scrollDown()
            #expect(clip.bounds.origin.y > 1000)

            try click("The other", in: viewer)
            #expect(await waitUntil { viewer.path == real(harness, "other.md") && viewer.isText })
            #expect(viewer.previewText.string.hasPrefix("Other"))
            #expect(clip.bounds.origin.y == 0)

            scrollDown()
            tab.stepFile(by: -1)
            #expect(await waitUntil { viewer.path == real(harness, "notes.md") && viewer.isText })
            #expect(viewer.previewText.string.hasPrefix("Notes"))
            #expect(clip.bounds.origin.y == 0)
        }

        // A folder opens in the pane as a step of Back; one that isn't there says so and leaves the file shown; a web
        // page is handed to the system, and the file stays.
        @Test func aFolderOpensAMissingItemSaysSoAndAWebPageGoesToTheSystem() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let (tab, viewer) = try await notesInPlace(
                harness, "# Notes\n\n[Gone](gone.md), [the site](https://example.com/a) and [Alpha](Alpha)\n")
            let pane = tab.activePane
            var handed: [URL] = []
            tab.openFile = { handed.append($0) }

            try click("Gone", in: viewer)
            #expect(await waitUntil { tab.frontAlert != nil })
            #expect(tab.frontAlert?.titleLabel.stringValue == "The Linked Item Can\u{2019}t Be Found")
            #expect(pane.viewer === viewer)
            DialogKeys.press(KeyCode.returnKey, "\r", in: tab.window)
            #expect(await waitUntil { tab.frontAlert == nil })

            try click("the site", in: viewer)
            #expect(handed == [URL(string: "https://example.com/a")!])
            #expect(pane.viewer === viewer)

            try click("Alpha", in: viewer)
            #expect(await waitUntil { pane.viewer == nil && samePath(pane.shownFolderPath, real(harness, "Alpha")) })
            #expect(pane.navigationHistory.backTarget.map { samePath($0, real(harness, "notes.md")) } == true)
        }

        // Beside the list, a file a link leads to shows in the same viewer, which stops following the list.
        @Test func besideTheListALinkShowsTheFileAndStopsFollowing() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            try "# Notes\n\nSee [the data](b.json).\n".write(
                to: harness.folder.appending("notes.md"), atomically: true, encoding: .utf8)
            try "{\"b\": 2}\n".write(to: harness.folder.appending("b.json"), atomically: true, encoding: .utf8)
            let tab = try await harness.open()
            tab.perform(.refreshOrApplySearchSort)
            let notes = real(harness, "notes.md")
            #expect(await waitUntil { tab.activePane.content.listedEntry(at: notes) != nil })
            tab.activePane.content.select(paths: [notes])
            tab.perform(.openSelectionInOtherPane)
            let viewer = try #require(tab.otherPane?.viewer)
            #expect(viewer.mode == .following)
            #expect(await waitUntil { viewer.isText && viewer.previewText.length > 0 })

            try click("the data", in: viewer)
            #expect(await waitUntil { viewer.path == real(harness, "b.json") && viewer.isText })
            #expect(viewer.mode == .pinned)
        }
    }
}
