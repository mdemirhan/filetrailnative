// New File from a template, New Text File and Save as Template in a real tab, with the app's file operations and a
// Templates folder of the test's own
import AppKit
import FTFileSystem
import FTFoundation
import FTOperations
import FTTestSupport
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    @MainActor
    @Suite(.restoresWindowSeams) struct TemplatesInWindowTests {
        /// A window with the app's file operations, pointed at a Templates folder in a temporary place. The folder
        /// isn't made: a test that wants templates writes them.
        @MainActor
        private final class Templates {
            let window: WritingWindow
            let home: TemporaryDirectory
            let folder: String
            /// How often the tab said the folder is there to be watched.
            private(set) var opened = 0
            var tab: MainWindowController { window.tab }

            init() async throws {
                window = try await WritingWindow.open()
                home = try TemporaryDirectory(prefix: "filetrail-templates")
                folder = home.path + "/Templates"
                MainWindowController.templatesFolderPath = folder
                MainWindowController.templatesFolderOpened = { [weak self] in self?.opened += 1 }
            }

            func write(_ name: String, _ text: String) throws {
                try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
                try text.write(toFile: folder + "/" + name, atomically: true, encoding: .utf8)
            }

            func template(_ name: String) -> String? {
                try? String(contentsOfFile: folder + "/" + name, encoding: .utf8)
            }

            /// The names in the Templates folder; nil when there is no folder.
            var names: [String]? {
                (try? FileManager.default.contentsOfDirectory(atPath: folder))?.sorted()
            }

            func text(_ relative: String) -> String? {
                try? String(contentsOf: window.folder.appendingPathComponent(relative), encoding: .utf8)
            }

            /// The names in the folder on screen, as the disk has them.
            var onDisk: [String] {
                ((try? FileManager.default.contentsOfDirectory(atPath: window.folder.path)) ?? []).sorted()
            }

            /// The file being named in its row, by its name.
            var naming: String? { tab.content.inlineRename.map { NodePath.basename($0.path) } }

            /// A file written into the folder on screen, and listed.
            func add(_ name: String, _ text: String) async throws {
                try text.write(to: window.folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
                tab.refresh()
                #expect(await waitUntil { self.tab.content.entries.contains { $0.name == name } })
            }

            func toasts(_ title: String) -> [String?] {
                tab.notifications?.toasts.entries.filter { $0.title == title }.map(\.message) ?? []
            }

            func close() async {
                await window.close()
                home.remove()
            }
        }

        private var undoLabel: (Templates) -> String? { { $0.window.operations.undoHistory.menu().undo } }

        // MARK: New File

        // The template's contents arrive in a file of the folder on screen under the template's name, dated now, with
        // none of the template's permissions; it opens for naming, and Undo, which says "New File", sends it to the
        // Trash. The template itself is as it was.
        @Test func aTemplateBecomesANewFileNamedInItsRowAndUndoTrashesIt() async throws {
            let templates = try await Templates()
            let tab = templates.tab
            let contents = "#!/bin/sh\n# \(UUID().uuidString)\n"
            try templates.write("Script.sh", contents)
            let template = templates.folder + "/Script.sh"
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 1_000_000), .posixPermissions: 0o755],
                ofItemAtPath: template)
            let started = Date()

            tab.newFileFromTemplate(named: "Script.sh")
            #expect(await waitUntil { templates.naming != nil })
            #expect(templates.naming == "Script.sh")
            #expect(templates.text("Script.sh") == contents)
            let made = templates.window.folder.appendingPathComponent("Script.sh").path
            let attributes = try FileManager.default.attributesOfItem(atPath: made)
            let modified = try #require(attributes[.modificationDate] as? Date)
            // A date of its own: the disk's clock may differ from the test's by less than a second.
            #expect(modified.timeIntervalSince(started) > -2)
            // Only the contents are copied: a script template's copy isn't executable.
            let permissions = try #require(attributes[.posixPermissions] as? Int)
            #expect(permissions & 0o111 == 0)
            #expect(templates.template("Script.sh") == contents)
            let templateDate = try FileManager.default.attributesOfItem(atPath: template)[.modificationDate] as? Date
            #expect(templateDate == Date(timeIntervalSince1970: 1_000_000))
            #expect(await waitUntil { !tab.isWriteLocked })
            #expect(undoLabel(templates) == "New File")
            #expect(templates.window.recorder.shown.isEmpty)

            tab.content.renameCancelled()
            tab.content.focusList()
            tab.perform(.undo)
            #expect(await waitUntil { !templates.window.exists("Script.sh") && !tab.isWriteLocked })
            // In the Trash (the tests' own), not deleted.
            let trashed = try FileManager.default.contentsOfDirectory(atPath: StandInTrash.folder.path)
                .filter { $0.hasSuffix("Script.sh") }
                .map { try String(contentsOf: StandInTrash.folder.appendingPathComponent($0), encoding: .utf8) }
            #expect(trashed.contains(contents))
            #expect(templates.template("Script.sh") == contents)
            await templates.close()
        }

        // A name the folder has is never replaced: the new file takes the next free one, whether the list knows of
        // the file that has the name or it was made behind the list's back.
        @Test func aTakenNameGetsTheNextFreeOneAndNothingIsReplaced() async throws {
            let templates = try await Templates()
            let tab = templates.tab
            try templates.write("note.txt", "from the template")
            try templates.write("Letter.txt", "a letter")

            // "note.txt" is in the list.
            tab.newFileFromTemplate(named: "note.txt")
            #expect(await waitUntil { templates.naming != nil && !tab.isWriteLocked })
            #expect(templates.naming == "note 2.txt")
            #expect(templates.text("note 2.txt") == "from the template")
            #expect(templates.text("note.txt") == "x")
            tab.content.renameCancelled()

            // "Letter.txt" was made by another app since the list was read.
            try "kept".write(
                to: templates.window.folder.appendingPathComponent("Letter.txt"), atomically: true, encoding: .utf8)
            #expect(!tab.content.entries.contains { $0.name == "Letter.txt" })
            tab.newFileFromTemplate(named: "Letter.txt")
            #expect(await waitUntil { templates.naming != nil && !tab.isWriteLocked })
            #expect(templates.naming == "Letter 2.txt")
            #expect(templates.text("Letter 2.txt") == "a letter")
            #expect(templates.text("Letter.txt") == "kept")
            #expect(templates.window.recorder.shown.isEmpty)
            tab.content.renameCancelled()
            await templates.close()
        }

        // A template taken out of the folder after the menu listed it: the dialog says so, and nothing is written.
        @Test func aTemplateThatVanishedIsToldAndNothingIsWritten() async throws {
            let templates = try await Templates()
            let tab = templates.tab
            try templates.write("Other.txt", "still here")
            let before = templates.onDisk

            tab.newFileFromTemplate(named: "Gone.txt")
            #expect(await waitUntil { !templates.window.recorder.shown.isEmpty })
            #expect(templates.window.recorder.shown.map(\.title) == ["The file couldn\u{2019}t be made"])
            #expect(
                templates.window.recorder.shown.map(\.message) == [
                    "The template \u{201C}Gone.txt\u{201D} can\u{2019}t be read. It may have been moved or removed."
                ])
            #expect(templates.onDisk == before)
            #expect(tab.content.inlineRename == nil)
            #expect(!tab.isWriteLocked)
            #expect(undoLabel(templates) == nil)
            await templates.close()
        }

        // New Text File makes an empty "untitled.txt", named in its row, then "untitled 2.txt"; Undo says "New File"
        // and takes the last one.
        @Test func newTextFileMakesAnEmptyFileNamedInItsRow() async throws {
            let templates = try await Templates()
            let tab = templates.tab
            #expect(tab.canPerform(.newTextFile))

            tab.perform(.newTextFile)
            #expect(await waitUntil { templates.naming != nil && !tab.isWriteLocked })
            #expect(templates.naming == "untitled.txt")
            #expect(templates.text("untitled.txt") == "")
            tab.content.renameCancelled()

            tab.perform(.newTextFile)
            #expect(await waitUntil { templates.naming != nil && !tab.isWriteLocked })
            #expect(templates.naming == "untitled 2.txt")
            #expect(templates.text("untitled 2.txt") == "")
            #expect(undoLabel(templates) == "New File")
            tab.content.renameCancelled()

            tab.content.focusList()
            tab.perform(.undo)
            #expect(await waitUntil { !templates.window.exists("untitled 2.txt") && !tab.isWriteLocked })
            #expect(templates.window.exists("untitled.txt"))
            // Nothing was made in the Templates folder, nor the folder itself.
            #expect(templates.names == nil)
            #expect(templates.window.recorder.shown.isEmpty)
            await templates.close()
        }

        // The background's right-click menu makes the same files: Text File, and a template by its name.
        @Test func theRightClickMenusNewFileItemsMakeTheSameFiles() async throws {
            let templates = try await Templates()
            let tab = templates.tab
            try templates.write("Letter.txt", "a letter")

            tab.contextMenus.contextMenu(newFile: .template("Letter.txt"))
            #expect(await waitUntil { templates.naming != nil && !tab.isWriteLocked })
            #expect(templates.naming == "Letter.txt")
            #expect(templates.text("Letter.txt") == "a letter")
            tab.content.renameCancelled()

            tab.contextMenus.contextMenu(newFile: .textFile)
            #expect(await waitUntil { templates.naming != nil && !tab.isWriteLocked })
            #expect(templates.naming == "untitled.txt")
            tab.content.renameCancelled()
            await templates.close()
        }

        // MARK: Save as Template

        // The selected files are copied into the Templates folder, which is made first; the toast says where they
        // went, the watch is told the folder is there, and Undo takes the copies back. The files stay where they are.
        @Test func saveAsTemplateCopiesTheSelectedFilesAndUndoTakesThemBack() async throws {
            let templates = try await Templates()
            let tab = templates.tab
            try await templates.add("budget.csv", "a,b\n1,2\n")
            #expect(templates.names == nil)
            templates.window.select(["budget.csv", "note.txt"])
            #expect(tab.canPerform(.saveAsTemplate))

            tab.perform(.saveAsTemplate)
            #expect(await waitUntil { templates.names == ["budget.csv", "note.txt"] && !tab.isWriteLocked })
            #expect(templates.template("budget.csv") == "a,b\n1,2\n")
            #expect(templates.template("note.txt") == "x")
            #expect(templates.text("budget.csv") == "a,b\n1,2\n" && templates.text("note.txt") == "x")
            #expect(templates.opened == 1)
            #expect(await waitUntil { !templates.toasts("Copied to Templates").isEmpty })
            #expect(templates.window.recorder.shown.isEmpty)

            tab.perform(.undo)
            #expect(await waitUntil { templates.names == [] && !tab.isWriteLocked })
            #expect(templates.text("budget.csv") == "a,b\n1,2\n" && templates.text("note.txt") == "x")
            await templates.close()
        }

        // A template of the same name is asked about, as any copy onto a name that is taken: nothing is replaced
        // until an answer is given, and Keep Both adds the file beside the template there.
        @Test func aTemplateOfTheSameNameIsAskedAbout() async throws {
            let templates = try await Templates()
            let tab = templates.tab
            try templates.write("note.txt", "the template there")
            templates.window.select(["note.txt"])

            tab.perform(.saveAsTemplate)
            let reviews = CopyPasteReviewPresenter.shared
            #expect(await waitUntil { reviews.alert != nil && reviews.alert?.window === tab.window })
            let alert = try #require(reviews.alert)
            #expect(
                alert.titleLabel.stringValue == "\u{201C}note.txt\u{201D} already exists in \u{201C}Templates\u{201D}")
            #expect(templates.names == ["note.txt"])
            #expect(templates.template("note.txt") == "the template there")
            #expect(alert.defaultButton?.title == "Keep Both")

            DialogKeys.press(36, "\r", in: tab.window)
            #expect(await waitUntil { templates.names == ["note copy.txt", "note.txt"] && !tab.isWriteLocked })
            #expect(templates.template("note.txt") == "the template there")
            #expect(templates.template("note copy.txt") == "x")
            #expect(await waitUntil { alert.window == nil })
            await templates.close()
        }

        // A file sitting where the Templates folder should be: the dialog says the folder couldn't be made, and
        // nothing is copied or started.
        @Test func aFileWhereTheFolderShouldBeIsToldAndNothingIsCopied() async throws {
            let templates = try await Templates()
            let tab = templates.tab
            try "in the way".write(toFile: templates.folder, atomically: true, encoding: .utf8)
            templates.window.select(["note.txt"])

            tab.perform(.saveAsTemplate)
            #expect(templates.window.recorder.shown.map(\.title) == ["The Templates folder couldn\u{2019}t be made"])
            for _ in 0..<20 { await Task.yield() }
            #expect(try String(contentsOfFile: templates.folder, encoding: .utf8) == "in the way")
            #expect(!tab.isWriteLocked)
            #expect(tab.writeActions?.session.card == nil)
            #expect(templates.opened == 0)
            #expect(undoLabel(templates) == nil)
            #expect(templates.text("note.txt") == "x")
            await templates.close()
        }

        /// Save as Template asked for with "note.txt" selected while a template of that name is there: the question.
        private func askedAboutNote(_ templates: Templates, after earlier: AlertCard? = nil) async throws -> AlertCard {
            let reviews = CopyPasteReviewPresenter.shared
            let tab = templates.tab
            templates.window.select(["note.txt"])
            tab.perform(.saveAsTemplate)
            #expect(
                await waitUntil {
                    reviews.alert != nil && reviews.alert !== earlier && reviews.alert?.window === tab.window
                })
            return try #require(reviews.alert)
        }

        // The question's other two answers. Cancel copies nothing and leaves nothing to undo. Replace puts the file
        // in the template's place, the template going to the Trash, and Undo brings the template back; Keep Both's
        // copy is taken back by Undo. The file selected stays as it is throughout.
        @Test func cancelLeavesTheTemplateAndReplaceReplacesItUntilUndo() async throws {
            let templates = try await Templates()
            let tab = templates.tab
            try templates.write("note.txt", "the template there")

            var alert = try await askedAboutNote(templates)
            #expect(alert.asideButton?.title == "Cancel")
            alert.asideButton?.perform()
            #expect(await waitUntil { alert.window == nil })
            #expect(templates.names == ["note.txt"] && templates.template("note.txt") == "the template there")
            #expect(!tab.isWriteLocked && tab.writeActions?.session.card == nil)
            #expect(undoLabel(templates) == nil)
            #expect(templates.toasts("Copied to Templates").isEmpty && templates.window.recorder.shown.isEmpty)

            alert = try await askedAboutNote(templates, after: alert)
            try #require(alert.buttons.first { $0.title == "Replace" }).perform()
            #expect(await waitUntil { templates.template("note.txt") == "x" && !tab.isWriteLocked })
            #expect(await waitUntil { alert.window == nil })
            #expect(templates.names == ["note.txt"])
            #expect(undoLabel(templates) != nil)
            tab.content.focusList()
            tab.perform(.undo)
            #expect(await waitUntil { templates.template("note.txt") == "the template there" && !tab.isWriteLocked })
            #expect(templates.names == ["note.txt"] && undoLabel(templates) == nil)

            alert = try await askedAboutNote(templates, after: alert)
            try #require(alert.buttons.first { $0.title == "Keep Both" }).perform()
            #expect(await waitUntil { templates.names == ["note copy.txt", "note.txt"] && !tab.isWriteLocked })
            #expect(await waitUntil { alert.window == nil })
            tab.content.focusList()
            tab.perform(.undo)
            #expect(await waitUntil { templates.names == ["note.txt"] && !tab.isWriteLocked })
            #expect(templates.template("note.txt") == "the template there")
            #expect(templates.text("note.txt") == "x")
            #expect(templates.window.recorder.shown.isEmpty)
            await templates.close()
        }

        // The command asks whether what is selected allows it as it starts, by the same rule that dims its item: it
        // runs wherever the item is on. From the File menu; from the command palette, which is gone by the time the
        // command asks; and from the menu right after its own question was cancelled. With the folder tree focused
        // the item is dimmed in both, and the file's right-click menu, which names its own files, still copies.
        @Test func saveAsTemplateRunsWhereverItsItemIsOn() async throws {
            let templates = try await Templates()
            let tab = templates.tab
            let harness = templates.window.harness
            let window = try #require(tab.window)
            let menu = MainMenu(windows: harness.windows, focusedWindow: { tab.window })
            menu.recentCommands = { [] }
            menu.recordCommand = { _ in }
            menu.build()
            harness.windows.onMenuState = { [weak menu] id, state in menu?.sync.setWindowState(windowID: id, state) }
            defer { NSApp.mainMenu = nil }
            func item(in menu: NSMenu?) -> NSMenuItem? {
                for each in menu?.items ?? [] {
                    if each.identifier?.rawValue == "saveAsTemplate" { return each }
                    if let found = item(in: each.submenu) { return found }
                }
                return nil
            }
            let fileItem = try #require(item(in: NSApp.mainMenu))
            /// The copy arrived; the Templates folder goes again, for the next way in.
            func copied() async -> Bool {
                let did = await waitUntil { templates.names == ["note.txt"] && !tab.isWriteLocked }
                try? FileManager.default.removeItem(atPath: templates.folder)
                return did
            }
            func paletteRow() throws -> CommandPaletteEntry {
                menu.toggleCommandPalette()
                let box = try #require(tab.commandPaletteBox)
                window.contentView?.layoutSubtreeIfNeeded()
                box.field.stringValue = "save as template"
                box.textChanged("save as template")
                return try #require(box.rows.first { $0.entry.id == "saveAsTemplate" }).entry
            }
            templates.window.select(["note.txt"])
            #expect(window.makeFirstResponder(tab.content.pane?.focusView))

            #expect(menu.router.validateMenuItem(fileItem))
            menu.router.choose(itemID: "saveAsTemplate")
            #expect(await copied())

            #expect(try paletteRow().enabled)
            #expect(tab.commandPaletteBox?.selectedRow?.entry.id == "saveAsTemplate")
            DialogKeys.press(36, "\r", in: window)
            #expect(tab.commandPaletteBox == nil)
            #expect(await copied())

            tab.perform(.focusTreePane)
            #expect(tab.sidebarController.isFocused)
            #expect(!menu.router.validateMenuItem(fileItem) && !tab.canPerform(.saveAsTemplate))
            #expect(try !paletteRow().enabled)
            DialogKeys.press(53, "\u{1b}", in: window)
            #expect(tab.commandPaletteBox == nil)
            let entries = tab.content.selectedEntries
            #expect(entries.map(\.name) == ["note.txt"])
            tab.contextMenus.contextMenu(
                perform: .saveAsTemplate,
                subject: ContextMenuSubject(
                    surface: .content, scope: .selection, paths: entries.map(\.path), targetPath: entries[0].path,
                    entries: entries.map(ContextMenuCoordinator.commandEntry)))
            #expect(await copied())

            // Its own question, cancelled: the item is on again at once, and runs.
            #expect(window.makeFirstResponder(tab.content.pane?.focusView))
            try templates.write("note.txt", "there")
            let alert = try await askedAboutNote(templates)
            #expect(!menu.router.validateMenuItem(fileItem))
            alert.asideButton?.perform()
            #expect(menu.router.validateMenuItem(fileItem))
            try FileManager.default.removeItem(atPath: templates.folder)
            menu.router.choose(itemID: "saveAsTemplate")
            #expect(await copied())
            #expect(templates.window.recorder.shown.isEmpty)
            await templates.close()
        }

        // Save as Template is dimmed for a folder, alone or among files, and the key of a dimmed item still reaches
        // the command (`keyOfDimmedItem`): it copies nothing, and doesn't even make the Templates folder. With files
        // alone the item is on, and its key is the menu's.
        @Test func theKeyOfTheDimmedItemCopiesNoFolder() async throws {
            let templates = try await Templates()
            let tab = templates.tab
            tab.updatePreferences { $0.shortcutOverrides = ["saveAsTemplate": ["F9"]] }
            let f9 = try #require(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: .function, timestamp: 0, windowNumber: 0,
                    context: nil, characters: "\u{F70C}", charactersIgnoringModifiers: "\u{F70C}", isARepeat: false,
                    keyCode: 101))

            for selection in [["Alpha"], ["Alpha", "note.txt"]] {
                templates.window.select(selection)
                #expect(!tab.canPerform(.saveAsTemplate))
                #expect(tab.keyOfDimmedItem(f9))
                // The folder is made before anything is copied: none means the command didn't start.
                #expect(templates.names == nil)
                for _ in 0..<20 { await Task.yield() }
                #expect(templates.names == nil)
                #expect(tab.writeActions?.session.card == nil)
                #expect(!tab.isWriteLocked)
            }
            #expect(templates.opened == 0)
            #expect(templates.window.recorder.shown.isEmpty)

            templates.window.select(["note.txt"])
            #expect(tab.canPerform(.saveAsTemplate))
            #expect(!tab.keyOfDimmedItem(f9))
            #expect(templates.names == nil)
            await templates.close()
        }
    }
}
