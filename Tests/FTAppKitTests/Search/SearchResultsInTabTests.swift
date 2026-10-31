// Ports by feature the cases of apps/desktop/src/renderer/App.search.test.tsx and SearchOptionsMenu.test.tsx that act
// on results in a real tab: Reveal in Folder, Duplicate next to the original, the path bar, Settings edits of the
// search defaults, Return in an empty field and the options button from the keyboard, over the stand-in fd runtime
import AppKit
import FTFileSystem
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    @MainActor
    @Suite struct SearchResultsInTabTests {
        private func open() async throws -> (ExplorerHarness, MainWindowController, FakeSearchEngine, ManualTimers) {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let engine = FakeSearchEngine()
            let timers = ManualTimers()
            tab.search.session.engine = engine
            tab.search.session.timers = timers
            return (harness, tab, engine, timers)
        }

        private func search(_ text: String, in tab: MainWindowController, _ timers: ManualTimers) throws {
            let field = try #require(tab.searchField)
            field.stringValue = text
            tab.search.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
            timers.advance(0.4)
        }

        private func command(_ selector: Selector, in tab: MainWindowController) throws {
            let field = try #require(tab.searchField)
            let window = try #require(tab.window)
            if window.firstResponder as? NSTextView == nil { window.makeFirstResponder(field) }
            let editor = try #require(window.firstResponder as? NSTextView)
            _ = tab.search.control(field, textView: editor, doCommandBy: selector)
        }

        private func key(_ code: UInt16, _ characters: String, in window: NSWindow) -> NSEvent? {
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false,
                keyCode: code)
        }

        // F-813: results keep column widths of their own: searchColumnWidths set before the search is what the results
        // are laid out with, Folder among them.
        @Test func theResultsUseTheSearchColumnWidths() async throws {
            let (harness, tab, engine, timers) = try await open()
            tab.perform(.viewAsDetails)
            engine.finds = { _ in (["note.txt", "Alpha/Inner"], false, false) }
            let window = try #require(tab.window)
            let prefs: [String: Scenario.PrefValue] = [
                "searchColumnWidths": .object([
                    "name": .number(300), "folder": .number(110), "modified": .number(180), "size": .number(90),
                    "kind": .number(160), "created": .number(180), "permissions": .number(90),
                ])
            ]
            _ = AutomationPrefs.apply(prefs, context: .init(controller: tab, window: window, prefs: prefs))
            // The window saving its session (any navigation does) keeps them.
            tab.group?.saveSession()
            #expect(tab.group?.session.panels.searchColumnWidths.folder == 110)
            try search("no", in: tab, timers)
            #expect(tab.searchRootPath != nil)
            #expect(await waitUntil { !tab.content.entries.isEmpty })
            #expect(tab.preferences.searchColumnWidths.folder == 110)
            #expect(tab.content.columnState.widths[.folder] == 110)
            #expect(tab.content.columnState.widths[.modified] == 180)
            await harness.close()
        }

        // F-813: details are read per folder at once and shown as each comes (`loadSearchResultMetadata`): a slow folder
        // keeps only its own rows waiting.
        // B-SRCH-112
        @Test func aSlowFolderKeepsOnlyItsOwnResultsWaiting() async throws {
            let (harness, tab, engine, timers) = try await open()
            tab.perform(.viewAsDetails)
            harness.layout(tab)
            let real = tab.content.loaders.metadata
            var letGo = false
            tab.content.loaders.metadata = { folder, paths in
                if NodePath.basename(folder) == "Alpha" {
                    while !letGo { try? await Task.sleep(for: .milliseconds(10)) }
                }
                return await real(folder, paths)
            }
            engine.finds = { _ in (["note.txt", "Alpha/Inner"], false, false) }
            try search("no", in: tab, timers)
            #expect(await waitUntil { tab.content.entries.count == 2 })
            harness.layout(tab)
            let note = try #require(tab.content.entries.first { $0.name == "note.txt" }?.path)
            let inner = try #require(tab.content.entries.first { $0.name == "Inner" }?.path)
            #expect(await waitUntil { tab.content.metadata(for: note) != nil })
            #expect(tab.content.metadata(for: inner) == nil)
            #expect(tab.content.isReadingDetails)
            letGo = true
            #expect(await waitUntil { tab.content.metadata(for: inner) != nil })
            await harness.close()
        }

        // F-813 B-SRCH-104: with the search field being edited, the results still get their dates and sizes.
        // B-SRCH-058 B-VIEW-012
        @Test func resultsGetTheirDetailsWhileTheFieldIsEdited() async throws {
            let (harness, tab, engine, timers) = try await open()
            tab.perform(.viewAsDetails)
            harness.layout(tab)
            let window = try #require(tab.window)
            let field = try #require(tab.searchField)
            window.makeFirstResponder(field)
            engine.finds = { _ in (["note.txt", "Alpha"], false, false) }
            try search("no", in: tab, timers)
            #expect(await waitUntil { tab.content.entries.count == 2 })
            harness.layout(tab)
            #expect(field.isActive)
            let note = harness.folder.path + "/note.txt"
            let shown = tab.content.entries.first { $0.name == "note.txt" }?.path ?? note
            #expect(await waitUntil { tab.content.metadata(for: shown)?.sizeBytes != nil })
            await harness.close()
        }

        // B-SRCH-148 B-SEL-094 B-NAV-211: Reveal in Folder on a result in the folder on screen ends search mode and
        // selects it in the folder.
        // B-NAV-075
        @Test func revealInTheFolderOnScreenPutsTheResultsAway() async throws {
            let (harness, tab, engine, timers) = try await open()
            engine.finds = { _ in (["note.txt", "Alpha/Inner"], false, false) }
            try search("no", in: tab, timers)
            #expect(tab.searchRootPath != nil)
            let note = harness.folder.path + "/note.txt"
            tab.revealSearchResult(note)
            #expect(await waitUntil { tab.searchRootPath == nil && tab.content.selection.paths.count == 1 })
            #expect(tab.content.selection.paths.map(NodePath.basename) == ["note.txt"])
            #expect(tab.searchField?.stringValue == "")
            #expect(tab.content.entries.map(\.name).contains("Alpha"))
            await harness.close()
        }

        // B-SEL-094: the menu's Reveal in Folder goes to the folder of the lead result.
        // B-NAV-075 T-f5252775
        @Test func revealGoesToTheLeadResult() async throws {
            let (harness, tab, engine, timers) = try await open()
            engine.finds = { _ in (["Alpha/Inner", "Beta/Inner"], false, false) }
            try search("in", in: tab, timers)
            let alpha = harness.folder.path + "/Alpha/Inner"
            let beta = harness.folder.path + "/Beta/Inner"
            tab.content.applySelection(ContentSelection(paths: [alpha, beta], anchorPath: alpha, leadPath: beta))
            tab.perform(.revealInFolder)
            #expect(await waitUntil { tab.folder.path.hasSuffix("/Beta") && tab.content.selection.paths.count == 1 })
            #expect(tab.content.selection.paths.first?.hasSuffix("/Beta/Inner") == true)
            await harness.close()
        }

        // B-SRCH-111: the path bar shows the one selected result, or else where the search runs from.
        // B-INFO-104 B-VIEW-103 T-78d2429c
        @Test func thePathBarShowsTheSelectedResultOrTheSearchRoot() async throws {
            let (harness, tab, engine, timers) = try await open()
            engine.finds = { _ in (["note.txt", "Alpha/Inner"], false, false) }
            let bar = tab.content.contentShell.pathBarRow
            try search("no", in: tab, timers)
            #expect(bar.path == harness.folder.path)
            let home = try #require(tab.search.header.scopes.first { $0.title == "Home" })
            home.onPress()
            let homePath = FileManager.default.homeDirectoryForCurrentUser.path
            #expect(bar.path == homePath)
            let result = try #require(tab.content.entryPaths.first)
            tab.content.applySelection(.single(result))
            #expect(bar.path == result)
            tab.content.applySelection(.of(tab.content.entryPaths))
            #expect(bar.path == homePath)
            tab.search.session.hideResults()
            #expect(bar.path == harness.folder.path)
            await harness.close()
        }

        // App.tsx:2438: the bar's segment of the selected result opens it as a double-click would, a file or an app
        // alike, and leaves the results showing; any other segment goes to its folder.
        // B-NAV-076 B-VIEW-103
        @Test func theSelectedResultsSegmentOpensIt() async throws {
            let (harness, tab, engine, timers) = try await open()
            try FileManager.default.createDirectory(
                at: harness.folder.url.appendingPathComponent("Tool.app"), withIntermediateDirectories: true)
            var opened: [String] = []
            tab.openFile = { opened.append($0.lastPathComponent) }
            engine.finds = { _ in (["note.txt", "Tool.app"], false, false) }
            let bar = tab.content.contentShell.pathBarRow
            try search("no", in: tab, timers)
            #expect(await waitUntil { tab.content.entryPaths.count == 2 })
            let root = tab.searchRootPath
            for result in tab.content.entryPaths {
                tab.content.applySelection(.single(result))
                #expect(bar.path == result)
                opened = []
                bar.onNavigate(result)
                #expect(opened == [NodePath.basename(result)])
                #expect(tab.searchRootPath == root)
            }
            let inner = harness.folder.url.appendingPathComponent("Alpha").path
            bar.onNavigate(inner)
            #expect(await waitUntil { tab.searchRootPath == nil && samePath(tab.folder.path, inner) })
            await harness.close()
        }

        // B-SRCH-091: a Settings edit of one search default changes that option only; the others chosen in the
        // options menu stay.
        // B-DLG-186 T-8923e42b
        @Test func aSettingsEditChangesOnlyThatOption() async throws {
            let (harness, tab, _, _) = try await open()
            let session = tab.search.session
            session.setPatternMode(.regex)
            #expect(tab.preferences.searchPatternMode == .text)
            harness.channel.update(["searchRecursive": .bool(false)], from: nil)
            #expect(!session.recursive)
            #expect(session.patternMode == .regex)
            await harness.close()
        }

        // B-SRCH-011 B-SRCH-015: Return in an empty field gives the keyboard to the list.
        // B-SRCH-057
        @Test func returnInAnEmptyFieldGivesTheKeyboardToTheList() async throws {
            let (harness, tab, _, _) = try await open()
            tab.searchField?.stringValue = "  "
            try command(#selector(NSResponder.insertNewline(_:)), in: tab)
            #expect(tab.searchRootPath == nil)
            #expect(tab.window?.firstResponder === tab.content.focusView)
            await harness.close()
        }

        // B-SRCH-081 F-807: the options button takes the keyboard before the field; Return or Space on it opens the
        // menu with its first item marked, while a press leaves the keyboard in the field.
        // B-SRCH-082
        @Test func theOptionsButtonOpensTheMenuFromTheKeyboard() async throws {
            let (harness, tab, _, _) = try await open()
            let window = try #require(tab.window)
            let field = try #require(tab.searchField)
            try command(#selector(NSResponder.insertBacktab(_:)), in: tab)
            #expect(window.firstResponder === field.optionsButton)
            field.optionsButton.keyDown(with: try #require(key(36, "\r", in: window)))
            #expect(AppMenuPresenter.shared.menu?.markedIndex == 1)
            AppMenuPresenter.shared.close()
            #expect(field.optionsButton.takeKeyboard())
            field.optionsButton.keyDown(with: try #require(key(49, " ", in: window)))
            #expect(AppMenuPresenter.shared.menu?.markedIndex == 1)
            AppMenuPresenter.shared.close()
            // Tab goes on to the field.
            #expect(field.optionsButton.takeKeyboard())
            field.optionsButton.keyDown(with: try #require(key(48, "\t", in: window)))
            #expect(field.isActive)
            // A press: nothing marked, the keyboard in the field.
            let press = try #require(
                NSEvent.mouseEvent(
                    with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            field.optionsButton.mouseDown(with: press)
            #expect(AppMenuPresenter.shared.menu?.markedIndex == nil)
            #expect(field.isActive)
            await harness.close()
        }
    }

    /// Duplicate in search results needs the app's file operations.
    @MainActor
    @Suite(.windowlessAlone) struct SearchResultWriteTests {
        // F-682 B-SEL-095: Duplicate on a result puts the copy next to it, not in the folder on screen.
        // T-dc31b764 T-f90496ca
        @Test func duplicateOfAResultGoesNextToIt() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let operations = AppWriteOperations(
                userData: harness.folder.url, directoryService: harness.services.directoryService,
                windows: harness.windows, trash: .standIn, log: { _ in })
            operations.dialogs.show = { _, _, _ in }
            operations.dialogs.confirm = { _, _ in false }
            let engine = FakeSearchEngine()
            let timers = ManualTimers()
            tab.search.session.engine = engine
            tab.search.session.timers = timers
            try "x".write(to: harness.folder.appending("Alpha/notes.md"), atomically: true, encoding: .utf8)
            engine.finds = { _ in (["Alpha/notes.md"], false, false) }
            let field = try #require(tab.searchField)
            field.stringValue = "notes"
            tab.search.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
            timers.advance(0.4)
            let result = harness.folder.path + "/Alpha/notes.md"
            tab.content.applySelection(.single(result))
            tab.content.focusList()
            tab.perform(.duplicateSelection)
            let alpha = harness.folder.path + "/Alpha"
            #expect(
                await waitUntil {
                    ((try? FileManager.default.contentsOfDirectory(atPath: alpha)) ?? []).count == 3
                })
            let made = try FileManager.default.contentsOfDirectory(atPath: alpha)
            #expect(made.contains { $0.hasPrefix("notes") && $0 != "notes.md" })
            #expect(!FileManager.default.fileExists(atPath: harness.folder.path + "/notes copy.md"))
            withExtendedLifetime(operations) {}
            await harness.close()
        }
    }
}
