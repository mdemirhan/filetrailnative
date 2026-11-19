// The Previews view: the Icons view's grid at the size of large previews, sized in steps of 40 points with the
// commands that size the icons, in each pane on its own
import AppKit
import FTFileSystem
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    @MainActor
    @Suite struct PreviewsTests {
        @Test func viewAsPreviewsFillsThePaneWithFourPreviews() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, probe) = try await harness.openGrid(.viewAsPreviews, files: 12)
            let previews = try #require(probe.pane as? PreviewsViewController)
            #expect(tab.viewState.viewMode == .previews)
            #expect(tab.menuState.viewMode == .previews)
            #expect(previews.count == 4)
            #expect(previews.columns == 2)
            #expect(previews.thumbnailStore === PreviewThumbnails.store)
            #expect(previews.picturesFillTheirPlace && previews.thumbnailPixelSize >= 256)
            #expect(probe.iconItems.count > 0)
            #expect(tab.explorerToolbar.button(.viewMenu)?.iconName == .previews)
            #expect(ApplicationMenu.sizeTitle(.increaseSize, viewMode: .previews) == "Make Previews Bigger")
            #expect(previews.itemsPerLine == 2)
            await harness.close()
        }

        @Test func theSizeCommandsGoFromNineToOnePreviewAndSaveIt() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, probe) = try await harness.openGrid(.viewAsPreviews, files: 12)
            let previews = try #require(probe.pane as? PreviewsViewController)
            let bar = tab.content.contentShell.pathBarRow
            #expect(bar.showsSizeSlider && bar.sizeSlider.doubleValue == 1 && bar.sizeSlider.numberOfTickMarks == 4)
            #expect(tab.menuState.disabledCommands.filter { ViewSize.Change($0) != nil } == [.resetSize])
            let four = previews.layout.iconSize
            tab.perform(.increaseSize)
            probe.layout()
            #expect(previews.count == 2 && previews.columns == 2)
            #expect(tab.preferences.previewCounts == DensitySizes(standard: 2, finder: 4))
            #expect(bar.sizeLabel.stringValue == "2 at a time")
            tab.perform(.increaseSize)
            probe.layout()
            #expect(previews.count == 1 && previews.columns == 1)
            #expect(previews.layout.iconSize > four)
            #expect(tab.menuState.disabledCommands.contains(.increaseSize))
            for _ in 0..<5 { tab.perform(.decreaseSize) }
            probe.layout()
            #expect(previews.count == 9 && previews.columns == 3)
            #expect(previews.layout.iconSize < four)
            // The icons keep their own size.
            #expect(tab.preferences.iconSizes == .iconDefaults)
            tab.perform(.resetSize)
            #expect(tab.preferences.previewCounts.standard == 4)
            // Back in the Icons view the size reads in points again.
            tab.perform(.viewAsIcons)
            #expect(bar.sizeLabel.stringValue == "64 pt" && bar.sizeSlider.numberOfTickMarks == 0)
            await harness.close()
        }

        // View ▸ Show Previews: from another view the pane goes to Previews at the count chosen, with the selected
        // file in view, alone at 1; in Previews only the count changes. The count is saved and checked in the menu,
        // and shows over the status text as after Make Bigger, as wide as it reads.
        @Test func showPreviewsGoesToPreviewsAtItsCountWithTheSelectedFileInView() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, _) = try await harness.openGrid(.viewAsList, files: 12)
            let chosen = tab.content.entries[7]
            tab.content.select(paths: [chosen.path])
            tab.perform(.showPreviews1)
            let probe = GridProbe(tab: tab)
            #expect(await waitUntil { probe.pane is PreviewsViewController })
            harness.layout(tab)
            probe.layout()
            let previews = try #require(probe.pane as? PreviewsViewController)
            previews.settleDelay = 0.02
            try? await Task.sleep(for: .milliseconds(100))
            _ = await waitUntil { !previews.isSettling }
            #expect(tab.viewState.viewMode == .previews && previews.count == 1)
            #expect(tab.content.selection.paths == [chosen.path])
            #expect(previews.isWhollyInView(index: 7))
            #expect(tab.preferences.previewCounts.standard == 1)
            let bar = tab.content.contentShell.pathBarRow
            #expect(bar.sizeLabel.stringValue == "1 at a time" && !bar.sizeLabel.isHidden)
            #expect(bar.sizeSlider.doubleValue == 3)
            func checked() -> [String] {
                ApplicationMenu.itemStates(tab.menuState, window: .init(explorerFocused: true))
                    .filter { $0.id.hasPrefix("showPreviews") && $0.checked == true }.map(\.id)
            }
            #expect(checked() == ["showPreviews1"])
            tab.perform(.showPreviews9)
            probe.layout()
            #expect(probe.pane === previews && previews.count == 9 && previews.columns == 3)
            #expect(checked() == ["showPreviews9"])
            #expect(tab.preferences.previewCounts.standard == 9)
            bar.needsLayout = true
            bar.layoutSubtreeIfNeeded()
            #expect(bar.sizeLabel.stringValue == "9 at a time")
            #expect(bar.sizeLabel.frame.width >= bar.sizeLabel.attributedStringValue.size().width)
            // The item checked already changes nothing.
            tab.perform(.showPreviews9)
            #expect(tab.viewState.viewMode == .previews && probe.pane === previews && previews.count == 9)
            await harness.close()
        }

        // In Previews already, with the selected file scrolled out of sight: a count's command brings it on screen,
        // at that count, where the slider would keep the pane's place. With nothing selected the pane stays put.
        @Test func showPreviewsInPreviewsBringsTheSelectedFileOnScreen() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, _) = try await harness.openGrid(.viewAsPreviews, files: 40)
            let probe = GridProbe(tab: tab)
            harness.layout(tab)
            probe.layout()
            let previews = try #require(probe.pane as? PreviewsViewController)
            tab.perform(.showPreviews9)
            probe.layout()
            let chosen = tab.content.entries[2]
            tab.content.select(paths: [chosen.path])
            probe.layout()
            // Scrolled to the end, the selected file far above.
            previews.scrollClamped(to: NSPoint(x: 0, y: previews.collection.frame.height))
            probe.layout()
            #expect(!previews.isWhollyInView(index: 2))

            tab.perform(.showPreviews1)
            probe.layout()
            #expect(previews.count == 1)
            #expect(previews.isWhollyInView(index: 2))

            // Checked already, it still shows the selected file.
            previews.scrollClamped(to: NSPoint(x: 0, y: previews.collection.frame.height))
            probe.layout()
            #expect(!previews.isWhollyInView(index: 2))
            tab.perform(.showPreviews1)
            probe.layout()
            #expect(previews.isWhollyInView(index: 2))
            await harness.close()
        }

        // At 1 at a time a scroll goes from file to file, and the file it rests on is selected, as ↓ would select it;
        // a selection of several files is kept. With more than one on screen, scrolling leaves the selection alone.
        @Test func aScrollAtOneAtATimeSelectsTheFileItRestsOn() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, probe) = try await harness.openGrid(.viewAsPreviews, files: 12)
            let previews = try #require(probe.pane as? PreviewsViewController)
            previews.settleDelay = 0.02
            tab.perform(.showPreviews1)
            probe.layout()
            try? await Task.sleep(for: .milliseconds(50))
            let clip = previews.scroll.contentView
            let entries = tab.content.entries
            func scroll(by rows: Double) async {
                clip.scroll(to: NSPoint(x: 0, y: clip.bounds.origin.y + rows * previews.layout.rowHeight))
                previews.scroll.reflectScrolledClipView(clip)
                try? await Task.sleep(for: .milliseconds(60))
                _ = await waitUntil { !previews.isSettling }
            }
            func onRow(_ row: Double) -> Bool {
                abs(Double(clip.bounds.origin.y) - row * previews.layout.rowHeight) < 0.5
            }
            #expect(previews.count == 1)
            tab.content.select(paths: [entries[0].path])
            // A notch down: the next file, selected.
            await scroll(by: 0.1)
            #expect(onRow(1))
            #expect(tab.content.selection.paths == [entries[1].path])
            await scroll(by: 2)
            #expect(tab.content.selection.paths == [entries[3].path])
            await scroll(by: -0.1)
            #expect(tab.content.selection.paths == [entries[2].path])
            // Nothing selected: the file on screen is.
            tab.content.select(paths: [])
            await scroll(by: 0.1)
            #expect(tab.content.selection.paths == [entries[3].path])
            // Several selected, the last of them on screen: they stay.
            let several = [entries[1].path, entries[3].path]
            tab.content.select(paths: several)
            await scroll(by: 0.1)
            #expect(onRow(4))
            #expect(tab.content.selection.paths == several)

            // 4 at a time: the selection stays where it was.
            tab.perform(.showPreviews4)
            probe.layout()
            tab.content.select(paths: [entries[0].path])
            previews.scrollClamped(to: .zero)
            try? await Task.sleep(for: .milliseconds(60))
            _ = await waitUntil { !previews.isSettling }
            await scroll(by: 1.1)
            #expect(onRow(2))
            #expect(tab.content.selection.paths == [entries[0].path])
            await harness.close()
        }

        /// The file leaves the disk and the folder is read again. `byThisWindow`: as a write of this window ends, its
        /// selection letting go of the file before the read; otherwise as the read alone finds it gone.
        private func remove(
            _ path: String, from tab: MainWindowController, _ probe: GridProbe, byThisWindow: Bool
        ) async throws {
            try FileManager.default.removeItem(atPath: path)
            if byThisWindow {
                tab.content.keepOrderBeforeRemoval()
                tab.content.dropFromSelection([path])
            }
            tab.refresh()
            #expect(await waitUntil { !tab.content.entries.contains { $0.path == path } && !tab.isNavigating })
            probe.layout()
        }

        // At 1 at a time, the file that takes the place of the selected one when it is removed is selected: the next
        // one, or the one before when it was the last. Another file removed, or the file on screen removed with
        // nothing selected, leaves the selection as it was.
        @Test func atOneAtATimeTheFileInPlaceOfTheRemovedSelectedOneIsSelected() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, probe) = try await harness.openGrid(.viewAsPreviews, files: 6)
            let previews = try #require(probe.pane as? PreviewsViewController)
            tab.perform(.showPreviews1)
            probe.layout()
            let clip = previews.scroll.contentView
            let paths = tab.content.entries.map(\.path)
            func onRow(_ row: Double) -> Bool {
                abs(Double(clip.bounds.origin.y) - row * previews.layout.rowHeight) < 0.5
            }
            // Opening the folder selected nothing.
            #expect(tab.content.selection.isEmpty)

            tab.content.select(paths: [paths[1]])
            probe.layout()
            #expect(onRow(1))
            try await remove(paths[1], from: tab, probe, byThisWindow: true)
            #expect(tab.content.selection.paths == [paths[2]])
            #expect(onRow(1))

            // The last one: the one before it comes on screen, and is selected. Listed: 0, 2, 3, 4, 5.
            tab.content.select(paths: [paths[5]])
            probe.layout()
            #expect(onRow(4))
            try await remove(paths[5], from: tab, probe, byThisWindow: true)
            #expect(tab.content.selection.paths == [paths[4]])
            #expect(onRow(3))

            // Found gone by the read alone, as in a tab the write wasn't started from. Listed: 0, 2, 3, 4.
            try await remove(paths[4], from: tab, probe, byThisWindow: false)
            #expect(tab.content.selection.paths == [paths[3]])
            #expect(onRow(2))

            // Another file removed: the selected one stays selected. Listed: 0, 2, 3.
            try await remove(paths[0], from: tab, probe, byThisWindow: true)
            #expect(tab.content.selection.paths == [paths[3]])

            // Nothing selected, and the file on screen removed: nothing is selected. Listed: 2, 3.
            tab.content.selectionChanged(.empty)
            try await remove(paths[3], from: tab, probe, byThisWindow: true)
            #expect(tab.content.selection.isEmpty)
            #expect(tab.content.entries.map(\.path) == [paths[2]])
            await harness.close()
        }

        // With more than one on screen a removed selection leaves nothing selected, as in the Icons view.
        @Test func atFourAtATimeARemovedSelectionLeavesNothingSelected() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, probe) = try await harness.openGrid(.viewAsPreviews, files: 6)
            let previews = try #require(probe.pane as? PreviewsViewController)
            #expect(previews.count == 4)
            let paths = tab.content.entries.map(\.path)
            tab.content.select(paths: [paths[1]])
            probe.layout()
            try await remove(paths[1], from: tab, probe, byThisWindow: true)
            #expect(tab.content.selection.isEmpty)
            tab.content.select(paths: [paths[2]])
            try await remove(paths[2], from: tab, probe, byThisWindow: false)
            #expect(tab.content.selection.isEmpty)
            await harness.close()
        }

        // A place left empty at 4 at a time is no reason to select anything later, at 1 at a time, when some other
        // file goes.
        @Test func aPlaceLeftEmptyAtAnotherCountSelectsNothingWhenAnotherFileGoes() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, probe) = try await harness.openGrid(.viewAsPreviews, files: 6)
            let paths = tab.content.entries.map(\.path)
            tab.content.select(paths: [paths[0]])
            probe.layout()
            try await remove(paths[0], from: tab, probe, byThisWindow: true)
            #expect(tab.content.selection.isEmpty && tab.content.selection.gapIndex != nil)
            tab.perform(.showPreviews1)
            probe.layout()
            try await remove(paths[4], from: tab, probe, byThisWindow: false)
            #expect(tab.content.selection.isEmpty)
            await harness.close()
        }

        // Move to Trash at 1 at a time, twice: each acts on the file on screen.
        @Test func moveToTrashAtOneAtATimeGoesOnToTheFileThatComesOnScreen() async throws {
            PreparingSheet.isEnabled = false
            let harness = try ExplorerHarness.windowless()
            let writes = try harness.writeOperations()
            defer { withExtendedLifetime(writes) {} }
            let (tab, probe) = try await harness.openGrid(.viewAsPreviews, files: 4)
            tab.perform(.showPreviews1)
            probe.layout()
            let paths = tab.content.entries.map(\.path)
            tab.content.select(paths: [paths[0]])
            tab.content.focusList()
            for index in 0..<2 {
                #expect(tab.canPerform(.trashSelection))
                tab.perform(.trashSelection)
                #expect(
                    await waitUntil {
                        !FileManager.default.fileExists(atPath: paths[index]) && !tab.isWriteLocked
                            && tab.content.selection.paths == [paths[index + 1]]
                    }, "file \(index) trashed, the next one selected")
            }
            #expect(tab.content.entries.map(\.path) == [paths[2], paths[3]])
            await harness.close()
        }

        // At 1 at a time the selected file is the one on screen after the other ways a selection leaves the list too:
        // several selected files moved to the Trash at once; the selected file renamed in another app, which is on
        // screen under its new name where that sorts in its place, and gives its place to the next file where it
        // doesn't; and a selected folder that a filter comes to hide as it is unpinned.
        @Test func atOneAtATimeTheFileOnScreenIsSelectedHoweverTheSelectedOnesLeftTheList() async throws {
            PreparingSheet.isEnabled = false
            let harness = try ExplorerHarness.windowless()
            let writes = try harness.writeOperations()
            defer { withExtendedLifetime(writes) {} }
            let (tab, probe) = try await harness.openGrid(.viewAsPreviews, files: 6)
            let previews = try #require(probe.pane as? PreviewsViewController)
            tab.perform(.showPreviews1)
            probe.layout()
            let clip = previews.scroll.contentView
            let folder = try #require(tab.content.entries.first).url.deletingLastPathComponent().path
            /// The file the pane shows, by its name.
            func onScreen() -> String? {
                let row = Int((Double(clip.bounds.origin.y) / previews.layout.rowHeight).rounded())
                let entries = tab.content.entries
                return entries.indices.contains(row) ? entries[row].name : nil
            }
            /// The folder read again, as after a change another app made.
            func readAgain(until changed: @escaping () -> Bool) async {
                tab.refresh()
                #expect(await waitUntil { changed() && !tab.isNavigating })
                probe.layout()
            }
            func listed(_ name: String) -> Bool { tab.content.entries.contains { $0.name == name } }

            // Two of them, moved to the Trash together.
            let paths = tab.content.entries.map(\.path)
            tab.content.select(paths: [paths[1], paths[2]])
            tab.content.focusList()
            probe.layout()
            tab.perform(.trashSelection)
            #expect(await waitUntil { tab.content.entries.count == 4 && !tab.isWriteLocked })
            probe.layout()
            #expect(!listed("item-001.txt") && !listed("item-002.txt"))
            #expect(probe.selectedNames.count == 1 && probe.selectedNames.first == onScreen())

            // Renamed in another app, to a name that sorts where it was: the same file, still on screen.
            tab.content.select(paths: [folder + "/item-003.txt"])
            probe.layout()
            #expect(onScreen() == "item-003.txt")
            try FileManager.default.moveItem(atPath: folder + "/item-003.txt", toPath: folder + "/item-003b.txt")
            await readAgain { listed("item-003b.txt") && !listed("item-003.txt") }
            #expect(probe.selectedNames == ["item-003b.txt"] && onScreen() == "item-003b.txt")
            // To a name that sorts last: the file that took its place is the one shown, and selected.
            try FileManager.default.moveItem(atPath: folder + "/item-003b.txt", toPath: folder + "/zzz.txt")
            await readAgain { listed("zzz.txt") && !listed("item-003b.txt") }
            #expect(probe.selectedNames == ["item-004.txt"] && onScreen() == "item-004.txt")

            // A pinned filter leaves folders alone; unpinned, it hides the folder selected.
            try FileManager.default.createDirectory(atPath: folder + "/Sub", withIntermediateDirectories: false)
            await readAgain { listed("Sub") }
            for character in "item-0" { tab.content.applyFilterKey(.type(String(character))) }
            tab.content.pinFilter()
            tab.content.select(paths: [folder + "/Sub"])
            probe.layout()
            #expect(probe.selectedNames == ["Sub"] && onScreen() == "Sub")
            tab.content.unpinFilter()
            probe.layout()
            #expect(!listed("Sub"))
            #expect(probe.selectedNames.count == 1 && probe.selectedNames.first == onScreen())
            await harness.close()
        }

        // At 1 at a time a name being edited keeps its file selected while the pane scrolls away from it; once the
        // name is let go of, a scroll selects the file it rests on again.
        @Test func aScrollAtOneAtATimeKeepsTheFileBeingRenamedSelected() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, probe) = try await harness.openGrid(.viewAsPreviews, files: 6)
            let previews = try #require(probe.pane as? PreviewsViewController)
            previews.settleDelay = 0.02
            tab.perform(.showPreviews1)
            probe.layout()
            let clip = previews.scroll.contentView
            let paths = tab.content.entries.map(\.path)
            func scrollARow() async {
                clip.scroll(to: NSPoint(x: 0, y: clip.bounds.origin.y + previews.layout.rowHeight))
                previews.scroll.reflectScrolledClipView(clip)
                // The pane waits for the scroll to rest, and then says which file it rests on.
                #expect(previews.isSettling)
                #expect(await waitUntil { !previews.isSettling })
            }
            tab.content.select(paths: [paths[0]])
            probe.layout()
            #expect(tab.content.beginRename(path: paths[0]))
            #expect(tab.content.inlineRename?.path == paths[0])
            await scrollARow()
            #expect(abs(Double(clip.bounds.origin.y) - previews.layout.rowHeight) < 0.5)
            #expect(tab.content.inlineRename?.path == paths[0])
            #expect(tab.content.selection.paths == [paths[0]])

            tab.content.endRename()
            #expect(tab.content.inlineRename == nil)
            await scrollARow()
            #expect(tab.content.selection.paths == [paths[2]])
            await harness.close()
        }

        @Test func eachPaneShowsItsOwnView() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, _) = try await harness.openGrid(.viewAsPreviews, files: 6)
            let right = tab.openSecondPane()
            #expect(await waitUntil { right.loaded && right.hasShownFolder && !right.isNavigating })
            harness.layout(tab)
            #expect(tab.panes[0].content.pane is PreviewsViewController)
            #expect(right.viewMode == .previews)
            tab.focusPane(right)
            tab.perform(.viewAsDetails)
            #expect(right.content.pane is ListViewController)
            #expect(tab.panes[0].content.pane is PreviewsViewController)
            await harness.close()
        }
    }
}
