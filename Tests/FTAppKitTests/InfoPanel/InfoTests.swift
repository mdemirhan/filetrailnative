// Covers the path bar, the Info Row, the Info panel and the folder sizes in an explorer window that is never shown,
// by feature row (App.commands.test.tsx's Info panel cases, App.menusAndTree.test.tsx's Calculate Size cases,
// ContentPane.test.tsx's path bar)
import AppKit
import FTFileSystem
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    @MainActor
    @Suite struct InfoTests {
        func texts(_ id: String, in tab: MainWindowController) -> [String] {
            guard let root = tab.window?.contentView?.superview else { return [] }
            return findViews(id, in: root).map(fieldText)
        }

        func path(_ name: String, in tab: MainWindowController) -> String {
            tab.content.entries.first { $0.name == name }?.path ?? ""
        }

        func select(_ names: [String], in tab: MainWindowController, harness: ExplorerHarness) {
            tab.content.select(paths: names.compactMap { name in tab.content.entries.first { $0.name == name }?.path })
        }

        // T-209d6f52 F-697 F-748 F-820 B-INFO-001 B-INFO-066 B-INFO-069: the panel and the row follow the selection.
        @Test func thePanelAndTheRowDescribeTheSelection() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            tab.perform(.toggleInfoPanel)
            tab.perform(.toggleInfoRow)
            harness.layout(tab)
            // Nothing selected: the folder on screen.
            let folderName = harness.folder.path.split(separator: "/").last.map(String.init) ?? ""
            #expect(await waitUntil { texts("infoPanel.name", in: tab) == [folderName] })
            #expect(texts("infoRow.name", in: tab) == [folderName])
            select(["note.txt"], in: tab, harness: harness)
            #expect(await waitUntil { texts("infoPanel.name", in: tab) == ["note.txt"] })
            #expect(texts("infoRow.name", in: tab) == ["note.txt"])
            #expect(await waitUntil { texts("infoPanel.row.label", in: tab).contains("Permissions") })
            #expect(await waitUntil { tab.content.contentShell.infoRow.height == 30 })
            await harness.close()
        }

        // F-805 B-INFO-009: Show Info points the panel at an item that is not selected, and a selection takes it back.
        @Test func showInfoPointsThePanelAtAnUnselectedItem() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let info = try #require(tab.infoController)
            info.showInfo(for: path("Beta", in: tab))
            harness.layout(tab)
            #expect(tab.panels.propertiesOpen)
            #expect(await waitUntil { texts("infoPanel.name", in: tab) == ["Beta"] })
            select(["Gamma"], in: tab, harness: harness)
            #expect(await waitUntil { texts("infoPanel.name", in: tab) == ["Gamma"] })
            await harness.close()
        }

        // T-650e6f58 T-df07c21f F-824 B-INFO-160 B-INFO-161: Calculate Size measures the selected folders; with nothing
        // selected, the folder on screen.
        @Test func calculateSizeMeasuresTheSelectedFolders() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            tab.perform(.toggleInfoRow)
            let alpha = path("Alpha", in: tab)
            let beta = path("Beta", in: tab)
            select(["Alpha", "Beta", "note.txt"], in: tab, harness: harness)
            tab.perform(.focusContentPane)
            tab.perform(.calculateSize)
            #expect(
                await waitUntil { tab.folderSizes.readySize(alpha) != nil && tab.folderSizes.readySize(beta) != nil })
            #expect(tab.folderSizes.readySize(tab.currentFolder.path) == nil)
            tab.content.select(paths: [])
            tab.perform(.calculateSize)
            #expect(await waitUntil { tab.folderSizes.readySize(tab.currentFolder.path) != nil })
            #expect(
                await waitUntil {
                    texts("infoRow.folderSize.size", in: tab).contains { $0.contains(" · ") && $0.contains("folder") }
                })
            await harness.close()
        }

        // T-3c985219 T-487ad066 F-743 F-805 B-INFO-120 B-INFO-121 B-INFO-123 B-INFO-124: a separator lists the folders next to the
        // one that follows it, with that one ticked; choosing another goes there.
        @Test func aSeparatorsMenuStepsSideways() async throws {
            let harness = try ExplorerHarness.windowless()
            let alphaPath = harness.folder.appending("Alpha").path
            // The listing reports the real path of a temporary folder (/private/var).
            let tab = try await harness.open(alphaPath.hasPrefix("/var/") ? "/private" + alphaPath : alphaPath)
            let bar = tab.content.contentShell.pathBarRow
            let parentName = harness.folder.path.split(separator: "/").last.map(String.init) ?? ""
            #expect(await waitUntil { bar.pathBar.segments.last?.label == "Alpha" })
            harness.layout(tab)
            let separators = findViews("pathBar.separator", in: bar).compactMap { $0 as? PathSeparatorView }
            let separator = try #require(separators.last)
            #expect(separator.accessibilityLabel() == "Folders in \(parentName)")
            separator.onClick?()
            guard let root = tab.window?.contentView else { return }
            #expect(await waitUntil { !findViews("pathBarMenu", in: root).isEmpty })
            let rows = findViews("pathBarMenu.item", in: root)
            #expect(rows.map(fieldText).sorted() == ["Alpha", "Beta", "Gamma"])
            #expect(findViews("pathBarMenu.item.checked", in: root).map(fieldText) == ["Alpha"])
            let menu = try #require(findViews("pathBarMenu", in: root).first as? PathFolderMenuView)
            menu.onChoose(1)
            #expect(await waitUntil { tab.currentFolder.lastPathComponent == "Beta" })
            #expect(await waitUntil { findViews("pathBarMenu", in: root).isEmpty })
            await harness.close()
        }

        // T-c3292381 F-745 B-INFO-113: Return goes to the typed path.
        @Test func returnGoesToTheTypedPath() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let bar = tab.content.contentShell.pathBarRow
            bar.beginEditing()
            let target = harness.folder.appending("Gamma").path
            bar.editor.field.stringValue = target
            bar.editor.controlTextDidChange(
                Notification(name: NSControl.textDidChangeNotification, object: bar.editor.field))
            let editor = try #require(bar.editor.field.currentEditor() as? NSTextView)
            _ = bar.editor.control(
                bar.editor.field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:)))
            #expect(await waitUntil { tab.currentFolder.lastPathComponent == "Gamma" })
            #expect(!bar.isEditing)
            await harness.close()
        }
    }
}
