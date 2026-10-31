// Ports the toolbar band's geometry of apps/desktop/src/renderer/styles.css (.window-toolbar: padding 0 12px 0 8px,
// min-height 52px; the workspace grid's columns) on a window whose band is the system toolbar's
import AppKit
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    @MainActor
    @Suite struct BandGeometryTests: ToolbarTesting {
        /// A view's frame in the window's content, from its top left.
        static func frame(_ view: NSView, in tab: MainWindowController) -> NSRect {
            tab.workspace.frame(of: view)
        }

        // The content column starts at the sidebar's width, with no divider of the split's between them, and the band
        // the capture names "toolbar" is the original's header over it.
        // covered-by-feature F-707
        @Test func theContentColumnStartsAtTheSidebarsWidth() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            harness.layout(tab)
            let workspace = tab.workspace
            #expect(workspace.split.splitView.dividerThickness == 0)
            #expect(workspace.split.splitView is WorkspaceSplitView)
            let column = workspace.frame(of: workspace.contentColumn)
            #expect(column.minX == 288 && column.width == workspace.bounds.width - 288, "\(column)")
            #expect(workspace.frame(of: workspace.mainCell).minX == 288)
            let band = workspace.frame(of: workspace.contentColumn.band)
            #expect(band == NSRect(x: 288, y: 0, width: workspace.bounds.width - 288, height: 52), "\(band)")
            #expect(workspace.contentColumn.band.accessibilityIdentifier() == "toolbar.band")
            await harness.close()
        }

        // The system places the items: in the band, over the content column, the title taking the room the others leave.
        // covered-by-feature F-707 F-708
        @Test func theItemsSitInTheBand() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            harness.layout(tab)
            #expect(tab.workspace.bounds.width == 1200)
            var last = 288.0
            for id in [ToolbarItemID.folderTree, .back, .forward, .view, .sort, .viewOptions, .infoPanel] {
                let view = try #require(tab.explorerToolbar.item(id)?.view)
                let rect = Self.frame(view, in: tab)
                #expect(rect.minX >= last && rect.maxY <= 52, "\(id): \(rect)")
                last = rect.maxX
            }
            let toolbar = tab.explorerToolbar
            let search = Self.frame(toolbar.searchField, in: tab)
            #expect(search.minY >= 0 && search.maxY <= 52, "\(search)")
            let title = try #require(toolbar.titleView)
            #expect(
                Self.frame(title, in: tab).width > DesignTokens.toolbar.titleMinWidth, "\(Self.frame(title, in: tab))")
            await harness.close()
        }

        // A press goes to the button (through the title bar only on screen: placesTheBandAndTakesItsPressesOnScreen):
        // Sort opens its menu, a second press closes it.
        // covered-by-feature F-712 F-700
        @Test func pressesInTheBandReachItsButtons() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            harness.layout(tab)
            let window = try #require(tab.window)
            let sort = try #require(button(tab, .sort))
            func press() {
                guard
                    let event = NSEvent.mouseEvent(
                        with: .leftMouseDown, location: center(of: sort), modifierFlags: [], timestamp: 0,
                        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
                else { return }
                sort.mouseDown(with: event)
                sort.mouseUp(with: event)
            }
            press()
            #expect(titles(menu) == ["Name", "Kind", "Date Modified", "Size", "-", "Ascending", "Descending"])
            #expect(sort.menuOpen)
            // A press on a row of the menu chooses it.
            let host = try #require(AppMenuPresenter.overlayHost(of: window))
            let size = try #require(
                identified("toolbarMenu.item", in: host).first { $0.accessibilityLabel() == "Size" })
            mouse(.leftMouseDown, at: center(of: size), in: window)
            mouse(.leftMouseUp, at: center(of: size), in: window)
            #expect(menu == nil)
            #expect(tab.viewState.sortBy == .size)
            press()
            #expect(menu != nil)
            press()
            #expect(menu == nil)

            await harness.close()
        }

        // The field takes the keyboard in its toolbar item, and its options button sits on the system's magnifier.
        // covered-by-feature F-713
        @Test func theSearchFieldTakesTheKeyboardWithItsOptionsOnTheMagnifier() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            harness.layout(tab)
            let window = try #require(tab.window)
            let field = try #require(tab.searchField)
            let cell = try #require(field.cell as? NSSearchFieldCell)
            #expect(window.makeFirstResponder(field))
            #expect(field.isActive)
            field.layoutSubtreeIfNeeded()
            #expect(field.optionsButton.frame == cell.searchButtonRect(forBounds: field.bounds))
            window.makeFirstResponder(nil)
            await harness.close()
        }

        // The accent the preferences chose is the one the window draws with; a capture's `prefs` step stores it, so a
        // theme set after it keeps it.
        // covered-by-feature F-662
        @Test func drawsWithTheChosenAccent() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let window = try #require(tab.window)
            let appearance = AppearanceModel.shared
            let before = appearance.accentHex
            // Synchronous on the main actor: no other suite draws while the accent is changed.
            let prefs: [String: Scenario.PrefValue] = ["accent": .string("#a550a7")]
            _ = AutomationPrefs.apply(prefs, context: .init(controller: tab, window: window, prefs: prefs))
            let chosen = appearance.accentHex
            let drawn = ChromeColors.accent(for: tab.workspace)
            let stored = tab.preferences.accent
            appearance.apply(accent: before)
            #expect(chosen == "#a550a7")
            #expect(drawn == AccentPalette(hex: "#a550a7", appearance: ChromeColors.appearance(of: tab.workspace)))
            #expect(stored == "#a550a7")
            await harness.close()
        }
    }
}
