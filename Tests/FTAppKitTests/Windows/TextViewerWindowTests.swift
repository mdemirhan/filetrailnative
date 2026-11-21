import AppKit
import FTFoundation
import Foundation
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
            #expect(window.firstResponder === direct.view)
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
            #expect(window.firstResponder === viewer.view)
            try press("\u{1B}", 53)
            #expect(await waitUntil { pane.viewer == nil })
            #expect(pane.content.selection.paths == [c])

            // Focusing a pane showing one gives the viewer the keyboard; Tab moves on, and Esc shows the pane's folder.
            tab.perform(.openSelectionInOtherPane)
            let besidePane = try #require(tab.otherPane)
            let beside = try #require(besidePane.viewer)
            #expect(await waitUntil { beside.quickLook.preview != nil })
            tab.focusPane(besidePane)
            #expect(window.firstResponder === beside.view)
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
    }
}
