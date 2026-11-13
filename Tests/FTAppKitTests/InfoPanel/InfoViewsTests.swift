import AppKit
import FTFileSystem
import FTFoundation
import FTTestSupport
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

    // Unknown (and failed) sizes offer Calculate.
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

    // A spinner turns in place: about its own center, wherever it is put and however often, and never by the view's
    // own layer, whose anchor and position AppKit sets again with each new frame.
    @Test func aSpinnerTurnsAboutItsOwnCenterWhereverItIsPut() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.borderless], backing: .buffered,
            defer: true)
        window.isReleasedWhenClosed = false
        let host = try #require(window.contentView)
        let spinner = InfoSpinnerView()
        host.addSubview(spinner)
        for frame in [
            NSRect(x: 40, y: 60, width: 12, height: 12), NSRect(x: 120, y: 10, width: 12, height: 12),
            NSRect(x: 5, y: 150, width: 20, height: 20),
        ] {
            spinner.frame = frame
            host.layoutSubtreeIfNeeded()
            #expect(spinner.ringCenter == CGPoint(x: frame.width / 2, y: frame.height / 2))
            let layer = try #require(spinner.layer)
            #expect(layer.animationKeys()?.isEmpty ?? true)
            #expect(CATransform3DIsIdentity(layer.transform))
            #expect(layer.sublayers?.contains { $0.animation(forKey: "spin") != nil } == true)
        }
        window.close()
    }

    // Nothing shows for the first 300 ms, then a spinner and Stop.
    @Test func aCalculationShowsASpinnerOnlyOnceItTakesAMoment() async throws {
        let view = cell(.panel)
        var cancelled = 0
        view.onCancel = { cancelled += 1 }
        view.update(.calculating(jobID: "j"))
        #expect(view.naturalSize == .zero)
        #expect(view.hitTest(NSPoint(x: 1, y: 1)) == nil)
        #expect(await waitUntil { Double(view.naturalSize.width) == 34.0 })
        let stop = try #require(view.subviews.compactMap { $0 as? ClearButton }.first)
        #expect(stop.toolTip == "Stop Calculating")
        stop.sendAction(stop.action, to: stop.target)
        #expect(cancelled == 1)
        view.update(.idle)
        view.layout()
        #expect(view.naturalSize.width > 0)
        let spinners = view.subviews.compactMap { $0 as? InfoSpinnerView }
        #expect(spinners.allSatisfy { $0.isHidden })
        #expect(view.subviews.compactMap { $0 as? TextLinkView }.first?.isHidden == false)
    }

    // The Info Row keeps the size and the counts on one line.
    @Test func aReadySizeInTheRowShowsTheSizeAndTheCounts() throws {
        let entry = FolderSizeEntry.ready(
            sizeBytes: 1_200_000_000, diskBytes: 1_300_000_000, fileCount: 1, folderCount: 0)
        let row = cell(.row)
        row.update(entry)
        _ = laidOut(row, width: 400, height: row.naturalSize.height)
        #expect(
            fieldText(try #require(findViews("test.cell.size", in: row).first)) == "1.2 GB (1.3 GB on disk) · 1 file")
        #expect(findViews("test.cell.items", in: row).isEmpty)
    }
}

@MainActor
struct InfoPanelViewTests {
    static let file = InfoItem(
        path: "/Users/demo/notes.md", name: "notes.md", fileExtension: "md", kind: .file,
        kindLabel: "Markdown document",
        createdAt: ISODateForTests.date("2026-03-01T09:00:00.000Z"),
        modifiedAt: ISODateForTests.date("2026-03-02T10:30:00.000Z"), sizeBytes: 2000,
        sizeStatus: .ready,
        permissionMode: 0o644)

    func display(
        _ item: InfoItem = file, pending: Bool = false,
        app: InfoOpenApp? = InfoOpenApp(path: "/Applications/Zed.app", name: "Zed")
    )
        -> InfoPanelDisplay
    {
        let content = InfoPanelModel.itemContent(
            item: item, pending: pending, volume: nil, isVolumeRoot: false, hasFolderSize: false, folderSize: nil,
            opensWith: .available, dates: DateText(locale: Locale(identifier: "en_US"), timeZone: .gmt))
        let actions = InfoPanelModel.quickActions(
            item: item, textEditorName: "Zed", isFavorite: false, canFavorite: true, copied: nil,
            shortcut: { ShortcutDisplay.defaults.label($0) })
        return InfoPanelDisplay(
            body: .item(
                .init(
                    item: item, content: content, folderSize: nil, openApp: app, actions: actions,
                    copied: nil)),
            wantsSpinner: pending)
    }

    func panel(_ display: InfoPanelDisplay) -> InfoPanelView {
        let view = InfoPanelView()
        view.show(display)
        return laidOut(view, width: 320, height: 700)
    }

    // The header, the hero, Open, the rows and the actions.
    @Test func aFileIsDescribedFromTheHeaderToTheQuickActions() throws {
        let view = panel(display())
        let header = try #require(findViews("infoPanel.header", in: view).first)
        #expect(header.frame.height == 32)
        #expect(fieldText(try #require(findViews("infoPanel.title", in: view).first)) == "Info")
        #expect(findViews("infoPanel.close", in: view).first?.frame.size == NSSize(width: 18, height: 18))
        #expect(fieldText(try #require(findViews("infoPanel.name", in: view).first)) == "notes.md")
        #expect(
            fieldText(try #require(findViews("infoPanel.subtitle", in: view).first)) == "Markdown document · 2.0 KB")
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

    // A folder only says Open.
    @Test func aFolderOnlySaysOpen() throws {
        var folder = Self.file
        folder.kind = .directory
        let view = panel(display(folder, app: nil))
        #expect(fieldText(try #require(findViews("infoPanel.open", in: view).first)) == "Open")
    }

    func folderDisplay(_ entry: FolderSizeEntry) -> InfoPanelDisplay {
        var folder = Self.file
        folder.path = "/Users/demo/notes"
        folder.kind = .directory
        folder.kindLabel = "Folder"
        let content = InfoPanelModel.itemContent(
            item: folder, pending: false, volume: nil, isVolumeRoot: false, hasFolderSize: true, folderSize: entry,
            opensWith: .hidden, dates: DateText(locale: Locale(identifier: "en_US"), timeZone: .gmt))
        return InfoPanelDisplay(
            body: .item(
                .init(
                    item: folder, content: content, folderSize: entry, openApp: nil, actions: [],
                    copied: nil)),
            wantsSpinner: false)
    }

    func rowTops(_ view: NSView) -> [Double] {
        findViews("infoPanel.row.label", in: view).map { Double($0.frame.minY) }
    }

    // Every row is in the same place for an unmeasured folder, a measured one and a file.
    @Test func theRowsStayInPlaceWhileAFolderIsMeasuredAndFromAFileToAFolder() async throws {
        let file = panel(display())
        let fileRows = findViews("infoPanel.row.label", in: file).map(fieldText)
        #expect(fileRows.prefix(3) == ["Kind", "Opens with", "Size"])

        let idle = panel(folderDisplay(.idle))
        #expect(findViews("infoPanel.row.label", in: idle).map(fieldText).prefix(3) == ["Kind", "Contains", "Size"])
        #expect(rowTops(idle) == rowTops(file))
        #expect(findViews("infoPanel.folderSize.calculate", in: idle).count == 1)
        #expect(findViews("infoPanel.folderSize.size", in: idle).isEmpty)

        let failed = panel(folderDisplay(.error(message: "x")))
        #expect(rowTops(failed) == rowTops(file))

        let measured = panel(
            folderDisplay(.ready(sizeBytes: 140_000, diskBytes: 143_000, fileCount: 2, folderCount: 1)))
        #expect(rowTops(measured) == rowTops(file))
        #expect(findViews("infoPanel.row.value", in: measured).map(fieldText).contains("2 files, 1 folder"))
        #expect(
            fieldText(try #require(findViews("infoPanel.folderSize.size", in: measured).first))
                == "140 KB (143 KB on disk)")
        #expect(findViews("infoPanel.folderSize.items", in: measured).isEmpty)
        #expect(findViews("infoPanel.folderSize.refresh", in: measured).count == 1)
        #expect(findViews("infoPanel.folderSize.calculate", in: measured).isEmpty)

        // The same panel, as the measurement goes on: the spinner and Stop keep to the one line.
        let live = panel(folderDisplay(.idle))
        live.show(folderDisplay(.calculating(jobID: "j")))
        live.layoutSubtreeIfNeeded()
        #expect(rowTops(live) == rowTops(file))
        #expect(
            await waitUntil {
                live.layoutSubtreeIfNeeded()
                return findViews("infoPanel.folderSize.stop", in: live).count == 1
            })
        #expect(rowTops(live) == rowTops(file))
        live.show(folderDisplay(.ready(sizeBytes: 140_000, diskBytes: 143_000, fileCount: 2, folderCount: 1)))
        live.layoutSubtreeIfNeeded()
        #expect(rowTops(live) == rowTops(file))
        #expect(findViews("infoPanel.folderSize.stop", in: live).isEmpty)
    }

    // Size has the size and disk size, and the counts are in the Contains row beside its label.
    @Test func aReadyFolderShowsItsSizeAndWhatItContains() throws {
        let view = panel(
            folderDisplay(.ready(sizeBytes: 1_048_576, diskBytes: 1_572_864, fileCount: 43016, folderCount: 3)))
        let size = fieldText(try #require(findViews("infoPanel.folderSize.size", in: view).first))
        #expect(size.contains("1.0 MB") && size.contains("on disk"))
        let label = try #require(findViews("infoPanel.row.label", in: view).first { fieldText($0) == "Contains" })
        let value = try #require(
            findViews("infoPanel.row.value", in: view).first { fieldText($0) == "43,016 files, 3 folders" })
        #expect(value.frame.minY < label.frame.maxY && label.frame.minY < value.frame.maxY)
        let refresh = try #require(findViews("infoPanel.folderSize.refresh", in: view).first)
        #expect(refresh.accessibilityLabel() == "Recalculate folder size")
    }

    // The measured Size row recalculates from its one line.
    @Test func theMeasuredSizeRecalculates() throws {
        let view = panel(folderDisplay(.ready(sizeBytes: 1000, diskBytes: 1000, fileCount: 1, folderCount: 0)))
        var recalculated = 0
        view.onRecalculate = { recalculated += 1 }
        let refresh = try #require(findViews("infoPanel.folderSize.refresh", in: view).first as? InfoIconButton)
        refresh.onClick?()
        #expect(recalculated == 1)
    }

    // Several items with folders among them have Contains above Size.
    @Test func severalItemsWithFoldersHaveAContainsRow() {
        let summary = InfoSelection(count: 2, folderCount: 1, fileCount: 1, totalBytes: nil, parentPath: "/Users/demo")
        let selection = InfoPanelDisplay(
            body: .selection(
                .init(
                    summary: summary,
                    rows: InfoPanelModel.selectionRows(summary, hasFolderSize: true, folderSize: .idle),
                    folderSize: .idle)),
            wantsSpinner: false)
        #expect(findViews("infoPanel.row.label", in: panel(selection)).map(fieldText) == ["Contains", "Size", "Where"])
    }

    // The Copy buttons say Copied with a check after a copy.
    @Test func theCopiedButtonSaysSo() throws {
        let item = Self.file
        let actions = InfoPanelModel.quickActions(
            item: item, textEditorName: "Zed", isFavorite: false, canFavorite: true, copied: .copyPath,
            shortcut: { _ in nil })
        #expect(actions.first { $0.id == .copyPath }?.label == "Copied")
        #expect(actions.first { $0.id == .copyName }?.label == "Copy Name")
    }

    // Several items are summed up, with no Open button and no quick actions.
    @Test func severalItemsAreSummedUp() throws {
        let summary = InfoSelection(count: 4, folderCount: 1, fileCount: 3, totalBytes: 4000, parentPath: "/Users/demo")
        let selection = InfoPanelDisplay(
            body: .selection(
                .init(
                    summary: summary,
                    rows: InfoPanelModel.selectionRows(summary, hasFolderSize: false, folderSize: nil), folderSize: nil)
            ),
            wantsSpinner: false)
        let view = panel(selection)
        #expect(fieldText(try #require(findViews("infoPanel.name", in: view).first)) == "4 items")
        #expect(
            fieldText(try #require(findViews("infoPanel.subtitle", in: view).first)) == "1 folder and 3 files · 4.0 KB")
        #expect(findViews("infoPanel.open", in: view).isEmpty)
        #expect(findViews("infoPanel.action", in: view).isEmpty)
        #expect(findViews("infoPanel.row.label", in: view).map(fieldText) == ["Size", "Where"])
    }

    // With nothing to show the panel says so.
    @Test func theEmptyPanelSaysWhatToDo() throws {
        let view = panel(InfoPanelDisplay(body: .empty, wantsSpinner: false))
        #expect(
            fieldText(try #require(findViews("infoPanel.empty", in: view).first))
                == "Select a file or folder to show its info.")
        let blank = panel(InfoPanelDisplay(body: .blank, wantsSpinner: false))
        #expect(findViews("infoPanel.empty", in: blank).isEmpty && findViews("infoPanel.name", in: blank).isEmpty)
    }

    // The spinner shows only after 300 ms, and goes with the wait.
    @Test func theSpinnerShowsOnlyAfterAMoment() async throws {
        let view = panel(display(pending: true))
        #expect(findViews("infoPanel.spinner", in: view).isEmpty)
        #expect(await waitUntil { findViews("infoPanel.spinner", in: view).count == 1 })
        view.show(display(pending: false))
        #expect(findViews("infoPanel.spinner", in: view).isEmpty)
    }

    // Values still on their way keep their rows with a dash.
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

    // A volume root shows Capacity, Available and Used.
    @Test func aVolumeRootShowsItsCapacity() throws {
        var root = Self.file
        root.kind = .directory
        root.path = "/"
        root.name = "Macintosh HD"
        let content = InfoPanelModel.itemContent(
            item: root, pending: false, volume: InfoVolume(totalBytes: 1_000_000_000, availableBytes: 400_000_000),
            isVolumeRoot: true, hasFolderSize: false, folderSize: nil, opensWith: .hidden)
        let state = InfoPanelDisplay(
            body: .item(
                .init(
                    item: root, content: content, folderSize: nil, openApp: nil, actions: [],
                    copied: nil)),
            wantsSpinner: false)
        let view = panel(state)
        let labels = findViews("infoPanel.row.label", in: view).map(fieldText)
        #expect(labels.contains("Capacity") && labels.contains("Available") && labels.contains("Used"))
        #expect(!labels.contains("Size"))
    }

    // The Open button keeps the icon of the shown item's app, however late the previous item's app icon arrives.
    @Test func aLateIconForThePreviousItemsAppDoesNotReplaceTheCurrentOne() async throws {
        let old = "/Applications/Old.app"
        let current = "/Applications/Current.app"
        let source = HeldAppIcons(
            [
                old: NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1),
                current: NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1),
            ],
            held: [old])
        let store = FileIconStore(source: source)
        let view = InfoPanelView()
        view.iconStore = store
        view.show(display(app: InfoOpenApp(path: old, name: "Old")))
        view.show(display(app: InfoOpenApp(path: current, name: "Current")))
        let button = try #require(findViews("infoPanel.openGroup", in: view).first as? SplitOpenButton)
        #expect(await waitUntil { isBlue(button.appIcon) })
        source.letGo(old)
        #expect(
            await waitUntil {
                if case .missing = store.lookup(IconRequest.app(path: old)) { return false }
                return true
            })
        await settle()
        #expect(isBlue(button.appIcon))
    }

    // A quick action's tooltip covers the button once it is placed: the tooltip is one of the view's tracking areas,
    // sized when it is set (before the button is), and the button's own hover area replaces only its own.
    @Test func aQuickActionKeepsItsTooltipOncePlaced() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 900), styleMask: [.borderless], backing: .buffered,
            defer: true)
        window.isReleasedWhenClosed = false
        let view = panel(display())
        window.contentView?.addSubview(view)
        let button = try #require(findViews("infoPanel.action", in: view).first as? InfoIconButton)
        button.updateTrackingAreas()
        #expect(button.toolTip == "Quick Look (Space)")
        #expect(button.trackingAreas.contains { $0.owner !== button && $0.rect == button.bounds })
        #expect(button.trackingAreas.contains { $0.owner === button })
        let close = try #require(findViews("infoPanel.close", in: view).first)
        #expect(close.trackingAreas.contains { $0.owner !== close && $0.rect == close.bounds })
    }
}

@MainActor
struct OpensWithPopupViewTests {
    // With no app it reads None.
    @Test func opensWithReadsNoneWithNoApp() {
        let row = OpensWithPopupView()
        row.kindLabel = "Plain Text"
        row.app = nil
        #expect(findViews("infoPanel.opensWith.name", in: row).map(fieldText) == ["None"])
        #expect(row.accessibilityLabel() == "Opens with no app: change the app for every Plain Text")
        row.app = InfoOpenApp(path: "/Applications/Zed.app", name: "Zed")
        #expect(findViews("infoPanel.opensWith.name", in: row).map(fieldText) == ["Zed"])
        #expect(row.accessibilityLabel() == "Opens with Zed: change the app for every Plain Text")
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

    // The icon, the name, then the facts with dots, and nothing for what is not known.
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
        #expect(
            findViews("infoRow.fact", in: view).map(fieldText) == [
                "Markdown document", "2.0 KB", "Modified Today, 9:12 AM",
            ])
        #expect(findViews("infoRow.dot", in: view).count == 2)
        #expect(findViews("infoRow.icon", in: view).first?.frame.size == NSSize(width: 16, height: 16))
        #expect(view.height == 30)
    }

    // A row that goes away while it slides (its window closed) stops its timer, which would otherwise fire 60 times a
    // second until the app quits.
    @Test func aRowGoneWhileItSlidesStopsItsTimer() async throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 100), styleMask: [.borderless], backing: .buffered,
            defer: true)
        window.isReleasedWhenClosed = false
        var view: InfoRowView? = InfoRowView()
        window.contentView?.addSubview(try #require(view))
        // It slides whatever the system's Reduce Motion setting, which would open it at once, with no timer.
        view?.reducesMotion = { false }
        view?.setOpen(true, animated: true)
        let timer = try #require(view?.slideTimer)
        weak let gone = view
        autoreleasepool {
            view?.removeFromSuperview()
            view = nil
        }
        #expect(await waitUntil { gone == nil })
        #expect(await waitUntil { !timer.isValid })
    }

    // Closed it keeps its line, out of sight and reach.
    @Test func aClosedRowIsOutOfReach() {
        let view = InfoRowView()
        #expect(view.height == 1)
        #expect(view.alphaValue == 0)
        #expect(view.hitTest(NSPoint(x: 5, y: 0)) == nil)
        view.setOpen(true, animated: false)
        #expect(view.height == 30 && view.alphaValue == 1)
    }

    // Another selection that reads the same ("2 items") shows its own lead's icon.
    @Test func anotherSelectionOfTheSameShapeShowsItsOwnIcon() throws {
        func display(_ icon: IconEntry) -> InfoRowDisplay {
            InfoRowDisplay(
                name: "2 items", nameTooltip: nil, icon: icon, facts: [.init(content: .text("4 KB"), tooltip: nil)])
        }
        let folder = IconEntry(path: "/f/Folder", name: "Folder", kind: .directory)
        let file = IconEntry(path: "/f/notes.md", name: "notes.md", extension: "md")
        let view = row(display(folder))
        let icon = try #require(findViews("infoRow.icon", in: view).first as? InfoIconView)
        #expect(icon.shown == IconRequest(entry: folder).cacheKey)

        view.show(display(file))

        #expect(icon.shown == IconRequest(entry: file).cacheKey)
        #expect(IconRequest(entry: file).cacheKey != IconRequest(entry: folder).cacheKey)
    }

    // Several items show the count and the size cell.
    @Test func severalItemsShowTheCountAndTheFolderSize() throws {
        let view = row(
            InfoRowDisplay(
                name: "3 items", nameTooltip: nil, icon: nil, facts: [.init(content: .folderSize(.idle), tooltip: nil)])
        )
        #expect(fieldText(try #require(findViews("infoRow.name", in: view).first)) == "3 items")
        #expect(findViews("infoRow.folderSize.calculate", in: view).count == 1)
    }

    // In a narrow row the facts give way before the name.
    @Test func theFactsGiveWayBeforeTheName() throws {
        let display = InfoRowDisplay(
            name: "a-long-file-name.txt", nameTooltip: nil, icon: nil,
            facts: [
                .init(content: .text("Plain Text Document"), tooltip: nil),
                .init(content: .text("Modified Yesterday, 6:03 PM"), tooltip: nil),
            ])
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

    // 20 tall segments, labels, the last one active.
    @Test func segmentsAreTwentyTall() throws {
        let view = bar("/Users/demo/Projects", width: 600)
        let segments = findViews("pathBar.segment", in: view)
        #expect(segments.map(fieldText) == ["Macintosh HD", "Users", "demo", "Projects"])
        #expect(segments.allSatisfy { $0.frame.height == 20 })
        #expect(findViews("pathBar.separator", in: view).count == 3)
        #expect(findViews("pathBar.separator", in: view).first?.frame.size == NSSize(width: 16, height: 22))
        #expect(segments.first?.toolTip == "/")
    }

    // A deep path in a narrow bar collapses behind "…", which expands it.
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

    // The separators are buttons, each labelled "Folders in <parent>" for the folder before it.
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

    // A double click on a segment edits the path: the single click it began with doesn't navigate.
    @Test func aDoubleClickEditsThePathInsteadOfNavigating() async throws {
        func up(_ count: Int) throws -> NSEvent {
            try #require(
                NSEvent.mouseEvent(
                    with: .leftMouseUp, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                    context: nil, eventNumber: 0, clickCount: count, pressure: 0))
        }
        func segment(_ view: PathBarView) throws -> PathSegmentView {
            try #require(
                findViews("pathBar.segment", in: view).first { fieldText($0) == "demo" } as? PathSegmentView)
        }
        let view = bar("/Users/demo/Projects", width: 600)
        var navigated: [String] = []
        var edits = 0
        view.onNavigate = { navigated.append($0) }
        view.onEdit = { edits += 1 }
        let demo = try segment(view)
        demo.onClick?(try up(1))
        demo.onClick?(try up(2))
        demo.onDoubleClick?()
        #expect(edits == 1)

        // A click on another bar, made after: once it has navigated, the first click's moment has long passed.
        let other = bar("/Users/demo/Projects", width: 600)
        var otherNavigated: [String] = []
        other.onNavigate = { otherNavigated.append($0) }
        try segment(other).onClick?(try up(1))
        #expect(await waitUntil { otherNavigated == ["/Users/demo"] })
        #expect(navigated.isEmpty)
        #expect(edits == 1)
    }

    // A click navigates after 250 ms; command-click opens a new tab at once.
    @Test func aSingleClickNavigatesAfterTheDelay() async throws {
        let view = bar("/Users/demo/Projects", width: 600)
        var navigated: [String] = []
        view.onNavigate = { navigated.append($0) }
        let segment = try #require(
            findViews("pathBar.segment", in: view).first { fieldText($0) == "demo" } as? PathSegmentView)
        let event = try #require(
            NSEvent.mouseEvent(
                with: .leftMouseUp, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                eventNumber: 0,
                clickCount: 1, pressure: 0))
        segment.onClick?(event)
        #expect(navigated.isEmpty)
        #expect(await waitUntil { navigated == ["/Users/demo"] })
        var tabs: [String] = []
        view.onOpenInNewTab = { tabs.append($0) }
        let command = try #require(
            NSEvent.mouseEvent(
                with: .leftMouseUp, location: .zero, modifierFlags: [.command], timestamp: 0, windowNumber: 0,
                context: nil,
                eventNumber: 0, clickCount: 1, pressure: 0))
        segment.onClick?(command)
        #expect(tabs == ["/Users/demo"])
    }
}

@MainActor
@Suite(.serialized) struct PathFolderMenuViewTests {
    private func open(
        active: String, request: @escaping @MainActor (String) async throws -> [PathbarFolder]
    ) async throws -> AppMenu {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 500), styleMask: [.titled], backing: .buffered,
            defer: true)
        window.isReleasedWhenClosed = false
        let separator = PathSeparatorView(isButton: true)
        separator.frame = NSRect(x: 100, y: 100, width: 16, height: 16)
        window.contentView?.addSubview(separator)
        let controller = PathFolderMenuController()
        let presenter = AppMenuPresenter()
        return try await AppMenuPresenter.withOwn(presenter) {
            controller.toggle(from: separator, parent: "/src", active: active, request: request)
            _ = await waitUntil { presenter.menu?.rows.first?.title != "Loading…" && presenter.isOpen }
            return try #require(presenter.menu)
        }
    }

    // A path bar laid out again while a slow list loads (the window resized) replaces the separator the menu opened
    // from: the menu closes when the folders come, instead of staying on "Loading…".
    @Test func aMenuWhoseSeparatorWentClosesInsteadOfStayingOnLoading() async throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 500), styleMask: [.titled], backing: .buffered,
            defer: true)
        window.isReleasedWhenClosed = false
        var separator: PathSeparatorView? = PathSeparatorView(isButton: true)
        separator?.frame = NSRect(x: 100, y: 100, width: 16, height: 16)
        window.contentView?.addSubview(try #require(separator))
        let controller = PathFolderMenuController()
        let presenter = AppMenuPresenter()
        var answer: CheckedContinuation<Void, Never>?
        try await AppMenuPresenter.withOwn(presenter) {
            controller.toggle(from: try #require(separator), parent: "/src", active: "") { _ in
                await withCheckedContinuation { answer = $0 }
                return [PathbarFolder(path: "/src/lib", name: "lib")]
            }
            #expect(await waitUntil { presenter.menu?.rows.first?.title == "Loading…" })
            autoreleasepool {
                separator?.removeFromSuperview()
                separator = nil
            }
            answer?.resume()
            #expect(await waitUntil { presenter.menu == nil })
            #expect(!controller.isOpen)
        }
    }

    // The folders at that level, the one on the path ticked.
    @Test func theFolderOnThePathIsTicked() async throws {
        let folders = ["components", "lib", "pages"].map { PathbarFolder(path: "/src/\($0)", name: $0) }
        let menu = try await open(active: "/src/components") { _ in folders }
        #expect(menu.identifier == "pathBarMenu")
        #expect(menu.rows.map(\.title) == ["components", "lib", "pages"])
        #expect(menu.rows.filter { $0.checked == true }.map(\.title) == ["components"])
        #expect(menu.markedIndex == 0)
        #expect(menu.rows.map(\.tooltip) == folders.map(\.path))
    }

    // Notes for an empty folder, and for the folders left out.
    @Test func notesStandInForMissingFolders() async throws {
        let empty = try await open(active: "") { _ in [] }
        #expect(empty.rows.map(\.title) == ["No Folders"])
        #expect(empty.rows.map(\.enabled) == [false])
        #expect(empty.markedIndex == nil)
        let many = (0..<400).map { PathbarFolder(path: "/src/\($0)", name: "\($0)") }
        let limited = try await open(active: "/src/200") { _ in many }
        #expect(limited.rows.count == 302)
        #expect(limited.rows.first?.enabled == false && limited.rows.last?.enabled == false)
        #expect(limited.rows.first?.title.hasSuffix("above") == true)
        #expect(limited.rows.last?.title.hasSuffix("below") == true)
        #expect(limited.items[limited.markedIndex ?? 0].title == "200")
    }

    // The folders that replace "Loading…" keep the menu's bottom 6 pt over the button, and a list too tall for that
    // opens with the ticked folder at the button.
    @Test func aSlowFoldersListIsPlacedForItsOwnHeight() async throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 500), styleMask: [.titled], backing: .buffered,
            defer: true)
        window.isReleasedWhenClosed = false
        let host = try #require(window.contentView)
        let separator = PathSeparatorView(isButton: true)
        separator.frame = NSRect(x: 100, y: 100, width: 16, height: 16)
        host.addSubview(separator)
        let buttonTop = host.bounds.height - 116
        for count in [3, 300] {
            let controller = PathFolderMenuController()
            let presenter = AppMenuPresenter()
            let (slow, answer) = AsyncStream<Void>.makeStream()
            let folders = (0..<count).map { PathbarFolder(path: "/src/\($0)", name: "\($0)") }
            try await AppMenuPresenter.withOwn(presenter) {
                controller.toggle(from: separator, parent: "/src", active: "/src/1") { _ in
                    for await _ in slow {}
                    return folders
                }
                #expect(await waitUntil { presenter.isOpen })
                let menu = try #require(presenter.menu)
                #expect(menu.rows.map(\.title) == ["Loading…"])
                answer.finish()
                #expect(await waitUntil { menu.rows.first?.title != "Loading…" })
                let place = try #require(presenter.place)
                #expect(controller.isOpen && presenter.menu === menu)
                if count == 3 {
                    #expect(place.positioning == nil)
                    #expect(abs(place.top + menu.size.height - (buttonTop - InfoMetrics.folderMenuGap)) < 1)
                    let standIn = host.subviews.first { $0.accessibilityIdentifier() == "pathBarMenu" }
                    #expect(abs((standIn?.frame.minY ?? 0) - (116 + InfoMetrics.folderMenuGap)) < 1)
                } else {
                    #expect(abs(place.top - buttonTop) < 1)
                    #expect(place.positioning == menu.markedIndex && place.positioning != nil)
                }
                controller.close()
            }
        }
    }

    @Test func aFolderThatCantBeReadSaysSo() async throws {
        struct Failure: Error {}
        let menu = try await open(active: "") { _ in throw Failure() }
        #expect(menu.rows.map(\.title) == ["Can’t Read This Folder"])
    }
}

/// Draws each app's icon in a colour of its own; the icons of `held` paths wait until let go.
private final class HeldAppIcons: IconSource, @unchecked Sendable {
    private let colors: [String: NSColor]
    private let gates: [String: DispatchSemaphore]

    init(_ colors: [String: NSColor], held: [String]) {
        self.colors = colors
        gates = Dictionary(uniqueKeysWithValues: held.map { ($0, DispatchSemaphore(value: 0)) })
    }

    func letGo(_ path: String) { gates[path]?.signal() }

    func icon(atPath path: String) -> NSImage? {
        guard let color = colors[path] else { return nil }
        gates[path]?.wait()
        return NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            color.setFill()
            rect.fill()
            return true
        }
    }
}

/// Whether an icon as the panel draws it is the blue one.
@MainActor
private func isBlue(_ image: NSImage?) -> Bool {
    guard let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return false }
    let rep = NSBitmapImageRep(cgImage: cg)
    guard let color = rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?.usingColorSpace(.deviceRGB) else {
        return false
    }
    return color.blueComponent > 0.5 && color.redComponent < 0.5
}
