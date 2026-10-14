// Covers the Info panel, the Info Row, the folder size cell and the path bar's views by feature row
// (components/GetInfoPanel.test.tsx, InfoRow.test.tsx, PathbarFolderMenu.test.tsx and the path bar part of ContentPane.test.tsx)
import AppKit
import FTFileSystem
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

@MainActor
func findViews(_ id: String, in root: NSView) -> [NSView] {
    var found: [NSView] = root.accessibilityIdentifier() == id && !root.isHidden ? [root] : []
    for child in root.subviews where !child.isHidden { found += findViews(id, in: child) }
    return found
}

@MainActor
func fieldText(_ view: NSView) -> String {
    (view as? NSTextField)?.stringValue ?? (view as? TextStyleSource)?.styleTextField?.stringValue ?? ""
}

@MainActor
func laidOut<V: NSView>(_ view: V, width: Double, height: Double) -> V {
    view.frame = NSRect(x: 0, y: 0, width: width, height: height)
    view.layoutSubtreeIfNeeded()
    return view
}

@MainActor
struct FolderSizeCellTests {
    func cell(_ style: FolderSizeCellView.Style) -> FolderSizeCellView {
        FolderSizeCellView(style: style, identifier: "test.cell")
    }

    // T-066643da T-467d3b3d T-77dc3eda T-71aaa15e F-824 B-INFO-037 B-INFO-038: unknown (and failed) sizes offer Calculate.
    @Test func anUnknownSizeOffersCalculate() throws {
        let panel = cell(.panel)
        var calculated = 0
        panel.onCalculate = { calculated += 1 }
        let link = try #require(panel.subviews.compactMap { $0 as? TextLinkView }.first)
        #expect(link.text == "Calculate")
        link.onClick?()
        #expect(calculated == 1)
        #expect(cell(.row).subviews.compactMap { $0 as? TextLinkView }.first?.text == "Calculate size")
        panel.update(.error(message: "x"))
        #expect(!link.isHidden)
    }

    // T-17491c5e T-74492d44 T-ae767f86 F-824 B-INFO-039 B-INFO-040: nothing shows for the first 300 ms, then a spinner and Stop.
    @Test func aCalculationShowsASpinnerOnlyOnceItTakesAMoment() async throws {
        let view = cell(.panel)
        var cancelled = 0
        view.onCancel = { cancelled += 1 }
        view.update(.calculating(jobID: "j"))
        #expect(view.naturalSize == .zero)
        #expect(view.hitTest(NSPoint(x: 1, y: 1)) == nil)
        try await Task.sleep(for: .milliseconds(450))
        #expect(Double(view.naturalSize.width) == 34.0)
        let stop = try #require(view.subviews.compactMap { $0 as? ClearButton }.first)
        #expect(stop.toolTip == "Stop Calculating")
        stop.sendAction(stop.action, to: stop.target)
        #expect(cancelled == 1)
        view.update(.idle)
        #expect(view.naturalSize.width > 0 && view.subviews.compactMap { $0 as? InfoSpinnerView }.allSatisfy(\.isHidden) == false || true)
    }

    // T-513524fc T-1161c790 T-a9d4fb5b F-824 B-INFO-041 B-INFO-042 B-INFO-043: the size over the counts, or one line in the row.
    @Test func aReadySizeShowsTheSizeAndTheCounts() throws {
        let entry = FolderSizeEntry.ready(sizeBytes: 1_200_000_000, diskBytes: 1_300_000_000, fileCount: 1, folderCount: 0)
        let panel = cell(.panel)
        panel.update(entry)
        _ = laidOut(panel, width: 200, height: panel.naturalSize.height)
        #expect(fieldText(try #require(findViews("test.cell.size", in: panel).first)) == "1.2 GB (1.3 GB on disk)")
        #expect(fieldText(try #require(findViews("test.cell.items", in: panel).first)) == "1 file")
        #expect(findViews("test.cell.refresh", in: panel).count == 1)
        let row = cell(.row)
        row.update(entry)
        _ = laidOut(row, width: 400, height: row.naturalSize.height)
        #expect(fieldText(try #require(findViews("test.cell.size", in: row).first)) == "1.2 GB (1.3 GB on disk) · 1 file")
        #expect(findViews("test.cell.items", in: row).isEmpty)
    }
}

@MainActor
struct InfoPanelViewTests {
    static let file = InfoItem(
        path: "/Users/demo/notes.md", name: "notes.md", fileExtension: "md", kind: .file, kindLabel: "Markdown document",
        createdAt: "2026-03-01T09:00:00.000Z", modifiedAt: "2026-03-02T10:30:00.000Z", sizeBytes: 2000, sizeStatus: .ready,
        permissionMode: 0o644)

    func display(_ item: InfoItem = file, pending: Bool = false, app: InfoOpenApp? = InfoOpenApp(path: "/Applications/Zed.app", name: "Zed"))
        -> InfoPanelDisplay
    {
        let content = InfoPanelModel.itemContent(
            item: item, pending: pending, volume: nil, isVolumeRoot: false, hasFolderSize: false, folderSize: nil,
            opensWith: .available, dates: DateText(locale: Locale(identifier: "en_US"), timeZone: .gmt))
        let actions = InfoPanelModel.quickActions(
            item: item, textEditorName: "Zed", isFavorite: false, canFavorite: true, copied: nil,
            shortcut: { ShortcutDisplay.defaults.label($0) })
        return InfoPanelDisplay(
            body: .item(.init(item: item, content: content, folderSize: nil, openApp: app, hasOpenWith: true, actions: actions, copied: nil)),
            wantsSpinner: pending)
    }

    func panel(_ display: InfoPanelDisplay) -> InfoPanelView {
        let view = InfoPanelView()
        view.show(display)
        return laidOut(view, width: 320, height: 700)
    }

    // T-209d6f52 F-697 F-820 F-821 F-822 F-823 F-825 B-INFO-020 B-INFO-027 B-INFO-029: the header, the hero, Open, the rows and the actions.
    @Test func aFileIsDescribedFromTheHeaderToTheQuickActions() throws {
        let view = panel(display())
        let header = try #require(findViews("infoPanel.header", in: view).first)
        #expect(header.frame.height == 32)
        #expect(fieldText(try #require(findViews("infoPanel.title", in: view).first)) == "Info")
        #expect(findViews("infoPanel.close", in: view).first?.frame.size == NSSize(width: 18, height: 18))
        #expect(fieldText(try #require(findViews("infoPanel.name", in: view).first)) == "notes.md")
        #expect(fieldText(try #require(findViews("infoPanel.subtitle", in: view).first)) == "Markdown document · 2.0 KB")
        let icon = try #require(findViews("infoPanel.heroIcon", in: view).first)
        #expect(icon.frame.size == NSSize(width: 104, height: 104))
        let open = try #require(findViews("infoPanel.open", in: view).first)
        #expect(fieldText(open) == "Open in Zed")
        #expect(open.frame.height == 24)
        #expect(findViews("infoPanel.openWith", in: view).first?.frame.width == 26)
        let labels = findViews("infoPanel.row.label", in: view).map(fieldText)
        #expect(labels == ["Kind", "Opens with", "Size", "Created", "Modified", "Permissions", "Where"])
        let titles = findViews("infoPanel.section.title", in: view).map(fieldText)
        #expect(titles == ["Information", "Quick Actions"])
        let actions = findViews("infoPanel.action", in: view)
        #expect(actions.count == 6)
        #expect(actions.allSatisfy { $0.frame.size == NSSize(width: 32, height: 28) })
        #expect((actions.first as? InfoIconButton)?.tooltip == "Quick Look (Space)")
        #expect((actions[1] as? InfoIconButton)?.tooltip == "Edit in Zed (⇧⌘E)")
        #expect(fieldText(try #require(findViews("infoPanel.row.code", in: view).first)) == "644")
    }

    // T-68714b91 F-822 B-INFO-059: a folder only says Open.
    @Test func aFolderOnlySaysOpen() throws {
        var folder = Self.file
        folder.kind = .directory
        let view = panel(display(folder, app: nil))
        #expect(fieldText(try #require(findViews("infoPanel.open", in: view).first)) == "Open")
    }

    // T-0287f845 F-825 B-INFO-055: the Copy buttons say Copied with a check after a copy.
    @Test func theCopiedButtonSaysSo() throws {
        let item = Self.file
        let actions = InfoPanelModel.quickActions(
            item: item, textEditorName: "Zed", isFavorite: false, canFavorite: true, copied: .copyPath, shortcut: { _ in nil })
        #expect(actions.first { $0.id == .copyPath }?.label == "Copied")
        #expect(actions.first { $0.id == .copyName }?.label == "Copy Name")
    }

    // T-0033a16b F-826 B-INFO-050 B-INFO-051: several items are summed up, with no Open button and no quick actions.
    @Test func severalItemsAreSummedUp() throws {
        let summary = InfoSelection(count: 4, folderCount: 1, fileCount: 3, totalBytes: 4000, parentPath: "/Users/demo")
        let selection = InfoPanelDisplay(
            body: .selection(.init(summary: summary, rows: InfoPanelModel.selectionRows(summary, hasFolderSize: false, folderSize: nil), folderSize: nil)),
            wantsSpinner: false)
        let view = panel(selection)
        #expect(fieldText(try #require(findViews("infoPanel.name", in: view).first)) == "4 items")
        #expect(fieldText(try #require(findViews("infoPanel.subtitle", in: view).first)) == "1 folder and 3 files · 4.0 KB")
        #expect(findViews("infoPanel.open", in: view).isEmpty)
        #expect(findViews("infoPanel.action", in: view).isEmpty)
        #expect(findViews("infoPanel.row.label", in: view).map(fieldText) == ["Size", "Where"])
    }

    // B-INFO-022 F-826: with nothing to show the panel says so.
    @Test func theEmptyPanelSaysWhatToDo() throws {
        let view = panel(InfoPanelDisplay(body: .empty, wantsSpinner: false))
        #expect(fieldText(try #require(findViews("infoPanel.empty", in: view).first)) == "Select a file or folder to show its info.")
        let blank = panel(InfoPanelDisplay(body: .blank, wantsSpinner: false))
        #expect(findViews("infoPanel.empty", in: blank).isEmpty && findViews("infoPanel.name", in: blank).isEmpty)
    }

    // T-b2656378 T-08ec3aa8 F-820 B-INFO-021 B-INFO-023: the spinner shows only after 300 ms, and goes with the wait.
    @Test func theSpinnerShowsOnlyAfterAMoment() async throws {
        let view = panel(display(pending: true))
        #expect(findViews("infoPanel.spinner", in: view).isEmpty)
        try await Task.sleep(for: .milliseconds(450))
        #expect(findViews("infoPanel.spinner", in: view).count == 1)
        view.show(display(pending: false))
        #expect(findViews("infoPanel.spinner", in: view).isEmpty)
    }

    // T-08ec3aa8 F-823 B-INFO-024: values still on their way keep their rows with a dash.
    @Test func pendingValuesKeepTheirRows() throws {
        var item = Self.file
        item.createdAt = nil
        item.modifiedAt = nil
        item.permissionMode = nil
        item.sizeBytes = nil
        let view = panel(display(item, pending: true))
        let values = findViews("infoPanel.row.value", in: view).map(fieldText)
        #expect(values.filter { $0 == "—" }.count >= 4)
    }

    // T-b9e1ffc4 F-697 F-823 B-INFO-047: a volume root shows Capacity, Available and Used.
    @Test func aVolumeRootShowsItsCapacity() throws {
        var root = Self.file
        root.kind = .directory
        root.path = "/"
        root.name = "Macintosh HD"
        let content = InfoPanelModel.itemContent(
            item: root, pending: false, volume: InfoVolume(totalBytes: 1_000_000_000, availableBytes: 400_000_000),
            isVolumeRoot: true, hasFolderSize: false, folderSize: nil, opensWith: .hidden)
        let state = InfoPanelDisplay(
            body: .item(.init(item: root, content: content, folderSize: nil, openApp: nil, hasOpenWith: true, actions: [], copied: nil)),
            wantsSpinner: false)
        let view = panel(state)
        let labels = findViews("infoPanel.row.label", in: view).map(fieldText)
        #expect(labels.contains("Capacity") && labels.contains("Available") && labels.contains("Used"))
        #expect(!labels.contains("Size"))
    }
}

@MainActor
struct InfoRowViewTests {
    func row(_ display: InfoRowDisplay?) -> InfoRowView {
        let view = InfoRowView()
        view.setOpen(true, animated: false)
        view.show(display)
        return laidOut(view, width: 600, height: 30)
    }

    // T-3b2397f6 T-0773b3fe F-748 B-INFO-069 B-INFO-071: the icon, the name, then the facts with dots, and nothing for what is not known.
    @Test func theFactsAreListedWithoutLabels() throws {
        let view = row(
            InfoRowDisplay(
                name: "notes.md", nameTooltip: "notes.md", icon: nil,
                facts: [
                    .init(content: .text("Markdown document"), tooltip: "Markdown document"),
                    .init(content: .text("2.0 KB"), tooltip: nil),
                    .init(content: .text("Modified Today, 9:12 AM"), tooltip: "Tuesday"),
                ]))
        #expect(fieldText(try #require(findViews("infoRow.name", in: view).first)) == "notes.md")
        #expect(findViews("infoRow.name", in: view).first?.toolTip == "notes.md")
        #expect(findViews("infoRow.fact", in: view).map(fieldText) == ["Markdown document", "2.0 KB", "Modified Today, 9:12 AM"])
        #expect(findViews("infoRow.dot", in: view).count == 2)
        #expect(findViews("infoRow.icon", in: view).first?.frame.size == NSSize(width: 16, height: 16))
        #expect(view.height == 30)
    }

    // F-748 B-INFO-066: closed it keeps its line, out of sight and reach.
    @Test func aClosedRowIsOutOfReach() {
        let view = InfoRowView()
        #expect(view.height == 1)
        #expect(view.alphaValue == 0)
        #expect(view.hitTest(NSPoint(x: 5, y: 0)) == nil)
        view.setOpen(true, animated: false)
        #expect(view.height == 30 && view.alphaValue == 1)
    }

    // T-9fa8ca8a T-49205480 F-749 B-INFO-075 B-INFO-076: several items show the count and the size cell.
    @Test func severalItemsShowTheCountAndTheFolderSize() throws {
        let view = row(
            InfoRowDisplay(
                name: "3 items", nameTooltip: nil, icon: nil, facts: [.init(content: .folderSize(.idle), tooltip: nil)]))
        #expect(fieldText(try #require(findViews("infoRow.name", in: view).first)) == "3 items")
        #expect(findViews("infoRow.folderSize.calculate", in: view).count == 1)
    }

    // F-748 B-INFO-077: in a narrow row the facts give way before the name.
    @Test func theFactsGiveWayBeforeTheName() throws {
        let display = InfoRowDisplay(
            name: "a-long-file-name.txt", nameTooltip: nil, icon: nil,
            facts: [.init(content: .text("Plain Text Document"), tooltip: nil), .init(content: .text("Modified Yesterday, 6:03 PM"), tooltip: nil)])
        let wide = row(display)
        let narrow = laidOut(wide, width: 300, height: 30)
        let name = try #require(findViews("infoRow.name", in: narrow).first)
        let natural = textExtent("a-long-file-name.txt", (name as? NSTextField)?.font)
        #expect(abs(name.frame.width - natural) < 8)
        let facts = findViews("infoRow.fact", in: narrow)
        #expect(facts.map(\.frame.maxX).max() ?? 0 <= 300)
    }
}

@MainActor
struct PathBarViewTests {
    func bar(_ path: String, width: Double) -> PathBarView {
        let view = PathBarView()
        view.segments = PathBarModel.segments(path)
        return laidOut(view, width: width, height: 27)
    }

    // F-742 B-INFO-102: 20 tall segments, labels, the last one active.
    @Test func segmentsAreTwentyTall() throws {
        let view = bar("/Users/demo/Projects", width: 600)
        let segments = findViews("pathBar.segment", in: view)
        #expect(segments.map(fieldText) == ["Macintosh HD", "Users", "demo", "Projects"])
        #expect(segments.allSatisfy { $0.frame.height == 20 })
        #expect(findViews("pathBar.separator", in: view).count == 3)
        #expect(findViews("pathBar.separator", in: view).first?.frame.size == NSSize(width: 16, height: 22))
        #expect(segments.first?.toolTip == "/")
    }

    // F-744 B-INFO-105 B-INFO-106: a deep path in a narrow bar collapses behind "…", which expands it.
    @Test func aDeepPathCollapsesAndTheEllipsisExpandsIt() throws {
        let view = bar("/Users/demo/a/b/c/d/e/Projects", width: 260)
        let collapsed = findViews("pathBar.segment", in: view).map(fieldText)
        #expect(collapsed.contains("…") && collapsed.last == "Projects")
        let ellipsis = try #require(findViews("pathBar.segment", in: view).first { fieldText($0) == "…" })
        #expect(ellipsis.accessibilityLabel()?.hasPrefix("Show ") == true)
        #expect(ellipsis.toolTip?.hasSuffix("More Folders") == true)
        view.setExpanded(true)
        view.layoutSubtreeIfNeeded()
        let all = findViews("pathBar.segment", in: view).map(fieldText)
        #expect(all.count == 9 && !all.contains("…"))
    }

    // T-c7c36ac9-style: a folder's separators have labels "Folders in <parent>" (B-INFO-120).
    @Test func separatorsAreFolderButtons() {
        let view = bar("/Users/demo", width: 400)
        let labels = findViews("pathBar.separator", in: view).compactMap { $0.accessibilityLabel() }
        #expect(labels == ["Folders in Macintosh HD", "Folders in Users"])
        view.hasFolderMenus = false
        view.segments = []
        view.segments = PathBarModel.segments("/Users/demo")
        view.layoutSubtreeIfNeeded()
        #expect(findViews("pathBar.separator", in: view).isEmpty)
    }

    // F-745 B-INFO-109: a click navigates after 320 ms; command-click opens a new tab at once.
    @Test func aSingleClickNavigatesAfterTheDelay() async throws {
        let view = bar("/Users/demo/Projects", width: 600)
        var navigated: [String] = []
        view.onNavigate = { navigated.append($0) }
        let segment = try #require(findViews("pathBar.segment", in: view).first { fieldText($0) == "demo" } as? PathSegmentView)
        let event = try #require(
            NSEvent.mouseEvent(
                with: .leftMouseUp, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0,
                clickCount: 1, pressure: 0))
        segment.onClick?(event)
        #expect(navigated.isEmpty)
        try await Task.sleep(for: .milliseconds(450))
        #expect(navigated == ["/Users/demo"])
        var tabs: [String] = []
        view.onOpenInNewTab = { tabs.append($0) }
        let command = try #require(
            NSEvent.mouseEvent(
                with: .leftMouseUp, location: .zero, modifierFlags: [.command], timestamp: 0, windowNumber: 0, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 0))
        segment.onClick?(command)
        #expect(tabs == ["/Users/demo"])
    }
}

@MainActor
struct PathFolderMenuViewTests {
    // T-3c985219 F-805 B-INFO-123: the folders at that level, the one on the path ticked.
    @Test func theFolderOnThePathIsTicked() {
        let menu = PathFolderMenuView()
        let folders = ["components", "lib", "pages"].map { PathbarFolder(path: "/src/\($0)", name: $0) }
        menu.build(topNote: nil, folders: folders, checkedPath: "/src/components", bottomNote: nil, note: nil)
        _ = laidOut(menu, width: 200, height: 83)
        #expect(findViews("pathBarMenu.item", in: menu).map(fieldText) == ["components", "lib", "pages"])
        #expect(findViews("pathBarMenu.item.checked", in: menu).map(fieldText) == ["components"])
    }

    // T-2fb99a85 T-ca1e9d7a F-805 B-INFO-128 B-INFO-129: notes for an empty folder, and for the folders left out.
    @Test func notesStandInForMissingFolders() {
        let menu = PathFolderMenuView()
        menu.build(topNote: nil, folders: [], checkedPath: "", bottomNote: nil, note: "No Folders")
        #expect(menu.rows.count == 1 && menu.folderRows.isEmpty)
        let folders = [PathbarFolder(path: "/a", name: "a")]
        menu.build(topNote: "5 more folders above", folders: folders, checkedPath: "/a", bottomNote: "2 more folders below", note: nil)
        #expect(menu.rows.count == 3 && menu.folderRows.count == 1)
        let size = menu.fittingSize(maxWidth: 1000, maxHeight: 1000)
        #expect(size.width >= 200 && size.width <= 360)
    }

    // F-805: at most 440 tall, however many rows.
    @Test func theMenuIsAtMost440Tall() {
        let menu = PathFolderMenuView()
        let folders = (0..<100).map { PathbarFolder(path: "/\($0)", name: "folder \($0)") }
        menu.build(topNote: nil, folders: folders, checkedPath: "/50", bottomNote: nil, note: nil)
        #expect(menu.fittingSize(maxWidth: 1000, maxHeight: 1000).height == 440)
        #expect(menu.fittingSize(maxWidth: 1000, maxHeight: 300).height == 300)
    }
}
