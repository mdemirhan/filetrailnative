// Ports the UI cases of components/TreePane.test.tsx, TreePane.rows.test.tsx and the sidebar cases of
// App.menusAndTree.test.tsx on an explorer window that is never shown
import AppKit
import FTFileSystem
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

/// What the sidebar suites look at and send.
@MainActor
protocol SidebarTesting {}

extension SidebarTesting {
    func sidebar(_ tab: MainWindowController) -> SidebarViewController { tab.sidebarController }

    func cells(_ controller: SidebarViewController) -> [SidebarItemCell] {
        controller.view.window?.contentView?.layoutSubtreeIfNeeded()
        var found: [SidebarItemCell] = []
        func walk(_ view: NSView) {
            if let cell = view as? SidebarItemCell, let outline = enclosingOutline(cell),
                outline.row(for: cell) >= 0
            {
                cell.layoutSubtreeIfNeeded()
                found.append(cell)
            }
            for child in view.subviews { walk(child) }
        }
        walk(controller.view)
        return found.sorted { $0.convert($0.bounds, to: nil).minY > $1.convert($1.bounds, to: nil).minY }
    }

    func enclosingOutline(_ view: NSView) -> NSOutlineView? {
        var current: NSView? = view.superview
        while let candidate = current, !(candidate is NSOutlineView) { current = candidate.superview }
        return current as? NSOutlineView
    }

    /// The tree rooted at the folder on screen, so its rows fit the window.
    func rooted(_ tab: MainWindowController, _ harness: ExplorerHarness) async {
        tab.perform(.rootTreeAtSelection)
        await settle()
        _ = await waitUntil { self.sidebar(tab).treeRootPath == listed(harness, "") }
        harness.layout(tab)
    }

    /// The folder as the tree names it: the listing resolves the temporary folder's symlinked `/var`.
    func listed(_ harness: ExplorerHarness, _ name: String) -> String {
        let path = name.isEmpty ? harness.folder.path : harness.folder.path + "/" + name
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Whether a favorite row is on screen (the tree may hold a folder named like one).
    func hasFavorites(_ controller: SidebarViewController) -> Bool {
        cells(controller).contains { $0.state?.item.kind == .favorite }
    }

    func label(_ cell: SidebarItemCell) -> String { cell.state?.item.label ?? "" }

    func labels(_ controller: SidebarViewController) -> [String] { cells(controller).map(label) }

    func key(_ code: UInt16, _ characters: String, modifiers: NSEvent.ModifierFlags = [], in window: NSWindow?) {
        guard let window,
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)
        else { return }
        window.sendEvent(event)
    }

    func setPlacement(_ tab: MainWindowController, _ placement: String, _ harness: ExplorerHarness) async {
        tab.updatePreferences(["favoritesPlacement": .string(placement)])
        tab.preferencesChanged(PreferencesChange(patch: [:], senderID: nil))
        harness.layout(tab)
        await settle()
        // Under a loaded machine the rows arrive a moment later.
        let controller = sidebar(tab)
        _ = await waitUntil { controller.model.placement.rawValue == placement && self.hasFavorites(controller) }
    }
}

extension ExplorerWindowlessTests {
    @MainActor
    @Suite struct SidebarTests: SidebarTesting {
        // T-cdf3463c T-2caf696c T-9aa3fb64 T-01d458a9 F-728 F-729 B-TREE-001 B-TREE-004
        @Test func drawsFavoritesInTheirOwnSectionAboveTheFoldersOrAsRowsOfTheTree() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open(listed(harness, ""))
            // The tree on the folder under test, so the rows are the few of it, not the temporary directory's.
            await rooted(tab, harness)
            await setPlacement(tab, "separate", harness)
            let controller = sidebar(tab)
            #expect(labels(controller).prefix(3) == ["Applications", "Desktop", "Documents"])
            #expect(!labels(controller).contains("Favorites"))
            #expect(!controller.foldersHeaderHiddenForTests)
            await setPlacement(tab, "integrated", harness)
            #expect(labels(controller).prefix(2) == ["Favorites", "Applications"])
            #expect(labels(controller).contains("Locations"))
            #expect(controller.foldersHeaderHiddenForTests)
            await harness.close()
        }

        // T-69575bf4 F-733 B-TREE-007 B-TREE-008
        @Test func rowsHaveTheOriginalsHeightIndentAndPadding() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open(listed(harness, ""))
            // The tree on the folder under test, so the rows are the few of it, not the temporary directory's.
            await rooted(tab, harness)
            await setPlacement(tab, "integrated", harness)
            let controller = sidebar(tab)
            let layout = controller.layout
            let all = cells(controller)
            let favorite = try #require(all.first { $0.state?.item.kind == .favorite })
            let heading = try #require(all.first { $0.state?.item.kind == .favoritesRoot })
            #expect(Double(favorite.box.frame.height) == layout.rowHeight)
            #expect(Double(favorite.box.frame.minX) == layout.rowMarginX)
            // A favorite is a level below its heading: one indent further to the right.
            let favoriteIcon = favorite.box.subviews.first { $0.accessibilityIdentifier() == "sidebar.row.icon" }
            let headingIcon = heading.box.subviews.first { $0.accessibilityIdentifier() == "sidebar.row.icon" }
            let difference = (favoriteIcon?.frame.minX ?? 0) - (headingIcon?.frame.minX ?? 0)
            #expect(Double(difference) == layout.indent)
            #expect(layout.rowHeight == 26)
            await harness.close()
        }

        // T-8cb3e771 T-764e53b9 T-8722d999 F-730 B-TREE-006 B-TREE-066
        @Test func aHeaderOpensAndClosesItsSectionAndKeepsItsChevronWhileClosed() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open(listed(harness, ""))
            await setPlacement(tab, "separate", harness)
            let controller = sidebar(tab)
            #expect(hasFavorites(controller))
            controller.model.toggleFavorites()
            await settle()
            harness.layout(tab)
            #expect(!hasFavorites(controller))
            #expect(tab.favoritesExpanded == false)
            controller.model.toggleFavorites()
            await settle()
            #expect(hasFavorites(controller))
            await harness.close()
        }

        // T-cf9aab91 F-731 B-TREE-163 B-TREE-164
        @Test func aDiskThatCanBeEjectedHasAnEjectButtonAndOtherPlacesHaveNone() async throws {
            let harness = try ExplorerHarness.windowless()
            SidebarVolumes.shared.override = [
                Volume(
                    path: "/Volumes/Backup", name: "Backup", isLocal: true, isReadOnly: false, fileSystem: "apfs",
                    canEject: true, disk: "disk5"),
                Volume(
                    path: "/Volumes/Shared", name: "Shared", isLocal: false, isReadOnly: false, fileSystem: "smbfs",
                    canEject: false, disk: nil),
            ]
            defer { SidebarVolumes.shared.override = nil }
            let tab = try await harness.open(listed(harness, ""))
            await setPlacement(tab, "separate", harness)
            let controller = sidebar(tab)
            let rows = cells(controller)
            let backup = try #require(rows.first { label($0) == "Backup" })
            let shared = try #require(rows.first { label($0) == "Shared" })
            let home = try #require(
                rows.first { $0.state?.item.kind == .location && $0.state?.item.path == NSHomeDirectory() })
            func ejectButton(_ cell: SidebarItemCell) -> NSView? {
                cell.box.subviews.first { $0.accessibilityIdentifier() == "sidebar.row.eject" }
            }
            #expect(ejectButton(backup)?.isHidden == false)
            #expect(ejectButton(backup)?.toolTip == "Eject \u{201C}Backup\u{201D}")
            #expect(ejectButton(shared)?.isHidden == true)
            #expect(ejectButton(home)?.isHidden == true)
            #expect(ejectButton(backup).map { Double($0.frame.width) } == controller.layout.ejectBox)
            await harness.close()
        }

        // T-ace3a16c T-263ef807 T-5ac955ab B-TREE-064 B-TREE-065
        @Test func aRightClickRingsOnlyThatRowAndLeavesTheSelection() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open(listed(harness, ""))
            await rooted(tab, harness)
            let controller = sidebar(tab)
            #expect(await waitUntil { self.labels(controller).contains("Beta") })
            let selected = controller.model.selected
            var asked: [String] = []
            controller.contextMenuProvider = { request in
                asked.append(request.item.label)
                return NSMenu()
            }
            let beta = try #require(cells(controller).first { label($0) == "Beta" })
            let outline = controller.tree.outline
            let point = outline.convert(NSPoint(x: beta.bounds.midX, y: beta.bounds.midY), from: beta)
            let event = try #require(
                NSEvent.mouseEvent(
                    with: .rightMouseDown, location: outline.convert(point, to: nil), modifierFlags: [],
                    timestamp: 0, windowNumber: tab.window?.windowNumber ?? 0, context: nil, eventNumber: 0,
                    clickCount: 1, pressure: 1))
            #expect(outline.menu(for: event) != nil)
            #expect(asked == ["Beta"])
            #expect(controller.model.selected == selected)
            #expect(controller.model.menuTarget?.path == listed(harness, "Beta"))
            controller.model.menuTarget = nil
            await harness.close()
        }
    }
}
