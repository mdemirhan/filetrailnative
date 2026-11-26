// The target, its properties, the volume and Open With answers, and the folder size controls
import AppKit
import FTFileSystem
import FTFoundation

/// Keeps the Info panel and the Info Row describing what the window points at, and carries out what they offer.
@MainActor
final class InfoController {
    unowned let host: MainWindowController
    /// Whether `host` is still there: a timer or an answer can outlast the tab while something still holds this controller.
    private weak var liveHost: MainWindowController?
    let panel: InfoPanelView
    /// The active pane's Info Row; the other pane's keeps what it last showed.
    private(set) var row: InfoRowView
    let auto: AutoFolderSizeController

    // The target.
    /// "Get Info" on an item: the panel describes this path whatever the selection.
    private(set) var targetOverride: String?
    private var seenSelection = ContentSelection.empty
    // Every read below goes through a `LatestRead`: after the same short wait, replacing what waits, the latest
    // answer only.
    // Properties: what is asked for and shown (`InfoPropertiesLoad`), and its read.
    private(set) var propertiesLoad = InfoPropertiesLoad(recentLimit: InfoMetrics.propertiesCacheLimit)
    private let propertiesRead = LatestRead<String, ItemProperties>()
    private var properties: InfoItem? { propertiesLoad.shown }
    private var loading: Bool { propertiesLoad.isLoading }
    // The volume.
    private var volume: (path: String, value: InfoVolume)?
    private var volumeRequested: String?
    private let volumeRead = LatestRead<String, VolumeInfo.Sizes>()
    // The room left on the disk of the folder on screen, for the Info Row: a read of its own, so the panel on a disk
    // and the row on a folder don't take each other's place.
    private var rowVolume: (path: String, available: Int64?)?
    private var rowVolumeRequested: String?
    private let rowVolumeRead = LatestRead<String, VolumeInfo.Sizes>()
    // Open With: what macOS is asked and answered (`OpenWithLookupLoad`), and the waits before asking and for it.
    private var lookup = OpenWithLookupLoad<OpenWithLookup>()
    private let lookupRead = LatestRead<String, OpenWithLookup?>()
    /// The last answer for each kind of file, by its extension: the apps a kind opens with are the same for every
    /// file of it, so the next file of a kind shows them at once while macOS is asked again.
    private var lookupByType: [String: OpenWithLookup] = [:]
    // What the panel and the row were last painted for, and the item being waited for (`InfoMetrics.holdGrace`).
    private var paintedKey: String?
    private var holding: (key: String, timer: DispatchWorkItem)?
    /// How long another item is waited for before it shows with dashes (tests set it to 0).
    var holdGrace = InfoMetrics.holdGrace
    private var frameQueued = false
    private var lookupPatience: DispatchWorkItem?
    // The copy buttons.
    private var observation: ExplorerWindowObservation?
    private var relativeRelease: RelativeClock.Release?
    private var refreshQueued = false
    // The tags: of the items last read, and those asked for (waiting or being read); stale once they changed, shown
    // until read again. Only the answer to the latest request is kept.
    private var tagsRead: (key: [DiskPath], value: FinderTagsOnItems)?
    private let tagsLoad = LatestRead<[DiskPath], FinderTagsOnItems>()
    private var tagsStale = false
    // The details of the one item described (`InfoDetailsReader`), and an app's signing: those read, shown until read
    // again; stale once its folder changed.
    private var details: (path: String, value: InfoDetails)?
    private let detailsRead = LatestRead<String, InfoDetails?>()
    private var detailsStale = false
    private var signing: (path: String, value: InfoDetails.Signing?)?
    private let signingRead = LatestRead<String, InfoDetails.Signing?>()
    /// Reads an item's details and an app's signing (tests put their own).
    var detailsReader: @Sendable (String, ReadCancel) -> InfoDetails? = { InfoDetailsReader.read($0, cancel: $1) }
    var signingReader: @Sendable (String) -> InfoDetails.Signing? = { InfoDetailsReader.signing($0) }
    /// Reads the tags of the items (tests put their own).
    var tagsReader: @Sendable ([String]) -> FinderTagsOnItems = { FinderTags.onItems($0, sparingAsked: true) }
    /// The items the Tags row describes, for its popover.
    private var tagPaths: [String] = []
    /// The items the panel describes, for the permissions popover its Sharing & Permissions title opens.
    private var permissionPaths: [String] = []
    let actions: InfoActions
    /// Whether Option is held as the Open With menu opens, which opens it as Always Open With: the keyboard's own
    /// state, replaceable so a test doesn't go by the keys someone is holding.
    var optionHeld: @MainActor () -> Bool = { NSEvent.modifierFlags.contains(.option) }

    init(host: MainWindowController, panel: InfoPanelView, row: InfoRowView) {
        self.host = host
        liveHost = host
        self.panel = panel
        self.row = row
        auto = AutoFolderSizeController(sizes: host.folderSizes)
        actions = InfoActions(host: host)
        actions.onLookupsForgotten = { [weak self] in self?.forgetLookups() }
        wire()
        observation = host.observe { [weak self] change in
            guard let self else { return }
            switch change {
            case .folder:
                // A change from outside keeps what the panel shows.
                if !self.host.isTakingInOutsideChange { self.targetOverride = nil }
                self.folderChanged()
            case .selection:
                // The tree's selection says so too, as the tree refreshes: only the list's lets Get Info's item go.
                // Items that left the folder aren't a selection made: they just drop out of it.
                if self.content.selection != self.seenSelection {
                    self.seenSelection = self.content.selection
                    if !self.host.isTakingInOutsideChange { self.targetOverride = nil }
                }
                self.update()
            case .panels, .preferences, .view, .history, .search: self.update()
            default: break
            }
        }
        watchDetails(of: host.content)
        // Something can still hold this controller when its tab has gone, and `host` is unowned.
        relativeRelease = RelativeClock.shared.subscribe { [weak self, weak host] in
            guard let host, host.window?.isBehindAnotherTab != true else { return }
            // Free space changes with copies anywhere on the disk, which no folder change here tells of.
            self?.volumeRequested = nil
            self?.rowVolumeRequested = nil
            self?.update()
        }
        update()
    }

    isolated deinit {
        relativeRelease?()
    }

    /// A pane's list read more of its items' details: the panel and the row update when it is the active one.
    func watchDetails(of content: ContentPaneController) {
        content.onDetailsChanged = { [weak self, weak content] in
            guard let self, let content, content === self.host.content else { return }
            self.queueUpdate()
        }
        content.onTagsChanged = { [weak self, weak content] in
            guard let self, let content, content === self.host.content else { return }
            self.tagsChanged()
        }
    }

    /// Another pane became active: its Info Row is the one kept up to date, and the panel describes its selection.
    func follow(row next: InfoRowView) {
        guard next !== row else { return }
        row = next
        wireRow()
        seenSelection = content.selection
        targetOverride = nil
        paintedKey = nil
        update()
    }

    private func wire() {
        wireRow()
        wirePanel(panel)
    }

    /// The panel this controller shows into: its window's, or the one in a window of its own while this tab drives it.
    private func wirePanel(_ panel: InfoPanelView) {
        panel.iconStore = host.services.iconStore
        panel.onClose = { [weak self] in self?.host.updatePanels { $0.propertiesOpen = false } }
        panel.onPopOut = { [weak self, weak panel] in
            guard let panel else { return }
            self?.host.setInfoPanelPoppedOut(!panel.isPoppedOut)
        }
        panel.onShowOriginal = { [weak self] original in self?.host.revealOriginal(original) }
        panel.onOpen = { [weak self] in
            guard let self, let path = self.resolved?.item.path else { return }
            self.actions.openExternally(path)
        }
        panel.onOpenWithMenu = { [weak self] anchor in self?.presentOpenWith(from: anchor, changeDefault: false) }
        panel.onOpensWithMenu = { [weak self] anchor in self?.presentOpenWith(from: anchor, changeDefault: true) }
        panel.onEditTags = { [weak self] anchor in
            guard let self, !self.tagPaths.isEmpty else { return }
            self.host.editTags(self.tagPaths, from: anchor)
        }
        panel.onEditPermissions = { [weak self] anchor in
            guard let self, !self.permissionPaths.isEmpty else { return }
            self.host.editPermissions(self.permissionPaths, from: anchor)
        }
        panel.onCalculate = { [weak self] in self?.calculate(forced: false) }
        panel.onRecalculate = { [weak self] in self?.calculate(forced: true) }
        panel.onCancel = { [weak self] in self?.cancelCalculating() }
        panel.onCopyText = { [weak self] text, what in _ = self?.actions.copy(text, what: what) }
    }

    private func wireRow() {
        row.iconStore = host.services.iconStore
        row.onCalculate = { [weak self] in self?.calculate(forced: false, targets: self?.rowSizeTargets) }
        row.onRecalculate = { [weak self] in self?.calculate(forced: true, targets: self?.rowSizeTargets) }
        row.onCancel = { [weak self] in self?.cancelCalculating(targets: self?.rowSizeTargets) }
    }

    /// The item the panel describes.
    var resolvedItemPath: String? { resolved?.item.path }
    private var content: ContentPaneController { host.content }
    /// Whether a panel shows what this controller describes: its window's, or the one in a window of its own while
    /// this tab is the one in front.
    private var panelOpen: Bool { host.panels.propertiesOpen || drivesPopOut }
    private var drivesPopOut: Bool {
        let preferences = host.preferences
        return preferences.infoPanelPoppedOut && preferences.infoPanelPopOutShown && InfoPopOut.shared.owner === host
    }
    /// The panel shown into.
    private var shownPanel: InfoPanelView { drivesPopOut ? InfoPopOut.shared.panel : panel }
    private var rowOpen: Bool { host.panels.detailRowOpen }
    private var homePath: String { DiskPath.home.string }
    private var folderPath: String { host.shownFolderPath }

    // MARK: The target

    /// Where the views point: the Get Info target, else the selection's lead, else the folder on screen.
    var targetPath: String? {
        if let targetOverride { return targetOverride }
        if let lead = content.selection.leadPath { return lead }
        return folderPath.isEmpty ? nil : folderPath
    }

    /// "Get Info": the panel opens and describes `path`.
    func showInfo(for path: String) {
        targetOverride = path
        if host.preferences.infoPanelPoppedOut {
            host.showInfoPopOut(focus: false)
        } else if !panelOpen {
            host.updatePanels { $0.propertiesOpen = true }
        }
        scheduleFetch(path, immediately: true)
        update()
    }

    /// The views follow the selection again.
    func letShowInfosItemGo() {
        guard targetOverride != nil else { return }
        targetOverride = nil
        update()
    }

    private func infoEntry(_ entry: DirectoryEntry) -> InfoEntry {
        InfoEntry(
            path: entry.path, name: entry.name, fileExtension: entry.fileExtension,
            kind: FTFoundation.EntryKind(rawValue: entry.kind.rawValue) ?? .other, isHidden: entry.isHidden,
            isSymlink: entry.isSymlink)
    }

    /// What the folder's read gave of an item, before its own details are read.
    private func listedMetadata(_ entry: DirectoryEntry) -> InfoMetadata {
        let isFile = entry.kind == .file || entry.kind == .symlinkFile
        return InfoMetadata(
            kindLabel: InfoPreview.fallbackKindLabel(
                kind: FTFoundation.EntryKind(rawValue: entry.kind.rawValue) ?? .other,
                fileExtension: entry.fileExtension),
            createdAt: entry.listedCreatedAt, modifiedAt: entry.listedModifiedAt,
            sizeBytes: isFile ? entry.sizeBytes : nil,
            sizeStatus: isFile && entry.sizeBytes != nil ? .ready : .deferred,
            permissionMode: entry.permissionMode)
    }

    private func infoMetadata(_ metadata: EntryMetadata?) -> InfoMetadata? {
        metadata.map {
            InfoMetadata(
                kindLabel: $0.kindLabel, createdAt: $0.createdAt, modifiedAt: $0.modifiedAt, sizeBytes: $0.sizeBytes,
                sizeStatus: FTFoundation.SizeStatus(rawValue: $0.sizeStatus.rawValue) ?? .deferred,
                permissionMode: $0.permissionMode)
        }
    }

    /// The item the views show for the target.
    var resolved: InfoPreview.Resolved? {
        guard let path = targetPath else { return nil }
        let listed = content.listedEntry(at: path)
        let found = listed.map { [infoEntry($0)] } ?? []
        // What the list knows of it already (its size, dates and mode, from the folder's read) shows at once, so the
        // panel comes up whole and its values fill in where they are as the rest is read.
        let known = infoMetadata(content.metadata(for: path)) ?? listed.map(listedMetadata)
        let metadata = known.map { [path: $0] } ?? [:]
        return InfoPreview.resolve(
            path: path, currentPath: folderPath, entries: found, metadataByPath: metadata, properties: properties,
            homePath: homePath, startupDiskName: startupDiskName)
    }

    private var startupDiskName: String { host.services.startupDisk.name }

    /// Whether the item is being asked for, or about to be: a test seam.
    var isAskingForItem: Bool { propertiesRead.isWaiting || loading }

    /// The startup disk was renamed: the item is asked for again, so `/` comes back with its new name.
    func namesChanged() {
        if let path = targetPath { scheduleFetch(path, immediately: true) }
        update()
    }

    // MARK: Properties

    /// This window changed the items' permissions: what the panel shows of them is read again now.
    func itemsChanged() {
        detailsStale = true
        if let path = targetPath { scheduleFetch(path, immediately: true) }
        update()
    }

    private func folderChanged() {
        // The folder reloaded or another one opened: what is shown stays, and is asked for again.
        volumeRequested = nil
        rowVolumeRequested = nil
        tagsStale = true
        detailsStale = true
        if let path = targetPath { scheduleFetch(path, immediately: false) }
        update()
    }

    private func scheduleFetch(_ path: String, immediately: Bool) {
        guard panelOpen || rowOpen, !folderPath.isEmpty else {
            propertiesRead.stop()
            propertiesLoad.stop()
            return
        }
        guard liveHost != nil else { return }
        let request = propertiesLoad.ask(path)
        let service = host.services.directoryService
        let disk = startupDiskName
        propertiesRead.askAsync(
            path, after: immediately ? 0 : InfoMetrics.fetchDelay,
            read: { _ in await service.itemProperties(path: path, startupDiskName: disk) },
            answered: { [weak self] item in
                guard let self else { return }
                let mapped = InfoItem(
                    path: item.path, name: item.name, fileExtension: item.fileExtension,
                    kind: FTFoundation.EntryKind(rawValue: item.kind.rawValue) ?? .other, kindLabel: item.kindLabel,
                    isHidden: item.isHidden, isSymlink: item.isSymlink, createdAt: item.createdAt,
                    modifiedAt: item.modifiedAt, sizeBytes: item.sizeBytes,
                    sizeStatus: FTFoundation.SizeStatus(rawValue: item.sizeStatus.rawValue) ?? .deferred,
                    permissionMode: item.permissionMode, addedAt: item.addedAt, lastOpenedAt: item.lastOpenedAt,
                    original: item.isLink ? item.originalPath.map(InfoOriginal.found) ?? .missing : nil)
                guard self.propertiesLoad.answered(path, mapped, request: request) else { return }
                self.updateNextFrame()
            })
    }

    // MARK: Details

    /// The details of the one item described, read again once its folder changed; those read show until then.
    private func detailsState(_ path: String) -> InfoDetailsState {
        if details?.path != path || detailsStale, detailsRead.asked != path { requestDetails(path) }
        guard let read = details, read.path == path else { return .pending }
        return .read(read.value)
    }

    private func requestDetails(_ path: String) {
        detailsStale = false
        let reader = detailsReader
        detailsRead.ask(
            path, after: 0, read: { reader(path, $0) },
            answered: { [weak self] value in
                guard let self else { return }
                if let value { self.details = (path, value) }
                self.updateNextFrame()
            })
    }

    /// An app's signing: read after the same wait, cancelled when the panel moves on.
    private func signingState(_ item: InfoItem) -> InfoSigningState {
        guard item.kind == .bundle, item.fileExtension.lowercased() == "app" else { return .none }
        let path = item.path
        if signing?.path != path, signingRead.asked != path {
            let reader = signingReader
            signingRead.ask(
                path, qos: .utility, read: { _ in reader(path) },
                answered: { [weak self] value in
                    guard let self else { return }
                    self.signing = (path, value)
                    self.updateNextFrame()
                })
        }
        guard let read = signing, read.path == path else { return .pending }
        return .read(read.value)
    }

    // MARK: Tags

    /// The Tags row of `paths`: read when they are other items than those last read, or changed since; what was read
    /// shows until then. None for more items than the right-click menu's colors read.
    private func tagsState(_ paths: [String], editable: Bool) -> InfoTagsState {
        guard !paths.isEmpty, paths.count <= TagColorsMenuRow.stateLimit else {
            tagPaths = []
            return .hidden
        }
        tagPaths = editable ? paths : []
        let key = paths.map(DiskPath.init)
        if tagsRead?.key != key || tagsStale { requestTags(paths, key: key) }
        guard let read = tagsRead, read.key == key else { return .pending }
        let tags = read.value.tags.map {
            InfoTag(name: $0.name, colorNumber: $0.color?.rawValue, count: read.value.count(of: $0))
        }
        return .read(InfoTags(tags: tags, itemCount: paths.count, editable: editable))
    }

    /// Asks after the wait the item's properties have, in place of what was waiting: a selection that grows item by
    /// item reads only where it stops, not every selection on the way.
    private func requestTags(_ paths: [String], key: [DiskPath]) {
        guard tagsLoad.asked != key else { return }
        tagsStale = false
        let reader = tagsReader
        // One item's tags at once; several wait, so a selection grown item by item reads only where it stops.
        tagsLoad.ask(
            key, after: paths.count > 1 ? InfoMetrics.fetchDelay : 0, read: { _ in reader(paths) },
            answered: { [weak self] read in
                guard let self else { return }
                self.tagsRead = (key, read)
                self.updateNextFrame()
            })
    }

    /// This window changed tags: those shown are read again.
    private func tagsChanged() {
        tagsStale = true
        tagsLoad.stop()
        queueUpdate()
    }

    // MARK: Volume

    /// A seam of the tests.
    static var volumeSizes: @Sendable (String) -> VolumeInfo.Sizes = { VolumeInfo.sizes(atPath: $0) }

    private func requestVolume(_ path: String) {
        guard volumeRequested != path else { return }
        volumeRequested = path
        let read = Self.volumeSizes
        volumeRead.ask(
            path, after: 0, read: { _ in read(path) },
            answered: { [weak self] sizes in
                guard let self, self.volumeRequested == path else { return }
                self.volume = (path, InfoVolume(totalBytes: sizes.totalBytes, availableBytes: sizes.availableBytes))
                self.updateNextFrame()
            })
    }

    private func requestRowVolume(_ path: String) {
        guard rowVolumeRequested != path else { return }
        rowVolumeRequested = path
        let read = Self.volumeSizes
        rowVolumeRead.ask(
            path, after: InfoMetrics.fetchDelay, qos: .utility, read: { _ in read(path) },
            answered: { [weak self] sizes in
                guard let self, self.rowVolumeRequested == path else { return }
                self.rowVolume = (path, sizes.availableBytes)
                self.updateNextFrame()
            })
    }

    // MARK: Open With

    /// The extension a file's Open With answer is kept by; nil for one whose answer is its own (no extension, an
    /// alias, which opens with its original's apps).
    private static func lookupType(_ item: InfoItem) -> String? {
        guard item.kind == .file, !item.fileExtension.isEmpty else { return nil }
        return item.fileExtension.lowercased()
    }

    private func requestLookup(_ path: String, type: String? = nil) {
        guard let generation = lookup.request(path) else { return }
        // The kind's last answer shows at once; macOS is asked all the same, and its answer takes its place.
        if let type, let known = lookupByType[type] { _ = lookup.answered(generation, known) }
        lookupPatience?.cancel()
        let pinned = host.preferences.openWithApplications
        let patience = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.lookup.patienceRanOut(generation) else { return }
                self.updateNextFrame()
            }
        }
        lookupPatience = patience
        DispatchQueue.main.asyncAfter(
            deadline: .now() + InfoMetrics.openWithPatience, execute: patience)
        lookupRead.askAsync(
            path, after: 0,
            read: { _ in
                await SystemActions.openWithApplications(paths: [path], pinnedAppPaths: pinned.map(\.appPath))
            },
            answered: { [weak self] answer in
                guard let self else { return }
                if let type, let answer {
                    if self.lookupByType.count >= 64 { self.lookupByType.removeAll() }
                    self.lookupByType[type] = answer
                }
                guard self.lookup.answered(generation, answer) else { return }
                self.updateNextFrame()
            })
    }

    /// Always Open With changed what a kind opens in: every answer is forgotten and asked again.
    func forgetLookups() {
        OpenWithCatalog.shared.forget()
        lookupByType = [:]
        if let path = lookup.forget() { requestLookup(path) }
    }

    var openWithLookup: OpenWithLookup? { lookup.path.flatMap(lookup.answer(for:)) }

    // MARK: Showing

    private func queueUpdate() {
        guard !refreshQueued else { return }
        refreshQueued = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.refreshQueued = false
                self?.update()
            }
        }
    }

    /// Describes the target again (cheap: nothing is read from disk here).
    func update() {
        guard liveHost != nil else { return }
        let popOut = InfoPopOut.shared
        popOut.sync(host.preferences, host: host)
        // The panel is in a window of its own: a window's own column shows none; asked open (a window view, the
        // toolbar's state of before), it is the other window that is shown.
        if host.preferences.infoPanelPoppedOut, host.panels.propertiesOpen {
            DispatchQueue.main.async { [weak host] in
                guard let host else { return }
                host.updatePanels { $0.propertiesOpen = false }
                if !host.preferences.infoPanelPopOutShown { host.showInfoPopOut(focus: false) }
            }
        }
        if drivesPopOut, popOut.wiredBy !== self {
            popOut.wiredBy = self
            wirePanel(popOut.panel)
        }
        guard panelOpen || rowOpen else {
            // Neither shows: nothing is described or asked for. Opening one updates them (`.panels`).
            propertiesRead.stop()
            tagsLoad.stop()
            detailsRead.stop()
            signingRead.stop()
            volumeRead.stop()
            rowVolumeRead.stop()
            propertiesLoad.stop()
            volumeRequested = nil
            rowVolumeRequested = nil
            auto.setPath(nil)
            paintedKey = nil
            holding?.timer.cancel()
            holding = nil
            return
        }
        let preferences = host.preferences
        let shortcuts = shortcutDisplay(preferences)
        shownPanel.closeTooltip = Tooltips.format("Hide Info Panel", shortcutLabel: shortcuts.label(.toggleInfoPanel))
        let selection = selectionDetails()
        updateAutoSize(preferences)
        if !panelOpen { volumeRequested = nil }
        // Another item: asked at once, as what it takes is under a millisecond and the panel waits for it
        // (`holdGrace`); a folder read again waits instead (`folderChanged`).
        if let path = targetPath, propertiesLoad.needsAsking(path) {
            scheduleFetch(path, immediately: true)
        }
        // The row's fact of a kind comes from the details too, with the panel closed.
        if !panelOpen, selection == nil, let path = targetPath, path != folderPath { _ = detailsState(path) }
        let panelNext = panelOpen ? panelDisplay(preferences, shortcuts, selection) : nil
        let rowNext = rowDisplay(selection)
        guard paints(displayKey(selection), ready: answersReady(selection)) else { return }
        if let panelNext { shownPanel.show(panelNext) }
        row.show(rowNext)
    }

    // MARK: Painting once

    /// What the panel and the row describe: the item, the items, or nothing.
    private func displayKey(_ selection: SelectionDetails?) -> String {
        if let selection { return "items\u{0}" + selection.entries.map(\.path).joined(separator: "\u{0}") }
        return "item\u{0}" + (targetPath ?? "")
    }

    /// Whether the answers that are quick to come are in for what is described: the item's properties, its details,
    /// its apps and its tags; for several items, their tags. What takes longer (an app's signing, a folder's size)
    /// fills in where it is afterwards.
    private func answersReady(_ selection: SelectionDetails?) -> Bool {
        if let selection {
            let key = selection.entries.map { DiskPath($0.path) }
            return selection.entries.count > TagColorsMenuRow.stateLimit || (tagsRead?.key == key && !tagsStale)
        }
        guard let path = targetPath else { return true }
        guard let resolved, resolved.item.path == path, !resolved.pending else { return false }
        if details?.path != path { return false }
        guard panelOpen else { return true }
        let item = resolved.item
        let isFile = item.kind == .file || item.kind == .symlinkFile
        if lookup.opensWith(for: path, isFile: isFile, canAlways: OpenWithMenu.canAlwaysOpenWith) == .pending {
            return false
        }
        if VolumePaths.isVolumeRootPath(path), volume?.path != path { return false }
        return tagsRead?.key == [DiskPath(path)]
    }

    /// Whether to paint now: the same item again (its values change in place), the first item since the panel or the
    /// row opened, or another item whose quick answers are in. Otherwise what is shown stays while they come, up to
    /// `holdGrace`; past it the other item shows with dashes, and its answers fill in where they are.
    private func paints(_ key: String, ready: Bool) -> Bool {
        if key == paintedKey || paintedKey == nil || ready {
            paintedKey = key
            holding?.timer.cancel()
            holding = nil
            return true
        }
        guard holding?.key != key else { return false }
        holding?.timer.cancel()
        let timer = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.holding?.key == key else { return }
                self.holding = nil
                self.paintedKey = key
                self.update()
            }
        }
        holding = (key, timer)
        DispatchQueue.main.asyncAfter(deadline: .now() + holdGrace, execute: timer)
        return false
    }

    /// An answer came: what came within the same frame is shown in one change.
    private func updateNextFrame() {
        guard !frameQueued else { return }
        frameQueued = true
        DispatchQueue.main.asyncAfter(deadline: .now() + InfoMetrics.frameInterval) { [weak self] in
            MainActor.assumeIsolated {
                self?.frameQueued = false
                self?.update()
            }
        }
    }

    private func shortcutDisplay(_ preferences: AppPreferences) -> ShortcutDisplay {
        ShortcutDisplay(
            shortcuts: ShortcutCommands.resolve(preferences.shortcutOverrides),
            returnKeyAction: preferences.returnKeyAction)
    }

    /// Several selected items: their entries (those shown), the sum of their sizes and the folder size controls.
    private struct SelectionDetails {
        var entries: [DirectoryEntry]
        var size: SelectionSize
    }

    /// The selected entries the filter leaves shown.
    private var shownSelectedEntries: [DirectoryEntry] {
        content.selectedEntries.filter { content.position(of: $0.path) != nil }
    }

    private func requestFileDetails(_ entries: [DirectoryEntry]) {
        content.requestMetadata(for: entries.filter { !$0.isFolderSizeEligible })
    }

    private func selectionDetails() -> SelectionDetails? {
        guard content.selection.paths.count > 1 else { return nil }
        let entries = shownSelectedEntries
        guard entries.count > 1 else { return nil }
        requestFileDetails(entries)
        let items = entries.map { SelectionItem(path: $0.path, isFolderSizeEligible: $0.isFolderSizeEligible) }
        let size = SelectionSizing.summarize(
            items,
            fileSize: { [content] path in
                if let metadata = content.metadata(for: path) {
                    return metadata.sizeStatus == .ready ? metadata.sizeBytes : nil
                }
                return nil
            },
            folderSize: { [folderSizes = host.folderSizes] in folderSizes.entry($0) })
        return SelectionDetails(entries: entries, size: size)
    }

    private func panelDisplay(
        _ preferences: AppPreferences, _ shortcuts: ShortcutDisplay, _ selection: SelectionDetails?
    )
        -> InfoPanelDisplay
    {
        permissionPaths = []
        if let selection {
            permissionPaths = selection.entries.map(\.path)
            let files = selection.entries.filter { $0.kind != .directory }.count
            let parents = Set(selection.entries.map { PathBarModel.parentPath($0.path) })
            let summary = InfoSelection(
                count: selection.entries.count, folderCount: selection.entries.count - files, fileCount: files,
                totalBytes: selection.size.totalBytes, parentPath: parents.count == 1 ? parents.first : nil)
            let hasFolders = selection.size.folderSizeEntry != nil
            return InfoPanelDisplay(
                body: .selection(
                    .init(
                        summary: summary,
                        sections: InfoPanelModel.selectionContent(
                            summary, facts: selectionFacts(selection.entries), hasFolderSize: hasFolders,
                            folderSize: selection.size.folderSizeEntry, homePath: homePath,
                            startupDiskName: startupDiskName,
                            tags: tagsState(
                                selection.entries.map(\.path),
                                editable: !selection.entries.contains {
                                    Paths.isInsideTrash($0.path, homePath: homePath)
                                })),
                        folderSize: selection.size.folderSizeEntry)), wantsSpinner: false)
        }
        guard let resolved else {
            let wants = loading
            return InfoPanelDisplay(body: loading ? .blank : .empty, wantsSpinner: wants)
        }
        let item = resolved.item
        permissionPaths = [item.path]
        let isVolume = VolumePaths.isVolumeRootPath(item.path)
        if isVolume { requestVolume(item.path) }
        requestLookup(item.path, type: Self.lookupType(item))
        let isFile = item.kind == .file || item.kind == .symlinkFile
        let opens = lookup.opensWith(for: item.path, isFile: isFile, canAlways: OpenWithMenu.canAlwaysOpenWith)
        let folderPath = item.kind.isFolderSizeEligible ? item.path : nil
        let folderSize = folderPath.map { host.folderSizes.entry($0) }
        // A disk's root and what is in the Trash show their tags; they aren't changed from here.
        let tags = tagsState(
            [item.path],
            editable: !isVolume && !Paths.isInsideTrash(item.path, homePath: homePath)
                && item.path != FavoriteLabel.trashPath(homePath: homePath))
        let content = InfoPanelModel.itemContent(
            item: item, pending: resolved.pending, volume: volume?.path == item.path ? volume?.value : nil,
            isVolumeRoot: isVolume, hasFolderSize: folderSize != nil, folderSize: folderSize, opensWith: opens,
            dates: .shared, homePath: homePath, startupDiskName: startupDiskName, tags: tags,
            details: detailsState(item.path), signing: signingState(item))
        let app =
            isFile ? lookup.answer(for: item.path)?.defaultApp.map { InfoOpenApp(path: $0.path, name: $0.name) } : nil
        return InfoPanelDisplay(
            body: .item(.init(item: item, content: content, folderSize: folderSize, openApp: app)),
            wantsSpinner: resolved.pending || (loading && properties == nil))
    }

    /// What the panel and the row sum up of several items, from the listing: their kinds, dates and modes.
    private func selectionFacts(_ entries: [DirectoryEntry]) -> InfoSelectionFacts {
        var facts = InfoSelectionFacts()
        for entry in entries {
            let metadata = content.metadata(for: entry.path)
            facts.kindLabels.append(
                metadata?.kindLabel
                    ?? InfoPreview.fallbackKindLabel(
                        kind: FTFoundation.EntryKind(rawValue: entry.kind.rawValue) ?? .other,
                        fileExtension: entry.fileExtension))
            if let date = metadata?.createdAt ?? entry.listedCreatedAt { facts.created.append(date) }
            if let date = metadata?.modifiedAt ?? entry.listedModifiedAt { facts.modified.append(date) }
            facts.modes.append(metadata?.permissionMode ?? entry.permissionMode)
        }
        return facts
    }

    /// The folder size control, while a folder's size isn't known: the status bar has the size once it is, and
    /// nothing to click before.
    private func sizeControl(_ entry: FolderSizeEntry) -> InfoRowDisplay.Fact? {
        if case .ready = entry { return nil }
        return .init(content: .folderSize(entry), tooltip: nil)
    }

    private func rowDisplay(_ selection: SelectionDetails?) -> InfoRowDisplay? {
        if let selection {
            // Several: what kinds they are and when they changed; their count and size are the status bar's.
            let leadPath = content.selection.leadPath.map(DiskPath.init)
            let lead = selection.entries.first { DiskPath($0.path) == leadPath } ?? selection.entries[0]
            let summary = InfoPanelModel.selectionRowFacts(selectionFacts(selection.entries))
            var facts: [InfoRowDisplay.Fact] = []
            if let entry = selection.size.folderSizeEntry, let control = sizeControl(entry) { facts.append(control) }
            if let modified = summary.modified { facts.append(.init(content: .text(modified), tooltip: nil)) }
            return InfoRowDisplay(
                name: summary.kinds.full, nameShort: summary.kinds.short, nameTooltip: summary.kinds.full,
                icon: lead.iconEntry, facts: facts)
        }
        let single = content.selectedEntries.first
        let active: InfoEntry?
        var iconEntry: IconEntry?
        var isShownFolder = false
        if let single, content.selection.paths.count == 1 {
            active = infoEntry(single)
            iconEntry = single.iconEntry
        } else if !folderPath.isEmpty {
            active = InfoPreview.folderEntry(folderPath, homePath: homePath, startupDiskName: startupDiskName)
            iconEntry = IconEntry(path: folderPath, name: active?.name ?? "", kind: .directory)
            isShownFolder = true
            // The room left on its disk, which the status bar doesn't say.
            if rowOpen { requestRowVolume(folderPath) }
        } else {
            return nil
        }
        guard let active else { return nil }
        let folderSize = active.kind.isFolderSizeEligible ? host.folderSizes.entry(active.path) : nil
        let facts = InfoPanelModel.rowFacts(
            entry: active, metadata: infoMetadata(content.metadata(for: active.path)), item: properties,
            folderSize: folderSize, details: details?.path == active.path ? details?.value : nil,
            isShownFolder: isShownFolder,
            availableBytes: rowVolume?.path == folderPath ? rowVolume?.available : nil,
            now: RelativeClock.shared.relativeNow, dates: .shared, homePath: homePath)
        var list: [InfoRowDisplay.Fact] = []
        if let kind = facts.kind { list.append(.init(content: .text(kind), tooltip: kind)) }
        if facts.showsFolderSize, let folderSize {
            list.append(.init(content: .folderSize(folderSize), tooltip: nil))
        } else if let fact = facts.fact {
            var tooltip: String?
            if case .ready(let size, let disk, let files, let folders)? = folderSize {
                let lines = InfoPanelModel.folderSizeLines(
                    sizeBytes: size, diskBytes: disk, fileCount: files, folderCount: folders)
                tooltip = "\(lines.top) · \(lines.items)"
            }
            list.append(.init(content: .text(fact), tooltip: tooltip ?? fact))
        }
        if let modified = facts.modified {
            list.append(.init(content: .text(modified), tooltip: facts.modifiedTooltip))
        }
        if let available = facts.available { list.append(.init(content: .text(available), tooltip: nil)) }
        let name = InfoPreview.displayName(active.path, name: active.name, homePath: homePath)
        return InfoRowDisplay(name: name, nameTooltip: name, icon: iconEntry, facts: list)
    }

    // MARK: Folder sizes

    /// The folder paths the panel's size controls work on now: the selected folders, or the one folder it describes.
    private var sizeTargets: [String] {
        if selectionDetails() == nil, panelOpen, let item = resolved?.item, item.kind.isFolderSizeEligible {
            return [item.path]
        }
        return rowSizeTargets
    }

    /// The folder paths the Info Row's size controls work on: what the row shows, whatever item the panel is on.
    private var rowSizeTargets: [String] {
        if let selection = selectionDetails() { return selection.size.folderPaths }
        if let single = content.selectedEntries.first, content.selection.paths.count == 1 {
            return single.isFolderSizeEligible ? [single.path] : []
        }
        return folderPath.isEmpty ? [] : [folderPath]
    }

    private func calculate(forced: Bool, targets chosen: [String]? = nil) {
        let targets = chosen ?? sizeTargets
        let sizes = host.folderSizes
        if targets.count == 1, let path = targets.first {
            forced ? sizes.recalculate(path) : sizes.calculate(path)
        } else if targets.count > 1 {
            sizes.calculate(targets, recalculate: forced)
        }
        update()
    }

    private func cancelCalculating(targets chosen: [String]? = nil) {
        let targets = chosen ?? sizeTargets
        if targets.count == 1, let path = targets.first {
            host.folderSizes.cancel(path)
        } else {
            host.folderSizes.cancel(targets)
        }
        update()
    }

    /// The Calculate Size command: what `calculateSizePaths` names, measured again, one folder or several. Unlike
    /// the menus' item it never opens the panel.
    func calculateSizeCommand() {
        let sizes = host.folderSizes
        let targets = host.calculateSizePaths
        if targets.count == 1, let path = targets.first {
            sizes.recalculate(path)
        } else if targets.count > 1 {
            sizes.calculate(targets, recalculate: true)
        }
        update()
    }

    private func updateAutoSize(_ preferences: AppPreferences) {
        var selected: (path: String, kind: FTFoundation.EntryKind)?
        if let entry = content.selectedEntries.first, content.selection.paths.count == 1 {
            selected = (entry.path, FTFoundation.EntryKind(rawValue: entry.kind.rawValue) ?? .other)
        }
        // With nothing selected both describe the folder on screen, however it was opened: its kind is the one the
        // panel has for it once its properties are in (a bundle opened as a folder), else a folder's.
        var folder: (path: String, kind: FTFoundation.EntryKind)?
        if content.selection.paths.isEmpty, !folderPath.isEmpty {
            let item = resolved?.item
            folder = (folderPath, item?.path == folderPath ? item?.kind ?? .directory : .directory)
        }
        // A tab behind another tab, or in a minimized window, measures nothing by itself: what it asked for goes,
        // and it asks again when it is shown.
        let window = host.window
        let hidden = window?.isBehindAnotherTab == true || window?.isMiniaturized == true
        let measures = preferences.autoCalculateFolderSizes && !hidden
        let shown = targetOverride == nil ? nil : resolved?.item
        // Several selected: the folders among those shown, from the top of the list down.
        var several: [(path: String, kind: FTFoundation.EntryKind)] = []
        if measures, panelOpen || rowOpen, content.selection.paths.count > 1 {
            let placed = content.selectedEntries.filter(\.isFolderSizeEligible).compactMap { entry in
                content.position(of: entry.path).map { (entry, $0) }
            }
            several = placed.sorted { $0.1 < $1.1 }.map {
                ($0.0.path, FTFoundation.EntryKind(rawValue: $0.0.kind.rawValue) ?? .other)
            }
        }
        auto.setPaths(
            AutoFolderSize.paths(
                infoPanelOpen: measures && panelOpen, infoRowOpen: measures && rowOpen,
                selectedPaths: content.selection.paths, selected: selected, selection: several, shownFolder: folder,
                showInfoPath: targetOverride, infoItem: shown.map { ($0.path, $0.kind) }, homePath: homePath))
    }

    // MARK: Open With

    /// The menu: under its button, 4 pt below, its right edge on the button's.
    private func showMenu(_ menu: AppMenu, anchor: NSView, window: NSWindow, onClose: @escaping () -> Void) {
        guard let host = AppMenuPresenter.overlayHost(of: window) else { return }
        let rect = anchor.convert(anchor.bounds, to: host)
        let top = (host.isFlipped ? rect.maxY : host.bounds.height - rect.minY) + 4
        AppMenuPresenter.shared.show(
            menu, in: window, at: NSPoint(x: rect.maxX - menu.size.width, y: top), owner: anchor, onClose: onClose)
    }

    /// A row of the Open With menus: an app with its own icon, else plain text from the same edge.
    static func openWithRow(_ action: OpenWithAction) -> AppMenuItem {
        var row = AppMenuItem(title: action.label)
        if case .application(_, _, let appPath, _, _) = action { row.appPath = appPath }
        return row
    }

    /// What says the menu's apps are for Always Open With, while Option is held.
    static var alwaysOpenWithHeading: AppMenuItem { .heading("Always Open With") }

    private func presentOpenWith(from anchor: NSView, changeDefault: Bool) {
        guard let item = resolved?.item, let window = anchor.window else { return }
        let pinned = host.preferences.openWithApplications
        let lookupValue = lookup.answer(for: item.path)
        let isFile = item.kind == .file || item.kind == .symlinkFile
        let always = isFile && OpenWithMenu.canAlwaysOpenWith(lookupValue)
        let kind = always ? lookupValue?.kinds.first : nil
        let defaultApp = lookupValue?.defaultApp
        func build(optionHeld: Bool) -> [AppMenuItem] {
            let useAlways = changeDefault || (optionHeld && always)
            let list = OpenWithMenu.menuItems(lookup: lookupValue, pinned: pinned, always: useAlways)
            var items: [AppMenuItem] = []
            if useAlways && !changeDefault {
                items.append(Self.alwaysOpenWithHeading)
            }
            for entry in list {
                switch entry {
                case .separator: items.append(.separator)
                case .action(let action):
                    var menuItem = Self.openWithRow(action)
                    menuItem.action = { [weak self] in
                        if changeDefault {
                            if case .application(_, _, let appPath, _, _) = action, appPath == defaultApp?.path {
                                return
                            }
                            self?.actions.changeDefaultApp(action, kind: kind)
                        } else {
                            self?.actions.runOpenWith(action, paths: [item.path], kind: kind)
                        }
                    }
                    items.append(menuItem)
                }
            }
            return items
        }
        let setOpen: (Bool) -> Void = { [weak self] open in
            if changeDefault {
                self?.shownPanel.setOpensWithMenuOpen(open)
            } else {
                self?.shownPanel.setOpenMenuOpen(open)
            }
        }
        let held = optionHeld()
        let menu = AppMenu(
            items: build(optionHeld: held), identifier: "contextMenu.submenu",
            rowIdentifier: "infoPanel.openWithMenu.item", minWidth: 200)
        // Option swaps the menu to Always Open With while it is open.
        if !changeDefault, always { menu.watchOption(held: held, items: build(optionHeld:)) }
        showMenu(menu, anchor: anchor, window: window) { setOpen(false) }
        setOpen(true)
    }
}
