// Ports the toolbar band's menus and right-click of apps/desktop/src/renderer/components/ExplorerWorkspace.tsx
// (handleToolbarContextMenu, the window-toolbar header) on a window whose band is the system toolbar's
import AppKit
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    @MainActor
    @Suite struct ZZReviewBandMenuTests {
        /// The hit view of the window's frame for a point of the workspace, from its top left.
        private static func hit(_ probe: NSPoint, in workspace: WorkspaceView, window: NSWindow) throws -> NSView? {
            let frameView = try #require(window.contentView?.superview)
            let point = workspace.convert(probe, to: nil)
            return frameView.hitTest(frameView.convert(point, from: nil))
        }

        private static func name(_ view: NSView?) -> String {
            view.map { String(describing: type(of: $0)) } ?? "nil"
        }

        // A menu opened in the band stands over the title bar for a scenario and takes its presses.
        // covered-by-feature F-700
        @Test func aMenuOpenedInTheBandTakesPressesThere() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            harness.layout(tab)
            let window = try #require(tab.window)
            let workspace = tab.workspace
            let menu = AppMenu(
                items: [AppMenuItem(title: "Customize Toolbar…", checked: false, action: {})],
                identifier: "toolbarMenu", rowIdentifier: "toolbarMenu.item")
            AppMenuPresenter.shared.show(menu, in: window, at: NSPoint(x: 500, y: 20), owner: nil)
            let hit = try Self.hit(NSPoint(x: 520, y: 30), in: workspace, window: window)
            #expect(hit is AppMenuStandInRow, "hit \(Self.name(hit))")
            AppMenuPresenter.shared.close()
            await harness.close()
        }

        // A button's tooltip, which starts in the band (under the button), is drawn over the title bar too.
        @Test func aTooltipInTheBandIsOverTheTitleBar() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            harness.layout(tab)
            let window = try #require(tab.window)
            let workspace = tab.workspace
            let frameView = try #require(window.contentView?.superview)
            let back = try #require(tab.explorerToolbar.button(.back))
            let tooltips = TooltipController.of(window)
            tooltips.scheduler.onShow(back, "Back")
            let bubble = try #require(Views.first(TooltipBubble.self, in: frameView))
            let top = frameView.subviews.last
            #expect(top is WindowOverlayView)
            #expect(top.map { bubble.isDescendant(of: $0) } == true)
            let rect = workspace.convert(bubble.bounds, from: bubble)
            #expect(rect.minY < WindowMetrics.standard.toolbar.minHeight, "\(rect)")
            tooltips.scheduler.onHide()
            TooltipController.remove(window)
            await harness.close()
        }

        // The top layer leaves the band alone: its presses are the system toolbar's (its own right-click menu, the
        // window's drag), the items' and the traffic lights'.
        @Test func theBandIsTheSystemsWithNoMenuOverIt() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            harness.layout(tab)
            let window = try #require(tab.window)
            let workspace = tab.workspace
            for probe in [NSPoint(x: 600, y: 3), NSPoint(x: 600, y: 49), NSPoint(x: 291, y: 26)] {
                let hit = try Self.hit(probe, in: workspace, window: window)
                #expect(!(hit is WindowOverlayView), "\(probe) hit \(Self.name(hit))")
            }
            let back = try #require(tab.explorerToolbar.button(.back))
            let onBack = workspace.convert(NSPoint(x: back.bounds.midX, y: back.bounds.midY), from: back)
            let hitBack = try Self.hit(onBack, in: workspace, window: window)
            #expect(hitBack === back, "back hit \(Self.name(hitBack))")
            // The traffic lights keep theirs.
            let close = try #require(window.standardWindowButton(.closeButton))
            let center = workspace.convert(NSPoint(x: close.bounds.midX, y: close.bounds.midY), from: close)
            let hit = try Self.hit(center, in: workspace, window: window)
            #expect(hit?.isDescendant(of: close) == true, "close hit \(Self.name(hit))")
            await harness.close()
        }
    }
}
