// The accent parity scenario's steps that write through the app or hand it a path from outside a listing, and what
// it keeps of a folder from one launch to the next
import AppKit
import FTFileSystem
import FTFoundation
import FTOperations
import FTTestSupport
import Foundation
import Testing

@testable import FTAppKit

extension AccentScenario {
    private var folder: String { names.folder }

    /// The rows now that weren't among `before`, byte for byte.
    private func rowsNew(since before: [String]) -> [String] {
        let known = Set(before.map(DiskPath.init))
        return rowPaths.filter { !known.contains(DiskPath($0)) }
    }

    /// What the top of the Undo list recorded: the paths made, and where items were moved to.
    private var undoRecord: (made: [String], movedTo: [String]) {
        let steps = window.operations.undoHistory.top(.undo)?.units.flatMap(\.steps) ?? []
        var made: [String] = []
        var movedTo: [String] = []
        for step in steps {
            if case .created(let path, _, _) = step { made.append(path) }
            if case .moved(let move) = step { movedTo.append(move.to) }
        }
        return (made, movedTo)
    }

    private var clipboardTold: String {
        let contents = tab.services.clipboard.contents
        let mode = contents.hasItems ? contents.mode.map { "\($0)" } ?? "no mode" : "empty"
        return mode + " " + names.told(contents.sourcePaths)
    }

    /// Opens the sub-folder by its row, as a double-click does.
    private func opensTheSubfolder() async -> Bool {
        guard let sub = row(.sub) else { return false }
        tab.content.activate([sub], newTab: false)
        return await arrives { self.shows(sub.path) }
    }

    // MARK: Rename in a row

    func renamesInARow() async {
        begin("rename")
        await backInTheFolder()
        guard let item = row(.renamed) else {
            note("the row is listed", false)
            return
        }
        let typed = names.typed
        select([item])
        tab.perform(.renameSelection)
        note("the name opens in its row", told: tab.content.inlineRename?.path)
        tab.content.renameSubmitted(typed)
        let renamed = await arrives {
            self.tab.content.inlineRename == nil && self.row(named: typed) != nil && self.isIdle
        }
        note("the row has the name typed", renamed)
        if let refusal = tab.content.inlineRename?.error { note("the field says", told: refusal) }
        note("the disk has the name as typed", holds(typed, in: folder))
        note("the old name is gone", !holds(names.name(.renamed), in: folder))
        note("the renamed row is selected", await arrives { self.selects([self.folder + "/" + typed]) })
        noteState("renamed")

        note("Undo runs", await undo())
        let back = await arrives { self.row(.renamed) != nil && self.row(named: typed) == nil && self.isIdle }
        note("Undo puts the name back", back)
        note("the disk has the old name again", holds(names.name(.renamed), in: folder))
        noteState("undone")
    }

    // MARK: New Folder, New Folder with Selection, New File

    func makesNewItems() async {
        begin("new folder")
        await backInTheFolder()
        let before = rowPaths
        select([])
        tab.perform(.newFolder)
        note("its name opens in its row", await arrives { self.tab.content.inlineRename != nil })
        note("the name being edited", told: tab.content.inlineRename?.path)
        note("the folder made", told: rowsNew(since: before))
        note("it is made in the folder", holds("untitled folder", in: folder))
        note("it is selected", await arrives { self.selects(self.rowsNew(since: before)) })
        note("Undo's record", told: undoRecord.made)
        tab.content.renameCancelled()
        note("Undo runs", await undo())
        note("Undo takes it away", await arrives { self.rowsNew(since: before).isEmpty && self.isIdle })
        note("it is gone from the disk", !holds("untitled folder", in: folder))

        begin("new folder with selection")
        if let items = rows([.zippedOne, .zippedTwo]) {
            select(items)
            tab.perform(.newFolderWithSelection)
            note("its name opens in its row", await arrives { self.tab.content.inlineRename != nil })
            note("the name being edited", told: tab.content.inlineRename?.path)
            note("the folder made", told: rowsNew(since: before))
            note("it is selected", await arrives { self.selects(self.rowsNew(since: before)) })
            note(
                "it holds the items",
                toldSorted: AccentDisk.names(in: folder + "/untitled folder").map {
                    String(decoding: $0, as: UTF8.self)
                })
            tab.content.renameCancelled()
            note("Undo runs", await undo())
            let back = await arrives {
                self.rowsNew(since: before).isEmpty && self.row(.zippedOne) != nil && self.row(.zippedTwo) != nil
                    && self.isIdle
            }
            note("Undo puts the items back", back)
            noteState("undone")
        }

        begin("new file")
        select([])
        tab.perform(.newTextFile)
        note("its name opens in its row", await arrives { self.tab.content.inlineRename != nil })
        note("the name being edited", told: tab.content.inlineRename?.path)
        note("the file made", told: rowsNew(since: before))
        note("it is selected", await arrives { self.selects(self.rowsNew(since: before)) })
        tab.content.renameCancelled()
        note("Undo runs", await undo())
        note("Undo takes it away", await arrives { self.rowsNew(since: before).isEmpty && self.isIdle })
    }

    // MARK: The clipboard and Duplicate

    func copiesCutsAndDuplicates() async {
        begin("copy and paste")
        await backInTheFolder()
        let before = rowPaths
        if let items = rows([.copied]) {
            select(items)
            tab.perform(.copySelection)
            note("the clipboard", clipboardTold)
            tab.perform(.pasteSelection)
            // A paste beside the item copied may ask what to do with the name: Keep Both is its default button.
            let reviews = CopyPasteReviewPresenter.shared
            _ = await arrives {
                !self.rowsNew(since: before).isEmpty || reviews.alert?.window === self.tab.window
                    || !self.window.recorder.shown.isEmpty
            }
            if let alert = reviews.alert, alert.window === tab.window {
                note("it asks", told: alert.titleLabel.stringValue)
                DialogKeys.press(KeyCode.returnKey, "\r", in: tab.window)
            }
            note("the copy is listed", await arrives { self.rowsNew(since: before).count == 1 && self.isIdle })
            note("the copy", told: rowsNew(since: before))
            note("the copy is selected", await arrives { self.selects(self.rowsNew(since: before)) })
            note("the clipboard after", clipboardTold)
            noteState("pasted")
            note("Undo runs", await undo())
            note("Undo takes the copy away", await arrives { self.rowsNew(since: before).isEmpty && self.isIdle })
        }

        begin("cut and paste")
        if let items = rows([.cut]) {
            let name = names.name(.cut)
            select(items)
            tab.perform(.cutSelection)
            note("the clipboard", clipboardTold)
            note("the sub-folder opens", await opensTheSubfolder())
            tab.perform(.focusContentPane)
            tab.perform(.pasteSelection)
            note("the item is listed there", await arrives { self.row(named: name) != nil && self.isIdle })
            note("the disk has it there", holds(name, in: names.sub))
            note("it left its folder", !holds(name, in: folder))
            note("it is selected", await arrives { self.selects([self.names.sub + "/" + name]) })
            note("the clipboard after", clipboardTold)
            noteState("pasted")
            note("Undo runs", await undo())
            let back = await arrives { self.holds(name, in: self.folder) && self.isIdle }
            note("Undo puts it back", back)
            note("it left the sub-folder", !holds(name, in: names.sub))
            tab.goBack(nil)
            note("Back: the folder opens", await arrives { self.shows(self.folder) })
            _ = await arrives { self.row(.cut) != nil }
            noteState("back")
        }
        tab.services.clipboard.set(.empty, from: nil)
        tab.clipboardChanged()

        begin("duplicate")
        if let items = rows([.duplicated]) {
            let before = rowPaths
            select(items)
            tab.perform(.duplicateSelection)
            note("the copy is listed", await arrives { self.rowsNew(since: before).count == 1 && self.isIdle })
            note("the copy", told: rowsNew(since: before))
            note("the copy is selected", await arrives { self.selects(self.rowsNew(since: before)) })
            note("Undo runs", await undo())
            note("Undo takes the copy away", await arrives { self.rowsNew(since: before).isEmpty && self.isIdle })
        }

        // An alias beside the item, listed as one; Show Original from it selects the item, in the folder on screen.
        begin("make alias and show original")
        if let items = rows([.duplicated]) {
            let before = rowPaths
            select(items)
            tab.perform(.makeAlias)
            note("the alias is listed", await arrives { self.rowsNew(since: before).count == 1 && self.isIdle })
            let made = rowsNew(since: before)
            note("the alias", told: made)
            note("the alias is selected", await arrives { self.selects(made) })
            let alias = rows.first { row in made.contains { self.same($0, row.path) } }
            note("it is listed as an alias", alias?.kind == .alias)
            if let alias {
                select([alias])
                tab.perform(.showOriginal)
                note("Show Original selects the item", await arrives { self.selects([items[0].path]) })
                note("Show Original stays in the folder", shows(folder))
            }
            note("Undo runs", await undo())
            note("Undo takes the alias away", await arrives { self.rowsNew(since: before).isEmpty && self.isIdle })
        }
    }

    // MARK: Into the sub-folder

    /// The sub-folder opened by its row and by its row in the tree, each of which names it as the folder above is
    /// read, where the pane then knows it as the read of the sub-folder itself names it; a write there; and the way
    /// back out.
    func goesIntoTheSubfolder() async {
        begin("into the sub-folder")
        await backInTheFolder()
        let model = tab.sidebarController.model
        let step = tab.historyIndex
        note("by its row: the path its row has", told: row(.sub)?.path)
        note("by its row: it opens", await opensTheSubfolder())
        note("by its row: the folder on screen", told: tab.folderPath)
        note("by its row: one step further", tab.historyIndex == step + 1)
        note(
            "by its row: the step",
            told: tab.historyPaths.indices.contains(tab.historyIndex) ? tab.historyPaths[tab.historyIndex] : nil)
        note("by its row: the tree's row is selected", await treeSelects(names.sub))
        note("by its row: the tree's selection", told: model.selected?.filesystemPath)
        note("by its row: the path bar's path", told: tab.content.contentShell.pathBarRow.path)

        // A write there: New Folder, selected with its name open.
        let before = rowPaths
        select([])
        tab.perform(.newFolder)
        note("a folder made there: its name opens in its row", await arrives { self.tab.content.inlineRename != nil })
        note("a folder made there: the name being edited", told: tab.content.inlineRename?.path)
        let made = rowPaths.filter { path in !before.contains { samePath($0, path) } }
        note("a folder made there: it is listed", told: made)
        note("a folder made there: it is selected", await arrives { !made.isEmpty && self.selects(made) })
        tab.content.renameCancelled()
        note("a folder made there: Undo runs", await undo())
        _ = await arrives { self.rowPaths.count == before.count && self.isIdle }

        tab.perform(.goEnclosingFolder)
        note("Enclosing Folder: the folder opens", await arrives { self.shows(self.names.folder) })
        note("Enclosing Folder: the folder on screen", told: tab.folderPath)
        note("Enclosing Folder: the tree's row is selected", await treeSelects(names.folder))
        tab.goBack(nil)
        note("Back: the sub-folder opens", await arrives { self.shows(self.names.sub) })
        note("Back: the tree's row is selected", await treeSelects(names.sub))
        tab.goForward(nil)
        note("Forward: the folder opens", await arrives { self.shows(self.names.folder) })
        note("Forward: the tree's row is selected", await treeSelects(names.folder))

        // By its row in the tree, which is named as the tree's read of the folder above names it.
        let inTree = treeRows.first { same($0, names.sub) }
        note("by the tree's row: the tree shows the sub-folder", inTree != nil)
        guard let inTree else { return }
        do {
            note("by the tree's row: the path the row has", told: inTree)
            model.selectItem(.filesystem(inTree))
            note("by the tree's row: it opens", await arrives { self.shows(self.names.sub) })
            note("by the tree's row: the folder on screen", told: tab.folderPath)
            note("by the tree's row: the tree's row is selected", await treeSelects(names.sub))
            note("by the tree's row: the tree's selection", told: model.selected?.filesystemPath)
            note("by the tree's row: its rows", toldSorted: rowPaths)
        }
        tab.perform(.goEnclosingFolder)
        note("and out again: the folder opens", await arrives { self.shows(self.names.folder) })
        _ = await arrives { self.row(.sub) != nil }
        note("and out again: the tree's row is selected", await treeSelects(names.folder))
    }

    // MARK: Move To, Extract To and Go To with the folder typed

    func movesToTheFolderTyped() async {
        begin("move to")
        await backInTheFolder()
        note("the sub-folder opens", await opensTheSubfolder())
        let group = tab.group
        for (role, typed, spelling) in [
            (AccentRole.movedOne, typedComposed, "typed composed"), (.movedTwo, typedDecomposed, "typed decomposed"),
        ] {
            guard let items = rows([role]) else { continue }
            let name = names.name(role)
            select(items)
            tab.perform(.moveSelection)
            note("\(spelling): the box takes the folder", await submit(typed))
            let moved = await arrives {
                self.tab.goToBox == nil && self.holds(name, in: self.folder) && self.isIdle
            }
            note("\(spelling): the item is in the folder", moved)
            note("\(spelling): it left the sub-folder", !holds(name, in: names.sub))
            note("\(spelling): its row left the sub-folder's list", await arrives { self.row(role) == nil })
            note("\(spelling): Undo's record", told: undoRecord.movedTo)
            note("\(spelling): tabs", "\(group?.tabs.count ?? 0)")
        }
        note("the folders chosen", told: store.destinations().map(\.path))
        noteState("moved")

        tab.perform(.goEnclosingFolder)
        note("Enclosing Folder: the folder opens", await arrives { self.shows(self.folder) })
        note("Enclosing Folder: the folder on screen", told: tab.folderPath)
        _ = await arrives { self.row(.movedOne) != nil && self.row(.movedTwo) != nil }
        noteState("Enclosing Folder")
    }

    func extractsToTheFolderTyped() async {
        begin("extract to")
        await backInTheFolder()
        let group = tab.group
        for (role, inside, typed, spelling) in [
            (AccentRole.archiveOne, "inside-one.txt", typedComposed, "typed composed"),
            (.archiveTwo, "inside-two.txt", typedDecomposed, "typed decomposed"),
        ] {
            guard let items = rows([role]) else { continue }
            select(items)
            tab.perform(.extractSelectionTo)
            note("\(spelling): the box takes the folder", await submit(typed))
            let out = await arrives { self.tab.goToBox == nil && self.row(named: inside) != nil && self.isIdle }
            note("\(spelling): what came out is listed", out)
            note("\(spelling): it is selected", await arrives { self.selects([self.folder + "/" + inside]) })
            note("\(spelling): selection", toldSorted: selection)
            note("\(spelling): tabs", "\(group?.tabs.count ?? 0) in \(harness.windows.count) window")
        }
        note("the folders chosen", told: store.destinations().map(\.path))
        noteState("extracted")
    }

    func goesToTheFolderTyped() async {
        begin("go to")
        await backInTheFolder()
        tab.go(to: names.parent)
        note("the folder above opens", await arrives { self.shows(self.names.parent) })
        let steps = tab.historyPaths.count
        for (typed, spelling) in [(typedComposed, "typed composed"), (typedDecomposed, "typed decomposed")] {
            tab.perform(.openLocationSheet)
            note("\(spelling): the box takes the folder", await submit(typed))
            note("\(spelling): the folder opens", await arrives { self.tab.goToBox == nil && self.shows(self.folder) })
            note("\(spelling): the folder on screen", told: tab.folderPath)
            note("\(spelling): one step further", tab.historyPaths.count == steps + 1 && tab.historyIndex == steps)
            note("\(spelling): the step", told: tab.historyPaths.last)
            note("\(spelling): the tree's row is selected", await treeSelects(folder))
            tab.goBack(nil)
            note("\(spelling): Back opens the folder above", await arrives { self.shows(self.names.parent) })
        }
        // The same path typed into the path bar.
        let bar = tab.content.contentShell.pathBarRow
        bar.beginEditing()
        bar.editor.onSubmit(typedOtherwise)
        note("typed in the path bar: the folder opens", await arrives { self.shows(self.folder) })
        note("typed in the path bar: the folder on screen", told: tab.folderPath)
        note("typed in the path bar: the step", told: tab.historyPaths.last)
        tab.goBack(nil)
        note("typed in the path bar: Back opens the folder above", await arrives { self.shows(self.names.parent) })
        tab.goForward(nil)
        note("Forward: the folder opens", await arrives { self.shows(self.folder) })
        note("Forward: the folder on screen", told: tab.folderPath)
        let visited = store.folders().filter { names.told($0.path).hasSuffix("<folder>") }
        note("the folder among those gone to", told: visited.map(\.path))
        note("its visits", "\(visited.map(\.visits.count))")
        noteState("gone to")
    }

    // MARK: Compress and Extract

    func compressesAndExtracts() async {
        begin("compress")
        await backInTheFolder()
        guard let items = rows([.zippedOne, .zippedTwo]) else { return }
        let before = rowPaths
        let group = tab.group
        select(items)
        tab.perform(.compressSelection)
        note("the archive is listed", await arrives { self.rowsNew(since: before).count == 1 && self.isIdle })
        let archive = rowsNew(since: before)
        note("the archive", told: archive)
        note("the archive is selected", await arrives { self.selects(archive) })

        begin("extract")
        let withArchive = rowPaths
        tab.content.select(paths: archive)
        tab.content.focusList()
        tab.perform(.focusContentPane)
        tab.perform(.extractSelection)
        note("what came out is listed", await arrives { !self.rowsNew(since: withArchive).isEmpty && self.isIdle })
        let out = rowsNew(since: withArchive)
        note("what came out", toldSorted: out)
        note("it is selected", await arrives { self.selects(out) })
        note("tabs", "\(group?.tabs.count ?? 0) in \(harness.windows.count) window")
        // An archive's names come out composed, whichever way the items compressed were stored: the app's own rule
        // for what it extracts. So what came out is each item's name with its accents composed.
        let inside = out.flatMap { AccentDisk.names(in: $0) }.filter { $0.first != UInt8(ascii: ".") }
        if anySpelling {
            // How the folder is read says nothing certain of how a name is kept: the items by their names alone.
            let came = inside.map { String(decoding: $0, as: UTF8.self) }
            note("what came out holds the items", Set(came) == Set(items.map(\.name)))
        } else {
            let composed = items.map { Array($0.name.precomposedStringWithCanonicalMapping.utf8) }
            note("what came out holds the items, their names composed", Set(inside) == Set(composed))
        }
        note("what came out holds", "\(inside.count) items")
        noteState("extracted")
    }

    // MARK: The Trash

    func trashesAndUndoes() async {
        begin("trash")
        await backInTheFolder()
        guard let items = rows([.trashed]) else { return }
        let name = names.name(.trashed)
        select(items)
        tab.perform(.trashSelection)
        note("the row goes", await arrives { self.row(.trashed) == nil && self.isIdle })
        note("the disk no longer has it", !holds(name, in: folder))
        note("Undo runs", await undo())
        note("Undo lists it again", await arrives { self.row(.trashed) != nil && self.isIdle })
        note("the disk has it under its name", holds(name, in: folder))
        noteState("undone")
    }

    // MARK: The Rename sheet

    func renamesSeveral() async {
        begin("rename sheet")
        await backInTheFolder()
        guard let items = rows([.sheetOne, .sheetTwo]) else { return }
        let before = rowPaths
        select(items)
        tab.perform(.renameSelection)
        let up = await arrives { self.tab.batchRenameSheet.map { !$0.model.checking } ?? false }
        note("the sheet opens", up)
        guard let sheet = tab.batchRenameSheet else { return }
        tab.window?.contentView?.layoutSubtreeIfNeeded()
        note("the sheet lists", toldSorted: sheet.preview.rows.map(\.oldName))
        sheet.modeControl.choose(.add)
        batchRenameType(sheet.addTextField, "-x")
        note("the names it will give", toldSorted: sheet.preview.rows.compactMap(\.newName))
        sheet.renameButton.perform()
        let renamed = await arrives {
            self.tab.batchRenameSheet == nil && self.rowsNew(since: before).count == 2 && self.isIdle
        }
        note("both are renamed", renamed)
        let made = rowsNew(since: before)
        note("the new names", toldSorted: made)
        note("the disk has them", made.allSatisfy { holds(NodePath.basename($0), in: folder) })
        note("nothing else changed", rowPaths.count == before.count)
        note("they are selected", await arrives { self.selects(made) })
        noteState("renamed")
        note("Undo runs", await undo())
        let back = await arrives {
            self.rowsNew(since: before).isEmpty && self.row(.sheetOne) != nil && self.row(.sheetTwo) != nil
                && self.isIdle
        }
        note("Undo puts the names back", back)
        noteState("undone")
    }

    // MARK: The other pane

    func readsAWriteInTheOtherPane() async {
        begin("other pane")
        await backInTheFolder()
        let left = tab.activePane
        let right = tab.openSecondPane()
        let open = await arrives { right.loaded && right.hasShownFolder && self.shows(right, self.folder) }
        note("the other pane opens on the folder", open)
        note("the other pane's folder", told: right.shownFolderPath)
        note("the pane with the keyboard is the first", tab.activePane === left)
        let both = SidebarPaneMark(left: true, right: true)
        let marked = await arrives {
            self.harness.layout(self.tab)
            return self.treeRow(self.folder)?.paneMark == both
        }
        note("the tree's row is marked for both panes", marked)

        if let items = rows([.paned]) {
            let before = rowPaths
            let known = Set(before.map(DiskPath.init))
            func arrived(_ pane: BrowserPane) -> [String] {
                pane.content.entries.map(\.path).filter { !known.contains(DiskPath($0)) }
            }
            select(items)
            tab.perform(.duplicateSelection)
            let listed = await arrives { arrived(left).count == 1 && arrived(right).count == 1 && self.isIdle }
            note("both panes list the copy", listed)
            note("the other pane's copy", told: arrived(right))
            let made = arrived(left)
            let selected = await arrives {
                Set(right.content.selection.paths.map(DiskPath.init)) == Set(made.map(DiskPath.init))
            }
            note("the other pane selects it", selected)
            note("the first pane selects it", await arrives { self.selects(made) })
            note("Undo runs", await undo())
            let gone = await arrives { arrived(left).isEmpty && arrived(right).isEmpty && self.isIdle }
            note("Undo takes it from both panes", gone)
        }
        tab.closeOtherPane()
        note("one pane again", await arrives { !self.tab.showsTwoPanes && self.shows(self.folder) })
        harness.layout(tab)
    }

    // MARK: A drag within the tab, and a drop from another app

    func dragsOntoTheSubfolder() async {
        begin("drag")
        await backInTheFolder()
        guard let items = rows([.dragged, .sub]) else { return }
        let name = names.name(.dragged)
        // No key held, whatever the Mac's keyboard says.
        let modifiers = TabDragDrop.modifiers
        TabDragDrop.modifiers = { [] }
        defer { TabDragDrop.modifiers = modifiers }
        let drags = tab.dragDrop
        let dragged = drags.automationDragStarted([items[0]])
        note("what is dragged", told: dragged)
        note(
            "the sub-folder takes the drop",
            drags.automationDrop(dragged, entry: items[1], allowed: [.copy, .move, .generic]))
        let moved = await arrives {
            self.holds(name, in: self.names.sub) && self.row(.dragged) == nil && self.isIdle
        }
        note("the item is in the sub-folder", moved)
        note("it left the folder", !holds(name, in: folder))
        note("the drag is over", TabDragDrop.ownDrag == nil)
        noteState("dropped")

        // Dragged back out of the sub-folder by another app, which hands over a URL made from the path's text: the
        // system spells that with every accent apart, whatever the disk keeps.
        begin("drop from another app")
        let before = rowPaths
        let drag = StubDraggingInfo(paths: [names.sub + "/" + name], sequence: 9_001, window: tab.window)
        drag.draggingSourceOperationMask = [.copy, .move, .generic]
        defer { drag.draggingPasteboard.releaseGlobally() }
        note("the folder on screen would take it", drags.contentDragUpdated(drag, entry: nil) != [])
        note("the folder on screen takes the drop", drags.contentPerformDrop(drag, entry: nil))
        let arrived = await arrives { self.row(.dragged) != nil && self.isIdle }
        note("the item is listed in the folder", arrived)
        note("the disk has it there under its name", holds(name, in: folder))
        note("what arrived", told: rowsNew(since: before))
        note("where it was moved to", told: undoRecord.movedTo)
        note("the sub-folder still has it", holds(name, in: names.sub) ? "yes" : "no")
        note("Undo runs", await undo())
        _ = await arrives { self.row(.dragged) == nil && self.isIdle }
        note("after Undo the sub-folder has it under its name", holds(name, in: names.sub))
        note("after Undo the folder has it", holds(name, in: folder) ? "yes" : "no")
        noteState("undone")
    }

    // MARK: An item another app opens

    /// An item opened from another app, or File Trail launched to open it, comes as a URL the system made: a tab
    /// opens on its folder with the item selected.
    func opensAnItemFromAnotherApp() async {
        begin("opened from another app")
        await backInTheFolder()
        guard let item = row(.tagged), let group = tab.group else {
            note("the row is listed", false)
            return
        }
        let handed = AppDelegate.paths(ofOpened: [URL(fileURLWithPath: item.path)])
        guard let request = handed.compactMap({ AppDelegate.describeOpened($0) }).first else {
            note("the item is found", false)
            return
        }
        note("the item asked for", told: request.path)
        noteOnDisk("it is spelled as on disk", spelledAsOnDisk(request.path))
        note("a window takes it", harness.windows.openFromOtherApp(request))
        guard let opened = group.selected, opened !== tab else {
            note("a tab opens for it", false)
            return
        }
        note("the tab's folder opens", await arrives { self.shows(opened.activePane, self.folder) })
        note("the tab's folder", told: opened.folderPath)
        let selected = await arrives {
            opened.content.selection.paths.count == 1 && samePath(opened.content.selection.paths[0], item.path)
        }
        note("the item is selected", selected)
        note("the tab's history", told: opened.historyPaths)
    }

    // MARK: What is kept: a favorite, the folder's view, a workspace, the tab

    /// What the sidebar and the pane say of the folder on screen in `tab`.
    private func noteKept(_ name: String, in tab: MainWindowController) {
        let pane = tab.activePane
        note("\(name): the folder on screen", told: tab.folderPath)
        note("\(name): the folder is a favorite", tab.sidebarController.isFavorite(tab.folderPath))
        note("\(name): the folder's view is its own", pane.shownFolderView?.use.own == true)
        note("\(name): the view's folder", told: pane.shownFolderView?.use.view.path)
        note("\(name): sorted by", "\(pane.shownSortBy)")
    }

    func keepsWhatWasSaved() async {
        begin("kept")
        await backInTheFolder()
        let sidebar = tab.sidebarController
        let pane = tab.activePane
        select([])
        note("the folder is offered as a favorite", told: tab.favoriteTargetPath)
        tab.perform(.toggleFavorite)
        note("the favorites", told: store.preferences().favorites.map(\.path))
        noteOnDisk(
            "the favorites are spelled as on disk",
            store.preferences().favorites.allSatisfy { spelledAsOnDisk($0.path) })

        // The folder's own view: sorted by the date modified, and remembered.
        tab.perform(.sortByModified)
        tab.perform(.rememberFolderView)
        note("the views kept", told: pane.folderViews.views.all.map(\.path))
        noteKept("remembered", in: tab)

        // A tab view that opens the folder.
        tab.updatePreferences {
            $0.tabViews = [
                TabView(
                    id: "tab-view-parity", name: "Parity", keeps: TabViewKeeps(pane: PaneKeeps(folder: tab.folderPath)))
            ]
        }
        note("the tab view is saved", await arrives { !self.store.preferences().tabViews.isEmpty })
        note("the tab view's folders", told: store.preferences().tabViews.flatMap(\.keeps.folders))

        // Left, and opened again by Go To, typed in the spelling the disk doesn't have.
        tab.go(to: names.parent)
        note("left: the folder above opens", await arrives { self.shows(self.names.parent) })
        note("left: sorted by", "\(pane.shownSortBy)")
        tab.perform(.openLocationSheet)
        note("by Go To: the box takes the folder", await submit(typedOtherwise))
        note("by Go To: the folder opens", await arrives { self.tab.goToBox == nil && self.shows(self.folder) })
        noteKept("by Go To", in: tab)

        // Left, and opened again by its favorite's row: the tab is then on its favorite, and is saved so.
        tab.go(to: names.parent)
        _ = await arrives { self.shows(self.names.parent) }
        if let favorite = store.preferences().favorites.first?.path {
            sidebar.model.selectItem(.favorite(favorite))
            note("by its row: the folder opens", await arrives { self.shows(self.folder) })
            let selected = await arrives { sidebar.model.selected?.favoritePath.map { samePath($0, favorite) } == true }
            note("by its row: the favorite's row is selected", selected)
            note("by its row: the tab's favorite", told: tab.favoritePath)
            noteKept("by its row", in: tab)
        }

        // The app started again on what was saved: the state files written, and read by a store of its own.
        tab.group?.saveSession()
        store.flush()
        do {
            let again = try ExplorerHarness(onScreen: false, startingAgainOn: harness.folder)
            again.windows.home = harness.windows.home
            again.services.folderViews = SharedFolderViews(store: again.store)
            let restored = try await again.openWhatWasKept()
            note(
                "started again: the tab's folder opens", await arrives { self.shows(restored.activePane, self.folder) })
            noteOnDisk("started again: the folder is spelled as on disk", spelledAsOnDisk(restored.folderPath))
            note("started again: history", told: restored.historyPaths)
            note("started again: the tree's top", told: restored.treeRootPath)
            note("started again: the favorites", told: again.store.preferences().favorites.map(\.path))
            note("started again: the tab's favorite", told: restored.favoritePath)
            noteKept("started again", in: restored)

            // The tab view, applied to the tab opened again once it has gone to the folder above.
            if let tabView = again.store.preferences().tabViews.first {
                restored.go(to: names.parent)
                _ = await arrives { self.shows(restored.activePane, self.names.parent) }
                restored.applyTabView(id: tabView.id)
                note(
                    "started again: the tab view opens the folder",
                    await arrives { self.shows(restored.activePane, self.folder) })
                note("tab view: the folder on screen", told: restored.folderPath)
                noteOnDisk("tab view: the folder is spelled as on disk", spelledAsOnDisk(restored.folderPath))
            } else {
                note("started again: the tab view is kept", false)
            }
            for tab in again.windows.allTabs { tab.window?.close() }
            await settle()
            again.pasteboard.releaseGlobally()
        } catch {
            note("started again", "\(error)")
        }
    }
}
