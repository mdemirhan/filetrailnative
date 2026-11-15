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
            #expect(tab.explorerToolbar.viewSwitch?.selected == .previews)
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
