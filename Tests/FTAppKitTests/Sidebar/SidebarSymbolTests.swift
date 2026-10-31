// Checks the sidebar's system symbols and colors, which follow Finder (D-021), on rows that are never shown
import AppKit
import FTFoundation
import Testing

@testable import FTAppKit

@MainActor
@Suite struct SidebarSymbolTests {
    private func cell(
        _ kind: TreeItemKind, id: TreeItemID, icon: FavoriteIconID?, path: String?,
        selection: SidebarRowState.Selection = .none, density: Density = .comfortable
    ) -> SidebarItemCell {
        let item = TreePresentationItem(
            id: id, kind: kind, label: "Row", depth: 0, path: path, parentID: nil, expanded: false, canExpand: false,
            icon: icon)
        let state = SidebarRowState(
            item: item, subview: .favorites, selection: selection, menuTarget: false, drop: nil, ejecting: false,
            dragging: false, dropLine: nil, showsLoading: false, density: density, hasDisclosure: false)
        let cell = SidebarItemCell(frame: NSRect(x: 0, y: 0, width: 240, height: 26))
        cell.configure(state, width: 240)
        cell.layoutSubtreeIfNeeded()
        return cell
    }

    private func iconView(_ cell: SidebarItemCell) throws -> SidebarIconView {
        try #require(cell.box.subviews.compactMap { $0 as? SidebarIconView }.first)
    }

    private func favorite(_ icon: FavoriteIconID) -> SidebarItemCell {
        cell(.favorite, id: .favorite("/x"), icon: icon, path: "/x")
    }

    private func location(_ icon: FavoriteIconID, _ path: String) -> SidebarItemCell {
        cell(.location, id: .location(path), icon: icon, path: path)
    }

    private func symbol(_ cell: SidebarItemCell) throws -> (name: String, pointSize: Double, color: NSColor) {
        guard case .symbol(let name, let pointSize, let color) = try iconView(cell).content else {
            Issue.record("no symbol")
            return ("", 0, .clear)
        }
        return (name, pointSize, color)
    }

    // The mapping the user approved (D-021, in place of the original's line icons), every symbol there on this system.
    // T-fe3f2758 F-732
    @Test func everyIconHasTheApprovedSymbol() {
        let approved: [FavoriteIconID: String] = [
            .home: "house", .applications: "square.grid.2x2", .desktop: "menubar.dock.rectangle", .documents: "doc",
            .downloads: "arrow.down.circle", .trash: "trash", .folder: "folder", .star: "star",
            .drive: "externaldrive", .code: "chevron.left.forwardslash.chevron.right", .terminal: "terminal",
            .globe: "globe", .music: "music.note", .photos: "photo", .videos: "film", .archive: "archivebox",
            .cloud: "icloud", .server: "server.rack", .projects: "square.stack.3d.up", .books: "books.vertical",
            .camera: "camera", .toolbox: "wrench.and.screwdriver", .network: "network",
        ]
        #expect(approved.count == FavoriteIconID.allCases.count)
        for icon in FavoriteIconID.allCases {
            #expect(SidebarIcons.symbolName(for: icon) == approved[icon])
            #expect(SidebarIcons.symbol(SidebarIcons.symbolName(for: icon), pointSize: 16) != nil)
        }
        #expect(SidebarIcons.symbol("internaldrive", pointSize: 16) != nil)
    }

    // `.tree-expand`: the chevron turns over 120 ms, ending where the row is.
    @Test func theChevronTurnsToWhereItIs() async {
        let chevron = SidebarChevronView()
        chevron.expanded = true
        #expect(chevron.rotation == .pi / 2)
        chevron.turnToWhereItIs()
        #expect(chevron.isTurning)
        #expect(chevron.rotation == 0)
        #expect(await waitUntil { !chevron.isTurning })
        #expect(chevron.rotation == .pi / 2)
        chevron.turnToWhereItIs()
        chevron.expanded = false
        #expect(!chevron.isTurning)
        #expect(chevron.rotation == 0)
    }

    @Test func locationsHaveTheirOwnDiskAndNetworkSymbols() throws {
        #expect(try symbol(location(.drive, "/")).name == "internaldrive")
        #expect(try symbol(location(.drive, "/Volumes/Disk")).name == "externaldrive")
        #expect(try symbol(location(.server, "/Volumes/Share")).name == "network")
        #expect(try symbol(location(.home, "/Users/me")).name == "house")
        #expect(try symbol(location(.trash, "/Users/me/.Trash")).name == "trash")
        // A favorite on a disk's root is what its saved icon says.
        #expect(try symbol(favorite(.drive)).name == "externaldrive")
        #expect(try symbol(favorite(.server)).name == "server.rack")
    }

    @Test func aSymbolIsTheRowsIconSizeAsItsPointSize() throws {
        #expect(try symbol(favorite(.folder)).pointSize == 16)
        let compact = cell(.favorite, id: .favorite("/x"), icon: .folder, path: "/x", density: .compact)
        #expect(try symbol(compact).pointSize == 14)
        // Centered over the 16 pt box, which keeps its size.
        let row = location(.drive, "/")
        let view = try iconView(row)
        #expect(view.frame.width == 16)
        let shown = try #require(view.subviews.compactMap { $0 as? NSImageView }.first)
        #expect(!shown.isHidden)
        #expect(shown.frame.width > 16)
        #expect(abs(shown.frame.midX - view.bounds.midX) <= 0.5)
        #expect(abs(shown.frame.midY - view.bounds.midY) <= 0.5)
        // Its ink isn't cut at the box's edge.
        let box = view.convert(view.bounds, to: row)
        let left = NSRect(x: box.minX - 3, y: box.minY, width: 3, height: box.height)
        #expect(InkScan.ink(row, in: left) != nil)
    }

    // T-0ec3e044
    @Test func favoritesTakeTheAppsAccentAndLocationsTheSystemsGray() throws {
        let row = favorite(.folder)
        #expect(try symbol(row).color == ChromeColors.color(SidebarColors.theme(for: row).accent.solid))
        #expect(try symbol(location(.home, "/Users/me")).color == .secondaryLabelColor)
        // On the focused selection they take its ink, as before.
        let selected = cell(.favorite, id: .favorite("/x"), icon: .folder, path: "/x", selection: .focused)
        let onSelection = ChromeColors.color(SidebarColors.theme(for: selected).accent.onSelection)
        #expect(try symbol(selected).color == onSelection)
    }

    // The headings aren't among the rows the user chose: their line icons stay, in the accent the app is set to.
    // T-0ec3e044
    @Test func headingsKeepTheirLineIconsInTheAppsAccent() throws {
        let headings = [
            cell(.favoritesRoot, id: .favoritesRoot, icon: .star, path: nil),
            cell(.locationsRoot, id: .locationsRoot, icon: .drive, path: nil),
        ]
        for row in headings {
            let view = try iconView(row)
            guard case .heading(_, let color) = view.content else {
                Issue.record("a heading has no line icon")
                continue
            }
            #expect(color == ChromeColors.color(SidebarColors.theme(for: row).accent.solid))
            #expect(view.subviews.compactMap { $0 as? NSImageView }.first?.isHidden == true)
            #expect(InkScan.ink(view) != nil)
        }
        // The original's paths (`resolveFavoriteIconPath`).
        #expect(SidebarIcons.Heading.favorites.path.hasPrefix("M12 4.5l2.2 4.45"))
        #expect(SidebarIcons.Heading.locations.path.hasPrefix("M5 7.5h14l1.5 4.5H3.5z"))
    }

    @Test func aFolderRowKeepsItsOwnIcon() throws {
        let row = cell(.filesystem, id: .filesystem("/x"), icon: nil, path: "/x")
        guard case .folder = try iconView(row).content else {
            Issue.record("not a folder's icon")
            return
        }
        #expect(try iconView(row).subviews.compactMap { $0 as? NSImageView }.first?.isHidden == true)
    }

    // The tree's rows are the same row.
    @Test func theGraySelectionIsTheSystemsFill() {
        for (kind, id) in [(TreeItemKind.favorite, TreeItemID.favorite("/x")), (.filesystem, .filesystem("/x"))] {
            let inactive = cell(kind, id: id, icon: nil, path: "/x", selection: .inactive)
            #expect(inactive.box.fill == .systemFill)
            let focused = cell(kind, id: id, icon: nil, path: "/x", selection: .focused)
            #expect(focused.box.fill == ChromeColors.color(SidebarColors.theme(for: focused).accent.selectionBg))
        }
    }

    // The picker's fixed boxes hold every symbol whole.
    @Test func thePickersSymbolsFitTheirBoxes() throws {
        final class Box: NSView {
            var icon = FavoriteIconID.home
            override var isFlipped: Bool { true }
            override func draw(_ dirtyRect: NSRect) {
                SidebarIcons.drawFavorite(icon, in: NSRect(x: 6, y: 6, width: 18, height: 18), color: .black)
            }
        }
        let box = Box(frame: NSRect(x: 0, y: 0, width: 30, height: 30))
        for icon in FavoriteIconID.allCases {
            box.icon = icon
            let ink = try #require(InkScan.ink(box), "no ink for \(icon)")
            #expect(ink.minX >= 5.5 && ink.maxX <= 24.5 && ink.minY >= 5.5 && ink.maxY <= 24.5, "\(icon): \(ink)")
        }
    }
}
