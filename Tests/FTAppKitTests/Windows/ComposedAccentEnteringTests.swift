// Paths that reach a window from outside a listing (typed, opened by another app, a disk's going), against a folder
// the disk keeps with a composed accent
import AppKit
import FTFileSystem
import FTFoundation
import FTOperations
import FTTestSupport
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    /// "café" with its "é" as one scalar on the disk, and the same folder named the other way, with the accent in
    /// two, where a path comes in from outside a listing: typed in Go To, Move To or Extract To, handed over by
    /// another app, or told of by the system. Each is to become the path as the disk spells it before anything is
    /// compared with it or written through it: every comparison here is byte for byte.
    @MainActor
    @Suite(.restoresWindowSeams) struct ComposedAccentEnteringTests: SidebarTesting {
        private struct Made {
            let harness: ExplorerHarness
            /// The harness's folder by its real path.
            let parent: String
            /// "café" in it, as the disk spells it.
            let folder: String
            /// The same folder with the accent decomposed.
            let decomposed: String
        }

        /// A harness with "café" in its folder, holding `files`.
        private func harness(files: [String] = ["one.txt", "two.txt"]) throws -> Made {
            let harness = try ExplorerHarness.windowless()
            let parent = listed(harness, "")
            // mkdir(2) keeps the name as given; Foundation would decompose it.
            let folder = parent + "/caf\u{E9}"
            #expect(mkdir(folder, 0o755) == 0)
            for name in files { touch(folder + "/" + name) }
            let store = harness.store
            MainWindowController.visitStore = { store }
            return Made(harness: harness, parent: parent, folder: folder, decomposed: parent + "/cafe\u{301}")
        }

        private func touch(_ path: String) {
            let file = Darwin.open(path, O_CREAT | O_WRONLY, 0o644)
            #expect(file >= 0)
            close(file)
        }

        private func bytes(_ paths: [String]) -> [NameKeys.Exact] { paths.map(NameKeys.Exact.init) }

        /// The pane shows `path`, spelled so, and nothing is on its way.
        private func shows(_ pane: BrowserPane, _ path: String) -> Bool {
            samePath(pane.shownFolderPath, path) && !pane.isNavigating
        }

        private func names(_ pane: BrowserPane) -> [String] { pane.content.listed.map(\.name) }

        /// A zip in `folder` holding one file, "inside.txt".
        private func zip(named name: String, in folder: String) throws -> String {
            let source = try TemporaryDirectory(prefix: "filetrail-zips")
            defer { source.remove() }
            let file = source.path + "/inside.txt"
            try Data("inside".utf8).write(to: URL(fileURLWithPath: file))
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            process.arguments = ["-q", "-j", folder + "/" + name, file]
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
            return folder + "/" + name
        }

        /// `text` typed into the box up over `tab`, and Return.
        private func submit(_ text: String, in tab: MainWindowController) throws {
            let box = try #require(tab.goToBox)
            tab.window?.contentView?.layoutSubtreeIfNeeded()
            DialogKeys.type(text, into: box)
            DialogKeys.press(KeyCode.returnKey, "\r", in: tab.window)
        }

        // Go To with the folder typed by its other spelling, with a slash at its end, through "..", and through a
        // link: each lands on the folder as the disk spells it, one step further in the history, its row selected in
        // the tree, and the visits Go To ranks by are kept under the one spelling.
        @Test func goToTypedInAnotherSpellingLandsOnTheFolderAsTheDiskSpellsIt() async throws {
            let made = try harness()
            let link = made.parent + "/link"
            #expect(symlink(made.folder, link) == 0)
            let tab = try await made.harness.open()
            tab.updatePreferences { $0.favorites = [] }
            await rooted(tab, made.harness)
            let controller = sidebar(tab)
            func row(_ path: String) -> SidebarRowState? {
                cells(controller).compactMap(\.state).first {
                    $0.item.kind == .filesystem && samePath($0.item.path ?? "", path)
                }
            }
            let typed = [
                made.decomposed, made.decomposed + "/", made.parent + "/Alpha/../cafe\u{301}", link,
            ]
            for (index, text) in typed.enumerated() {
                tab.perform(.openLocationSheet)
                try submit(text, in: tab)

                #expect(await waitUntil { tab.goToBox == nil && shows(tab.activePane, made.folder) }, "\(index)")
                #expect(bytes(tab.historyPaths) == bytes([made.parent, made.folder]), "\(index)")
                #expect(tab.historyIndex == 1, "\(index)")
                #expect(await waitUntil { row(made.folder).map { $0.selection != .none } == true }, "\(index)")
                // Back where it started, for the next.
                tab.goBack(nil)
                #expect(await waitUntil { shows(tab.activePane, made.parent) }, "\(index)")
            }
            // One folder to Go To, by the disk's spelling, with a visit for each time it was gone to.
            let visited = made.harness.store.folders().filter { $0.path == made.folder }
            #expect(bytes(visited.map(\.path)) == bytes([made.folder]))
            #expect(visited.first?.visits.count == typed.count)
            await made.harness.close()
        }

        // Move To with the folder in the other pane typed by its other spelling: the item goes into the folder as the
        // disk spells it, is selected in the pane on it, and the folder is remembered as a destination by that
        // spelling.
        @Test func moveToTypedInTheOtherSpellingMovesIntoTheFolderAsTheDiskSpellsIt() async throws {
            let made = try harness()
            let window = try await WritingWindow.open(made.parent, in: made.harness)
            let tab = window.tab
            let group = try #require(tab.group)
            let left = tab.activePane
            let right = tab.openSecondPane(at: made.folder)
            #expect(await waitUntil { right.loaded && right.hasShownFolder && shows(right, made.folder) })
            #expect(tab.activePane === left)

            window.select(["note.txt"])
            tab.perform(.moveSelection)
            try submit(made.decomposed, in: tab)

            let moved = made.folder + "/note.txt"
            #expect(await waitUntil { names(right).contains("note.txt") && !tab.isWriteLocked })
            #expect(await waitUntil { tab.goToBox == nil })
            #expect(await waitUntil { bytes(right.content.selection.paths) == bytes([moved]) })
            // The write was sent there by the disk's spelling: Undo's record has it.
            let steps = window.operations.undoHistory.top(.undo)?.units.flatMap(\.steps) ?? []
            var recorded: [String] = []
            for case .moved(let step) in steps { recorded.append(step.to) }
            #expect(bytes(recorded) == bytes([moved]))
            #expect(bytes(made.harness.store.destinations().map(\.path)) == bytes([made.folder]))
            #expect(group.tabs.count == 1)
            #expect(window.recorder.shown.isEmpty)
            await window.close()
        }

        // Extract To with the folder on screen typed by its other spelling: what comes out is selected where it is, no
        // tab or window opens on the same folder, and the folder is remembered by the disk's spelling.
        @Test func extractToTheFolderOnScreenTypedInTheOtherSpellingSelectsWhatCameOut() async throws {
            let made = try harness(files: [])
            let archive = try zip(named: "papers.zip", in: made.folder)
            let window = try await WritingWindow.open(made.folder, in: made.harness)
            let tab = window.tab
            let group = try #require(tab.group)
            tab.updatePreferences { $0.diskImageOpensIn = .tab }

            tab.content.select(paths: [archive])
            tab.content.focusList()
            tab.perform(.extractSelectionTo)
            try submit(made.decomposed, in: tab)

            #expect(await waitUntil { names(tab.activePane).contains("inside.txt") && !tab.isWriteLocked })
            #expect(await waitUntil { tab.goToBox == nil })
            #expect(await waitUntil { bytes(tab.content.selection.paths) == bytes([made.folder + "/inside.txt"]) })
            // Nothing opens later either.
            try? await Task.sleep(for: .milliseconds(300))
            #expect(group.tabs.count == 1)
            #expect(made.harness.windows.count == 1)
            #expect(bytes(made.harness.store.destinations().map(\.path)) == bytes([made.folder]))
            #expect(window.recorder.shown.isEmpty)
            await window.close()
        }

        // An item another app opens, or File Trail is launched to open, comes as a URL the system made: it is
        // selected in its folder by the path its row has.
        @Test func anItemOpenedFromAnotherAppIsSelectedByTheDisksSpelling() async throws {
            let made = try harness()
            let tab = try await made.harness.open()
            let group = try #require(tab.group)
            let item = made.folder + "/one.txt"
            // As the system hands it over: with the accent decomposed.
            let url = URL(fileURLWithPath: item)
            #expect(bytes([url.path]) == bytes([made.decomposed + "/one.txt"]))

            let web = try #require(URL(string: "https://example.com/one.txt"))
            let paths = AppDelegate.paths(ofOpened: [url, web])
            #expect(bytes(paths) == bytes([made.decomposed + "/one.txt"]))
            let request = try #require(paths.compactMap { AppDelegate.describeOpened($0) }.first)
            #expect(request.kind == .reveal)
            #expect(bytes([request.path]) == bytes([item]))
            #expect(made.harness.windows.openFromOtherApp(request))

            #expect(group.tabs.count == 2)
            let opened = try #require(group.selected)
            #expect(await waitUntil { shows(opened.activePane, made.folder) })
            #expect(await waitUntil { bytes(opened.content.selection.paths) == bytes([item]) })
            #expect(bytes(opened.historyPaths) == bytes([made.folder]))
            await made.harness.close()
        }

        // A disk mounted at a folder with a composed accent goes: the system's notice names the folder by a URL, which
        // spells the accent in two, and what was cut from the disk comes off the clipboard all the same, with the
        // notification that says so.
        @Test func aDiskThatGoesTakesItsCutItemsOffTheClipboard() async throws {
            let made = try harness()
            let tab = try await made.harness.open()
            let windows = made.harness.windows
            let disk = made.folder
            windows.volumeRoot = { path in
                samePath(path, disk) || path.hasPrefix(disk + "/") ? disk : ExplorerTabs.volumeRootPath(path)
            }
            let kept = made.parent + "/note.txt"
            let cut = ClipboardRules.set(.cut, [disk + "/one.txt", kept], capturedAt: "t")
            windows.clipboard.set(cut, from: nil)
            // As the system's notice has it (measured: the accent in two, whatever the mount table says).
            let url = URL(fileURLWithPath: disk, isDirectory: true)
            #expect(DiskPath(urlSpelling: url) == DiskPath(made.decomposed))

            windows.diskUnmounted(at: url)

            #expect(await waitUntil { bytes(windows.clipboard.contents.sourcePaths) == bytes([kept]) })
            #expect(windows.clipboard.contents.mode == .cut)
            let said = ClipboardTexts.cutItemsLeftMessage(from: cut, to: windows.clipboard.contents)
            #expect(said != nil)
            #expect(tab.notifications?.toasts.entries.map(\.title) == [said].compactMap { $0 })
            windows.clipboard.set(.empty, from: nil)
            await made.harness.close()
        }

        // Root Tree at Selection on the folder's row in the list: the tree's top is the folder as the disk spells it,
        // from the start.
        @Test func rootTreeAtSelectionRootsTheTreeAtTheDisksSpelling() async throws {
            let made = try harness()
            let tab = try await made.harness.open()
            await rooted(tab, made.harness)
            let model = sidebar(tab).model
            let row = try #require(tab.content.entries.first { samePath($0.path, made.folder) })
            var tops: [String] = []
            let changed = model.onChange
            model.onChange = {
                changed()
                if tops.last.map({ !samePath($0, model.rootPath) }) ?? true { tops.append(model.rootPath) }
            }

            tab.content.select(paths: [row.path])
            tab.content.focusList()
            tab.perform(.rootTreeAtSelection)

            #expect(await waitUntil { samePath(model.rootPath, made.folder) && shows(tab.activePane, made.folder) })
            #expect(await waitUntil { model.nodes[made.folder]?.loaded == true })
            // The tree never had another top on the way.
            #expect(bytes(tops.filter { !samePath($0, made.parent) }) == bytes([made.folder]))
            await made.harness.close()
        }

        // The folder on screen asked for by its other spelling is this folder, not another: a result of a search
        // revealed in it takes the folder's place in the history, as one revealed by the folder's own spelling does.
        @Test func theFolderOnScreenAskedForByItsOtherSpellingIsThisFolder() async throws {
            let made = try harness()
            let tab = try await made.harness.open(made.folder)
            #expect(bytes(tab.historyPaths) == bytes([made.folder]))

            tab.revealSearchResult(made.decomposed + "/two.txt")

            #expect(await waitUntil { bytes(tab.content.selection.paths) == bytes([made.folder + "/two.txt"]) })
            #expect(shows(tab.activePane, made.folder))
            #expect(bytes(tab.historyPaths) == bytes([made.folder]))

            // Asked for through a link, it is this folder too.
            let link = made.parent + "/link"
            #expect(symlink(made.folder, link) == 0)
            tab.content.select(paths: [])
            tab.revealSearchResult(link + "/one.txt")
            #expect(await waitUntil { bytes(tab.content.selection.paths) == bytes([made.folder + "/one.txt"]) })
            #expect(bytes(tab.historyPaths) == bytes([made.folder]))
            await made.harness.close()
        }
    }
}
