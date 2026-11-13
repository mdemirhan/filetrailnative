// The chrome that follows Finder: the sidebar's straight edge, the band's line under the pointer. Finder's
// numbers are measured from its 2x screenshots; the Info panel's resizer stays an opaque gutter with its hairline
import AppKit
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    @MainActor
    @Suite struct ChromeLikeFinderTests {
        /// A color as sRGB levels.
        private static func level(_ color: NSColor) -> [Double] {
            let srgb = color.usingColorSpace(.sRGB) ?? color
            return [srgb.redComponent, srgb.greenComponent, srgb.blueComponent].map { ($0 * 255).rounded() }
        }

        private static func pixel(of resizer: PaneResizerView, xFraction: Double, y: Double) throws -> NSColor {
            let rep = try #require(resizer.bitmapImageRepForCachingDisplay(in: resizer.bounds))
            resizer.cacheDisplay(in: resizer.bounds, to: rep)
            let scale = Double(rep.pixelsHigh) / Double(resizer.bounds.height)
            let x = min(rep.pixelsWide - 1, Int(Double(rep.pixelsWide) * xFraction))
            let color = rep.colorAt(x: x, y: Int(y * scale))
            return try #require(color?.usingColorSpace(.sRGB))
        }

        private static func crossing(_ type: NSEvent.EventType) throws -> NSEvent {
            try #require(
                NSEvent.enterExitEvent(
                    with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                    eventNumber: 0, trackingNumber: 0, userData: nil))
        }

        // The window at rest, on one window. The tree's resizer paints nothing, beside the band or under it: the
        // sidebar's material shows through.
        @Test func theChromeAtRest() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            harness.layout(tab)
            let workspace = tab.workspace
            let resizer = workspace.treeResizer
            let top = workspace.panesTop
            #expect(workspace.frame(of: resizer).minY == 0)
            for y in [20, top + 20] {
                for xFraction in [0.1, 0.5, 0.99] {
                    let color = try Self.pixel(of: resizer, xFraction: xFraction, y: y)
                    #expect(color.alphaComponent == 0, "\(xFraction), \(y): \(color)")
                }
            }
            // The material runs to the column's edge, where the band and the panes start.
            let column = workspace.frame(of: workspace.sidebarColumn)
            #expect(workspace.sidebarColumn.subviews == [workspace.sidebarCell, resizer])
            #expect(workspace.sidebarColumn.layer?.backgroundColor == nil)
            #expect(workspace.frame(of: resizer).maxX == column.maxX)
            #expect(workspace.frame(of: workspace.contentColumn.band).minX == column.maxX)
            #expect(workspace.frame(of: workspace.mainCell).minX == column.maxX)
            // The rows that used to reach the hairline stop at the edge instead of notching the sidebar.
            #expect(workspace.mainCell.layer?.masksToBounds == true)

            // The content's background is the system's content material, Finder's, under both columns from the
            // window's top: in dark mode it takes the desktop's tint as Finder's does. The panes paint nothing over it.
            for backdrop in [workspace.contentColumn.backdrop, workspace.inspectorColumn.backdrop] {
                #expect(backdrop.material == .contentBackground && backdrop.blendingMode == .behindWindow)
                #expect(backdrop.state == .followsWindowActiveState)
            }
            #expect(workspace.contentColumn.subviews.first === workspace.contentColumn.backdrop)
            #expect(workspace.inspectorColumn.subviews.first === workspace.inspectorColumn.backdrop)
            #expect(workspace.mainCell.layer?.backgroundColor == nil)

            // The dialog's extra dim covers the sidebar, up to its edge.
            tab.perform(.openLocationSheet)
            tab.window?.contentView?.layoutSubtreeIfNeeded()
            let scrim = try #require(tab.dialogs.first)
            #expect(scrim.sidebarRect?.minX == 0 && scrim.sidebarRect?.maxX == column.maxX)
            await harness.close()
        }

        // Each resizer takes the pointer across its whole width: the split's dividers, which can't move anything, claim
        // none of it and none of the panes beside it.
        @Test func theSplitsDividersLeaveThePointerToTheResizers() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            tab.perform(.toggleInfoPanel)
            harness.layout(tab)
            let workspace = tab.workspace
            #expect(await waitUntil { workspace.infoPanelOpen && workspace.slide == nil })
            harness.layout(tab)
            let splitView = workspace.split.splitView
            for resizer in [workspace.treeResizer, workspace.inspectorResizer] {
                let frame = workspace.frame(of: resizer)
                #expect(frame.width == 8)
                let hit = { (x: Double) in splitView.hitTest(NSPoint(x: x, y: frame.midY)) }
                for x in stride(from: frame.minX + 0.5, to: frame.maxX, by: 1) {
                    #expect(hit(x) === resizer, "\(x) in \(frame)")
                }
                for x in [frame.minX - 2.5, frame.minX - 0.5, frame.maxX + 0.5, frame.maxX + 2.5] {
                    let other = hit(x)
                    #expect(other !== splitView && other !== resizer, "\(x) beside \(frame)")
                }
            }
            await harness.close()
        }

        // The tree hidden: no sidebar, the content's color and the line from the window's left.
        @Test func withTheTreeHiddenTheContentStartsAtTheWindowsLeft() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            tab.perform(.toggleFolderTree)
            harness.layout(tab)
            let workspace = tab.workspace
            #expect(workspace.sidebarItem.isCollapsed)
            let column = workspace.contentColumn
            #expect(workspace.frame(of: column.backdrop).minX == 0)
            #expect(workspace.frame(of: column.backdrop).minY == 0)
            #expect(workspace.frame(of: column.bandLine).minX == 0)
            await harness.close()
        }

        // Under the pointer the sidebar's edge shows the accent's line, on the edge, from the window's top.
        @Test func theTreeResizerShowsTheAccentUnderThePointer() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            harness.layout(tab)
            let resizer = tab.workspace.treeResizer
            let top = tab.workspace.panesTop
            resizer.mouseEntered(with: try Self.crossing(.mouseEntered))
            #expect(try Self.pixel(of: resizer, xFraction: 0.99, y: top + 20).alphaComponent > 0)
            #expect(try Self.pixel(of: resizer, xFraction: 0.5, y: top + 20).alphaComponent == 0)
            #expect(try Self.pixel(of: resizer, xFraction: 0.99, y: 0).alphaComponent > 0)
            #expect(try Self.pixel(of: resizer, xFraction: 0.99, y: 20).alphaComponent > 0)
            resizer.mouseExited(with: try Self.crossing(.mouseExited))
            #expect(try Self.pixel(of: resizer, xFraction: 0.99, y: top + 20).alphaComponent == 0)
            #expect(try Self.pixel(of: resizer, xFraction: 0.99, y: 20).alphaComponent == 0)
            await harness.close()
        }

        // The Info panel's resizer is a gutter with its hairline: the column's material shows on either side of it.
        @Test func theInfoPanelsResizerIsAGutterWithItsHairline() throws {
            let resizer = PaneResizerView(pane: .inspector, identifier: "t", label: "t")
            resizer.frame = NSRect(x: 0, y: 0, width: 8, height: 40)
            #expect(try Self.pixel(of: resizer, xFraction: 0.1, y: 20).alphaComponent == 0)
            #expect(try Self.pixel(of: resizer, xFraction: 0.5, y: 20).alphaComponent > 0)
        }

        // Finder: no line at rest; the pointer over the band shows one device pixel under it, across the content column.
        @Test func theBandsLineShowsOnlyUnderThePointer() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            harness.layout(tab)
            let workspace = tab.workspace
            let column = workspace.contentColumn
            let line = column.bandLine
            #expect(line.isHidden)
            #expect(column.band.trackingAreas.count == 1)
            column.band.mouseEntered(with: try Self.crossing(.mouseEntered))
            #expect(!line.isHidden)
            // Laying out again doesn't take it away, nor does it bring it back after the pointer goes.
            harness.layout(tab)
            #expect(!line.isHidden)
            column.band.mouseExited(with: try Self.crossing(.mouseExited))
            harness.layout(tab)
            #expect(line.isHidden)

            let scale = try #require(tab.window?.backingScaleFactor)
            #expect(line.frame == NSRect(x: 0, y: 52, width: column.bounds.width, height: 1 / scale))
            #expect(column.subviews.last === line)
            #expect(line.hitTest(NSPoint(x: 1, y: 52)) == nil)
            await harness.close()
        }

        // With the Info panel open the band's line goes across the panel too, and the pointer over the band of
        // either column shows it; moving from one to the other keeps it.
        @Test func theBandsLineCoversTheInfoPanelToo() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let workspace = tab.workspace
            tab.perform(.toggleInfoPanel)
            harness.layout(tab)
            let content = workspace.contentColumn
            let inspector = workspace.inspectorColumn
            #expect(inspector.frame.width > 0)
            #expect(inspector.band.trackingAreas.count == 1)
            #expect(inspector.band.frame.width == inspector.bounds.width)
            #expect(inspector.bandLine.frame.width == inspector.bounds.width)
            #expect(inspector.bandLine.frame.minY == content.bandLine.frame.minY)
            #expect(inspector.subviews.last === inspector.bandLine)

            inspector.band.mouseEntered(with: try Self.crossing(.mouseEntered))
            #expect(!content.bandLine.isHidden && !inspector.bandLine.isHidden)
            content.band.mouseEntered(with: try Self.crossing(.mouseEntered))
            inspector.band.mouseExited(with: try Self.crossing(.mouseExited))
            #expect(!content.bandLine.isHidden && !inspector.bandLine.isHidden)
            content.band.mouseExited(with: try Self.crossing(.mouseExited))
            #expect(content.bandLine.isHidden && inspector.bandLine.isHidden)
            await harness.close()
        }

        // The levels below are the screenshots' stored values, not converted from their display profile: the same files
        // store the app's own #1d1d1f title as 29,29,31, so those are the values to compare with what a view
        // sets. Converted to sRGB the #1d1d1f reads 39, and Finder's title 94.

        // Stored as 229 over white, Finder's, which is the system's separator; in dark it follows by itself.
        @Test func theBandsLineIsFindersColor() throws {
            var light: NSColor?
            var dark: NSColor?
            NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
                light = WorkspaceBandLine.color.usingColorSpace(.sRGB)
            }
            NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
                dark = WorkspaceBandLine.color.usingColorSpace(.sRGB)
            }
            let onWhite = try #require(light)
            #expect(abs((1 - onWhite.alphaComponent) * 255 - 229) <= 1 && onWhite.redComponent == 0)
            let onDark = try #require(dark)
            #expect(onDark.redComponent == 1 && onDark.alphaComponent < 0.15)
        }

        // Finder's title is stored as 76-77 on its white band in a key window, with the band's line and without.
        @Test func theTitleIsFindersGray() throws {
            let title = ToolbarTitleView(frame: NSRect(x: 0, y: 0, width: 260, height: ToolbarTitleView.height))
            let window = KeyStateWindow()
            window.appearance = NSAppearance(named: .aqua)
            window.contentView?.addSubview(title)
            func color() throws -> NSColor { try #require(title.field.textColor?.usingColorSpace(.sRGB)) }

            window.key = true
            NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
            let key = try color()
            #expect(key.redComponent == 0)
            let onWhite = (1 - key.alphaComponent) * 255
            #expect(onWhite >= 76 && onWhite <= 77, "\(onWhite)")

            // Not key: the system's dimmest label, and back again.
            window.key = false
            NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
            let notKey = try color()
            #expect(notKey.alphaComponent < key.alphaComponent)
            window.key = true
            NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
            #expect(try color().alphaComponent == key.alphaComponent)

            // Dark: the system's label, as strong as in light.
            window.appearance = NSAppearance(named: .darkAqua)
            title.viewDidChangeEffectiveAppearance()
            let dark = try color()
            #expect(dark.redComponent == 1 && abs(dark.alphaComponent - key.alphaComponent) < 0.01)
        }

        // What lies over scrolling content holds the same material under its own views, so it is opaque and the same
        // color as the columns; the path bar is lifted as Finder's in dark mode, and nothing else is.
        @Test func thePanesOverTheContentHoldTheMaterial() throws {
            let infoRow = InfoRowView()
            infoRow.setOpen(true, animated: false)
            let pathBar = PathBarRowView()
            let views: [NSView] = [
                infoRow, SearchHeaderView(frame: .zero), TrashHeaderView(), pathBar, InfoPanelView(),
            ]
            for view in views {
                view.frame = NSRect(x: 0, y: 0, width: 600, height: 40)
                view.layout()
                let backdrop = try #require(view.subviews.first as? ContentBackdrop, "\(type(of: view))")
                #expect(backdrop.isLifted == (view === pathBar), "\(type(of: view))")
                #expect(backdrop.frame.width == 600 && backdrop.frame.height >= 39, "\(type(of: view))")
            }
        }

        // The lift is white at 3.3% over the material, in dark mode only.
        @Test func aLiftedBackdropIsLighterInDarkModeOnly() throws {
            let backdrop = ContentBackdrop()
            func shade(_ name: NSAppearance.Name, lifted: Bool) -> NSColor? {
                backdrop.appearance = NSAppearance(named: name)
                backdrop.isLifted = lifted
                backdrop.viewDidChangeEffectiveAppearance()
                return backdrop.shade.layer?.backgroundColor.flatMap { NSColor(cgColor: $0) }
            }
            let dark = try #require(shade(.darkAqua, lifted: true))
            #expect(Self.level(dark) == [255, 255, 255] && abs(dark.alphaComponent - 0.033) < 0.001)
            #expect(shade(.aqua, lifted: true) == nil)
            #expect(shade(.darkAqua, lifted: false) == nil)
        }

        // Finder's toolbar fit: the traffic lights and the row on one line, 26 pt below the window's top.
        @Test func theTrafficLightsAndTheRowShareALine() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            harness.layout(tab)
            let workspace = tab.workspace
            let close = try #require(tab.window?.standardWindowButton(.closeButton))
            #expect(workspace.frame(of: close).midY == 26)
            let back = try #require(tab.explorerToolbar.item(.back)?.view)
            #expect(workspace.frame(of: back).midY == 26)
            await harness.close()
        }
    }
}

/// A window that says it is key when the test does.
private final class KeyStateWindow: NSWindow {
    var key = false
    override var isKeyWindow: Bool { key }
}
