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

        // The top layer leaves the band alone: its presses are the system toolbar's (its own right-click menu, the
        // window's drag), the items' and the traffic lights'. A toolbar button's tooltip is the system's: there while
        // it can be used, quiet while its menu is open. A menu opened in the band stands over the title bar for a
        // scenario and takes its presses.
        @Test func theBandIsTheSystemsUntilAMenuOpensInIt() async throws {
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

            // The tooltip.
            let button = try #require(tab.explorerToolbar.button(.sort))
            let wasEnabled = button.isEnabled
            button.isEnabled = true
            button.tooltip = "Sort"
            #expect(button.toolTip == "Sort")
            button.menuOpen = true
            #expect(button.toolTip == nil)
            button.menuOpen = false
            #expect(button.toolTip == "Sort")
            button.isEnabled = false
            #expect(button.toolTip == nil)
            button.isEnabled = wasEnabled

            // A menu in the band.
            let menu = AppMenu(
                items: [AppMenuItem(title: "Customize Toolbar…", checked: false, action: {})],
                identifier: "toolbarMenu", rowIdentifier: "toolbarMenu.item")
            AppMenuPresenter.shared.show(menu, in: window, at: NSPoint(x: 500, y: 20), owner: nil)
            let inMenu = try Self.hit(NSPoint(x: 520, y: 30), in: workspace, window: window)
            #expect(inMenu is AppMenuStandInRow, "hit \(Self.name(inMenu))")
            AppMenuPresenter.shared.close()
            await harness.close()
        }
    }
}
