// Checks Tab View Options and Window View Options as they are used: names and numbers typed key by key, Tab along the
// rows, Return and Escape, items chosen in the pop-ups, a saved view chosen by its name and the question that follows,
// Choose Folder…, the sheet within a short window, and the controls staying the same ones whatever changes
import AppKit
import FTFileSystem
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    @MainActor
    @Suite struct SavedViewSheetTests {
        // MARK: Typing

        // Each key typed in the name stays: nothing is made again under the field. The line saying a name is taken
        // comes and goes, and Save reads Replace while it shows.
        @Test func aNameIsTypedKeyByKeyInBothSheets() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let tab = try await harness.open()
            tab.updatePreferences {
                $0.tabViews = [TabView(id: "t", name: "Ab", keeps: TabViewKeeps(panes: 1))]
                $0.windowViews = [WindowView(id: "w", name: "Work", tabs: [nil])]
            }
            tab.perform(.saveTabView)
            let sheet = try SheetInput.tabSheet(tab)
            let name = sheet.nameBox
            let note = try #require(SheetInput.control("tabViewOptions.nameNote", in: sheet, as: NSTextField.self))
            let save = sheet.saveButton
            SheetInput.focus(name, in: tab.window)
            try SheetInput.type("Ab", in: tab.window)
            #expect(name.stringValue == "Ab" && sheet.draft.name == "Ab")
            #expect(!note.isHidden && sheet.takenBy?.id == "t" && save.title == "Replace")
            try SheetInput.type("c", in: tab.window)
            #expect(name.stringValue == "Abc" && sheet.draft.name == "Abc")
            #expect(note.isHidden && save.title == "Save")
            #expect(name.currentEditor() != nil)
            try SheetInput.press(["Escape"], in: tab.window)
            #expect(await waitUntil { tab.dialogs.isEmpty })

            tab.perform(.saveWindowView)
            let windowSheet = try SheetInput.windowSheet(tab)
            SheetInput.focus(windowSheet.nameBox, in: tab.window)
            try SheetInput.type("Work 2", in: tab.window)
            #expect(windowSheet.nameBox.stringValue == "Work 2" && windowSheet.draft.name == "Work 2")
        }

        // The width and the height are typed key by key, and the summary follows as they are typed. Tab goes from
        // the width to the height and on to the next row, ⇧Tab back; a size out of reach is held to it once its field
        // is left, the screen's room above and the smallest window below.
        @Test func aSizeIsTypedTabbedThroughAndHeld() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let tab = try await harness.open()
            tab.perform(.saveWindowView)
            let sheet = try SheetInput.windowSheet(tab)
            sheet.showPartForTesting(.window)
            try SheetInput.click("windowViewOptions.keep.Size", in: sheet)
            try SheetInput.choose("Custom", in: "windowViewOptions.size", of: sheet)
            let width = try #require(SheetInput.control("windowViewOptions.width", in: sheet, as: NSTextField.self))
            let height = try #require(SheetInput.control("windowViewOptions.height", in: sheet, as: NSTextField.self))
            let room = try #require(sheet.draft.largestSize)
            SheetInput.focus(width, in: tab.window)
            try SheetInput.type("99999", in: tab.window)
            #expect(width.stringValue == "99999")
            #expect(sheet.draft.customSize.width == room.width)
            #expect(sheet.summary.stringValue.contains("Size \(room.width) \u{00D7}"))
            try SheetInput.press(["Tab"], in: tab.window)
            #expect(sheet.focusedControl === height)
            #expect(width.stringValue == "\(room.width)")
            try SheetInput.type("9", in: tab.window)
            // Typed so far, a height under the smallest stays as typed in its field.
            #expect(height.stringValue == "9")
            try SheetInput.press(["Tab"], in: tab.window)
            #expect(sheet.focusedControl?.accessibilityIdentifier() == "windowViewOptions.keep.Folder Tree")
            #expect(height.stringValue == "\(WindowView.minimumSize.height)")
            #expect(sheet.draft.customSize.height == WindowView.minimumSize.height)
            try SheetInput.press(["Tab"], modifiers: .shift, in: tab.window)
            try SheetInput.press(["Tab"], modifiers: .shift, in: tab.window)
            #expect(sheet.focusedControl === width)
        }

        // A share for the divider is typed key by key, held to what a drag allows once left, and Tab goes on to the
        // next row.
        @Test func aShareIsTypedAndHeld() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let tab = try await harness.open()
            tab.openSecondPane()
            tab.perform(.saveTabView)
            let sheet = try SheetInput.tabSheet(tab)
            sheet.showGroupForTesting(.left, part: .tab)
            try SheetInput.click("tabViewOptions.keep.Divider", in: sheet)
            try SheetInput.choose("Custom", in: "tabViewOptions.divider", of: sheet)
            let field = try #require(SheetInput.control("tabViewOptions.customShare", in: sheet, as: NSTextField.self))
            SheetInput.focus(field, in: tab.window)
            try SheetInput.type("35", in: tab.window)
            #expect(field.stringValue == "35" && sheet.draft.keeps.divider == .share(0.35))
            try SheetInput.press(["Backspace", "Backspace", "5"], in: tab.window)
            #expect(field.stringValue == "5")
            try SheetInput.press(["Tab"], in: tab.window)
            #expect(sheet.focusedControl?.accessibilityIdentifier() == "tabViewOptions.keep.Hidden Files")
            #expect(sheet.draft.keeps.divider == .share(PaneSplit.minimum))
            #expect(field.stringValue == "\(Int(PaneSplit.minimum * 100))")
        }

        // Forget the Second Pane shows only with one pane kept, and is what Save keeps.
        @Test func forgetTheSecondPaneIsOfferedWithOnePane() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let tab = try await harness.open()
            tab.perform(.saveTabView)
            let sheet = try SheetInput.tabSheet(tab)
            sheet.showGroupForTesting(.onePane, part: .tab)
            let forget = try #require(SheetInput.control("tabViewOptions.forgetSecondPane", in: sheet))
            #expect(!forget.isHiddenOrHasHiddenAncestor)
            #expect(SheetInput.tabOrder(sheet).prefix(5).last == "tabViewOptions.forgetSecondPane")
            // Space checks the box Tab has reached, past the parts' list.
            SheetInput.focus(sheet.nameBox, in: tab.window)
            try SheetInput.press(["Tab", "Tab", "Tab", "Tab"], in: tab.window)
            #expect(sheet.focusedControl?.accessibilityIdentifier() == "tabViewOptions.forgetSecondPane")
            try SheetInput.press(["Space"], in: tab.window)
            #expect(sheet.draft.keeps.forgetsSecondPane == true)
            try SheetInput.choose("Two", in: "tabViewOptions.panes", of: sheet)
            #expect(forget.isHiddenOrHasHiddenAncestor && sheet.draft.keeps.forgetsSecondPane == nil)
            try SheetInput.choose("One", in: "tabViewOptions.panes", of: sheet)
            SheetInput.focus(sheet.nameBox, in: tab.window)
            try SheetInput.type("Alone", in: tab.window)
            try SheetInput.press(["Return"], in: tab.window)
            #expect(await waitUntil { tab.preferences.tabViews.first?.keeps.forgetsSecondPane == true })
        }

        // MARK: Tab, Return and Escape

        // Tab goes along each row, then down, through what can be used: dimmed and hidden controls are passed by.
        @Test func tabGoesThroughEachSheetRowByRow() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let tab = try await harness.open()
            tab.openSecondPane()
            tab.perform(.saveTabView)
            let sheet = try SheetInput.tabSheet(tab)
            try SheetInput.choose("Icons", in: "tabViewOptions.view", of: sheet)
            // The left pane's View: the name, the parts, then the rows; a row not kept has its control dimmed.
            #expect(
                SheetInput.tabOrder(sheet) == [
                    "tabViewOptions.name", "tabViewOptions.parts", "tabViewOptions.keep.Starts In",
                    "tabViewOptions.view", "tabViewOptions.keep.Group By", "tabViewOptions.keep.Sort By",
                    "tabViewOptions.keep.Folders First", "tabViewOptions.keep.Icon Size", "tabViewOptions.keep.Columns",
                    "tabViewOptions.keep.Column Width", "tabViewOptions.keep.Previews at a Time",
                    "tabViewOptions.reset", "tabViewOptions.manage", "tabViewOptions.cancel", "tabViewOptions.save",
                ])
            // Every view's options show, whatever view the pane starts in.
            try SheetInput.choose("List", in: "tabViewOptions.view", of: sheet)
            #expect(SheetInput.tabOrder(sheet).contains("tabViewOptions.keep.Icon Size"))
            sheet.showGroupForTesting(.left, part: .tab)
            #expect(
                SheetInput.tabOrder(sheet) == [
                    "tabViewOptions.name", "tabViewOptions.parts", "tabViewOptions.keep.Panes", "tabViewOptions.panes",
                    "tabViewOptions.keep.Divider", "tabViewOptions.keep.Hidden Files", "tabViewOptions.reset",
                    "tabViewOptions.manage", "tabViewOptions.cancel", "tabViewOptions.save",
                ])
            sheet.showGroupForTesting(.right, part: .viewer)
            #expect(
                SheetInput.tabOrder(sheet) == [
                    "tabViewOptions.name", "tabViewOptions.parts", "tabViewOptions.keep.Opens the Viewer",
                    "tabViewOptions.keep.Read or Edit", "tabViewOptions.keep.Follow", "tabViewOptions.reset",
                    "tabViewOptions.manage", "tabViewOptions.cancel", "tabViewOptions.save",
                ])
            // With one pane too, the pane can open the viewer.
            try SheetInput.choose("One", in: "tabViewOptions.panes", of: sheet)
            sheet.showGroupForTesting(.onePane, part: .viewer)
            #expect(SheetInput.tabOrder(sheet).contains("tabViewOptions.keep.Opens the Viewer"))
            sheet.onCancel()

            tab.perform(.saveWindowView)
            let windowSheet = try SheetInput.windowSheet(tab)
            #expect(
                SheetInput.tabOrder(windowSheet) == [
                    "windowViewOptions.name", "windowViewOptions.parts", "windowViewOptions.count",
                    "windowViewOptions.tab1", "windowViewOptions.front", "windowViewOptions.manage",
                    "windowViewOptions.cancel",
                ])
            windowSheet.showPartForTesting(.window)
            #expect(
                SheetInput.tabOrder(windowSheet) == [
                    "windowViewOptions.name", "windowViewOptions.parts", "windowViewOptions.keep.Size",
                    "windowViewOptions.keep.Folder Tree", "windowViewOptions.keep.Info Panel",
                    "windowViewOptions.manage", "windowViewOptions.cancel",
                ])
            // Save is dimmed, and passed by, until there is a name.
            SheetInput.focus(windowSheet.nameBox, in: tab.window)
            try SheetInput.type("W", in: tab.window)
            #expect(SheetInput.tabOrder(windowSheet).last == "windowViewOptions.save")
        }

        // Return saves once there is a name, and does nothing without one; Escape and ⌘. cancel. While the name list
        // is open, Return and Escape are the list's own.
        @Test func returnSavesEscapeCancelsAndTheOpenListKeepsBoth() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let tab = try await harness.open()
            tab.updatePreferences { $0.windowViews = [WindowView(id: "w", name: "Work", tabs: [nil])] }
            tab.perform(.saveWindowView)
            let sheet = try SheetInput.windowSheet(tab)
            try SheetInput.press(["Return"], in: tab.window)
            #expect(tab.dialogs.count == 1 && tab.preferences.windowViews.count == 1)
            let box = sheet.nameBox
            box.comboBoxWillPopUp(Notification(name: NSComboBox.willPopUpNotification, object: box))
            try SheetInput.press(["Escape"], in: tab.window)
            try SheetInput.press(["Return"], in: tab.window)
            #expect(tab.dialogs.count == 1)
            box.comboBoxWillDismiss(Notification(name: NSComboBox.willDismissNotification, object: box))
            #expect(await waitUntil { !box.isListOpen })
            try SheetInput.press(["."], modifiers: .command, in: tab.window)
            #expect(await waitUntil { tab.dialogs.isEmpty })

            tab.perform(.saveWindowView)
            let again = try SheetInput.windowSheet(tab)
            SheetInput.focus(again.nameBox, in: tab.window)
            try SheetInput.type("Home", in: tab.window)
            try SheetInput.press(["Return"], in: tab.window)
            #expect(await waitUntil { tab.preferences.windowViews.map(\.name) == ["Work", "Home"] })
            #expect(tab.dialogs.isEmpty)
        }

        // MARK: Choosing a saved view by name

        // A saved tab view chosen from the name's list asks whether to load it. Loaded, the sheet shows it and Save
        // changes that one in its place; kept, the sheet's settings are saved under its name, in its place.
        @Test func aTabViewChosenByNameIsLoadedOrReplaced() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let tab = try await harness.open()
            let compare = TabView(
                id: "c", name: "Compare",
                keeps: TabViewKeeps(
                    panes: 2, divider: .share(0.3), right: PaneKeeps(view: FolderViewKeeps(view: .list))))
            tab.updatePreferences {
                $0.tabViews = [TabView(id: "a", name: "Alone", keeps: TabViewKeeps(panes: 1)), compare]
            }
            tab.perform(.saveTabView)
            var sheet = try SheetInput.tabSheet(tab)
            #expect(sheet.nameBox.objectValues as? [String] == ["Alone", "Compare"])
            SheetInput.chooseInNameList(1, of: sheet.nameBox)
            #expect(
                await waitUntil {
                    tab.frontAlert?.titleLabel.stringValue == "Load the settings of \u{201C}Compare\u{201D}?"
                })
            try SheetInput.press(["Return"], in: tab.window)
            #expect(await waitUntil { sheet.draft.editingID == "c" })
            #expect(sheet.draft.keeps == compare.keeps)
            // The divider shows the saved share, as the tab view keeps it.
            let divider = try #require(SheetInput.control("tabViewOptions.divider", in: sheet, as: NSPopUpButton.self))
            #expect(divider.titleOfSelectedItem == "Saved: 30% / 70%")
            try SheetInput.click("tabViewOptions.keep.Hidden Files", in: sheet)
            try SheetInput.choose("Hidden", in: "tabViewOptions.hidden", of: sheet)
            try SheetInput.press(["Return"], in: tab.window)
            #expect(await waitUntil { tab.dialogs.isEmpty })
            #expect(tab.preferences.tabViews.map(\.id) == ["a", "c"])
            #expect(tab.preferences.tabViews[1].keeps.includeHidden == false)
            #expect(tab.preferences.tabViews[1].keeps.divider == .share(0.3))

            tab.perform(.saveTabView)
            sheet = try SheetInput.tabSheet(tab)
            SheetInput.chooseInNameList(0, of: sheet.nameBox)
            #expect(await waitUntil { tab.frontAlert != nil })
            try SheetInput.press(["Escape"], in: tab.window)
            #expect(await waitUntil { tab.frontAlert == nil })
            #expect(sheet.draft.editingID == nil && sheet.takenBy?.id == "a")
            #expect(sheet.saveButton.title == "Replace")
            let kept = sheet.draft.keeps
            try SheetInput.press(["Return"], in: tab.window)
            #expect(await waitUntil { tab.dialogs.isEmpty })
            #expect(tab.preferences.tabViews.map(\.id) == ["a", "c"])
            #expect(tab.preferences.tabViews[0].keeps == kept)
        }

        // A window view chosen by name and loaded shows its tabs, its front tab and its size.
        @Test func aWindowViewChosenByNameIsLoaded() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let tab = try await harness.open()
            tab.updatePreferences {
                $0.windowViews = [WindowView(id: "w", name: "Work", tabs: [nil, nil], frontTab: 1, sizing: .maximized)]
            }
            tab.perform(.saveWindowView)
            let sheet = try SheetInput.windowSheet(tab)
            SheetInput.chooseInNameList(0, of: sheet.nameBox)
            #expect(await waitUntil { tab.frontAlert != nil })
            try SheetInput.press(["Return"], in: tab.window)
            #expect(await waitUntil { sheet.draft.editingID == "w" })
            #expect(sheet.draft.tabs.count == 2 && sheet.draft.front == 1 && sheet.draft.sizeChoice == .maximized)
            #expect(sheet.tabRowsShown == 2)
            let size = SheetInput.control("windowViewOptions.size", in: sheet, as: NSPopUpButton.self)
            #expect(size?.titleOfSelectedItem == "Maximized")
        }

        // Moving through the open list only shows each name; closed with Escape, nothing is chosen.
        @Test func theNameListChoosesOnlyWhenItClosesOnAName() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let tab = try await harness.open()
            tab.updatePreferences {
                $0.windowViews = [
                    WindowView(id: "w", name: "Work", tabs: [nil]), WindowView(id: "h", name: "Home", tabs: [nil]),
                ]
            }
            tab.perform(.saveWindowView)
            let sheet = try SheetInput.windowSheet(tab)
            let box = sheet.nameBox
            box.comboBoxWillPopUp(Notification(name: NSComboBox.willPopUpNotification, object: box))
            for index in [0, 1] {
                box.selectItem(at: index)
                box.comboBoxSelectionDidChange(
                    Notification(name: NSComboBox.selectionDidChangeNotification, object: box))
            }
            await settle()
            #expect(tab.frontAlert == nil)
            box.stringValue = "Home"
            try SheetInput.dismissNameList(box, with: "Escape", in: tab.window)
            #expect(await waitUntil { !box.isListOpen })
            await settle()
            #expect(tab.frontAlert == nil && sheet.draft.editingID == nil)
        }

        // MARK: Made once

        // Whatever changes in the sheet, its controls stay the ones it was made with: rows that don't apply are
        // hidden or dimmed, never made again, so nothing typed is lost and the keyboard stays where it is.
        @Test func theControlsStayTheSameWhateverChanges() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let tab = try await harness.open()
            tab.openSecondPane()
            tab.perform(.saveTabView)
            let sheet = try SheetInput.tabSheet(tab)
            let before = SheetInput.controlIdentities(in: sheet)
            #expect(before.count > 30)
            try SheetInput.click("tabViewOptions.keep.Divider", in: sheet)
            try SheetInput.choose("Custom", in: "tabViewOptions.divider", of: sheet)
            sheet.showGroupForTesting(.right)
            try SheetInput.choose("List", in: "tabViewOptions.view", of: sheet)
            try SheetInput.choose("Icons", in: "tabViewOptions.view", of: sheet)
            sheet.showGroupForTesting(.right, part: .viewer)
            try SheetInput.click("tabViewOptions.keep.Opens the Viewer", in: sheet)
            sheet.showGroupForTesting(.right, part: .tab)
            try SheetInput.choose("One", in: "tabViewOptions.panes", of: sheet)
            try SheetInput.click("tabViewOptions.keep.Panes", in: sheet)
            try SheetInput.click("tabViewOptions.reset", in: sheet)
            #expect(SheetInput.controlIdentities(in: sheet) == before)

            sheet.onCancel()
            tab.perform(.saveWindowView)
            let windowSheet = try SheetInput.windowSheet(tab)
            let windowBefore = SheetInput.controlIdentities(in: windowSheet)
            try SheetInput.choose("9 tabs", in: "windowViewOptions.count", of: windowSheet)
            try SheetInput.click("windowViewOptions.keep.Size", in: windowSheet)
            try SheetInput.choose("Custom", in: "windowViewOptions.size", of: windowSheet)
            try SheetInput.choose("Full Screen", in: "windowViewOptions.size", of: windowSheet)
            try SheetInput.choose("2 tabs", in: "windowViewOptions.count", of: windowSheet)
            #expect(SheetInput.controlIdentities(in: windowSheet) == windowBefore)
        }

        // Every tab's row is there from the start; the ones past the number of tabs are hidden, and past six the
        // list scrolls rather than growing the sheet.
        @Test func tabRowsFollowTheNumberOfTabs() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let tab = try await harness.open()
            tab.perform(.saveWindowView)
            let sheet = try SheetInput.windowSheet(tab)
            #expect(sheet.tabRowsShown == 1)
            try SheetInput.choose("3 tabs", in: "windowViewOptions.count", of: sheet)
            let front = try #require(SheetInput.control("windowViewOptions.front", in: sheet, as: NSPopUpButton.self))
            #expect(sheet.tabRowsShown == 3 && front.itemTitles == ["Tab 1", "Tab 2", "Tab 3"])
            #expect(sheet.tabListHeight == 3 * FolderViewPopover.rowHeight + 2)
            try SheetInput.choose("20 tabs", in: "windowViewOptions.count", of: sheet)
            #expect(sheet.tabRowsShown == 20)
            // Six rows and the hairlines between them.
            #expect(sheet.tabListHeight == 6 * FolderViewPopover.rowHeight + 5)
            try SheetInput.choose("Tab 20", in: "windowViewOptions.front", of: sheet)
            try SheetInput.choose("2 tabs", in: "windowViewOptions.count", of: sheet)
            #expect(sheet.draft.front == 1 && front.itemTitles == ["Tab 1", "Tab 2"])
        }

        // MARK: Choose Folder…

        // Choose Folder… keeps the folder chosen in the system's picker for the pane; cancelled, the folder chosen
        // before stays.
        @Test func chooseFolderKeepsTheFolderPicked() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let tab = try await harness.open()
            let beta = harness.folder.appending("Beta").path
            // What the system's picker answers, changed between the two choices.
            final class Answer: @unchecked Sendable { var path: String? }
            let answer = Answer()
            answer.path = beta
            let picker = MainWindowController.pickDirectory
            MainWindowController.pickDirectory = { _, _ in answer.path }
            defer { MainWindowController.pickDirectory = picker }
            tab.perform(.saveTabView)
            let sheet = try SheetInput.tabSheet(tab)
            try SheetInput.click("tabViewOptions.keep.Folder", in: sheet)
            try SheetInput.choose("Choose Folder\u{2026}", in: "tabViewOptions.folder", of: sheet)
            #expect(await waitUntil { sheet.draft.keeps.pane?.folder == beta })
            let folder = try #require(SheetInput.control("tabViewOptions.folder", in: sheet, as: NSPopUpButton.self))
            #expect(folder.titleOfSelectedItem == "Beta")
            answer.path = nil
            try SheetInput.choose("Choose Folder\u{2026}", in: "tabViewOptions.folder", of: sheet)
            #expect(await waitUntil { folder.titleOfSelectedItem == "Beta" })
            #expect(sheet.draft.keeps.pane?.folder == beta)
        }

        // MARK: Size

        // In a short window the sheet ends above the window's bottom edge, its buttons inside it and its rows
        // scrolling, a row Tab reaches scrolled into view; in a tall one it is as tall as its rows.
        @Test func theSheetFitsUnderTheToolbarOfAShortWindow() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let tab = try await harness.open()
            tab.openSecondPane()
            let window = try #require(tab.window)
            window.setContentSize(NSSize(width: 1000, height: 520))
            tab.perform(.saveTabView)
            let sheet = try SheetInput.tabSheet(tab)
            let scrim = try #require(tab.dialogs.first)
            scrim.layoutSubtreeIfNeeded()
            #expect(sheet.frame.maxY <= scrim.bounds.maxY - SavedViewSheet.bottomInset + 0.5)
            for button in [sheet.saveButton, sheet.cancelButton] {
                #expect(sheet.bounds.contains(button.convert(button.bounds, to: sheet)))
            }
            let folderViews = try #require(SheetInput.control("tabViewOptions.folderViews", in: sheet))
            let scroll = try #require(folderViews.enclosingScrollView)
            let document = try #require(scroll.documentView)
            #expect(document.frame.height > scroll.contentView.bounds.height)
            sheet.moveKeyboard(to: folderViews)
            #expect(
                scroll.contentView.documentVisibleRect.contains(folderViews.convert(folderViews.bounds, to: document)))

            let tall = sheet.panelSize(in: NSSize(width: 1000, height: 4000))
            #expect(tall == sheet.panelSize(in: NSSize(width: 1000, height: 3000)))
        }

        // Maximized and Full Screen are size choices; one chosen hides the fields and is what Save keeps.
        @Test func maximizedAndFullScreenAreChosenAndKept() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let tab = try await harness.open()
            tab.perform(.saveWindowView)
            let sheet = try SheetInput.windowSheet(tab)
            let size = try #require(SheetInput.control("windowViewOptions.size", in: sheet, as: NSPopUpButton.self))
            #expect(size.itemTitles.suffix(3) == ["Custom", "Maximized", "Full Screen"])
            try SheetInput.click("windowViewOptions.keep.Size", in: sheet)
            try SheetInput.choose("Full Screen", in: "windowViewOptions.size", of: sheet)
            #expect(SheetInput.control("windowViewOptions.width", in: sheet)?.isHidden == true)
            SheetInput.focus(sheet.nameBox, in: tab.window)
            try SheetInput.type("Full", in: tab.window)
            try SheetInput.press(["Return"], in: tab.window)
            #expect(await waitUntil { tab.preferences.windowViews.first?.sizing == .fullScreen })
            #expect(tab.preferences.windowViews.first?.size == nil)
        }

        // A window view edited after its size was saved offers it as Saved, and Full Screen in place of it.
        @Test func editingASizedWindowViewOffersItsSizeAndFullScreen() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let tab = try await harness.open()
            let view = WindowView(id: "w", name: "Work", tabs: [nil], size: .init(width: 900, height: 600))
            tab.updatePreferences { $0.windowViews = [view] }
            tab.editWindowView(view)
            let sheet = try SheetInput.windowSheet(tab)
            let size = try #require(SheetInput.control("windowViewOptions.size", in: sheet, as: NSPopUpButton.self))
            #expect(size.titleOfSelectedItem == "Saved: 900 \u{00D7} 600")
            try SheetInput.choose("Full Screen", in: "windowViewOptions.size", of: sheet)
            try SheetInput.press(["Return"], in: tab.window)
            #expect(await waitUntil { tab.preferences.windowViews.first?.sizing == .fullScreen })
            #expect(tab.preferences.windowViews.map(\.id) == ["w"])
        }
    }
}

/// Drives a saved view's sheet as a person does: keys pressed through the window, items chosen in the pop-ups, boxes
/// clicked, and the name list opened, moved through and closed as AppKit tells its delegate.
@MainActor
enum SheetInput {
    static func tabSheet(_ tab: MainWindowController) throws -> TabViewOptionsSheet {
        try #require(tab.dialogs.lazy.compactMap { $0.panel as? TabViewOptionsSheet }.first)
    }

    static func windowSheet(_ tab: MainWindowController) throws -> WindowViewOptionsSheet {
        try #require(tab.dialogs.lazy.compactMap { $0.panel as? WindowViewOptionsSheet }.first)
    }

    /// The view identified as `identifier` in `root`, of type `T`.
    static func control<T: NSView>(_ identifier: String, in root: NSView, as: T.Type = NSView.self) -> T? {
        if root.accessibilityIdentifier() == identifier, let view = root as? T { return view }
        for child in root.subviews {
            if let found = control(identifier, in: child, as: T.self) { return found }
        }
        return nil
    }

    /// Every control under `root`, as objects: the same set once nothing was made again. The sidebar's rows are left
    /// out: its list makes those as it shows them, and they hold nothing typed.
    static func controlIdentities(in root: NSView) -> Set<ObjectIdentifier> {
        var found = Set<ObjectIdentifier>()
        func visit(_ view: NSView) {
            if view is SheetSidebar { return }
            if view is NSControl { found.insert(ObjectIdentifier(view)) }
            for child in view.subviews { visit(child) }
        }
        visit(root)
        return found
    }

    /// Presses `keys` one after another in `window`, as the keyboard would: each a key down and up, through the
    /// window, so the dialog's own handling of keys comes first.
    static func press(_ keys: [String], modifiers: NSEvent.ModifierFlags = [], in window: NSWindow?) throws {
        let window = try #require(window)
        for name in keys {
            let key = try #require(KeyEvents.key(named: name), "no key \(name)")
            for event in KeyEvents.events(key, modifiers: modifiers, window: window) { window.sendEvent(event) }
        }
    }

    static func type(_ text: String, in window: NSWindow?) throws {
        try press(text.map { String($0) }, in: window)
    }

    /// The field takes the keyboard with what it shows selected, as a click and ⌘A leave it.
    static func focus(_ field: NSTextField, in window: NSWindow?) {
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    /// The button or checkbox identified as `identifier` pressed.
    static func click(_ identifier: String, in sheet: NSView) throws {
        let button = try #require(control(identifier, in: sheet, as: NSButton.self), "no \(identifier)")
        #expect(button.isEnabled, "\(identifier) is dimmed")
        button.performClick(nil)
    }

    /// `title` chosen in the pop-up identified as `identifier`, as a click on it in its menu does.
    static func choose(_ title: String, in identifier: String, of sheet: NSView) throws {
        let popup = try #require(control(identifier, in: sheet, as: NSPopUpButton.self), "no \(identifier)")
        #expect(popup.isEnabled, "\(identifier) is dimmed")
        let index = try #require(popup.itemTitles.firstIndex(of: title), "no \(title) in \(popup.itemTitles)")
        popup.selectItem(at: index)
        NSApp.sendAction(try #require(popup.action), to: popup.target, from: popup)
    }

    /// The name list opened, moved to the item at `index` and closed on it with a click, as AppKit tells its
    /// delegate: the field takes the item's name as the list closes.
    static func chooseInNameList(_ index: Int, of box: SheetNameBox) {
        box.comboBoxWillPopUp(Notification(name: NSComboBox.willPopUpNotification, object: box))
        box.selectItem(at: index)
        box.comboBoxSelectionDidChange(Notification(name: NSComboBox.selectionDidChangeNotification, object: box))
        box.stringValue = box.itemObjectValue(at: index) as? String ?? ""
        box.comboBoxWillDismiss(Notification(name: NSComboBox.willDismissNotification, object: box))
    }

    /// The open name list closed by the key `key`, as AppKit closes it while handling the key.
    static func dismissNameList(_ box: SheetNameBox, with key: String, in window: NSWindow?) throws {
        let window = try #require(window)
        let named = try #require(KeyEvents.key(named: key))
        let event = try #require(KeyEvents.events(named, modifiers: [], window: window).first)
        box.listClosed(by: event)
    }

    /// The identifiers of the controls Tab goes to, in order.
    static func tabOrder(_ sheet: SavedViewSheet) -> [String] {
        sheet.focusOrder().map { $0.accessibilityIdentifier() }
    }
}
