// Checks Tab View Options and Window View Options as they are used: a name typed, Tab along a row, a value typed and
// held, the sheet within the window, a pane showing the viewer, and the Views window's list taking a click
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
        private func tabSheet(_ tab: MainWindowController) throws -> TabViewOptionsSheet {
            try #require(tab.dialogs.lazy.compactMap { $0.panel as? TabViewOptionsSheet }.first)
        }

        private func windowSheet(_ tab: MainWindowController) throws -> WindowViewOptionsSheet {
            try #require(tab.dialogs.lazy.compactMap { $0.panel as? WindowViewOptionsSheet }.first)
        }

        private func control<T: NSView>(_ identifier: String, in root: NSView, as: T.Type = NSView.self) -> T? {
            if root.accessibilityIdentifier() == identifier, let view = root as? T { return view }
            for child in root.subviews {
                if let found = control(identifier, in: child, as: T.self) { return found }
            }
            return nil
        }

        private func typeLetters(_ text: String, into field: NSTextField) throws {
            for letter in text {
                let editor = try #require(field.currentEditor() as? NSTextView)
                editor.insertText(String(letter), replacementRange: editor.selectedRange())
            }
        }

        // Each letter typed in the name stays: the sheet isn't built again under the field, which would select what
        // was typed and have the next letter replace it. The line saying a name is taken comes and goes in place.
        @Test func aNameIsTypedLetterByLetterInBothSheets() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let tab = try await harness.open()
            tab.updatePreferences { $0.tabViews = [TabView(id: "t", name: "Ab", keeps: TabViewKeeps(panes: 1))] }
            tab.perform(.saveTabView)
            let sheet = try tabSheet(tab)
            let name = try #require(control("tabViewOptions.name", in: sheet, as: NSTextField.self))
            let note = try #require(control("tabViewOptions.nameNote", in: sheet, as: NSTextField.self))
            tab.window?.makeFirstResponder(name)
            name.currentEditor()?.selectAll(nil)
            try typeLetters("Ab", into: name)
            #expect(name.stringValue == "Ab" && sheet.draft.name == "Ab")
            #expect(!note.isHidden && sheet.takenBy?.id == "t")
            try typeLetters("c", into: name)
            #expect(name.stringValue == "Abc" && sheet.draft.name == "Abc")
            #expect(note.isHidden)
            #expect(name.currentEditor() != nil)

            sheet.onCancel()
            tab.perform(.saveWindowView)
            let windowSheet = try windowSheet(tab)
            let windowName = try #require(control("windowViewOptions.name", in: windowSheet, as: NSTextField.self))
            tab.window?.makeFirstResponder(windowName)
            try typeLetters("Work", into: windowName)
            #expect(windowName.stringValue == "Work" && windowSheet.draft.name == "Work")
        }

        // Tab goes along a row before it goes down: from the width to the height, and from the height to the next
        // row. A size typed is held to what a window can be once its field is left, and the keyboard stays where Tab
        // put it though the sheet is built again.
        @Test func tabGoesFromTheWidthToTheHeightAndASizeIsHeld() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let tab = try await harness.open()
            let view = WindowView(
                id: "w", name: "Work", tabs: [nil], size: WindowView.Size(width: 1000, height: 700))
            tab.updatePreferences { $0.windowViews = [view] }
            tab.editWindowView(view)
            let sheet = try windowSheet(tab)
            #expect(sheet.draft.sizeChoice == .saved)
            sheet.changeForTesting { $0.sizeChoice = .custom }
            sheet.layoutSubtreeIfNeeded()
            let order = sheet.focusOrder().map { $0.accessibilityIdentifier() }
            let width = try #require(order.firstIndex(of: "windowViewOptions.width"))
            #expect(order[width + 1] == "windowViewOptions.height")
            #expect(order[width - 1] == "windowViewOptions.size")
            #expect(order[width + 2] == "windowViewOptions.keep.Folder Tree")

            let widthField = try #require(control("windowViewOptions.width", in: sheet, as: NSTextField.self))
            tab.window?.makeFirstResponder(widthField)
            widthField.currentEditor()?.selectAll(nil)
            try typeLetters("100", into: widthField)
            sheet.cycleFocus(backward: false)
            #expect(await waitUntil { sheet.focusedControl?.accessibilityIdentifier() == "windowViewOptions.height" })
            #expect(sheet.draft.customSize.width == WindowView.minimumSize.width)
            #expect(
                await waitUntil {
                    self.control("windowViewOptions.width", in: sheet, as: NSTextField.self)?.stringValue == "760"
                })
            #expect(sheet.focusedControl?.accessibilityIdentifier() == "windowViewOptions.height")
            if let largest = sheet.draft.largestSize {
                let heightField = try #require(control("windowViewOptions.height", in: sheet, as: NSTextField.self))
                heightField.currentEditor()?.selectAll(nil)
                try typeLetters("99999", into: heightField)
                sheet.cycleFocus(backward: false)
                #expect(sheet.draft.customSize.height == largest.height)
                #expect(
                    await waitUntil {
                        sheet.focusedControl?.accessibilityIdentifier() == "windowViewOptions.keep.Folder Tree"
                    })
            }
        }

        // A share typed for the divider is kept as typed, held to what a drag allows once left, and Tab goes on from
        // it to the next row.
        @Test func aShareTypedIsHeldAndTabGoesOn() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let tab = try await harness.open()
            tab.openSecondPane()
            tab.perform(.saveTabView)
            let sheet = try tabSheet(tab)
            sheet.changeForTesting {
                $0.keepsDivider = true
                $0.divider = .custom
            }
            let field = try #require(control("tabViewOptions.customShare", in: sheet, as: NSTextField.self))
            tab.window?.makeFirstResponder(field)
            field.currentEditor()?.selectAll(nil)
            try typeLetters("5", into: field)
            sheet.cycleFocus(backward: false)
            #expect(
                await waitUntil {
                    sheet.focusedControl?.accessibilityIdentifier() == "tabViewOptions.keep.Hidden Files"
                })
            #expect(sheet.draft.keeps.divider == .share(PaneSplit.minimum))
            #expect(
                await waitUntil {
                    self.control("tabViewOptions.customShare", in: sheet, as: NSTextField.self)?.stringValue == "20"
                })
        }

        // However short the window, the sheet ends above its bottom edge: what doesn't fit scrolls, its buttons kept.
        @Test func theSheetFitsUnderTheToolbarOfAShortWindow() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let tab = try await harness.open()
            tab.openSecondPane()
            tab.perform(.saveTabView)
            let sheet = try tabSheet(tab)
            for height in [400.0, 520, 700, 2000] {
                let size = sheet.panelSize(in: NSSize(width: 1000, height: height))
                #expect(size.height <= max(160, height - DialogLayout.sheetTop - SavedViewSheet.bottomInset))
            }
            let tall = sheet.panelSize(in: NSSize(width: 1000, height: 4000))
            #expect(tall.height < 4000 - DialogLayout.sheetTop - SavedViewSheet.bottomInset)
        }

        // A pane of two can show the viewer: the sheet offers Viewer in either pane's View, with Follow and Read or
        // Edit, and the tab view applied opens the viewer beside the other's list, showing what it selects.
        @Test func aTabViewOpensTheViewerBesideTheOtherPane() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let tab = try await harness.open()
            let note = harness.folder.appending("note.txt").path
            tab.perform(.saveTabView)
            var sheet = try tabSheet(tab)
            let onePane = try #require(control("tabViewOptions.view", in: sheet, as: NSPopUpButton.self))
            #expect(!onePane.itemTitles.contains("Viewer"))
            sheet.changeForTesting { $0.panes = 2 }
            let view = try #require(control("tabViewOptions.view", in: sheet, as: NSPopUpButton.self))
            #expect(view.itemTitles.last == "Viewer")
            sheet.onCancel()

            tab.updatePreferences {
                $0.tabViews = [
                    TabView(
                        id: "v", name: "Read Beside",
                        keeps: TabViewKeeps(
                            panes: 2, right: PaneKeeps(viewer: PaneViewer(follows: true, editing: true))))
                ]
            }
            tab.panes[0].content.select(paths: [note])
            tab.applyTabView(id: "v")
            #expect(
                await waitUntil { tab.panes.count == 2 && tab.panes[1].viewer?.path.map { samePath($0, note) } == true }
            )
            let viewer = try #require(tab.panes[1].viewer)
            #expect(viewer.mode == .following)
            #expect(await waitUntil { viewer.isEditing })
            #expect(tab.activePane === tab.panes[0])
            // Saved again from the tab, the viewer is what the right pane keeps.
            tab.perform(.saveTabView)
            sheet = try tabSheet(tab)
            #expect(sheet.draft.keeps.right?.viewer == PaneViewer(follows: true, editing: true))
            sheet.onCancel()

            // A tab view that gives the pane a view of a folder closes its viewer.
            tab.updatePreferences {
                $0.tabViews.append(
                    TabView(
                        id: "l", name: "List",
                        keeps: TabViewKeeps(panes: 2, right: PaneKeeps(view: FolderViewKeeps(view: .details)))))
            }
            tab.applyTabView(id: "l")
            #expect(await waitUntil { tab.panes.count == 2 && tab.panes[1].viewer == nil })
            #expect(tab.panes[1].viewMode == .details)
        }

        // A click on a tab view's name selects its row, so Edit… and Apply can act on it; its name is edited only
        // once double-clicked.
        @Test func aNameInTheListIsEditedOnlyOnceDoubleClicked() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let tab = try await harness.open()
            tab.updatePreferences { $0.tabViews = [TabView(id: "a", name: "A", keeps: TabViewKeeps(panes: 1))] }
            let views = ViewsWindowController(views: SharedFolderViews(), open: { _ in })
            defer { views.close() }
            views.present(.tabViews, explorer: tab)
            let pane: SavedViewsPane = views.tabViewsPane
            pane.reload()
            let table = pane.tableView
            let column = table.column(withIdentifier: NSUserInterfaceItemIdentifier("name"))
            let name = try #require(table.view(atColumn: column, row: 0, makeIfNecessary: true) as? NSTextField)
            #expect(!name.isEditable)
            pane.startRenaming(row: 0)
            #expect(name.isEditable && table.selectedRow == 0)
            views.window?.makeFirstResponder(table)
            #expect(!name.isEditable)
            // Selected, Edit… opens the tab view's sheet over the window.
            pane.editSelected()
            let sheet = try tabSheet(tab)
            #expect(sheet.draft.editingID == "a")
        }
    }
}
