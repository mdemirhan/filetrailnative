import AppKit
import FTFileSystem
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

/// Keys and text sent to a window that is never shown.
@MainActor
enum DialogKeys {
    static func press(
        _ code: UInt16, _ characters: String = "", modifiers: NSEvent.ModifierFlags = [], in window: NSWindow?
    ) {
        guard let window,
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)
        else { return }
        window.sendEvent(event)
    }

    /// A left press where the window sends one: to the view its hit test finds at `point` of `scrim`, whose own
    /// `mouseDown` passes it up the responder chain if it takes none. A window never shown delivers no press itself.
    static func pressMouse(at point: NSPoint, in scrim: DialogScrim) {
        guard let window = scrim.window, let frameView = window.contentView?.superview else { return }
        let location = scrim.convert(point, to: nil)
        guard
            let event = NSEvent.mouseEvent(
                with: .leftMouseDown, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                eventNumber: 1, clickCount: 1, pressure: 1)
        else { return }
        frameView.hitTest(location)?.mouseDown(with: event)
    }

    static func type(_ text: String, into box: GoToFolderBox) {
        box.field.stringValue = text
        box.textChanged(text)
    }
}

extension ExplorerWindowlessTests {
    @MainActor
    @Suite(.restoresWindowSeams) struct GoToBoxTests {
        /// A windowless tab whose opened folders are the harness's, and whose completions wait for timers moved by
        /// hand.
        private func open() async throws -> (ExplorerHarness, MainWindowController, ManualTimers) {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            // No favorites but the ones a test sets.
            tab.updatePreferences { $0.favorites = [] }
            let store = harness.store
            MainWindowController.visitStore = { store }
            let timers = ManualTimers()
            MainWindowController.dialogTimers = timers
            return (harness, tab, timers)
        }

        private func close(_ harness: ExplorerHarness) async {
            await harness.close()
        }

        private func path(_ harness: ExplorerHarness, _ name: String) -> String {
            harness.folder.appending(name).path
        }

        private func names(_ box: GoToFolderBox) -> [String] { box.rowViews.map(\.row.name) }
        private func selected(_ box: GoToFolderBox) -> String? { box.rowViews.first(where: \.isSelected)?.row.name }

        private func openBox(_ tab: MainWindowController) throws -> GoToFolderBox {
            tab.perform(.openLocationSheet)
            let box = try #require(tab.goToBox)
            tab.window?.contentView?.layoutSubtreeIfNeeded()
            return box
        }

        @Test func opensEmptyListsTheFoldersInUseAndReturnGoesToTheTopOne() async throws {
            let (harness, tab, _) = try await open()
            harness.store.recordFolderVisit(path(harness, "Beta"), kind: .stay)
            harness.store.recordFolderVisit(path(harness, "Alpha"), kind: .goTo)
            let box = try openBox(tab)
            #expect(box.titleLabel == nil)
            #expect(box.field.stringValue.isEmpty)
            #expect(box.field.placeholderString == "Folder name, or a path starting with / or ~")
            #expect(box.field.accessibilityLabel() == "Folder name or path")
            #expect(box.shell.holdsKeyboard)
            #expect(tab.focusedPane == nil)
            #expect(box.listLabel.stringValue == "Recent and favorite folders")
            #expect(names(box) == ["Alpha", "Beta"])
            #expect(selected(box) == "Alpha")
            #expect(box.rowViews.first?.toolTip == path(harness, "Alpha"))
            #expect(box.submitButton.title == "Open" && box.submitButton.isEnabled && box.submitButton.isDefault)
            #expect(box.browseButton == nil)
            // The scrim covers the window, the box 560 wide and 60 below its top.
            let scrim = try #require(tab.dialogs.first)
            #expect(scrim.frame == tab.window?.contentView?.bounds)
            #expect(box.frame.width == 560 && box.frame.minY == 60)
            DialogKeys.press(36, "\r", in: tab.window)
            #expect(await waitUntil { tab.folder.lastPathComponent == "Alpha" })
            #expect(await waitUntil { tab.goToBox == nil })
            // The visit counts as a Go To.
            #expect(harness.store.folders().first?.visits.first?.kind == .goTo)
            await close(harness)
        }

        // Tab goes round the box and stays in it, the rows included, and Return on a row opens that folder.
        @Test func tabGoesRoundTheBoxAndReturnOnARowOpensIt() async throws {
            let (harness, tab, _) = try await open()
            for name in ["Alpha", "Beta"] { harness.store.recordFolderVisit(path(harness, name), kind: .stay) }
            let box = try openBox(tab)
            DialogKeys.type("a", into: box)
            #expect(names(box) == ["Alpha", "Beta"])
            let window = try #require(tab.window)
            let scrim = try #require(tab.dialogs.first)
            func hasKeyboard(_ view: NSView) -> Bool {
                if let editor = window.firstResponder as? NSTextView, editor.isFieldEditor {
                    return editor.delegate as? NSView === view
                }
                return window.firstResponder === view
            }
            #expect(hasKeyboard(box.field))

            // Backward from the field, the first of the box: round to the last, the default button.
            DialogKeys.press(48, "\t", modifiers: .shift, in: window)
            #expect(hasKeyboard(box.submitButton))
            // Forward from the last: back to the field, on to the × beside it, and on to the first row.
            DialogKeys.press(48, "\t", in: window)
            #expect(hasKeyboard(box.field))
            DialogKeys.press(48, "\t", in: window)
            #expect(window.firstResponder === box.shell.clearButton)
            DialogKeys.press(48, "\t", in: window)
            #expect(hasKeyboard(box.rowViews[0]))
            #expect(scrim.holdsKeyboard(window))
            // And back from the first row to the ×.
            DialogKeys.press(48, "\t", modifiers: .shift, in: window)
            #expect(window.firstResponder === box.shell.clearButton)
            DialogKeys.press(48, "\t", in: window)
            #expect(hasKeyboard(box.rowViews[0]))
            // All the way round it never leaves.
            for _ in DialogPanelView.focusable(in: scrim.panel) {
                DialogKeys.press(48, "\t", in: window)
                #expect(scrim.holdsKeyboard(window))
            }
            #expect(hasKeyboard(box.rowViews[0]))

            DialogKeys.press(48, "\t", in: window)
            #expect(hasKeyboard(box.rowViews[1]))
            DialogKeys.press(36, "\r", in: window)
            #expect(await waitUntil { tab.folder.lastPathComponent == "Beta" })
            #expect(await waitUntil { tab.goToBox == nil })
            await close(harness)
        }

        // The × is a button of the box like the others: with the keyboard on it, Return or Space empties the
        // field, and the keyboard goes back there. With nothing typed it isn't there, so Tab no longer stops on it.
        @Test func returnOrSpaceOnTheClearButtonEmptiesTheField() async throws {
            let (harness, tab, _) = try await open()
            harness.store.recordFolderVisit(path(harness, "Alpha"), kind: .stay)
            let box = try openBox(tab)
            let window = try #require(tab.window)
            for (key, characters) in [(UInt16(36), "\r"), (UInt16(49), " ")] {
                DialogKeys.type("a", into: box)
                DialogKeys.press(48, "\t", in: window)
                #expect(window.firstResponder === box.shell.clearButton)

                DialogKeys.press(key, characters, in: window)
                #expect(box.field.stringValue == "")
                #expect(box.shell.clearButton.isHidden)
                #expect(box.shell.holdsKeyboard)
                // The box is still up: the key went to the ×, not to Open.
                #expect(tab.goToBox === box)
                #expect(!DialogPanelView.focusable(in: box).contains { $0 === box.shell.clearButton })
            }
            await close(harness)
        }

        @Test func findsAFolderFromAFewLettersMarksThemAndOpensTheOneClicked() async throws {
            let (harness, tab, _) = try await open()
            for name in ["Alpha", "Beta", "Gamma"] { harness.store.recordFolderVisit(path(harness, name), kind: .stay) }
            let box = try openBox(tab)
            DialogKeys.type("a", into: box)
            #expect(names(box) == ["Alpha", "Gamma", "Beta"])
            #expect(box.listLabel.stringValue == "3 matches")
            #expect(selected(box) == "Alpha")
            // The letters typed are bold.
            let name = box.rowViews[0].nameLabel.attributedStringValue
            let font = name.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
            #expect(font?.fontDescriptor.symbolicTraits.contains(.bold) == true)
            DialogKeys.press(125, in: tab.window)
            DialogKeys.press(125, in: tab.window)
            DialogKeys.press(125, in: tab.window)
            #expect(selected(box) == "Beta")
            DialogKeys.press(126, in: tab.window)
            #expect(selected(box) == "Gamma")
            box.rowClicked(1)
            #expect(await waitUntil { tab.folder.lastPathComponent == "Gamma" })
            #expect(await waitUntil { tab.goToBox == nil })
            await close(harness)
        }

        @Test func forgetsTheSelectedFolderWithCommandDeleteButNotAFavoriteNeverOpened() async throws {
            let (harness, tab, _) = try await open()
            harness.store.recordFolderVisit(path(harness, "Alpha"), kind: .stay)
            let gamma = path(harness, "Gamma")
            tab.updatePreferences { $0.favorites = [FavoritePreference(path: gamma, icon: .folder)] }
            let box = try openBox(tab)
            #expect(names(box) == ["Alpha", "Gamma"])
            #expect(box.hintLabel.stringValue == "⌘⌫ Removes from List")
            DialogKeys.press(51, "\u{7f}", modifiers: .command, in: tab.window)
            #expect(harness.store.folders().isEmpty)
            #expect(names(box) == ["Gamma"])
            #expect(box.rowViews.first?.glyph.isFavorite == true)
            #expect(box.hintLabel.isHidden)
            DialogKeys.press(51, "\u{7f}", modifiers: .command, in: tab.window)
            #expect(names(box) == ["Gamma"])
            await close(harness)
        }

        // An opened folder chosen from the list that turns out gone leaves the list of the box, still up with the
        // error, at once.
        @Test func aGoneFolderLeavesTheListOfTheBoxStillUp() async throws {
            let (harness, tab, _) = try await open()
            let gone = harness.folder.appending("Gone")
            try FileManager.default.createDirectory(at: gone, withIntermediateDirectories: true)
            harness.store.recordFolderVisit(gone.path, kind: .stay)
            try FileManager.default.removeItem(at: gone)
            let box = try openBox(tab)
            DialogKeys.type("Gone", into: box)
            #expect(names(box) == ["Gone"])
            DialogKeys.press(36, "\r", in: tab.window)
            #expect(await waitUntil { !box.errorLabel.isHidden })
            #expect(await waitUntil { harness.store.folders().allSatisfy { $0.path != gone.path } })
            #expect(names(box).isEmpty)
            #expect(box.state.places.allSatisfy { $0.path != gone.path })
            #expect(tab.goToBox === box)
            await close(harness)
        }

        // A Go To that fails leaves the folder on screen with "Couldn’t open this folder" and the read's message over
        // it, until the next folder opens.
        @Test func aFailedGoToShowsTheErrorOverTheFolderOnScreen() async throws {
            let (harness, tab, _) = try await open()
            let before = tab.folder
            let shown = tab.content.entries.map(\.path)
            #expect(!shown.isEmpty)
            let box = try openBox(tab)
            DialogKeys.type(path(harness, "Nowhere"), into: box)
            DialogKeys.press(36, "\r", in: tab.window)
            #expect(await waitUntil { !box.errorLabel.isHidden })
            let message = box.errorLabel.stringValue
            DialogKeys.press(53, "\u{1b}", in: tab.window)
            #expect(tab.folder == before)
            #expect(tab.content.entries.map(\.path) == shown)
            #expect(tab.content.container.stateView.kind == .error(message: message))
            // The next folder that opens puts it away.
            _ = await tab.navigate(to: before)
            #expect(tab.content.container.stateView.kind == .none)
            await close(harness)
        }

        @Test func completesAPathFolderByFolderAndOpensIt() async throws {
            let (harness, tab, timers) = try await open()
            let box = try openBox(tab)
            let base = tab.folder.path
            DialogKeys.type(base + "/A", into: box)
            #expect(box.rowViews.isEmpty)
            #expect(box.emptyLabel.stringValue == "No folders match this path")
            timers.advance(0.35)
            #expect(await waitUntil { names(box) == ["Alpha"] })
            #expect(box.hintLabel.stringValue == "⇥ Completes")
            // All of the hint fits inside the cell's insets, and the row's label stops short of it.
            box.layoutSubtreeIfNeeded()
            let hintRoom = box.hintLabel.frame.width - 2 * GoToRowView.cellInset
            #expect(hintRoom >= box.hintLabel.attributedStringValue.size().width)
            #expect(box.listLabel.frame.maxX <= box.hintLabel.frame.minX)
            #expect(box.listLabel.stringValue == "1 match")
            #expect(selected(box) == nil)
            DialogKeys.press(48, "\t", in: tab.window)
            #expect(box.field.stringValue.hasSuffix("/Alpha/"))
            timers.advance(0.35)
            #expect(await waitUntil { names(box) == ["Inner"] })
            DialogKeys.press(125, in: tab.window)
            #expect(selected(box) == "Inner")
            DialogKeys.press(36, "\r", in: tab.window)
            #expect(box.field.stringValue.hasSuffix("/Alpha/Inner"))
            #expect(tab.goToBox != nil)
            DialogKeys.press(36, "\r", in: tab.window)
            #expect(await waitUntil { tab.folder.lastPathComponent == "Inner" })
            #expect(await waitUntil { tab.goToBox == nil })
            await close(harness)
        }

        // What is submitted is trimmed, and ~ is the home folder.
        @Test func expandsTheHomeFolderWhenSubmitting() async throws {
            let (harness, tab, _) = try await open()
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            #expect(PathText2.expandHome(GoToBoxState.trim(" ~/Documents "), homePath: home) == home + "/Documents")
            let box = try openBox(tab)
            DialogKeys.type(" ~ ", into: box)
            DialogKeys.press(36, "\r", in: tab.window)
            #expect(await waitUntil { tab.folder.path == home })
            await close(harness)
        }

        @Test func showsTheReadErrorClosesOnEscapeAndOpensEmptyAgain() async throws {
            let (harness, tab, _) = try await open()
            let before = tab.folder
            let box = try openBox(tab)
            #expect(box.emptyLabel.stringValue.hasPrefix("Folders you open are listed here."))
            DialogKeys.type(path(harness, "Nowhere"), into: box)
            #expect(!box.shell.clearButton.isHidden)
            DialogKeys.press(36, "\r", in: tab.window)
            #expect(await waitUntil { !box.errorLabel.isHidden })
            #expect(!box.errorLabel.stringValue.isEmpty)
            #expect(tab.goToBox === box)
            #expect(tab.folder == before)
            // The ✕ empties the field.
            box.shell.clearButton.perform()
            #expect(box.field.stringValue.isEmpty)
            #expect(box.shell.clearButton.isHidden)
            DialogKeys.type("down", into: box)
            DialogKeys.press(53, "\u{1b}", in: tab.window)
            #expect(tab.goToBox == nil)
            let again = try openBox(tab)
            #expect(again.field.stringValue.isEmpty)
            #expect(again.errorLabel.isHidden)
            #expect(again.shell.holdsKeyboard)
            // ⌘. closes it too, and so does a press on the scrim.
            DialogKeys.press(47, ".", modifiers: .command, in: tab.window)
            #expect(tab.goToBox == nil)
            _ = try openBox(tab)
            let scrim = try #require(tab.dialogs.first)
            DialogKeys.pressMouse(at: NSPoint(x: scrim.panel.frame.minX - 2, y: scrim.panel.frame.midY), in: scrim)
            #expect(tab.goToBox == nil)
            await close(harness)
        }

        // A press on the box itself goes to the box: only the backdrop closes it, and what was typed stays. Move To is the
        // same box under another title, which is the box's too.
        @Test func aPressOnTheBoxOrTheMoveToBoxsTitleKeepsItOpen() async throws {
            let (harness, tab, _) = try await open()
            harness.layout(tab)
            let box = try openBox(tab)
            DialogKeys.type("down", into: box)
            let scrim = try #require(tab.dialogs.first)
            let plainViews: [NSView] = [box, box.shell, box.footer]
            for view in plainViews {
                // Just inside its corner: its own padding, no control of it.
                DialogKeys.pressMouse(at: view.convert(NSPoint(x: 3, y: 3), to: scrim), in: scrim)
                #expect(tab.goToBox === box, "\(type(of: view))")
            }
            #expect(box.field.stringValue == "down")
            DialogKeys.pressMouse(at: NSPoint(x: scrim.panel.frame.minX - 2, y: scrim.panel.frame.midY), in: scrim)
            #expect(tab.goToBox == nil)

            let window = try #require(tab.window)
            let moveTo = tab.presentGoToBox(.moveTo(currentPath: harness.folder.path, browse: { _ in nil }), in: window)
            window.contentView?.layoutSubtreeIfNeeded()
            let moveScrim = try #require(tab.dialogs.first)
            let title = try #require(moveTo.titleLabel)
            DialogKeys.pressMouse(at: title.convert(NSPoint(x: 3, y: 3), to: moveScrim), in: moveScrim)
            #expect(tab.dialogs.first === moveScrim)
            DialogKeys.pressMouse(
                at: NSPoint(x: moveScrim.panel.frame.minX - 2, y: moveScrim.panel.frame.midY), in: moveScrim)
            #expect(tab.dialogs.isEmpty)
            await close(harness)
        }

        // The keyboard comes back to the field when it falls out of the box.
        @Test func theKeyboardComesBackToTheField() async throws {
            let (harness, tab, _) = try await open()
            let box = try openBox(tab)
            tab.content.focusList()
            #expect(!box.shell.holdsKeyboard)
            DialogKeys.press(0, "a", in: tab.window)
            #expect(box.shell.holdsKeyboard)
            DialogKeys.press(53, "\u{1b}", in: tab.window)
            await close(harness)
        }

        // While the box is up the tab's commands wait.
        @Test func theTabsCommandsWaitWhileTheBoxIsUp() async throws {
            let (harness, tab, _) = try await open()
            harness.layout(tab)
            tab.content.focusList()
            _ = try openBox(tab)
            #expect(!tab.canPerform(.goEnclosingFolder))
            #expect(!tab.canPerform(.newTab))
            let before = tab.folder
            tab.perform(.goEnclosingFolder)
            tab.perform(.newTab)
            #expect(tab.folder == before)
            #expect(tab.group?.tabs.count == 1)
            // ⌘K again does not open a second box.
            tab.perform(.openLocationSheet)
            #expect(tab.dialogs.count == 1)
            DialogKeys.press(53, "\u{1b}", in: tab.window)
            #expect(tab.canPerform(.goEnclosingFolder))
            await close(harness)
        }

        // Where the pointer was over a box's list is kept for its window only while the window is there.
        @Test func thePointerOfAWindowThatWentIsNotKept() throws {
            let before = GoToFolderBox.rememberedPointerCount
            weak var gone: NSWindow?
            autoreleasepool {
                let window = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                    backing: .buffered, defer: true)
                window.isReleasedWhenClosed = false
                let box = GoToFolderBox(
                    places: [], options: .goTo, timers: ManualTimers(), requestCompletions: { _ in [] })
                box.opened(in: window)
                box.pointerMoved(over: 0, at: CGPoint(x: 10, y: 10))
                #expect(GoToFolderBox.rememberedPointerCount == before + 1)
                box.closed()
                gone = window
            }
            try #require(gone == nil)
            #expect(GoToFolderBox.rememberedPointerCount == before)
        }
    }
}
