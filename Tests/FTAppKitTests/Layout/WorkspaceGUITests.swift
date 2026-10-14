// Ports the grid cases of apps/desktop/src/renderer/components/ExplorerWorkspace.test.tsx, the window cases of
// hooks/useExplorerPaneLayout.test.tsx, useElementSize.test.tsx and styles.responsive.test.ts, and the window frame
// the user reported (no lines the original doesn't have)
import AppKit
import FTFileSystem
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowGUITests {
    @MainActor
    @Suite struct WorkspaceGUITests {
        // T-880733c9 T-6d329198 F-698 F-699 F-700 F-701 F-702 B-INFO-190 B-VIEW-236
        @Test func hidesTheFolderTreeGivingItsRoomToTheListAndTheToolbar() async throws {
            let harness = try ExplorerHarness()
            let tab = try await harness.open()
            let workspace = tab.workspace
            let layout = WindowMetrics.standard.explorer
            // Tree 280, an 8 pt resizer, the content; the toolbar over the content only.
            #expect(workspace.sidebarCell.frame == NSRect(x: 0, y: 0, width: 280, height: workspace.bounds.height))
            #expect(workspace.treeResizer.frame.minX == 280 && workspace.treeResizer.frame.width == layout.resizerWidth)
            #expect(workspace.toolbar.frame.minX == 288 && workspace.toolbar.frame.height == 52)
            #expect(workspace.mainCell.frame.minX == 288 && workspace.mainCell.frame.minY == 52)
            #expect(workspace.toolbar.rowOrigin == 8)

            tab.perform(.toggleFolderTree)
            harness.layout(tab)
            #expect(workspace.sidebarCell.isHidden && workspace.treeResizer.isHidden)
            #expect(workspace.toolbar.frame.minX == 0 && workspace.mainCell.frame.minX == 0)
            // The toolbar's first item clears the traffic lights.
            #expect(workspace.toolbar.rowOrigin == layout.toolbarInsetWithoutTree)
            await harness.close()
        }

        // T-5c92ae3b T-6932d3fd T-5d509651 F-705 B-INFO-183 B-INFO-184 B-INFO-185
        @Test func slidesTheInfoPanelInAndOutOverTheContent() async throws {
            let harness = try ExplorerHarness()
            // A panel open when the window is restored does not slide.
            _ = harness.store.updatePreferences(["propertiesOpen": .bool(true)])
            let tab = try await harness.open()
            let workspace = tab.workspace
            #expect(workspace.infoPanelOpen && workspace.slide == nil)
            #expect(workspace.inspectorCell.frame.width == 320)
            #expect(workspace.inspectorResizer.frame.maxX == workspace.inspectorCell.frame.minX)
            #expect(workspace.mainCell.frame.maxX == workspace.inspectorResizer.frame.minX)

            tab.perform(.toggleInfoPanel)
            harness.layout(tab)
            // Closing: the content takes the whole width at once, the panel slides away over it, then goes.
            #expect(workspace.slide == .slidingOut)
            #expect(workspace.mainCell.frame.maxX == workspace.bounds.width)
            #expect(!workspace.inspectorCell.isHidden && workspace.inspectorResizer.isHidden)
            #expect(await waitUntil { workspace.slide == nil })
            harness.layout(tab)
            #expect(workspace.inspectorCell.isHidden)

            tab.perform(.toggleInfoPanel)
            #expect(workspace.slide == .slidingIn)
            #expect(WorkspaceView.slideDuration == 0.22)
            #expect(await waitUntil { workspace.slide == nil })
            await harness.close()
        }

        // T-21dbb5e8 T-f539501b T-f1326c67 F-703 F-704 B-INFO-187 B-INFO-188 B-INFO-189
        @Test func squeezesThePanesInANarrowWindowAndKeepsTheChosenWidths() async throws {
            let harness = try ExplorerHarness()
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

        // F-707: the window's frame is the original's: no system toolbar or title, no lines in the title bar, the band
        // 52 tall, the traffic lights 14 in and 16 down; the sidebar is translucent and runs the window's height.
        @Test func drawsNoLinesTheOriginalDoesNotHave() async throws {
            let harness = try ExplorerHarness()
            let tab = try await harness.open()
            let window = try #require(tab.window)
            #expect(window.toolbar == nil)
            #expect(window.titlebarAppearsTransparent && window.titleVisibility == .hidden)
            #expect(window.titlebarSeparatorStyle == .none)
            #expect(window.styleMask.contains(.fullSizeContentView))
            #expect(!(window.contentViewController is NSSplitViewController))
            let close = try #require(window.standardWindowButton(.closeButton))
            let frame = close.convert(close.bounds, to: nil)
            #expect(frame.minX == WindowChrome.trafficLights.x)
            #expect(window.frame.height - frame.maxY == WindowChrome.trafficLights.y)
            let container = try #require(close.superview?.superview)
            #expect(container.frame.height == 52)
            #expect(tab.workspace.sidebarCell.frame.minY == 0)
            await harness.close()
        }

        // T-afab159e T-ffa12885 T-f37b9997 T-39ebe2dd T-a8ad7dc0: N/A, scrollbarVisibility.ts shows a pane's scrollbars
        // while it scrolls; AppKit's overlay scrollers already do, and the panes' scroll views let them hide.
        @Test func leavesTheScrollersToTheSystemsOverlayScrollers() async throws {
            let harness = try ExplorerHarness()
            let tab = try await harness.open()
            let scrolls = Views.all(NSScrollView.self, in: tab.workspace)
            #expect(!scrolls.isEmpty)
            for scroll in scrolls { #expect(scroll.autohidesScrollers) }
            await harness.close()
        }
    }
}
