// One run through the app in a real folder, for the accent parity suite: the window, the folder's items as the disk
// keeps them, and the steps that look at the folder without writing through the app
import AppKit
import FTFileSystem
import FTFoundation
import FTOperations
import FTTestSupport
import Foundation
import Testing

@testable import FTAppKit

/// The same steps in a folder of each kind, each step telling what it saw as facts whose names don't depend on how
/// the folder and its files are spelled. A step never stops the run: what didn't arrive is a fact too.
@MainActor
final class AccentScenario: SidebarTesting, ListTesting {
    let names: AccentNames
    let harness: ExplorerHarness
    private(set) var facts: [AccentFact] = []
    private var step = ""
    private var noticesTold = 0
    private var opened: WritingWindow?

    /// The folder typed with every accent as one scalar, and with every accent apart.
    var typedComposed: String { names.folder.precomposedStringWithCanonicalMapping }
    var typedDecomposed: String { names.folder.decomposedStringWithCanonicalMapping }
    /// The folder typed in the spelling the disk doesn't keep it in (the same text, for a folder with no accent).
    var typedOtherwise: String { samePath(typedComposed, names.folder) ? typedDecomposed : typedComposed }

    /// The run in a folder of `kind` under the harness's own folder, where every call of the disk spells a name as
    /// it is stored; or under `top`, a folder of another disk, where the calls may not agree (`anySpelling`).
    static func run(_ kind: AccentKind, under top: String? = nil) async throws -> [AccentFact] {
        let scenario = try AccentScenario(kind, under: top)
        try await scenario.open()
        await scenario.looksAtTheRows()
        await scenario.seesChangesFromOutside()
        await scenario.renamesInARow()
        await scenario.makesNewItems()
        await scenario.copiesCutsAndDuplicates()
        if scenario.anySpelling { await scenario.goesIntoTheSubfolder() }
        await scenario.movesToTheFolderTyped()
        await scenario.extractsToTheFolderTyped()
        await scenario.goesToTheFolderTyped()
        await scenario.compressesAndExtracts()
        await scenario.trashesAndUndoes()
        await scenario.renamesSeveral()
        await scenario.readsAWriteInTheOtherPane()
        await scenario.revealsAndRootsTheTree()
        await scenario.dragsOntoTheSubfolder()
        await scenario.keepsWhatWasSaved()
        await scenario.opensAnItemFromAnotherApp()
        await scenario.close()
        return scenario.facts
    }

    private init(_ kind: AccentKind, under top: String?) throws {
        let harness = try ExplorerHarness.windowless()
        self.harness = harness
        names = AccentNames(kind: kind, under: top ?? harness.folder.path, anySpelling: top != nil)
        // The tree starts at the folder the run is under.
        if top != nil { harness.windows.home = names.root }
        if kind.nested { AccentDisk.makeFolder(names.parent) }
        AccentDisk.makeFolder(names.folder)
        AccentDisk.makeFolder(names.sub)
        for role in AccentRole.allCases {
            let path = names.path(role)
            switch role {
            case .sub, .appears: break
            case .picture: AccentDisk.write(AccentDisk.picture(), to: path)
            case .archiveOne: try AccentDisk.makeZip(at: path, holding: "inside-one.txt")
            case .archiveTwo: try AccentDisk.makeZip(at: path, holding: "inside-two.txt")
            default: AccentDisk.write(Data(repeating: UInt8(ascii: "a"), count: role.size), to: path)
            }
        }
        try FinderTags.write([FinderTag(name: "Red", color: .red)], to: names.path(.tagged))
    }

    // MARK: What the steps share

    var window: WritingWindow {
        guard let opened else { preconditionFailure("the scenario's window is opened first") }
        return opened
    }

    var tab: MainWindowController { window.tab }
    var store: AppStateStore { harness.store }
    var anySpelling: Bool { names.anySpelling }

    /// Whether two paths are the one item: by their bytes, or, where the disk's calls don't agree on a spelling, by
    /// their text, which takes an accent spelled either way for the same.
    func same(_ left: String, _ right: String) -> Bool {
        anySpelling ? left == right : samePath(left, right)
    }

    /// Whether `folder` holds `name`: under exactly that name as the folder is read, or, where the disk's calls
    /// don't agree on a spelling, under it however it is spelled.
    func holds(_ name: String, in folder: String) -> Bool {
        anySpelling ? AccentDisk.has(name, in: folder) : AccentDisk.holds(name, in: folder)
    }

    func begin(_ step: String) {
        if anySpelling, opened != nil { startsClean() }
        self.step = step
    }

    /// Whether a sheet or an alert saying a write couldn't be done stands over the tab.
    private var saysAWriteFailed: Bool {
        if let sheet = CopyPasteResultPresenter.shared.sheet, sheet.window === tab.window { return true }
        if let alert = tab.frontAlert, alert.content.accessory == nil,
            CopyPasteReviewPresenter.shared.alert !== alert
        {
            return true
        }
        return false
    }

    /// What stands over the tab, as a person reads it: a refusal under a name being typed, a sheet of what a write
    /// couldn't do, a question, a box left open.
    var standing: [String] {
        var standing: [String] = []
        if let rename = tab.content.inlineRename {
            standing.append("a name open in its row" + (rename.error.map { ": " + $0 } ?? ""))
        }
        if let sheet = CopyPasteResultPresenter.shared.sheet, sheet.window === tab.window {
            let rows = sheet.text.sections.flatMap { section in
                section.rows.map { section.label + ": " + NodePath.basename($0.path) + ": " + $0.detail }
            }
            standing.append(
                "result sheet: " + ([sheet.text.title, sheet.text.message] + rows).joined(separator: " | "))
        }
        if let sheet = CopyPasteReviewPresenter.shared.sheet, sheet.window === tab.window {
            standing.append("review sheet: " + sheet.titleLabel.stringValue)
        }
        if let alert = tab.frontAlert {
            standing.append(
                "alert: " + alert.titleLabel.stringValue + (alert.messageLabel.map { " | " + $0.stringValue } ?? ""))
        }
        if tab.goToBox != nil { standing.append("a box to type a folder into") }
        if tab.batchRenameSheet != nil { standing.append("the Rename sheet") }
        return standing
    }

    /// On a disk whose spellings disagree a step may leave something standing that holds the tab, and every step
    /// after it would then say the same thing: what stands is told once, with the step that left it, and taken away,
    /// and the folder is put back on screen.
    private func startsClean() {
        let left = standing + (window.recorder.shown.count > noticesTold ? ["a notice"] : [])
        if !left.isEmpty { note("left standing", told: left) }
        let shown = window.recorder.shown
        if shown.count > noticesTold {
            note("notices", told: shown[noticesTold...].map { $0.title + ": " + $0.message })
            noticesTold = shown.count
        }
        if tab.content.inlineRename != nil { tab.content.renameCancelled() }
        tab.batchRenameSheet?.onCancel()
        for dialog in tab.dialogs.reversed() { dialog.dismiss() }
        if tab.showsTwoPanes, step != "other pane" { tab.closeOtherPane() }
        // A tab opened beside the scenario's own (an Extract that took the folder on screen for another) is told and
        // closed, so the steps after it work in the tab they mean to.
        if let group = tab.group, group.tabs.count > 1 {
            let others = group.tabs.filter { $0 !== tab }
            note("another tab was opened on", told: others.map(\.folderPath))
            for other in others { group.closeTab(other) }
            group.select(tab)
        }
    }

    /// The folder on screen again, for a step that starts in it, when the step before left the pane elsewhere.
    func backInTheFolder() async {
        guard anySpelling else { return }
        _ = await arrives { self.isIdle }
        if !shows(names.folder) {
            note("the pane was left on", told: tab.folderPath)
            tab.go(to: names.folder)
            _ = await arrives { self.shows(self.names.folder) && self.row(.plain) != nil }
        }
    }

    func note(_ name: String, _ value: String) {
        facts.append(AccentFact(step: step, name: name, value: value))
    }

    func note(_ name: String, _ value: Bool) { note(name, value ? "true" : "false") }

    /// A path, or a text that may hold names, told by what its names are there for.
    func note(_ name: String, told value: String?) {
        facts.append(
            AccentFact(
                step: step, name: name, value: names.told(value), spelled: names.spelled(value.map { [$0] } ?? [])))
    }

    func note(_ name: String, told values: [String]) {
        facts.append(AccentFact(step: step, name: name, value: names.told(values), spelled: names.spelled(values)))
    }

    /// Several paths whose order isn't the point.
    func note(_ name: String, toldSorted values: [String]) {
        facts.append(
            AccentFact(step: step, name: name, value: names.toldSorted(values), spelled: names.spelled(values)))
    }

    /// Whether a path is spelled as its folders are read: a fact where the disk has one spelling for a name, and left
    /// to the spellings told beside each path where it hasn't.
    func noteOnDisk(_ name: String, _ value: @autoclosure () -> Bool) {
        if !anySpelling { note(name, value()) }
    }

    /// Waits for what a step expects, not as long as a test that has nothing else to say: what doesn't come is told.
    /// The same ten seconds on every disk: a run that passes waits for nothing that doesn't come, and on a Mac kept busy
    /// by the other test processes what a disk image sends may take seconds.
    func arrives(sourceLocation: SourceLocation = #_sourceLocation, _ condition: () -> Bool) async -> Bool {
        // On a disk whose spellings disagree, a write that said it failed holds the tab until its sheet is answered:
        // what the step waits for doesn't come then.
        let start = ContinuousClock.now
        let deadline = start + .seconds(10)
        var refusedSince: ContinuousClock.Instant?
        while !condition() {
            if anySpelling, opened != nil, saysAWriteFailed {
                let since = refusedSince ?? ContinuousClock.now
                refusedSince = since
                if ContinuousClock.now - since > .milliseconds(300) { return false }
            }
            guard ContinuousClock.now < deadline else {
                let place = "\(sourceLocation.fileID):\(sourceLocation.line)"
                FileHandle.standardError.write(Data("the scenario gave up waiting at \(place)\n".utf8))
                return false
            }
            // Looked at often: most of what a step waits for is there within a few milliseconds.
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    /// The active pane's rows, their paths, and what is selected in it: the three places the scenario reads the list.
    var rows: [DirectoryEntry] { tab.content.entries }
    var rowPaths: [String] { rows.map(\.path) }
    var selection: [String] { tab.content.selection.paths }

    func select(_ entries: [DirectoryEntry]) {
        tab.content.select(paths: entries.map(\.path))
        tab.content.focusList()
        tab.perform(.focusContentPane)
    }

    /// The row whose name is `name` byte for byte; where the disk's calls don't agree on a spelling, failing that,
    /// the row of that name however it is spelled.
    func row(named name: String) -> DirectoryEntry? {
        rows.first { $0.name.utf8.elementsEqual(name.utf8) } ?? (anySpelling ? rows.first { $0.name == name } : nil)
    }

    func row(_ role: AccentRole) -> DirectoryEntry? { row(named: names.name(role)) }

    /// The rows for `roles`, or nil with a fact saying which is missing.
    func rows(_ roles: [AccentRole]) -> [DirectoryEntry]? {
        var found: [DirectoryEntry] = []
        for role in roles {
            guard let row = row(role) else {
                note("the row of \(role.rawValue) is listed", false)
                return nil
            }
            found.append(row)
        }
        return found
    }

    func shows(_ pane: BrowserPane, _ path: String) -> Bool {
        same(pane.shownFolderPath, path) && !pane.isNavigating
    }

    func shows(_ path: String) -> Bool { shows(tab.activePane, path) }

    /// Whether the selection is exactly the rows of `paths`, in any order: each selected by its row's own path, byte
    /// for byte, which is what draws the row selected.
    func selects(_ paths: [String]) -> Bool {
        let all = rowPaths
        let wanted = paths.compactMap { path in all.first { same($0, path) } }
        return wanted.count == paths.count && selection.count == paths.count
            && Set(selection.map(DiskPath.init)) == Set(wanted.map(DiskPath.init))
    }

    var isIdle: Bool { !tab.isWriteLocked && !tab.isNavigating }

    /// The folder on screen as it stands: its rows, whether they are the disk's own names, and the selection.
    func noteState(_ name: String) {
        let folder = tab.folderPath
        let onDisk = Set(AccentDisk.names(in: folder).filter { $0.first != UInt8(ascii: ".") })
        note("\(name): rows", toldSorted: rowPaths)
        note("\(name): the rows are the disk's names", Set(rows.map { Array($0.name.utf8) }) == onDisk)
        noteOnDisk("\(name): the rows' paths are spelled as on disk", rows.allSatisfy { spelledAsOnDisk($0.path) })
        note("\(name): selection", toldSorted: selection)
    }

    func spelledAsOnDisk(_ path: String) -> Bool { AccentDisk.spells(path, below: names.root) }

    /// The files' Undo, and whether it ran.
    @discardableResult
    func undo() async -> Bool {
        let outcome = await tab.writeActions?.undo()
        if case .queued = outcome { return true }
        return false
    }

    /// `text` typed into the box up over the tab, and Return.
    func submit(_ text: String) async -> Bool {
        guard await arrives({ self.tab.goToBox != nil }), let box = tab.goToBox else { return false }
        tab.window?.contentView?.layoutSubtreeIfNeeded()
        DialogKeys.type(text, into: box)
        DialogKeys.press(KeyCode.returnKey, "\r", in: tab.window)
        return true
    }

    /// The tree's row of `path`, when it is drawn.
    func treeRow(_ path: String) -> SidebarRowState? {
        cells(sidebar(tab)).compactMap(\.state).first {
            $0.item.kind == .filesystem && same($0.item.path ?? "", path)
        }
    }

    var treeRows: [String] {
        tab.sidebarController.model.treePresentation.visibleItemIDs.compactMap(\.filesystemPath)
    }

    /// Whether the tree's row of `path` comes to be the one drawn selected.
    func treeSelects(_ path: String) async -> Bool {
        let model = tab.sidebarController.model
        // The tree follows a folder within a moment of its opening.
        return await arrives {
            self.harness.layout(self.tab)
            return (self.anySpelling || model.selected == .filesystem(path))
                && self.treeRow(path).map { $0.selection != .none } == true
        }
    }

    // MARK: Opening

    private func open() async throws {
        begin("open")
        let store = harness.store
        MainWindowController.visitStore = { store }
        // The folders' views are kept in the store, as the app's are.
        harness.services.folderViews = SharedFolderViews(store: store)
        opened = anySpelling ? try await openOnItsDisk() : try await WritingWindow.open(names.folder, in: harness)
        tab.updatePreferences {
            $0.favorites = []
            $0.favoritesInitialized = true
            // A second tab on the folder would show, if an Extract took the folder on screen for another.
            $0.diskImageOpensIn = .tab
        }
        tab.preferencesChanged(PreferencesChange(keys: [], senderID: nil))
        let tree = tab.sidebarController
        let root = names.root
        _ = await arrives { samePath(tree.treeRootPath, root) && tree.model.nodes[root]?.loaded == true }
        harness.layout(tab)

        note("the folder on screen", told: tab.folderPath)
        noteOnDisk("the folder on screen is spelled as on disk", spelledAsOnDisk(tab.folderPath))
        note("history", names.told(tab.historyPaths) + " at \(tab.historyIndex)")
        note("the tree's row is selected", await treeSelects(tab.folderPath))
        note("the tree's selection", told: tab.sidebarController.model.selected?.filesystemPath)
        note("the tree's rows", toldSorted: treeRows)
        noteOnDisk("the tree's rows are spelled as on disk", treeRows.allSatisfy { spelledAsOnDisk($0) })
        let bar = tab.content.contentShell.pathBarRow
        note("the path bar's path", told: bar.path)
        note("the path bar's last part", told: bar.pathBar.segments.last.map { $0.label + " at " + $0.path })
        note("the window's title", told: tab.window?.title)
        let represented = tab.window?.representedURL.flatMap { DiskPath(urlSpelling: $0)?.string }
        note("the window's file", told: represented)
    }

    /// The window with the app's file operations, as `WritingWindow.open` makes it, but for the Trash: a folder of
    /// the disk the run is on, as each disk has its own, where the tests' stand-in is on this Mac's disk.
    private func openOnItsDisk() async throws -> WritingWindow {
        PreparingSheet.isEnabled = false
        let tab = try await harness.open(names.folder)
        let trash = names.root + "/.parity-trash"
        let fileSystem = PosixFileSystem()
        let operations = AppWriteOperations(
            userData: harness.folder.url, directoryService: harness.services.directoryService,
            windows: harness.windows,
            trash: TrashItem(
                trash: { path in
                    mkdir(trash, 0o755)
                    let target = trash + "/" + NodePath.basename(path)
                    guard rename(path, target) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                    return target
                },
                lstat: { try fileSystem.lstat($0) }, getFlags: NativeFS.getFlags,
                homePath: FileManager.default.homeDirectoryForCurrentUser.path),
            emptyTrash: { (true, nil) }, log: { _ in })
        let recorder = DialogRecorder()
        operations.dialogs = recorder.dialogs
        tab.perform(.viewAsDetails)
        _ = await arrives { !tab.content.entries.isEmpty }
        harness.layout(tab)
        return WritingWindow(
            harness: harness, tab: tab, operations: operations, recorder: recorder,
            folder: DiskPath(names.folder).url(isDirectory: true))
    }

    private func close() async {
        begin("end")
        note("notices shown", told: window.recorder.shown.map { $0.title + ": " + $0.message })
        note("tabs", "\(tab.group?.tabs.count ?? 0) in \(harness.windows.count) window")
        await window.close()
    }

    // MARK: The rows

    private func looksAtTheRows() async {
        begin("rows")
        await backInTheFolder()
        let content = tab.content
        let entries = rows
        noteState("listed")
        note("count", "\(entries.count)")

        // The details, asked for as the rows ask when they come into view.
        content.requestMetadata(for: entries)
        let read = await arrives {
            !content.isReadingDetails && entries.allSatisfy { content.metadata(for: $0.path) != nil }
        }
        note("details arrive for every row", read)
        note(
            "details",
            names.toldSorted(
                entries.map { entry in
                    let details = content.metadata(for: entry.path)
                    let size = details?.sizeBytes.map(String.init) ?? "none"
                    return "\(entry.path): size \(size), modified \(details?.modifiedAt != nil), created "
                        + "\(details?.createdAt != nil), \(details?.kindLabel ?? "no kind")"
                }))
        // The rows on screen draw what was read for them.
        func sizesDrawn() -> [String] {
            harness.layout(tab)
            return bars(tab).compactMap { bar in
                guard let entry = bar.entry, entry.kind == .file else { return nil }
                let size = SizeText.size(content.metadata(for: entry.path)?.sizeBytes)
                return "\(entry.path): \(texts(bar).contains(size))"
            }
        }
        _ = await arrives { sizesDrawn().allSatisfy { $0.hasSuffix("true") } }
        note("the rows drawn show their sizes", names.toldSorted(sizesDrawn()))

        // The tags: one file has a red one.
        content.requestTags(for: entries.map(\.path))
        let tagged = row(.tagged)
        let colored = await arrives { tagged.map { content.tagColors(for: $0) == [.red] } ?? false }
        note("the tagged file has its colour", colored)
        note(
            "tag colours",
            names.toldSorted(entries.map { "\($0.path): \(content.tagColors(for: $0).map(\.rawValue))" }))
        let dotted = await arrives {
            self.harness.layout(self.tab)
            let bar = self.bars(self.tab).first { bar in
                bar.entry.map { entry in tagged.map { samePath($0.path, entry.path) } ?? false } ?? false
            }
            return bar?.nameCell.tagDots.colors == [.red]
        }
        note("the tagged file's row draws its colour", dotted)

        // The icons, asked of the store as the rows ask.
        var icons: [DiskPath: Bool] = [:]
        if let iconStore = harness.services.iconStore {
            for entry in entries {
                iconStore.load(IconRequest(entry: entry.iconEntry)) { image in
                    icons[DiskPath(entry.path)] = image != nil
                }
            }
        }
        note("every row's icon is answered", await arrives { icons.count == entries.count })
        note(
            "icons",
            names.toldSorted(entries.map { "\($0.path): \(icons[DiskPath($0.path)].map(String.init) ?? "pending")" }))

        // The sub-folder's size, by Calculate Size on its row.
        if let sub = row(.sub) {
            select([sub])
            tab.perform(.calculateSize)
            let measured = await arrives { self.tab.folderSizes.readySize(sub.path) != nil }
            note("the sub-folder is measured", measured)
            let size = tab.folderSizes.readySize(sub.path)
            note("the sub-folder's size", size.map(String.init) ?? "none")
            note("the sub-folder's row has it", content.sizeBytes(of: sub).map(String.init) ?? "none")
            // The rows are drawn again a moment after a size arrives.
            let drawn = await arrives {
                self.harness.layout(self.tab)
                let bar = self.bars(self.tab).first { bar in bar.entry.map { samePath($0.path, sub.path) } ?? false }
                return bar?.sizeCell.label.stringValue == SizeText.size(size)
            }
            note("the sub-folder's row draws it", drawn)
        } else {
            note("the sub-folder is listed", false)
        }

        // The picture's preview, in the Icons view.
        tab.perform(.viewAsIcons)
        let grid = GridProbe(tab: tab)
        _ = await arrives { grid.pane != nil && content.mode == .icons }
        harness.layout(tab)
        grid.layout()
        if let picture = row(.picture) {
            let loaded = await arrives { IconThumbnails.store.loadedPicture(forPath: picture.path) != nil }
            note("the picture's preview is read", loaded)
            grid.layout()
            let shown = await arrives { grid.iconItems[picture.name]?.thumbnail.image != nil }
            note("the picture's item shows it", shown)
        } else {
            note("the picture is listed", false)
        }
        tab.perform(.viewAsDetails)
        _ = await arrives { content.mode == .details && !self.bars(self.tab).isEmpty }
        harness.layout(tab)
    }

    // MARK: Changes from outside

    /// A file made, a file removed and a file grown behind the app's back, heard of by the folder's watch as the app
    /// has it: the system's own events for the folder, not a stand-in for them.
    private func seesChangesFromOutside() async {
        begin("outside")
        await backInTheFolder()
        let windows = harness.windows
        let watches = FolderWatches(
            .app(cache: harness.services.directoryService.cache) { [weak windows] windowID, change in
                windows?.folderChanged(windowID: windowID, change)
            })
        windows.folderWatches = watches
        windows.tabNavigated(tab)
        note("the folder watched", told: watches.watchedPaths[tab.activePane.watchID])

        // A file made: listed once the watch has looked at the folder for the first time. On another disk the watch
        // is left to start first, so the file too is heard of by the system's events: a disk that keeps a folder's
        // time to two seconds says nothing of a change made in the moment the folder was read.
        if anySpelling { try? await Task.sleep(for: .milliseconds(600)) }
        AccentDisk.write(Data(repeating: UInt8(ascii: "a"), count: AccentRole.appears.size), to: names.path(.appears))
        note("a file made outside is listed", await arrives { self.row(.appears) != nil })

        // Then a file removed and a file grown. The watch has had its first look, so these are heard of only by the
        // events the system sends for the folder, which name it and its items as the disk spells them.
        let content = tab.content
        let grown = 100
        #expect(unlink(names.path(.vanishes)) == 0)
        AccentDisk.write(Data(repeating: UInt8(ascii: "a"), count: grown), to: names.path(.paned))
        note("a file removed outside is gone", await arrives { self.row(.vanishes) == nil })
        let read = await arrives {
            // As its row asks when it is drawn again: nothing is asked for a row whose details still stand.
            guard let row = self.row(.paned) else { return false }
            content.requestMetadata(for: [row])
            return content.metadata(for: row.path)?.sizeBytes == Int64(grown)
        }
        note("a file grown outside has its new size", read)
        noteState("after")

        // The steps after this write through the app, which reads the folder itself.
        watches.stopAll()
        windows.folderWatches = nil
    }

    // MARK: Reveal, the tree's top, the folder above

    private func revealsAndRootsTheTree() async {
        begin("reveal")
        await backInTheFolder()
        guard let item = row(.tagged) else {
            note("the row is listed", false)
            return
        }
        let clipboard = tab.services.clipboard
        clipboard.set(ClipboardRules.set(.copy, [item.path], capturedAt: "t"), from: nil)
        tab.clipboardChanged()
        let history = names.told(tab.historyPaths) + " at \(tab.historyIndex)"

        // In the folder on screen: selected where it is.
        tab.content.select(paths: [])
        tab.revealClipboardItem(item.path)
        note("in place: selected", await arrives { self.selects([item.path]) })
        await settle()
        note("in place: the history is as it was", names.told(tab.historyPaths) + " at \(tab.historyIndex)" == history)

        // A search's result revealed, its folder spelled the way the disk doesn't spell it: this folder, not another.
        tab.content.select(paths: [])
        tab.revealSearchResult(typedOtherwise + "/" + item.name)
        note("a result of another spelling: selected", await arrives { self.selects([item.path]) })
        note("a result of another spelling: the folder on screen", told: tab.folderPath)
        await settle()
        note(
            "a result of another spelling: the history is as it was",
            names.told(tab.historyPaths) + " at \(tab.historyIndex)" == history)

        // From the folder above: the folder opens, and the item is selected in it.
        tab.go(to: names.parent)
        _ = await arrives { self.shows(self.names.parent) }
        tab.revealClipboardItem(item.path)
        let revealed = await arrives { self.shows(self.names.folder) && self.selects([item.path]) }
        note("from above: the folder opens with it selected", revealed)
        note("from above: the folder on screen", told: tab.folderPath)
        note("from above: selection", toldSorted: selection)
        clipboard.set(.empty, from: nil)
        tab.clipboardChanged()

        // Root Tree at Selection on the sub-folder's row.
        begin("tree")
        let model = tab.sidebarController.model
        guard let sub = row(.sub) else {
            note("the sub-folder is listed", false)
            return
        }
        select([sub])
        tab.perform(.rootTreeAtSelection)
        let rooted = await arrives { self.same(model.rootPath, sub.path) && self.shows(sub.path) }
        note("Root Tree at Selection: the tree starts at the sub-folder", rooted)
        note("Root Tree at Selection: the tree's top", told: model.rootPath)
        noteOnDisk("Root Tree at Selection: the top is spelled as on disk", spelledAsOnDisk(model.rootPath))
        note("Root Tree at Selection: the folder on screen", told: tab.folderPath)
        note("Root Tree at Selection: its row is selected", await treeSelects(sub.path))

        // The tree back where the harness starts it, and the folder on screen again, for the steps that follow. (The
        // folder above the tree's top is left alone: the tree would start again at the disk, and list it.)
        tab.sidebarController.rootTree(at: names.root)
        _ = await arrives { samePath(model.rootPath, self.names.root) && model.nodes[self.names.root]?.loaded == true }
        tab.go(to: names.folder)
        note("the folder opens again", await arrives { self.shows(self.names.folder) && self.row(.sub) != nil })
        note("the tree's row is selected again", await treeSelects(names.folder))
        harness.layout(tab)
    }
}
