import AppKit
import FTFoundation
import Foundation
import PDFKit
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    /// A file in a pane: in place of its folder (Open in Viewer), and in the other pane, following the list (Open in
    /// Other Pane on a file).
    @MainActor
    @Suite struct TextViewerWindowTests {
        private func real(_ harness: ExplorerHarness, _ name: String) -> String {
            let path = harness.folder.path + "/" + name
            guard let resolved = realpath(path, nil) else { return path }
            defer { free(resolved) }
            return String(cString: resolved)
        }

        /// A tab on the harness's folder with two text files beside its folders, read.
        private func tabWithFiles(_ harness: ExplorerHarness) async throws -> MainWindowController {
            try "let a = 1\n".write(to: harness.folder.appending("a.swift"), atomically: true, encoding: .utf8)
            try "{\"b\": 2}\n".write(to: harness.folder.appending("b.json"), atomically: true, encoding: .utf8)
            let tab = try await harness.open()
            tab.perform(.refreshOrApplySearchSort)
            #expect(await waitUntil { tab.activePane.content.listedEntry(at: real(harness, "b.json")) != nil })
            return tab
        }

        private func select(_ path: String, in tab: MainWindowController) {
            tab.activePane.content.select(paths: [path])
        }

        /// The name of the file a viewer shows, for a failure's message.
        private func shown(_ viewer: TextViewerController) -> String {
            viewer.path.map(NodePath.basename) ?? "nothing"
        }

        @Test func openInViewerIsAStepOfTheHistoryAndBackReturnsWithTheFileSelected() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let tab = try await tabWithFiles(harness)
            let pane = tab.activePane
            let a = real(harness, "a.swift")
            #expect(!tab.canPerform(.viewFile))
            select(real(harness, "Alpha"), in: tab)
            #expect(!tab.canPerform(.viewFile))
            select(a, in: tab)
            #expect(tab.canPerform(.viewFile))

            tab.perform(.viewFile)
            let viewer = try #require(pane.viewer)
            #expect(await waitUntil { viewer.isText })
            #expect(viewer.mode == .inPlace)
            #expect(viewer.textView.string == "let a = 1\n")
            #expect(pane.content.showsViewer)
            #expect(pane.navigationHistory.current == a)
            // What acts on the folder or its items waits while the file shows.
            #expect(!tab.canPerform(.viewFile))
            #expect(!tab.canPerform(.viewAsIcons))
            #expect(!tab.canPerform(.newFolder))
            #expect(tab.canGoBack)

            tab.perform(.goBack)
            #expect(await waitUntil { pane.viewer == nil })
            #expect(!pane.content.showsViewer)
            #expect(pane.content.selection.paths == [a])
            #expect(pane.navigationHistory.forwardTarget == a)

            tab.perform(.goForward)
            let again = try #require(pane.viewer)
            #expect(await waitUntil { again.path == a && again.isText })
            #expect(pane.navigationHistory.current == a)
        }

        @Test func nextFileStepsThroughTheFolderAndReadOrEditIsRemembered() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let tab = try await tabWithFiles(harness)
            let pane = tab.activePane
            select(real(harness, "a.swift"), in: tab)
            tab.perform(.viewFile)
            let viewer = try #require(pane.viewer)
            #expect(await waitUntil { viewer.isText })
            #expect(!viewer.isEditing)

            viewer.setEditing(true, chosen: true)
            #expect(await waitUntil { tab.preferences.textViewerSettings.opensForEditing })

            tab.stepFile(by: 1)
            #expect(await waitUntil { viewer.path == real(harness, "b.json") && viewer.isText })
            #expect(viewer.isEditing)
            #expect(pane.content.selection.paths == [real(harness, "b.json")])
            #expect(pane.navigationHistory.current == real(harness, "b.json"))
        }

        @Test func openInOtherPaneShowsAFileThereAndFollowsTheList() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let tab = try await tabWithFiles(harness)
            let list = tab.activePane
            select(real(harness, "a.swift"), in: tab)
            #expect(tab.canPerform(.openSelectionInOtherPane))

            tab.perform(.openSelectionInOtherPane)
            #expect(tab.showsTwoPanes)
            let viewerPane = try #require(tab.otherPane)
            let viewer = try #require(viewerPane.viewer)
            #expect(viewer.mode == .following)
            #expect(tab.activePane === list)
            #expect(await waitUntil { viewer.path == real(harness, "a.swift") && viewer.isText })
            // The viewer pane's bottom bar tells of the file, not of a folder out of sight.
            let bar = viewerPane.content.contentShell.pathBarRow
            #expect(bar.fileStatus?.contains("Swift") == true)
            bar.layoutSubtreeIfNeeded()
            #expect(bar.pathBar.isHidden)

            select(real(harness, "b.json"), in: tab)
            #expect(await waitUntil { viewer.path == real(harness, "b.json") && viewer.isText })
            // A folder shows what it is, not its contents.
            select(real(harness, "Alpha"), in: tab)
            #expect(await waitUntil { viewer.path == real(harness, "Alpha") })
            #expect(!viewer.isText)
            // A folder shown has no line or language, and still no path below it.
            #expect(bar.fileStatus != nil)
            #expect(tab.openTab.secondPane?.viewer?.mode == .following)

            // Two Panes closes it as it closes any second pane, and brings it back as it was.
            tab.perform(.toggleTwoPanes)
            #expect(!tab.showsTwoPanes)
            tab.perform(.toggleTwoPanes)
            let back = try #require(tab.otherPane?.viewer)
            #expect(back.mode == .following)
        }

        // Read or Edit and Follow are the pane's: chosen by hand in a viewer, the next viewer in that pane starts the
        // same way, whatever another pane chose since; Read or Edit chosen is the app's too, what a new pane starts at.
        @Test func readOrEditAndFollowAreThePanes() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let tab = try await tabWithFiles(harness)
            let list = tab.activePane
            select(real(harness, "a.swift"), in: tab)
            tab.perform(.openSelectionInOtherPane)
            let viewerPane = try #require(tab.otherPane)
            let viewer = try #require(viewerPane.viewer)
            #expect(await waitUntil { viewer.isText })
            viewer.onFollowChange(false)
            viewer.setEditing(true, chosen: true)
            #expect(viewer.mode == .pinned)
            #expect(viewerPane.viewerDefaults == PaneViewer(follows: false, editing: true))
            #expect(await waitUntil { tab.preferences.textViewerSettings.opensForEditing })
            // Read chosen since in another pane is the app's now, but this pane keeps Edit.
            tab.updatePreferences { $0.textViewerSettings.opensForEditing = false }

            #expect(await tab.closeViewer(in: viewerPane))
            tab.focusPane(list)
            select(real(harness, "b.json"), in: tab)
            tab.perform(.openSelectionInOtherPane)
            let again = try #require(viewerPane.viewer)
            #expect(again.mode == .pinned)
            #expect(await waitUntil { again.path == real(harness, "b.json") && again.isText })
            #expect(again.isEditing)
            // Not following, it stays on its file as the list's selection moves.
            select(real(harness, "a.swift"), in: tab)
            try? await Task.sleep(for: .milliseconds(400))
            #expect(again.path == real(harness, "b.json"))
        }

        // A following viewer's pane closed with Two Panes and opened again comes back following the list as it is
        // now: it shows the file selected since, and the list keeps that selection when it reads its folder again,
        // where the pane showed the file it was closed on and the list's next read selected that one again.
        @Test func aFollowingPaneOpenedAgainShowsWhatTheListSelectsNow() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let tab = try await tabWithFiles(harness)
            let list = tab.activePane
            select(real(harness, "a.swift"), in: tab)
            tab.perform(.openSelectionInOtherPane)
            let first = try #require(tab.otherPane)
            var firstRead = false
            first.whenFirstReadFinished { _ in firstRead = true }
            #expect(await waitUntil { firstRead && first.viewer?.path == real(harness, "a.swift") })

            tab.perform(.toggleTwoPanes)
            #expect(!tab.showsTwoPanes)
            select(real(harness, "b.json"), in: tab)
            tab.perform(.toggleTwoPanes)
            let back = try #require(tab.otherPane?.viewer)
            #expect(back.mode == .following)
            #expect(back.path == real(harness, "b.json"), "shows \(shown(back)) at once")
            #expect(tab.activePane === list)

            // The list reads its folder again: what it selects stays selected, and the viewer shows it.
            try "c\n".write(to: harness.folder.appending("c.txt"), atomically: true, encoding: .utf8)
            tab.perform(.refreshOrApplySearchSort)
            #expect(await waitUntil { list.content.listedEntry(at: real(harness, "c.txt")) != nil })
            #expect(list.content.selection.paths == [real(harness, "b.json")])
            try await Task.sleep(for: .seconds(InfoMetrics.fetchDelay + 0.3))
            #expect(back.path == real(harness, "b.json") && back.isText, "shows \(shown(back))")
        }

        // A second pane closed with Two Panes before its first read ends finishes that read in a pane no longer the
        // tab's: nothing it selects reaches the viewer of the pane opened again, which showed nothing once it had.
        @Test func aClosedPanesLastReadLeavesTheViewerOpenedAgainAlone() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let tab = try await tabWithFiles(harness)
            select(real(harness, "a.swift"), in: tab)
            tab.perform(.openSelectionInOtherPane)
            let closed = try #require(tab.otherPane)
            var closedRead = false
            closed.whenFirstReadFinished { _ in closedRead = true }
            // Closed and opened again in the same turn, before the closed pane's read can end.
            tab.perform(.toggleTwoPanes)
            #expect(!closedRead)
            tab.perform(.toggleTwoPanes)
            let back = try #require(tab.otherPane?.viewer)
            #expect(await waitUntil { closedRead }, "the closed pane's read ended")
            try await Task.sleep(for: .seconds(InfoMetrics.fetchDelay + 0.3))
            #expect(back.path == real(harness, "a.swift") && back.isText, "shows \(shown(back))")
        }

        @Test func editingKeepsFollowingAndSaveWritesTheFile() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let tab = try await tabWithFiles(harness)
            let a = real(harness, "a.swift")
            select(a, in: tab)
            tab.perform(.openSelectionInOtherPane)
            let viewer = try #require(tab.otherPane?.viewer)
            #expect(await waitUntil { viewer.isText })

            viewer.setEditing(true, chosen: true)
            #expect(viewer.isEditing)
            #expect(viewer.mode == .following)
            #expect(await waitUntil { tab.preferences.textViewerSettings.opensForEditing })
            viewer.textView.setSelectedRange(NSRange(location: 0, length: 0))
            viewer.textView.insertText("// top\n", replacementRange: NSRange(location: 0, length: 0))
            #expect(viewer.isDirty)

            // ⌘S saves it from its own pane only: from the list it goes on as it would.
            let window = try #require(tab.window)
            let save = try #require(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, characters: "s", charactersIgnoringModifiers: "s",
                    isARepeat: false, keyCode: 1))
            tab.focusPane(tab.panes[0])
            _ = window.performKeyEquivalent(with: save)
            #expect(viewer.isDirty)
            tab.focusPane(try #require(tab.otherPane))
            #expect(window.performKeyEquivalent(with: save))
            #expect(!viewer.isDirty)
            #expect(try String(contentsOfFile: a, encoding: .utf8) == "// top\nlet a = 1\n")
            #expect(tab.openTab.secondPane?.viewer == ViewerPreference(mode: .following, path: a, editing: true))

            // Saved: the next selection is followed with no question, in Edit as before.
            tab.focusPane(tab.panes[0])
            select(real(harness, "b.json"), in: tab)
            #expect(await waitUntil { viewer.path == real(harness, "b.json") && viewer.isText })
            #expect(viewer.isEditing)
        }

        @Test func escLeavesEditThenTheFileInPlaceAndUndoBackLeavesNothingToSave() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let tab = try await tabWithFiles(harness)
            let pane = tab.activePane
            select(real(harness, "a.swift"), in: tab)
            tab.perform(.viewFile)
            let viewer = try #require(pane.viewer)
            #expect(await waitUntil { viewer.isText })
            // The pane's bottom bar tells of the file, not the folder; the keyboard is in the text.
            #expect(pane.content.contentShell.pathBarRow.fileStatus?.contains("Swift") == true)
            tab.focusPane(pane)
            #expect(viewer.textHasKeyboard)
            // Going elsewhere would do it under the file: the Go menu's places wait.
            #expect(!tab.canPerform(.goDocuments))
            #expect(tab.canGoBack)

            viewer.setEditing(true)
            viewer.textView.setSelectedRange(NSRange(location: 3, length: 0))
            viewer.textView.insertNewline(nil)
            #expect(viewer.isDirty)
            viewer.textView.breakUndoCoalescing()
            tab.perform(.undo)
            #expect(viewer.textView.string == "let a = 1\n")
            #expect(!viewer.isDirty)

            viewer.textView.cancelOperation(nil)
            #expect(!viewer.isEditing)
            #expect(pane.viewer === viewer)
            // Return in Read is Edit again, and Esc Read.
            let window = try #require(tab.window)
            let returnKey = try #require(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, characters: "\r",
                    charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
            viewer.textView.keyDown(with: returnKey)
            #expect(viewer.isEditing)
            #expect(!tab.preferences.textViewerSettings.opensForEditing)
            viewer.textView.cancelOperation(nil)
            #expect(!viewer.isEditing)
            // In place, Esc in Read closes the file: its folder again.
            viewer.textView.cancelOperation(nil)
            #expect(await waitUntil { pane.viewer == nil })
            #expect(pane.content.contentShell.pathBarRow.fileStatus == nil)
        }

        @Test func escBesideTheListLeavesEditThenShowsThePanesFolderAgain() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let tab = try await tabWithFiles(harness)
            select(real(harness, "a.swift"), in: tab)
            tab.perform(.openSelectionInOtherPane)
            let viewerPane = try #require(tab.otherPane)
            let viewer = try #require(viewerPane.viewer)
            #expect(await waitUntil { viewer.isText })
            tab.focusPane(viewerPane)
            #expect(viewer.textHasKeyboard)
            viewer.setEditing(true)

            viewer.textView.cancelOperation(nil)
            #expect(!viewer.isEditing)
            #expect(viewerPane.viewer === viewer)
            // Esc in Read closes the viewer, as in place: the pane shows its folder again, with the keyboard, and the
            // two panes stay.
            viewer.textView.cancelOperation(nil)
            #expect(await waitUntil { viewerPane.viewer == nil })
            #expect(tab.showsTwoPanes)
            #expect(!viewerPane.content.showsViewer)
            #expect(viewerPane.shownFolderPath == real(harness, ""))
            #expect(tab.activePane === viewerPane)
            let window = try #require(tab.window)
            let responder = try #require(window.firstResponder as? NSView)
            #expect(responder.isDescendant(of: viewerPane.content.view))
        }

        @Test func thePageKeysMoveTheCaretWithTheTextInEditAndOnlyTheTextInRead() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let lines = (0..<400).map { String(format: "line %03d abcdef", $0) }
            try (lines.joined(separator: "\n") + "\n").write(
                to: harness.folder.appending("long.txt"), atomically: true, encoding: .utf8)
            let tab = try await tabWithFiles(harness)
            let pane = tab.activePane
            let long = real(harness, "long.txt")
            #expect(await waitUntil { pane.content.listedEntry(at: long) != nil })
            select(long, in: tab)
            tab.perform(.viewFile)
            let viewer = try #require(pane.viewer)
            #expect(await waitUntil { viewer.isText })
            tab.focusPane(pane)
            let text = viewer.textView
            let window = try #require(tab.window)
            func press(_ characters: String, _ ignoring: String, _ keyCode: UInt16, _ flags: NSEvent.ModifierFlags = [])
                throws
            {
                text.keyDown(
                    with: try #require(
                        NSEvent.keyEvent(
                            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                            windowNumber: window.windowNumber, context: nil, characters: characters,
                            charactersIgnoringModifiers: ignoring, isARepeat: false, keyCode: keyCode)))
            }
            let pageDown = String(UnicodeScalar(UInt16(NSPageDownFunctionKey))!)
            let pageUp = String(UnicodeScalar(UInt16(NSPageUpFunctionKey))!)
            let lineLength = lines[0].utf16.count + 1
            func line() -> Int { text.selectedRange().location / lineLength }
            func column() -> Int { text.selectedRange().location % lineLength }
            func caretShown() -> Bool {
                let caret = text.firstRect(forCharacterRange: text.selectedRange(), actualRange: nil)
                return window.convertFromScreen(caret).intersects(text.convert(text.visibleRect, to: nil))
            }

            // Read: the text moves, the caret stays.
            let top = viewer.scrollView.contentView.bounds.origin.y
            try press(pageDown, pageDown, 121)
            #expect(viewer.scrollView.contentView.bounds.origin.y > top)
            #expect(text.selectedRange().location == 0)

            // Edit: the caret goes as far as the text, in its column, and stays on screen.
            viewer.setEditing(true)
            text.setSelectedRange(NSRange(location: 2 * lineLength + 5, length: 0))
            text.scrollRangeToVisible(text.selectedRange())
            try press(pageDown, pageDown, 121)
            let afterPage = line()
            #expect(afterPage > 10)
            #expect(column() == 5)
            #expect(caretShown())
            try press("\u{4}", "d", 2, [.control])
            #expect(line() > afterPage)
            #expect(line() < afterPage + afterPage)
            #expect(column() == 5)
            #expect(caretShown())
            try press("\u{15}", "u", 32, [.control])
            #expect(line() == afterPage)
            try press(pageUp, pageUp, 116)
            #expect(line() == 2)
            #expect(column() == 5)
            // At the top, the first line; at the bottom, the end.
            try press(pageUp, pageUp, 116)
            #expect(text.selectedRange().location == 0)
            for _ in 0..<60 { try press(pageDown, pageDown, 121) }
            #expect(text.selectedRange().location == (text.string as NSString).length)
            #expect(caretShown())

            // From the command palette, the same.
            text.setSelectedRange(NSRange(location: 0, length: 0))
            text.scrollRangeToVisible(text.selectedRange())
            #expect(tab.runPaletteKeyCommand(.halfPageDown))
            #expect(line() > 2)
            #expect(viewer.isEditing)
        }

        // Markdown's Preview takes the keys of the text in Read: it has the keyboard, the page keys and the arrows move
        // it, Return is Edit in the source, and Esc there is the Preview again, with the keyboard.
        @Test func theMarkdownPreviewTakesTheKeysOfTheTextInRead() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let paragraphs = (0..<300).map { "Paragraph \($0) of the notes." }
            try ("# Notes\n\n" + paragraphs.joined(separator: "\n\n") + "\n").write(
                to: harness.folder.appending("notes.md"), atomically: true, encoding: .utf8)
            let tab = try await tabWithFiles(harness)
            let pane = tab.activePane
            let notes = real(harness, "notes.md")
            #expect(await waitUntil { pane.content.listedEntry(at: notes) != nil })
            select(notes, in: tab)
            tab.perform(.viewFile)
            let viewer = try #require(pane.viewer)
            #expect(await waitUntil { viewer.isText && viewer.previewText.length > 0 })
            tab.focusPane(pane)
            let window = try #require(tab.window)
            #expect(window.firstResponder === viewer.previewView)
            #expect(viewer.textHasKeyboard)
            #expect(tab.isTextFieldEditing)
            func press(_ characters: String, _ ignoring: String, _ keyCode: UInt16, _ flags: NSEvent.ModifierFlags = [])
                throws
            {
                let event = try #require(
                    NSEvent.keyEvent(
                        with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                        windowNumber: window.windowNumber, context: nil, characters: characters,
                        charactersIgnoringModifiers: ignoring, isARepeat: false, keyCode: keyCode))
                (window.firstResponder as? NSView)?.keyDown(with: event)
            }
            let clip = try #require(viewer.previewView.enclosingScrollView).contentView
            func top() -> CGFloat { clip.bounds.origin.y }
            let pageDown = String(UnicodeScalar(UInt16(NSPageDownFunctionKey))!)
            let pageUp = String(UnicodeScalar(UInt16(NSPageUpFunctionKey))!)
            let down = String(UnicodeScalar(UInt16(NSDownArrowFunctionKey))!)

            let start = top()
            try press("\u{4}", "d", 2, [.control])
            let half = top() - start
            #expect(half > 0)
            try press(pageDown, pageDown, 121)
            #expect(top() - start > half * 2.5)
            try press(pageUp, pageUp, 116)
            #expect(abs(top() - start - half) < 1)
            try press("\u{15}", "u", 32, [.control])
            #expect(abs(top() - start) < 1)
            try press(down, down, 125)
            #expect(top() > start)
            try press(" ", " ", 49)
            #expect(top() - start > half)
            // From the command palette, the same.
            let beforePalette = top()
            #expect(tab.runPaletteKeyCommand(.halfPageDown))
            #expect(top() > beforePalette)

            // Return: Edit, in the source, with the keyboard, at the paragraph the Preview showed at its top, the caret
            // on its line; the next file still opens in Read.
            for _ in 0..<12 { try press(pageDown, pageDown, 121) }
            let preview = viewer.previewView
            let previewString = preview.string as NSString
            let topParagraph = previewString.substring(
                with: previewString.lineRange(for: NSRange(location: preview.firstCharacterShown, length: 0)))
            let number = try #require(Int(topParagraph.split(separator: " ")[1]))
            #expect(number > 40, "\(topParagraph)")
            try press("\r", "\r", 36)
            #expect(viewer.isEditing)
            #expect(window.firstResponder === viewer.textView)
            #expect(preview.enclosingScrollView?.isHidden == true)
            #expect(!viewer.scrollView.isHidden)
            #expect(!tab.preferences.textViewerSettings.opensForEditing)
            let source = viewer.textView.string as NSString
            func sourceLine(_ location: Int) -> String {
                source.substring(with: source.lineRange(for: NSRange(location: location, length: 0)))
            }
            #expect(sourceLine(viewer.textView.firstCharacterShown) == "Paragraph \(number) of the notes.\n")
            #expect(sourceLine(viewer.textView.selectedRange().location) == "Paragraph \(number) of the notes.\n")
            // A half page at once moves the text and the caret as far, though the source was hidden till now.
            let sourceClip = viewer.scrollView.contentView
            let beforeHalf = sourceClip.bounds.origin.y
            let caretBefore = viewer.textView.selectedRange().location
            try press("\u{4}", "d", 2, [.control])
            let moved = sourceClip.bounds.origin.y - beforeHalf
            #expect(moved > sourceClip.bounds.height * 0.4 && moved < sourceClip.bounds.height * 0.6, "\(moved)")
            #expect(viewer.textView.selectedRange().location > caretBefore)
            // Esc: the Preview follows the source, and the keyboard goes with it.
            let sourceTop = sourceLine(viewer.textView.firstCharacterShown)
            #expect(sourceTop.hasPrefix("Paragraph"))
            let sourcePlace = sourceClip.bounds.origin.y
            viewer.textView.cancelOperation(nil)
            #expect(!viewer.isEditing)
            #expect(window.firstResponder === preview)
            let previewTop = previewString.substring(
                with: previewString.lineRange(for: NSRange(location: preview.firstCharacterShown, length: 0)))
            #expect(previewTop == sourceTop, "\(previewTop) for \(sourceTop)")
            // Back and forth with nothing moved: each where it was.
            let previewPlace = top()
            try press("\r", "\r", 36)
            #expect(sourceClip.bounds.origin.y == sourcePlace)
            viewer.textView.cancelOperation(nil)
            #expect(top() == previewPlace)
            // So does Source and Preview in Read, and back at the top, the top.
            viewer.setPreview(false)
            #expect(sourceLine(viewer.textView.firstCharacterShown) == sourceTop)
            viewer.setPreview(true)
            preview.page(-1000)
            viewer.setPreview(false)
            #expect(viewer.scrollView.contentView.bounds.origin.y <= 0)
            viewer.setPreview(true)
            // Esc in the Preview closes the file, as in Read.
            viewer.previewView.cancelOperation(nil)
            #expect(await waitUntil { pane.viewer == nil })
        }

        // Long lines wrap: Edit from the Preview starts at a line's start, and each half page from there moves the text
        // and the caret half a page, the caret drawn at the start of a wrapped line and not at the end of the one
        // before, off screen, which the text would jump back to. A caret line partly off the top is brought on screen
        // by as little as that takes.
        @Test func theHalfPageKeysGoOnThroughWrappedLinesInEdit() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let words = (0..<90).map { "word\($0)" }.joined(separator: " ")
            let paragraphs = (0..<80).map { "Paragraph \($0): \(words)" }
            try ("# Notes\n\n" + paragraphs.joined(separator: "\n\n") + "\n").write(
                to: harness.folder.appending("long.md"), atomically: true, encoding: .utf8)
            let tab = try await tabWithFiles(harness)
            let pane = tab.activePane
            let long = real(harness, "long.md")
            #expect(await waitUntil { pane.content.listedEntry(at: long) != nil })
            select(long, in: tab)
            tab.perform(.viewFile)
            let viewer = try #require(pane.viewer)
            #expect(await waitUntil { viewer.isText && viewer.previewText.length > 0 })
            tab.focusPane(pane)
            let window = try #require(tab.window)
            func press(_ characters: String, _ ignoring: String, _ keyCode: UInt16, _ flags: NSEvent.ModifierFlags = [])
                throws
            {
                let event = try #require(
                    NSEvent.keyEvent(
                        with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                        windowNumber: window.windowNumber, context: nil, characters: characters,
                        charactersIgnoringModifiers: ignoring, isARepeat: false, keyCode: keyCode))
                (window.firstResponder as? NSView)?.keyDown(with: event)
            }
            let pageDown = String(UnicodeScalar(UInt16(NSPageDownFunctionKey))!)
            for _ in 0..<4 { try press(pageDown, pageDown, 121) }
            try press("\r", "\r", 36)
            #expect(viewer.isEditing)
            let text = viewer.textView
            let clip = viewer.scrollView.contentView
            let font = try #require(text.font)
            let lineHeight = try #require(text.layoutManager).defaultLineHeight(for: font)
            let half = (clip.bounds.height - 2 * lineHeight) / 2
            #expect(half > 100)
            // The top line partly scrolled off, as after a scroll: the caret's line comes in on screen, as little as
            // that takes, and not to the middle.
            text.scroll(lines: 0.4)
            for step in 0..<6 {
                // As keys come, with the run loop turning between them.
                try await Task.sleep(for: .milliseconds(150))
                let before = clip.bounds.origin.y
                let caret = text.selectedRange().location
                try press("\u{4}", "d", 2, [.control])
                let moved = clip.bounds.origin.y - before
                #expect(moved > half - lineHeight && moved < half + 1, "step \(step): \(moved)")
                #expect(text.selectedRange().location > caret, "step \(step)")
            }
        }

        // A Markdown file's Preview shows the pictures beside it from the first, and one added in Edit once it is
        // read, back in Read.
        @Test func theMarkdownPreviewShowsPicturesOnTheDiskAndOneAddedInEdit() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            func png(_ width: Int) throws -> Data {
                let rep = try #require(
                    NSBitmapImageRep(
                        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: 10, bitsPerSample: 8,
                        samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB,
                        bytesPerRow: 0, bitsPerPixel: 0))
                return try #require(rep.representation(using: .png, properties: [:]))
            }
            try png(30).write(to: harness.folder.appending("one.png"))
            try png(20).write(to: harness.folder.appending("two.png"))
            try "# Notes\n\n![one](one.png)\n".write(
                to: harness.folder.appending("notes.md"), atomically: true, encoding: .utf8)
            let tab = try await tabWithFiles(harness)
            let pane = tab.activePane
            let notes = real(harness, "notes.md")
            #expect(await waitUntil { pane.content.listedEntry(at: notes) != nil })
            select(notes, in: tab)
            tab.perform(.viewFile)
            let viewer = try #require(pane.viewer)
            func widths() -> [CGFloat] {
                var found: [CGFloat] = []
                let text = viewer.previewText
                text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, _, _ in
                    if let cell = (value as? NSTextAttachment)?.attachmentCell { found.append(cell.cellSize().width) }
                }
                return found
            }
            // The text shows first, and the picture once it is read.
            #expect(await waitUntil { viewer.isText })
            #expect(await waitUntil { widths() == [30] }, "\(widths())")

            // The file changed on disk, and its picture with it: the picture is read again.
            try png(40).write(to: harness.folder.appending("one.png"))
            try "# Notes\n\n![one](one.png)\n\n".write(
                to: harness.folder.appending("notes.md"), atomically: true, encoding: .utf8)
            #expect(await waitUntil { widths() == [40] }, "\(widths())")

            viewer.setEditing(true)
            viewer.textView.insertText("![two](two.png)\n\n", replacementRange: NSRange(location: 9, length: 0))
            viewer.setEditing(false)
            #expect(await waitUntil { widths() == [20, 40] }, "\(widths())")
        }

        @Test func escClosesAFileInPlaceThatIsNotTextAndTabGoesOnBesideTheList() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            try Data([0, 1, 2, 3, 0, 0xFF, 0xFE, 0]).write(to: harness.folder.appending("c.bin"))
            let tab = try await tabWithFiles(harness)
            let pane = tab.activePane
            let c = real(harness, "c.bin")
            #expect(await waitUntil { pane.content.listedEntry(at: c) != nil })
            let window = try #require(tab.window)
            func press(_ characters: String, _ keyCode: UInt16) throws {
                let event = try #require(
                    NSEvent.keyEvent(
                        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                        windowNumber: window.windowNumber, context: nil, characters: characters,
                        charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
                (window.firstResponder as? NSView)?.keyDown(with: event)
            }

            /// Esc as the app sends it: to the window's key equivalents, then to what has the keyboard.
            func escape() throws {
                let event = try #require(
                    NSEvent.keyEvent(
                        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                        windowNumber: window.windowNumber, context: nil, characters: "\u{1B}",
                        charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53))
                if !window.performKeyEquivalent(with: event) { window.sendEvent(event) }
            }

            // Open in Viewer on one: the viewer has the keyboard, and Esc closes it.
            select(c, in: tab)
            tab.perform(.viewFile)
            let direct = try #require(pane.viewer)
            #expect(await waitUntil { direct.quickLook.preview != nil })
            #expect(
                await waitUntil {
                    direct.hasKeyboard
                        && direct.quickLook.preview.map {
                            (window.firstResponder as? NSView)?.isDescendant(of: $0) == true
                        } == true
                })
            try escape()
            #expect(await waitUntil { pane.viewer == nil })

            // The same with Quick Look's preview clicked into.
            tab.perform(.viewFile)
            let clicked = try #require(pane.viewer)
            let preview = try #require(
                await waitUntil { clicked.quickLook.preview != nil } ? clicked.quickLook.preview : nil)
            window.makeFirstResponder(preview)
            try escape()
            #expect(await waitUntil { pane.viewer == nil })

            // From a text file to one that isn't: the keyboard goes from the text to the viewer, and Esc still closes.
            select(real(harness, "b.json"), in: tab)
            tab.perform(.viewFile)
            let viewer = try #require(pane.viewer)
            #expect(await waitUntil { viewer.isText })
            tab.focusPane(pane)
            #expect(viewer.textHasKeyboard)
            tab.stepFile(by: 1)
            #expect(await waitUntil { viewer.path == c && viewer.quickLook.preview != nil })
            #expect(
                await waitUntil {
                    viewer.hasKeyboard
                        && viewer.quickLook.preview.map {
                            (window.firstResponder as? NSView)?.isDescendant(of: $0) == true
                        } == true
                })
            try press("\u{1B}", 53)
            #expect(await waitUntil { pane.viewer == nil })
            #expect(pane.content.selection.paths == [c])

            // Focusing a pane showing one gives the viewer the keyboard; Tab moves on, and Esc shows the pane's folder.
            tab.perform(.openSelectionInOtherPane)
            let besidePane = try #require(tab.otherPane)
            let beside = try #require(besidePane.viewer)
            #expect(await waitUntil { beside.quickLook.preview != nil })
            tab.focusPane(besidePane)
            #expect(
                await waitUntil {
                    beside.hasKeyboard
                        && beside.quickLook.preview.map {
                            (window.firstResponder as? NSView)?.isDescendant(of: $0) == true
                        } == true
                })
            try press("\t", 48)
            #expect(!beside.hasKeyboard)
            tab.focusPane(besidePane)
            #expect(beside.hasKeyboard)
            try press("\u{1B}", 53)
            #expect(await waitUntil { besidePane.viewer == nil })
            #expect(tab.showsTwoPanes)
        }

        /// Quick Look stops the app when its view is closed out of a window: it is closed as the viewer leaves the
        /// window, whichever way it goes.
        @Test func aFileShownByQuickLookIsClosedAsItsViewerGoes() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            try Data([0, 1, 2, 3, 0, 0xFF, 0xFE, 0]).write(to: harness.folder.appending("c.bin"))
            let tab = try await tabWithFiles(harness)
            let pane = tab.activePane
            let c = real(harness, "c.bin")
            #expect(await waitUntil { pane.content.listedEntry(at: c) != nil })

            // In place, then Back.
            select(c, in: tab)
            tab.perform(.viewFile)
            let inPlace = try #require(pane.viewer)
            #expect(await waitUntil { inPlace.quickLook.preview != nil })
            tab.perform(.goBack)
            #expect(await waitUntil { pane.viewer == nil })
            #expect(inPlace.quickLook.preview == nil)

            // In the other pane, then Two Panes off, then on again with it shown anew.
            tab.perform(.openSelectionInOtherPane)
            let beside = try #require(tab.otherPane?.viewer)
            #expect(await waitUntil { beside.quickLook.preview != nil })
            tab.perform(.toggleTwoPanes)
            #expect(beside.quickLook.preview == nil)
            tab.perform(.toggleTwoPanes)
            let back = try #require(tab.otherPane?.viewer)
            #expect(await waitUntil { back.quickLook.preview != nil })

            // The window closed with it shown.
            tab.window?.close()
            #expect(back.quickLook.preview == nil)
        }

        // A press anywhere in a file a pane shows makes that pane the active one, with the keyboard: on Quick Look's
        // preview and on the viewer's bar, which take no keyboard of their own.
        @Test func aPressInAViewerMakesItsPaneTheActiveOne() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            try Data([0, 1, 2, 3, 0, 0xFF, 0xFE, 0]).write(to: harness.folder.appending("c.bin"))
            let tab = try await tabWithFiles(harness)
            let list = tab.activePane
            let c = real(harness, "c.bin")
            #expect(await waitUntil { list.content.listedEntry(at: c) != nil })
            select(c, in: tab)
            tab.perform(.openSelectionInOtherPane)
            let besidePane = try #require(tab.otherPane)
            let viewer = try #require(besidePane.viewer)
            let preview = try #require(
                await waitUntil { viewer.quickLook.preview != nil } ? viewer.quickLook.preview : nil)
            #expect(tab.activePane === list)
            let window = try #require(tab.window)
            window.layoutIfNeeded()
            func press(_ view: NSView, at point: NSPoint) throws {
                let location = view.convert(point, to: nil)
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    window.sendEvent(
                        try #require(
                            NSEvent.mouseEvent(
                                with: type, location: location, modifierFlags: [], timestamp: 0,
                                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                pressure: 1)))
                }
            }

            try press(preview, at: NSPoint(x: preview.bounds.midX, y: preview.bounds.midY))
            #expect(tab.activePane === besidePane)
            #expect(viewer.hasKeyboard)

            tab.focusPane(list)
            #expect(tab.activePane === list)
            // Its bar, beside the file's name.
            try press(viewer.view, at: NSPoint(x: viewer.view.bounds.maxX - 200, y: 10))
            #expect(tab.activePane === besidePane)
            #expect(viewer.hasKeyboard)
        }

        // A search typed in the toolbar would run in the folder under the file: the field waits while the active pane
        // shows one.
        @Test func theSearchFieldWaitsWhileTheActivePaneShowsAFile() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let tab = try await tabWithFiles(harness)
            let field = tab.explorerToolbar.searchField
            #expect(field.isEnabled)
            select(real(harness, "a.swift"), in: tab)
            tab.perform(.viewFile)
            let viewer = try #require(tab.activePane.viewer)
            #expect(await waitUntil { viewer.isText && !field.isEnabled })
            tab.perform(.goBack)
            #expect(await waitUntil { field.isEnabled })

            // Beside the list it is the list's again, and waits again in the viewer's pane.
            tab.perform(.openSelectionInOtherPane)
            #expect(await waitUntil { tab.otherPane?.viewer?.isText == true })
            #expect(field.isEnabled)
            tab.focusPane(try #require(tab.otherPane))
            #expect(await waitUntil { !field.isEnabled })
        }

        // Save File, Next File and Previous File are the viewer's keys as Settings → Shortcuts has them.
        @Test func theViewersKeysAreTheOnesChosenInSettings() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let tab = try await tabWithFiles(harness)
            tab.updatePreferences {
                $0.shortcutOverrides = ["nextViewerFile": ["Cmd+Option+N"], "saveViewerFile": ["Cmd+Shift+S"]]
            }
            let pane = tab.activePane
            let a = real(harness, "a.swift")
            select(a, in: tab)
            tab.perform(.viewFile)
            let viewer = try #require(pane.viewer)
            #expect(await waitUntil { viewer.isText })
            tab.focusPane(pane)
            #expect(viewer.keyLabel(.nextViewerFile) == "⌥⌘N")
            #expect(viewer.keyLabel(.previousViewerFile) == "⌥⌘[")
            let window = try #require(tab.window)
            func press(_ key: String, _ keyCode: UInt16, _ flags: NSEvent.ModifierFlags) throws -> Bool {
                let event = try #require(
                    NSEvent.keyEvent(
                        with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                        windowNumber: window.windowNumber, context: nil, characters: key,
                        charactersIgnoringModifiers: key, isARepeat: false, keyCode: keyCode))
                return window.performKeyEquivalent(with: event)
            }

            // The key it had before is no longer Next File; the one chosen is.
            _ = try press("]", 30, [.command, .option])
            #expect(viewer.path == a)
            #expect(try press("n", 45, [.command, .option]))
            #expect(await waitUntil { viewer.path == real(harness, "b.json") && viewer.isText })

            // Nor is ⌘S Save File any more; ⇧⌘S is.
            viewer.setEditing(true)
            viewer.textView.insertText("1", replacementRange: NSRange(location: 0, length: 0))
            #expect(viewer.isDirty)
            _ = try press("s", 1, [.command])
            #expect(viewer.isDirty)
            #expect(try press("S", 1, [.command, .shift]))
            #expect(!viewer.isDirty)
        }

        @Test func aTabsSnapshotKeepsItsViewers() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let tab = try await tabWithFiles(harness)
            select(real(harness, "a.swift"), in: tab)
            tab.perform(.openSelectionInOtherPane)
            let saved = tab.snapshot
            #expect(saved.secondPane?.pane.viewer?.mode == .following)
            #expect(saved.viewer == nil)
        }

        /// A PDF of `pages` US Letter pages, each with its number.
        private func writePDF(pages: Int, to url: URL) throws {
            var box = CGRect(x: 0, y: 0, width: 612, height: 792)
            let context = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
            for page in 1...pages {
                context.beginPDFPage(nil)
                let line = CTLineCreateWithAttributedString(
                    NSAttributedString(string: "Page \(page)", attributes: [.font: NSFont.systemFont(ofSize: 48)]))
                context.textPosition = CGPoint(x: 72, y: 700)
                CTLineDraw(line, context)
                context.endPDFPage()
            }
            context.closePDF()
        }

        /// A PDF is drawn by the viewer itself: it takes the keyboard as it opens at the pane's width, the size commands
        /// zoom it and Zoom to Fit shows a whole page, ← and → step its pages, the half-page keys move it, and Tab goes
        /// on to the next pane. Nothing else the viewer shows zooms.
        @Test func aPDFTakesTheKeyboardZoomsAndStepsItsPages() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            try writePDF(pages: 3, to: harness.folder.appending("d.pdf"))
            let tab = try await tabWithFiles(harness)
            let pane = tab.activePane
            let d = real(harness, "d.pdf")
            #expect(await waitUntil { pane.content.listedEntry(at: d) != nil })
            let window = try #require(tab.window)
            #expect(!tab.canPerform(.zoomToFit))

            select(d, in: tab)
            tab.perform(.viewFile)
            let viewer = try #require(pane.viewer)
            #expect(await waitUntil { viewer.pdfView.document?.pageCount == 3 })
            let pdf = viewer.pdfView
            #expect(await waitUntil { window.firstResponder === pdf })
            window.layoutIfNeeded()
            #expect(pdf.fit == .width)
            #expect(tab.menuState.fileShown)
            #expect(tab.canPerform(.increaseSize) && tab.canPerform(.decreaseSize) && tab.canPerform(.zoomToFit))

            let opened = pdf.scaleFactor
            tab.perform(.increaseSize)
            #expect(pdf.scaleFactor > opened)
            tab.perform(.resetSize)
            #expect(pdf.isActualSize)
            #expect(!tab.canPerform(.resetSize))
            tab.perform(.zoomToFit)
            #expect(pdf.fitsPage)
            #expect(!tab.canPerform(.zoomToFit))
            let pageRoom = pdf.bounds.height
            let pageHeight = try #require(pdf.document?.page(at: 0)).bounds(for: .mediaBox).height * pdf.scaleFactor
            #expect(pageHeight <= pageRoom)

            func send(_ characters: String, _ ignoring: String, _ keyCode: UInt16, _ flags: NSEvent.ModifierFlags = [])
                throws
            {
                window.sendEvent(
                    try #require(
                        NSEvent.keyEvent(
                            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                            windowNumber: window.windowNumber, context: nil, characters: characters,
                            charactersIgnoringModifiers: ignoring, isARepeat: false, keyCode: keyCode)))
            }
            func page() -> Int { pdf.currentPage.flatMap { pdf.document?.index(for: $0) } ?? -1 }
            let right = String(UnicodeScalar(UInt16(NSRightArrowFunctionKey))!)
            let left = String(UnicodeScalar(UInt16(NSLeftArrowFunctionKey))!)
            try send(right, right, 124, [.function, .numericPad])
            #expect(await waitUntil { page() == 1 })
            try send(left, left, 123, [.function, .numericPad])
            #expect(await waitUntil { page() == 0 })

            let clip = try #require(pdf.documentView?.enclosingScrollView?.contentView)
            let top = clip.bounds.origin.y
            try send("\u{4}", "d", 2, [.control])
            #expect(abs(clip.bounds.origin.y - top) >= clip.bounds.height / 2 - 1)
            // ⌘=, ⌘+'s other key, which the menu doesn't listen for.
            let fitted = pdf.scaleFactor
            try send("=", "=", 24, [.command])
            #expect(pdf.scaleFactor > fitted)

            try send("\t", "\t", 48)
            #expect(!viewer.hasKeyboard)

            // Text doesn't zoom.
            tab.focusPane(pane)
            tab.stepFile(by: -1)
            #expect(await waitUntil { viewer.isText })
            #expect(!tab.canPerform(.increaseSize) && !tab.canPerform(.zoomToFit))
            #expect(viewer.pdfView.document == nil)
        }
    }
}
