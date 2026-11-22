// Checks that a viewer gives way only when a command sends its pane to another folder, and that it keeps to its file
// where the file is moved or renamed, and says so when the file goes
import AppKit
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    @MainActor
    @Suite struct ViewerPlaceTests {
        private func real(_ harness: ExplorerHarness, _ name: String = "") -> String {
            let path = name.isEmpty ? harness.folder.path : harness.folder.path + "/" + name
            guard let resolved = realpath(path, nil) else { return path }
            defer { free(resolved) }
            return String(cString: resolved)
        }

        /// A tab on the harness's folder with two text files beside its folders, and a folder "Work" with one, read.
        private func tabWithFiles(_ harness: ExplorerHarness) async throws -> MainWindowController {
            try "let a = 1\n".write(to: harness.folder.appending("a.swift"), atomically: true, encoding: .utf8)
            try "{\"b\": 2}\n".write(to: harness.folder.appending("b.json"), atomically: true, encoding: .utf8)
            try FileManager.default.createDirectory(
                at: harness.folder.appending("Work"), withIntermediateDirectories: true)
            try "work\n".write(to: harness.folder.appending("Work/w.txt"), atomically: true, encoding: .utf8)
            let tab = try await harness.open()
            tab.perform(.refreshOrApplySearchSort)
            #expect(await waitUntil { tab.activePane.content.listedEntry(at: real(harness, "b.json")) != nil })
            return tab
        }

        private func settled(_ pane: BrowserPane) async {
            var read = false
            pane.whenNavigationSettles { read = true }
            #expect(await waitUntil { read })
        }

        /// `pane` reads its folder again for a change on disk, as its folder's watch would have it do: the windowless
        /// harness watches no folder, and its listings are kept a moment unless a change says otherwise.
        private func readAgain(_ pane: BrowserPane, in tab: MainWindowController) {
            tab.services.directoryService.cache.clear()
            pane.reload()
        }

        private func shown(_ viewer: TextViewerController?) -> String {
            viewer?.path.map(NodePath.basename) ?? "no viewer"
        }

        // The list under a viewer beside the other pane follows its folder to a new name, then to the folder above it
        // once it is gone: the pane reads where it is, nothing sent it anywhere, and the viewer stays.
        @Test func aHiddenListFollowingItsFolderKeepsTheViewer() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let tab = try await tabWithFiles(harness)
            tab.openFileInOtherPane(real(harness, "Work/w.txt"))
            let pane = try #require(tab.otherPane)
            let viewer = try #require(pane.viewer)
            await settled(pane)
            #expect(pane.folderPath == real(harness, "Work"))
            tab.panes[0].content.select(paths: [real(harness, "a.swift")])
            #expect(await waitUntil { viewer.path == real(harness, "a.swift") }, "shows \(shown(viewer))")

            let renamed = harness.folder.appending("Work 2").path
            try FileManager.default.moveItem(atPath: harness.folder.appending("Work").path, toPath: renamed)
            pane.followOnScreen([PathMove(from: real(harness, "Work"), to: real(harness, "Work 2"))])
            #expect(await waitUntil { pane.folderPath == real(harness, "Work 2") && !pane.isNavigating })
            #expect(pane.viewer === viewer, "the viewer stays as its list follows its folder")

            try FileManager.default.removeItem(atPath: renamed)
            readAgain(pane, in: tab)
            #expect(
                await waitUntil { pane.folderPath == real(harness) && !pane.isNavigating },
                "in \(pane.folderPath), navigating \(pane.isNavigating)")
            #expect(pane.viewer === viewer, "the viewer stays as its list goes to the folder above one that went")
            #expect(viewer.path == real(harness, "a.swift"))
        }

        // Open in Other Pane on a file by a path through a link: the pane is known by its folder's real path once it
        // arrives, and the viewer it was sent there for stays.
        @Test func openInOtherPaneThroughALinkKeepsTheViewer() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let tab = try await tabWithFiles(harness)
            try FileManager.default.createSymbolicLink(
                atPath: harness.folder.appending("Link").path, withDestinationPath: real(harness, "Work"))
            tab.openFileInOtherPane(real(harness) + "/Link/w.txt")
            let pane = try #require(tab.otherPane)
            await settled(pane)
            #expect(pane.folderPath == real(harness, "Work"))
            #expect(pane.viewer != nil, "the viewer stays once its pane arrived by the folder's real path")
        }

        // A following viewer's pane closed with Two Panes, its folder deleted, then opened again: it opens the folder
        // above, on its own, and the viewer it comes back with stays.
        @Test func aPaneOpenedAgainWhereItsFolderWentKeepsTheViewer() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let tab = try await tabWithFiles(harness)
            tab.openFileInOtherPane(real(harness, "Work/w.txt"))
            await settled(try #require(tab.otherPane))
            tab.panes[0].content.select(paths: [real(harness, "a.swift")])
            tab.perform(.toggleTwoPanes)
            #expect(!tab.showsTwoPanes)
            try FileManager.default.removeItem(atPath: real(harness, "Work"))
            tab.services.directoryService.cache.clear()

            tab.perform(.toggleTwoPanes)
            let pane = try #require(tab.otherPane)
            #expect(pane.viewer != nil)
            await settled(pane)
            #expect(pane.folderPath == real(harness), "in \(pane.folderPath)")
            #expect(pane.viewer != nil, "the viewer stays as its pane opens the folder above")
            #expect(await waitUntil { pane.viewer?.path == real(harness, "a.swift") }, "shows \(shown(pane.viewer))")
        }

        // A command sending the pane elsewhere still closes its viewer, as before.
        @Test func aCommandSendingTheViewersPaneElsewhereClosesIt() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let tab = try await tabWithFiles(harness)
            tab.openFileInOtherPane(real(harness, "a.swift"))
            let pane = try #require(tab.otherPane)
            await settled(pane)
            #expect(pane.viewer != nil)
            tab.focusPane(pane)
            tab.go(to: real(harness, "Alpha"))
            #expect(await waitUntil { pane.folderPath == real(harness, "Alpha") && pane.viewer == nil })
        }

        // A file in place renamed by another app, then moved to a folder of its own: the viewer shows it where it
        // is, its step of the history goes with it, and it has no place among the folder's files once it left.
        @Test func aFileInPlaceFollowsItsRenameAndMove() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let tab = try await tabWithFiles(harness)
            let pane = tab.activePane
            pane.content.select(paths: [real(harness, "a.swift")])
            tab.perform(.viewFile)
            let viewer = try #require(pane.viewer)
            #expect(await waitUntil { viewer.isText && viewer.position != nil })

            try FileManager.default.moveItem(atPath: real(harness, "a.swift"), toPath: real(harness) + "/c.swift")
            #expect(await waitUntil { viewer.path == real(harness, "c.swift") }, "shows \(shown(viewer))")
            #expect(viewer.isText && viewer.textView.string == "let a = 1\n")
            #expect(viewer.gone == nil)
            #expect(pane.navigationHistory.current == real(harness, "c.swift"))
            // The list under it reads its folder again (the windowless harness watches no folder).
            readAgain(pane, in: tab)
            #expect(await waitUntil { viewer.position != nil }, "still one of its folder's files")

            try FileManager.default.moveItem(
                atPath: real(harness, "c.swift"), toPath: real(harness, "Alpha") + "/c.swift")
            #expect(await waitUntil { viewer.path == real(harness, "Alpha/c.swift") }, "shows \(shown(viewer))")
            #expect(pane.navigationHistory.current == real(harness, "Alpha/c.swift"))
            readAgain(pane, in: tab)
            #expect(await waitUntil { viewer.position == nil }, "no longer one of its folder's files")
            #expect(viewer.isText)

            // Back returns to the folder it was opened in, with nothing selected: the file is no longer there.
            #expect(await tab.closeViewer(in: pane))
            #expect(pane.folderPath == real(harness))
            #expect(pane.content.selection.paths.isEmpty)
        }

        // A following viewer with edits keeps its file where it was moved, and saves it there; one that doesn't
        // follow stays on its file wherever it goes.
        @Test func aViewerKeepsItsFileWhereItWasMoved() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let tab = try await tabWithFiles(harness)
            tab.panes[0].content.select(paths: [real(harness, "a.swift")])
            tab.perform(.openSelectionInOtherPane)
            let viewer = try #require(tab.otherPane?.viewer)
            #expect(await waitUntil { viewer.isText })
            viewer.setEditing(true)
            viewer.textView.insertText("// top\n", replacementRange: NSRange(location: 0, length: 0))
            #expect(viewer.isDirty)

            let moved = real(harness, "Alpha") + "/a.swift"
            try FileManager.default.moveItem(atPath: real(harness, "a.swift"), toPath: moved)
            #expect(await waitUntil { viewer.path == moved }, "shows \(shown(viewer))")
            // The list reads its folder again, which no longer has it (the windowless harness watches no folder): the
            // edited file stays on screen.
            readAgain(tab.panes[0], in: tab)
            #expect(await waitUntil { tab.panes[0].content.listedEntry(at: real(harness) + "/a.swift") == nil })
            try await Task.sleep(for: .seconds(InfoMetrics.fetchDelay + 0.3))
            #expect(viewer.path == moved && viewer.isDirty)
            #expect(viewer.save())
            #expect(try String(contentsOfFile: moved, encoding: .utf8) == "// top\nlet a = 1\n")
            #expect(!FileManager.default.fileExists(atPath: real(harness) + "/a.swift"))

            tab.panes[0].content.select(paths: [real(harness, "b.json")])
            #expect(await waitUntil { viewer.path == real(harness, "b.json") && viewer.isText })
            viewer.mode = .pinned
            let pinned = real(harness, "Work") + "/b.json"
            try FileManager.default.moveItem(atPath: real(harness, "b.json"), toPath: pinned)
            #expect(await waitUntil { viewer.path == pinned }, "shows \(shown(viewer))")
            #expect(viewer.isText && viewer.textView.string == "{\"b\": 2}\n")
        }

        // A file deleted while shown: without edits the viewer says so, and shows it again once a file is back in
        // its place; with edits they stay, and Save asks first, then puts it back where it was.
        @Test func aFileDeletedWhileShownIsSaidSoAndSavedBackOnlyWhenAsked() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let tab = try await tabWithFiles(harness)
            let pane = tab.activePane
            let b = real(harness, "b.json")
            pane.content.select(paths: [b])
            tab.perform(.viewFile)
            let viewer = try #require(pane.viewer)
            #expect(await waitUntil { viewer.isText })
            try FileManager.default.removeItem(atPath: b)
            #expect(await waitUntil { viewer.gone == .deleted })
            #expect(pane.viewer === viewer)
            try "{\"b\": 3}\n".write(toFile: b, atomically: true, encoding: .utf8)
            #expect(await waitUntil { viewer.gone == nil && viewer.textView.string == "{\"b\": 3}\n" })
            #expect(await tab.closeViewer(in: pane))

            let a = real(harness, "a.swift")
            pane.content.select(paths: [a])
            tab.perform(.viewFile)
            let edited = try #require(pane.viewer)
            #expect(await waitUntil { edited.isText })
            edited.setEditing(true)
            edited.textView.insertText("// kept\n", replacementRange: NSRange(location: 0, length: 0))
            try FileManager.default.removeItem(atPath: a)
            #expect(await waitUntil { edited.gone == .deleted })
            #expect(edited.isDirty && edited.textView.string == "// kept\nlet a = 1\n")

            #expect(!edited.save())
            #expect(
                await waitUntil { tab.frontAlert?.titleLabel.stringValue == "\u{201C}a.swift\u{201D} was deleted." })
            #expect(!FileManager.default.fileExists(atPath: a), "nothing is written before the answer")
            let alert = try #require(tab.frontAlert)
            let save = try #require(alert.buttons.first { $0.title == "Save" })
            save.performClick(nil)
            #expect(await waitUntil { !edited.isDirty && edited.gone == nil })
            #expect(try String(contentsOfFile: a, encoding: .utf8) == "// kept\nlet a = 1\n")
        }

        // A pane closed with Two Panes takes nothing a following viewer waits for, and what waits is cleared once
        // the list it was meant for has read its folder, whether that has the file or not.
        @Test func aViewersPendingSelectionGoesOnlyToItsList() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let tab = try await tabWithFiles(harness)
            tab.openSecondPane()
            let closed = try #require(tab.otherPane)
            await settled(closed)
            tab.perform(.toggleTwoPanes)
            #expect(!tab.showsTwoPanes)

            tab.viewerSelectsAfterRead = real(harness, "a.swift")
            tab.paneFinishedFirstRead(closed)
            #expect(tab.viewerSelectsAfterRead == real(harness, "a.swift"), "a closed pane takes nothing")
            #expect(tab.panes[0].content.selection.paths.isEmpty)

            tab.viewerSelectsAfterRead = real(harness, "gone.txt")
            tab.paneFinishedFirstRead(tab.panes[0])
            #expect(tab.viewerSelectsAfterRead == nil, "cleared once its list has read, though it isn't there")
        }
    }
}
