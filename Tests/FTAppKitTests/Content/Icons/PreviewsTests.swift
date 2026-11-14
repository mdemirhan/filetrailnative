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
        @Test func viewAsPreviewsShowsTheGridAtThePreviewSize() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, probe) = try await harness.openGrid(.viewAsPreviews, files: 12)
            let previews = try #require(probe.pane as? PreviewsViewController)
            #expect(tab.viewState.viewMode == .previews)
            #expect(tab.menuState.viewMode == .previews)
            #expect(previews.layout.iconSize == 240)
            #expect(previews.thumbnailPixelSize == 512)
            #expect(previews.thumbnailStore === PreviewThumbnails.store)
            #expect(probe.iconItems.count > 0)
            #expect(tab.explorerToolbar.viewSwitch?.selected == .previews)
            #expect(ApplicationMenu.sizeTitle(.increaseSize, viewMode: .previews) == "Make Previews Bigger")
            // The arrows step by the columns the pane holds, as in the Icons view.
            #expect(previews.itemsPerLine == previews.columns)
            #expect(previews.columns >= 1)
            await harness.close()
        }

        @Test func theSizeCommandsStepThePreviewsBy40AndSaveTheSize() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, probe) = try await harness.openGrid(.viewAsPreviews, files: 12)
            let previews = try #require(probe.pane as? PreviewsViewController)
            let bar = tab.content.contentShell.pathBarRow
            #expect(bar.showsSizeSlider && bar.sizeSlider.doubleValue == 240)
            #expect(tab.menuState.disabledCommands.filter { ViewSize.Change($0) != nil } == [.resetSize])
            let wide = previews.columns
            tab.perform(.increaseSize)
            probe.layout()
            #expect(previews.layout.iconSize == 280 && bar.sizeSlider.doubleValue == 280)
            #expect(tab.preferences.previewSizes == DensitySizes(standard: 280, finder: 240))
            // The icons keep their own size.
            #expect(tab.preferences.iconSizes == .iconDefaults)
            for _ in 0..<20 { tab.perform(.increaseSize) }
            probe.layout()
            #expect(tab.preferences.previewSizes.standard == 640)
            #expect(previews.columns <= wide)
            #expect(tab.menuState.disabledCommands.contains(.increaseSize))
            tab.perform(.resetSize)
            #expect(tab.preferences.previewSizes.standard == 240)
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
