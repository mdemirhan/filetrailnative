// Ports the grid cases of apps/desktop/src/renderer/components/ExplorerWorkspace.test.tsx, the window cases of
// hooks/useExplorerPaneLayout.test.tsx, useElementSize.test.tsx and styles.responsive.test.ts, on an explorer window
// that is never shown
import AppKit
import FTFileSystem
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    @MainActor
    @Suite struct WorkspaceTests {
        // T-880733c9 T-6d329198 F-698 F-699 F-700 F-701 F-702 B-INFO-190 B-VIEW-236
        // B-VIEW-105
        @Test func hidesTheFolderTreeGivingItsRoomToTheListAndTheToolbar() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let workspace = tab.workspace
            let layout = WindowMetrics.standard.explorer
            let height = workspace.bounds.height
            // Tree 280 from the window's top, an 8 pt resizer, the content under the 52 pt band.
            #expect(workspace.frame(of: workspace.sidebarCell) == NSRect(x: 0, y: 0, width: 280, height: height))
            let resizer = workspace.frame(of: workspace.treeResizer)
            #expect(resizer.minX == 280 && resizer.width == layout.resizerWidth && resizer.minY == 0)
            #expect(workspace.frame(of: workspace.mainCell).minX == 288)
            #expect(workspace.frame(of: workspace.mainCell).minY == 52)
            // The toolbar's items over the content only, in the 52 pt band: the system places them.
            let first = try #require(tab.explorerToolbar.button(.folderTree))
            let frame = workspace.frame(of: first)
            #expect(frame.minX >= 288 && frame.maxY <= 52, "\(frame)")

            tab.perform(.toggleFolderTree)
            harness.layout(tab)
            #expect(workspace.sidebarItem.isCollapsed)
            #expect(workspace.frame(of: workspace.mainCell).minX == 0)
            // The items start after the traffic lights, where the system puts them.
            let zoom = try #require(tab.window?.standardWindowButton(.zoomButton))
            let moved = workspace.frame(of: first)
            #expect(moved.minX > workspace.frame(of: zoom).maxX, "\(moved)")
            await harness.close()
        }

        // F-707 F-698: the window is a sidebar split under a unified system toolbar, as Finder's: the sidebar runs the
        // window's height, and the system tab bar shows over the content column only.
        @Test func putsTheTabBarOverTheContentColumnOnly() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let window = try #require(tab.window)
            let workspace = tab.workspace
            #expect(window.toolbar === tab.explorerToolbar.toolbar && window.toolbarStyle == .unified)
            #expect(window.styleMask.contains(.fullSizeContentView) && window.titleVisibility == .hidden)
            let identifiers = window.toolbar?.items.map(\.itemIdentifier)
            #expect(identifiers?.first == .sidebarTrackingSeparator)
            #expect(identifiers?.count == ToolbarItems.defaultTopItems.count + 1)
            #expect(window.toolbar?.allowsUserCustomization == true)
            #expect(window.toolbar?.autosavesConfiguration == false)
            #expect(window.toolbar?.displayMode == .iconOnly)
            if #available(macOS 15, *) { #expect(window.toolbar?.allowsDisplayModeCustomization == false) }
            #expect(workspace.sidebarItem.behavior == .sidebar)
            // The band: 52 points, the content's panes under it.
            #expect(WindowChrome.panesTop(window) == 52)
            // The traffic lights are where the system puts them, over the sidebar.
            let close = try #require(window.standardWindowButton(.closeButton))
            #expect(workspace.frame(of: close).origin == NSPoint(x: 19, y: 19))

            tab.perform(.newTab)
            let group = try #require(tab.group)
            #expect(await waitUntil { group.tabs.count == 2 })
            let other = try #require(group.tabs.last?.window)
            // The tabs of a window that is never shown are not put in a native group: put them in one, unshown.
            window.addTabbedWindow(other, ordered: .above)
            #expect(window.tabGroup?.isTabBarVisible == true)
            harness.layout(tab)
            #expect(!window.isVisible && !other.isVisible)
            let frameView = try #require(window.contentView?.superview)
            let tabBar = try #require(
                Views.all(NSView.self, in: frameView).first { String(describing: type(of: $0)) == "NSTabBar" })
            let bar = workspace.frame(of: tabBar)
            #expect(bar.minX == 288.5 && bar.maxX == workspace.bounds.width, "\(bar)")
            #expect(bar.minY >= 52)
            // The sidebar still starts at the window's top; the content's panes start under the tab bar.
            #expect(workspace.frame(of: workspace.sidebarCell).minY == 0)
            let panesTop = workspace.frame(of: workspace.mainCell).minY
            #expect(panesTop == WindowChrome.panesTop(window) && panesTop >= bar.maxY, "\(panesTop)")
            // The toolbar's items stay in the band, over the content.
            let item = try #require(tab.explorerToolbar.button(.folderTree))
            #expect(workspace.frame(of: item).minX >= 288 && workspace.frame(of: item).maxY <= 52)
            await harness.close()
        }

        // D-001 D-015: the system draws the tabs and the title bar is its own, with no separator at rest; the band is the
        // content's color from the window's top; a veil or a dialog's scrim dims it once.
        @Test func theBandIsTheContentsColor() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let window = try #require(tab.window)
            let workspace = tab.workspace
            harness.layout(tab)
            #expect(!window.titlebarAppearsTransparent && window.titlebarSeparatorStyle == .none)
            #expect(workspace.contentColumn.layer?.backgroundColor == nil)
            let backdrop = workspace.contentColumn.backdrop
            #expect(backdrop.frame == workspace.contentColumn.bounds)
            #expect(backdrop.layer?.backgroundColor == ChromeColors.contentBackground(for: workspace).cgColor)
            let band = workspace.contentColumn.band
            #expect(band.frame.minY == 0 && band.frame.height == 52)
            #expect(band.frame.width == workspace.contentColumn.frame.width)

            // A dialog's scrim leaves out what its title bar veil dims.
            tab.perform(.openLocationSheet)
            window.contentView?.layoutSubtreeIfNeeded()
            let scrim = try #require(tab.dialogs.first)
            let titlebarVeil = try #require(scrim.titlebarVeil)
            let veiled = scrim.convert(titlebarVeil.bounds, from: titlebarVeil)
            #expect(veiled.minY == 0, "\(veiled)")
            #expect(veiled.minX == workspace.frame(of: workspace.contentColumn).minX, "\(veiled)")
            #expect(veiled.maxX == scrim.bounds.maxX)
            #expect(!scrim.dimmedRects.contains { $0.intersects(veiled) })
            let area = scrim.dimmedRects.reduce(0) { $0 + $1.width * $1.height }
            #expect(area == scrim.bounds.width * scrim.bounds.height - veiled.width * veiled.height)
            await harness.close()
        }

        // T-5c92ae3b T-6932d3fd T-5d509651 F-705 B-INFO-183 B-INFO-184 B-INFO-185
        // B-VIEW-104
        @Test func slidesTheInfoPanelInAndOutOverTheContent() async throws {
            let harness = try ExplorerHarness.windowless()
            // A panel open when the window is restored does not slide.
            _ = harness.store.updatePreferences(["propertiesOpen": .bool(true)])
            let tab = try await harness.open()
            let workspace = tab.workspace
            #expect(workspace.infoPanelOpen && workspace.slide == nil)
            // D-020: the system's inspector item, from under the title bar, the content beside it.
            #expect(workspace.inspectorItem.behavior == .inspector && !workspace.inspectorItem.isCollapsed)
            #expect(workspace.inspectorCell.frame.width == 320)
            #expect(workspace.inspectorResizer.frame.maxX == workspace.inspectorCell.frame.minX)
            let width = workspace.bounds.width
            #expect(workspace.frame(of: workspace.inspectorCell).maxX == width)
            #expect(workspace.frame(of: workspace.inspectorCell).minY == 52)
            #expect(workspace.frame(of: workspace.mainCell).maxX == width - 328)
            #expect(workspace.frame(of: workspace.inspectorResizer).minX == width - 328)
            // The toolbar's band runs over the panel, as the original's.
            #expect(workspace.frame(of: workspace.contentColumn.band).maxX == width)

            tab.perform(.toggleInfoPanel)
            harness.layout(tab)
            // Closing: the content takes the whole width at once, the panel slides away over it, then goes.
            #expect(workspace.slide == .slidingOut)
            #expect(workspace.inspectorItem.isCollapsed)
            #expect(workspace.frame(of: workspace.mainCell).maxX == width)
            #expect(!workspace.inspectorCell.isHidden && workspace.inspectorResizer.isHidden)
            #expect(await waitUntil { workspace.slide == nil })
            harness.layout(tab)
            #expect(workspace.inspectorCell.isHidden)
            #expect(workspace.inspectorCell.superview === workspace.inspectorColumn)

            tab.perform(.toggleInfoPanel)
            #expect(workspace.slide == .slidingIn)
            #expect(WorkspaceView.slideDuration == 0.22)
            #expect(await waitUntil { workspace.slide == nil })
            harness.layout(tab)
            #expect(!workspace.inspectorItem.isCollapsed)
            #expect(workspace.frame(of: workspace.mainCell).maxX == width - 328)
            await harness.close()
        }

        // T-21dbb5e8 T-f539501b T-f1326c67 F-703 F-704 B-INFO-187 B-INFO-188 B-INFO-189
        @Test func squeezesThePanesInANarrowWindowAndKeepsTheChosenWidths() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let workspace = tab.workspace
            tab.updatePanels {
                $0.propertiesOpen = true
                $0.treeWidth = 520
                $0.inspectorWidth = 480
            }
            tab.window?.setContentSize(NSSize(width: 1080, height: 700))
            harness.layout(tab)
            #expect(workspace.panes.treeWidth == 384 && workspace.panes.inspectorWidth == 260)
            tab.window?.setContentSize(NSSize(width: 1600, height: 700))
            harness.layout(tab)
            #expect(workspace.panes.treeWidth == 520 && workspace.panes.inspectorWidth == 480)
            // ←/→ on a focused resizer; the chosen width is the window's session.
            tab.window?.makeFirstResponder(workspace.treeResizer)
            let event = try #require(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                    characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 123))
            workspace.treeResizer.keyDown(with: event)
            #expect(workspace.panes.treeWidth == 508)
            #expect(tab.panels.treeWidth == 508)
            await harness.close()
        }

        // T-afab159e T-ffa12885 T-f37b9997 T-39ebe2dd T-a8ad7dc0: N/A, scrollbarVisibility.ts shows a pane's scrollbars
        // while it scrolls; AppKit's overlay scrollers already do, and the panes' scroll views let them hide.
        @Test func leavesTheScrollersToTheSystemsOverlayScrollers() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let scrolls = Views.all(NSScrollView.self, in: tab.workspace)
            #expect(!scrolls.isEmpty)
            for scroll in scrolls { #expect(scroll.autohidesScrollers) }
            await harness.close()
        }
    }
}
