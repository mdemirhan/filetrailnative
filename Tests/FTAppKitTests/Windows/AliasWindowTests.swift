import AppKit
import FTFileSystem
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    /// Finder aliases and symbolic links in a tab: Make Alias, Show Original, and opening or reading one, which reaches
    /// its original while everything else acts on the alias itself.
    @MainActor
    @Suite struct AliasWindowTests {
        private func path(_ window: WritingWindow, _ name: String) -> String {
            window.folder.appendingPathComponent(name).path
        }

        private func write(_ window: WritingWindow, _ name: String, _ text: String = "text") throws {
            let url = window.folder.appendingPathComponent(name)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }

        /// The folder read again, and the row of `name` once it is listed.
        private func listed(_ window: WritingWindow, _ name: String) async -> DirectoryEntry? {
            window.tab.refresh()
            _ = await waitUntil { window.tab.content.listed.contains { $0.name == name } }
            return window.tab.content.listed.first { $0.name == name }
        }

        /// An alias of `original` named `name`, as Finder's Make Alias writes one, listed.
        private func alias(_ window: WritingWindow, of original: String, named name: String) async throws {
            try Links.writeAlias(of: path(window, original), at: path(window, name))
            #expect(await listed(window, name)?.kind.isAlias == true)
        }

        /// The alias Make Alias wrote is Finder's, beside its item and named as Finder names it, then numbered; it
        /// leads to the item; and one Undo moves what one Make Alias made to the Trash.
        @Test func makeAliasMakesFindersAliasBesideTheItemAndUndoTrashesIt() async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            try write(window, "a.txt")
            #expect(await listed(window, "a.txt") != nil)
            window.select(["a.txt"])
            #expect(tab.canPerform(.makeAlias))

            tab.perform(.makeAlias)
            #expect(await waitUntil { window.exists("a.txt alias") && !tab.isWriteLocked })
            let made = path(window, "a.txt alias")
            #expect(Links.isFinderAlias(made))
            #expect(Links.original(of: made) == path(window, "a.txt"))
            #expect(await listed(window, "a.txt alias")?.kind == .alias)
            // What it made is selected.
            #expect(await waitUntil { tab.content.selection.paths == [made] })

            window.select(["a.txt"])
            tab.perform(.makeAlias)
            #expect(await waitUntil { window.exists("a.txt alias 2") && !tab.isWriteLocked })
            #expect(window.operations.undoHistory.menu().undo == "Make Alias")

            tab.content.focusList()
            tab.perform(.undo)
            #expect(await waitUntil { !window.exists("a.txt alias 2") && !tab.isWriteLocked })
            #expect(window.exists("a.txt alias"))
            #expect(window.exists("a.txt"))
            #expect(window.recorder.shown.isEmpty)
            await window.close()
        }

        /// Make Alias waits for a selection. (Where it isn't offered, the Trash and results from several folders, is in
        /// the rules' tests and the availability golden.)
        @Test func makeAliasWaitsForASelection() async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            tab.content.select(paths: [])
            tab.content.focusList()
            #expect(!tab.canPerform(.makeAlias))
            await window.close()
        }

        /// The original is in the folder on screen: it is selected there, and nothing is added to Back.
        @Test func showOriginalSelectsTheOriginalInTheFolderOnScreen() async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            try write(window, "a.txt")
            try await alias(window, of: "a.txt", named: "a.txt alias")
            window.select(["a.txt alias"])
            #expect(tab.canPerform(.showOriginal))
            let steps = tab.activePane.navigationHistory.paths.count

            tab.perform(.showOriginal)
            #expect(await waitUntil { tab.content.selection.paths == [path(window, "a.txt")] })
            #expect(tab.activePane.navigationHistory.paths.count == steps)
            #expect(tab.focusedPane == .content)
            await window.close()
        }

        /// The original is elsewhere: its folder opens as a step of Back, with it selected. A symbolic link's is shown
        /// the same way.
        @Test func showOriginalOpensTheOriginalsFolderWithItSelected() async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            try write(window, "Inner Folder/b.txt")
            try await alias(window, of: "Inner Folder/b.txt", named: "b alias")
            window.select(["b alias"])

            tab.perform(.showOriginal)
            #expect(await waitUntil { tab.folderPath.hasSuffix("/Inner Folder") })
            #expect(await waitUntil { tab.content.selection.paths == [path(window, "Inner Folder/b.txt")] })
            #expect(tab.canGoBack)

            tab.perform(.goBack)
            #expect(await waitUntil { tab.folderPath == window.folder.path })
            try FileManager.default.createSymbolicLink(
                atPath: path(window, "b link"), withDestinationPath: "Inner Folder/b.txt")
            #expect(await listed(window, "b link")?.kind == .symlinkFile)
            window.select(["b link"])
            #expect(tab.canPerform(.showOriginal))
            tab.perform(.showOriginal)
            #expect(await waitUntil { tab.content.selection.paths == [path(window, "Inner Folder/b.txt")] })
            await window.close()
        }

        /// Show Original is for one link or alias: not a plain file, nor several.
        @Test func showOriginalIsForOneLinkOrAlias() async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            try write(window, "a.txt")
            try await alias(window, of: "a.txt", named: "a.txt alias")
            window.select(["a.txt"])
            #expect(!tab.canPerform(.showOriginal))
            window.select(["a.txt", "a.txt alias"])
            #expect(!tab.canPerform(.showOriginal))
            await window.close()
        }

        /// An alias of a folder opens the folder in the tab, as a symbolic link to one does, not in Finder.
        @Test func openingAnAliasOfAFolderOpensTheFolder() async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            try write(window, "Inner Folder/b.txt")
            try await alias(window, of: "Inner Folder", named: "Inner Folder alias")
            let entry = try #require(await listed(window, "Inner Folder alias"))

            tab.open([entry])
            #expect(await waitUntil { tab.folderPath == path(window, "Inner Folder") })
            await window.close()
        }

        /// An alias whose original was deleted says so when it is opened or its original asked for, and is left as it
        /// is.
        @Test func anAliasWhoseOriginalIsGoneSaysSo() async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            try write(window, "gone.txt")
            try await alias(window, of: "gone.txt", named: "gone alias")
            try FileManager.default.removeItem(atPath: path(window, "gone.txt"))
            window.select(["gone alias"])

            tab.perform(.showOriginal)
            #expect(await waitUntil { tab.frontAlert != nil })
            #expect(tab.frontAlert?.titleLabel.stringValue == "The Original Can\u{2019}t Be Found")
            #expect(window.exists("gone alias"))
            await window.close()
        }

        /// The viewer shows an alias's original under the alias's name, and what is saved goes into the original: the
        /// alias stays an alias.
        @Test func theViewerReadsAndSavesAnAliassOriginal() async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            try write(window, "a.txt", "first\n")
            try await alias(window, of: "a.txt", named: "a.txt alias")
            window.select(["a.txt alias"])
            // Open in Viewer is offered once the alias is known to lead to a file.
            #expect(await waitUntil { tab.canPerform(.viewFile) })

            tab.perform(.viewFile)
            let viewer = try #require(tab.activePane.viewer)
            #expect(await waitUntil { viewer.isText })
            #expect(viewer.textView.string == "first\n")
            #expect(viewer.fileName == "a.txt alias")

            viewer.textView.string = "second\n"
            #expect(viewer.save())
            #expect(try String(contentsOfFile: path(window, "a.txt"), encoding: .utf8) == "second\n")
            #expect(Links.isFinderAlias(path(window, "a.txt alias")))
            await window.close()
        }
    }
}
