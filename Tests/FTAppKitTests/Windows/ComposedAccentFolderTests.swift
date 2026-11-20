// A folder on screen whose path the disk keeps with a composed accent, against the paths its rows and writes spell
import AppKit
import FTFileSystem
import FTFoundation
import FTOperations
import FTTestSupport
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    /// "café" with its "é" as one scalar, as git, unzip, Terminal and a name typed in the app store it. A `URL` gives
    /// the path back with the accent in two, and the pane is to know its folder as the listing spells it, which is how
    /// the rows' paths start and how a write names what it made: every comparison here is byte for byte.
    @MainActor
    @Suite struct ComposedAccentFolderTests: SidebarTesting {
        /// A harness with "café" in its folder, holding `files`; the folder by its real path, and "café" in it.
        private func harness(files: [String] = ["one.txt", "two.txt"]) throws -> (
            harness: ExplorerHarness, parent: String, folder: String
        ) {
            let harness = try ExplorerHarness.windowless()
            let parent = listed(harness, "")
            // mkdir(2) keeps the name as given; Foundation would decompose it.
            let folder = parent + "/caf\u{E9}"
            #expect(mkdir(folder, 0o755) == 0)
            for name in files { touch(folder + "/" + name) }
            return (harness, parent, folder)
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

        // The folder on screen is known as its listing spells it, so it is the folder its rows are in.
        @Test func theFolderOnScreenIsSpelledAsItsListingSpellsIt() async throws {
            let made = try harness()
            let tab = try await made.harness.open(made.folder)
            #expect(bytes([tab.shownFolderPath]) == bytes([made.folder]))
            #expect(bytes(tab.historyPaths) == bytes([made.folder]))
            #expect(bytes(tab.content.entries.map { NodePath.dirname($0.path) }) == bytes([made.folder, made.folder]))
            await made.harness.close()
        }

        // What an Extract made in the folder on screen is selected there: no tab opens on the same folder.
        @Test func anExtractInTheFolderOnScreenSelectsWhatCameOutAndOpensNoTab() async throws {
            let made = try harness(files: [])
            let archive = try zip(named: "papers.zip", in: made.folder)
            let window = try await WritingWindow.open(made.folder, in: made.harness)
            let tab = window.tab
            let group = try #require(tab.group)
            tab.updatePreferences { $0.diskImageOpensIn = .tab }

            _ = await tab.writeActions?.extract([archive])

            #expect(await waitUntil { names(tab.activePane).contains("inside.txt") && !tab.isWriteLocked })
            #expect(await waitUntil { bytes(tab.content.selection.paths) == bytes([made.folder + "/inside.txt"]) })
            // Nothing opens later either.
            try? await Task.sleep(for: .milliseconds(300))
            #expect(group.tabs.count == 1)
            #expect(made.harness.windows.count == 1)
            #expect(window.recorder.shown.isEmpty)
            await window.close()
        }

        // With both panes on the folder, a write started in one is read by the other at once, and what it made is
        // selected there too.
        @Test func theOtherPaneOnTheFolderReadsAWritesEndAndSelectsWhatArrived() async throws {
            let made = try harness()
            let window = try await WritingWindow.open(made.folder, in: made.harness)
            let tab = window.tab
            let left = tab.activePane
            let right = tab.openSecondPane()
            #expect(await waitUntil { right.loaded && right.hasShownFolder && shows(right, made.folder) })
            #expect(tab.activePane === left)

            _ = await tab.writeActions?.rename(made.folder + "/one.txt", to: "uno.txt")

            let renamed = made.folder + "/uno.txt"
            #expect(await waitUntil { names(left).contains("uno.txt") && names(right).contains("uno.txt") })
            #expect(await waitUntil { bytes(right.content.selection.paths) == bytes([renamed]) })
            #expect(await waitUntil { bytes(left.content.selection.paths) == bytes([renamed]) })
            #expect(window.recorder.shown.isEmpty)
            await window.close()
        }

        // The folder renamed by its row in the other pane, which shows the folder it is in: the pane on it follows it
        // to its new name, as a pane on a plainly named folder does.
        @Test func aPaneOnTheFolderFollowsItWhenItsRowIsRenamedInTheOtherPane() async throws {
            let made = try harness()
            let window = try await WritingWindow.open(made.parent, in: made.harness)
            let tab = window.tab
            let right = tab.openSecondPane(at: made.folder)
            #expect(await waitUntil { right.loaded && right.hasShownFolder && shows(right, made.folder) })
            let row = try #require(tab.content.entries.first { samePath($0.path, made.folder) })

            _ = await tab.writeActions?.rename(row.path, to: "bistro")

            #expect(await waitUntil { shows(right, made.parent + "/bistro") })
            #expect(names(right) == ["one.txt", "two.txt"])
            #expect(bytes(right.navigationHistory.paths) == bytes([made.parent + "/bistro"]))
            #expect(window.recorder.shown.isEmpty)
            await window.close()
        }

        // A tab on a folder inside it follows too when the folder above is renamed by the path its row has.
        @Test func aTabInsideTheFolderFollowsItWhenItIsRenamed() async throws {
            let made = try harness()
            #expect(mkdir(made.folder + "/sub", 0o755) == 0)
            touch(made.folder + "/sub/deep.txt")
            let window = try await WritingWindow.open(made.folder + "/sub", in: made.harness)
            let tab = window.tab
            #expect(bytes([tab.shownFolderPath]) == bytes([made.folder + "/sub"]))

            _ = await tab.writeActions?.rename(made.folder, to: "bistro")

            #expect(await waitUntil { shows(tab.activePane, made.parent + "/bistro/sub") })
            #expect(names(tab.activePane) == ["deep.txt"])
            #expect(window.recorder.shown.isEmpty)
            await window.close()
        }

        // The clipboard's Reveal of an item of the folder on screen selects it where it is: the folder isn't opened
        // again, which would add a step to the history and select nothing.
        @Test func revealingAClipboardItemOfTheFolderOnScreenSelectsItInPlace() async throws {
            let made = try harness()
            let window = try await WritingWindow.open(made.folder, in: made.harness)
            let tab = window.tab
            let item = made.folder + "/two.txt"
            tab.services.clipboard.set(ClipboardRules.set(.copy, [item], capturedAt: "t"), from: nil)

            tab.revealClipboardItem(item)

            #expect(bytes(tab.content.selection.paths) == bytes([item]))
            #expect(!tab.isNavigating)
            await settle()
            #expect(bytes(tab.historyPaths) == bytes([made.folder]))
            await window.close()
        }

        // The tree's row of the folder is the one selected, and with two panes it has the mark of the pane on it.
        @Test func theTreesRowOfTheFolderIsSelectedAndMarkedForItsPane() async throws {
            let made = try harness()
            let tab = try await made.harness.open()
            await rooted(tab, made.harness)
            let controller = sidebar(tab)
            func row(_ path: String) -> SidebarRowState? {
                cells(controller).compactMap(\.state).first {
                    $0.item.kind == .filesystem && samePath($0.item.path ?? "", path)
                }
            }

            tab.go(to: URL(fileURLWithPath: made.folder))
            #expect(await waitUntil { shows(tab.activePane, made.folder) })
            #expect(await waitUntil { row(made.folder).map { $0.selection != .none } == true })

            let alpha = made.parent + "/Alpha"
            let right = tab.openSecondPane(at: alpha)
            #expect(await waitUntil { right.loaded && right.hasShownFolder && shows(right, alpha) })
            made.harness.layout(tab)
            #expect(await waitUntil { row(made.folder)?.paneMark == SidebarPaneMark(left: true, right: false) })
            #expect(row(alpha)?.paneMark == SidebarPaneMark(left: false, right: true))
            await made.harness.close()
        }

        // New Folder makes its folder through the disk's spelling of the folder on screen, and Undo's record has it.
        @Test func newFolderIsMadeAndRecordedByTheDisksSpelling() async throws {
            let made = try harness()
            let window = try await WritingWindow.open(made.folder, in: made.harness)
            let tab = window.tab

            tab.perform(.newFolder)
            #expect(await waitUntil { tab.content.inlineRename != nil })

            let folder = made.folder + "/untitled folder"
            #expect(tab.content.inlineRename.map { bytes([$0.path]) } == bytes([folder]))
            let steps = window.operations.undoHistory.top(.undo)?.units.flatMap(\.steps) ?? []
            var recorded: [String] = []
            for case .created(let path, _, _) in steps { recorded.append(path) }
            #expect(bytes(recorded) == bytes([folder]))
            tab.content.renameCancelled()
            #expect(window.recorder.shown.isEmpty)
            await window.close()
        }

        // A tab kept from an earlier launch may have the folder with its accent decomposed, and Go To its visits: the
        // tab opens on the folder as its listing spells it, history and visits with it, and acts as any tab on it.
        @Test func aTabKeptWithTheAccentDecomposedOpensOnTheFolderAsItIsListed() async throws {
            let made = try harness()
            let decomposed = made.parent + "/cafe\u{301}"
            #expect(bytes([URL(fileURLWithPath: made.folder).path]) == bytes([decomposed]))
            let store = made.harness.store
            MainWindowController.visitStore = { store }
            defer { MainWindowController.visitStore = { (NSApp.delegate as? AppDelegate)?.store } }
            store.recordFolderVisit(decomposed, kind: .goTo)
            store.recordFolderVisit(made.parent, kind: .goTo)

            let window = try await WritingWindow.open(decomposed, in: made.harness)
            let tab = window.tab

            #expect(bytes([tab.shownFolderPath]) == bytes([made.folder]))
            #expect(bytes(tab.historyPaths) == bytes([made.folder]))
            // Go To lists the folder once, by the listing's spelling, with the visits it had.
            #expect(bytes(store.folders().map(\.path)) == bytes([made.parent, made.folder]))
            #expect(store.folders().last?.visits.count == 1)
            // And a write started on its rows ends in it.
            let item = made.folder + "/one.txt"
            tab.revealClipboardItem(item)
            #expect(bytes(tab.content.selection.paths) == bytes([item]))
            _ = await tab.writeActions?.rename(item, to: "uno.txt")
            #expect(await waitUntil { bytes(tab.content.selection.paths) == bytes([made.folder + "/uno.txt"]) })
            #expect(bytes(tab.historyPaths) == bytes([made.folder]))
            #expect(window.recorder.shown.isEmpty)
            await window.close()
        }
    }
}
