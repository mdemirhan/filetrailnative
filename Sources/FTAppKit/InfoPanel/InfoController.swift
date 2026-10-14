// Port of what apps/desktop/src/renderer/App.tsx (:512-700, 2192-2260, 2535-2660) and hooks/useExplorerNavigationController.ts
// (:2300-2430) keep for the Info panel and the Info Row: the target, its properties, the volume and Open With answers, and the
// folder size controls
import AppKit
import FTFileSystem
import FTFoundation

/// Keeps the Info panel and the Info Row describing what the window points at, and carries out what they offer.
@MainActor
final class InfoController {
    unowned let host: MainWindowController
    let panel: InfoPanelView
    let row: InfoRowView
    let auto: AutoFolderSizeController

    // The target.
    /// "Show Info" on an item: the panel describes this path whatever the selection (B-INFO-009).
    private(set) var targetOverride: String?
    // Properties.
    private var properties: InfoItem?
    private var cache: [(path: String, item: InfoItem)] = []
    private var fetchTimer: DispatchWorkItem?
    private var fetchTarget: String?
    private var loading = false
    // The volume.
    private var volume: (path: String, value: InfoVolume)?
    private var volumeRequested: String?
    // Open With.
    private var lookup: (path: String, value: OpenWithLookup?, ready: Bool)?
    private var lookupTimer: DispatchWorkItem?
    private var lookupPatience: DispatchWorkItem?
    private var lookupGeneration = 0
    // The copy buttons.
    private var copied: InfoPanelModel.QuickAction.ID?
    private var copiedTimer: DispatchWorkItem?
    private var observation: ExplorerWindowObservation?
    private var relativeRelease: RelativeClock.Release?
    private var refreshQueued = false
    let actions: InfoActions

    init(host: MainWindowController, panel: InfoPanelView, row: InfoRowView) {
        self.host = host
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
                self.targetOverride = nil
                self.folderChanged()
            case .selection:
                self.targetOverride = nil
                self.update()
            case .panels, .preferences, .view, .history, .search: self.update()
            default: break
            }
        }
        host.content.onDetailsChanged = { [weak self] in self?.queueUpdate() }
        relativeRelease = RelativeClock.shared.subscribe { [weak self] in self?.update() }
        update()
    }

    isolated deinit {
        relativeRelease?()
        fetchTimer?.cancel()
    }

    private func wire() {
        panel.iconStore = host.services.iconStore
        row.iconStore = host.services.iconStore
        panel.onClose = { [weak self] in self?.host.updatePanels { $0.propertiesOpen = false } }
        panel.onNavigate = { [weak self] path in
            guard let self else { return }
            self.host.go(to: URL(fileURLWithPath: path))
        }
        panel.onOpen = { [weak self] in
            guard let self, let path = self.resolved?.item.path else { return }
            self.actions.openExternally(path)
        }
        panel.onAction = { [weak self] id in self?.quickAction(id) }
        panel.onOpenWithMenu = { [weak self] anchor in self?.presentOpenWith(from: anchor, changeDefault: false) }
        panel.onOpensWithMenu = { [weak self] anchor in self?.presentOpenWith(from: anchor, changeDefault: true) }
        panel.onCalculate = { [weak self] in self?.calculate(forced: false) }
        panel.onRecalculate = { [weak self] in self?.calculate(forced: true) }
        panel.onCancel = { [weak self] in self?.cancelCalculating() }
        row.onCalculate = { [weak self] in self?.calculate(forced: false) }
        row.onRecalculate = { [weak self] in self?.calculate(forced: true) }
        row.onCancel = { [weak self] in self?.cancelCalculating() }
    }

    private var content: ContentPaneController { host.content }
    private var panelOpen: Bool { host.panels.propertiesOpen }
    private var rowOpen: Bool { host.panels.detailRowOpen }
    private var homePath: String { FileManager.default.homeDirectoryForCurrentUser.path }
    private var folderPath: String { host.currentFolder.path }

    // MARK: The target

    /// Where the views point: the Show Info target, else the selection's lead, else the folder on screen (B-INFO-001).
    var targetPath: String? {
        if let targetOverride { return targetOverride }
        if let lead = content.selection.leadPath { return lead }
        return folderPath.isEmpty ? nil : folderPath
    }

    /// "Show Info": the panel opens and describes `path` (B-INFO-009).
    func showInfo(for path: String) {
        targetOverride = path
        if !panelOpen { host.updatePanels { $0.propertiesOpen = true } }
        scheduleFetch(path, immediately: true)
        update()
    }

    private func entry(at path: String) -> DirectoryEntry? {
        if let selected = content.selectedEntries.first(where: { $0.path == path }) { return selected }
        return content.listed.first { $0.path == path }
    }

    private func infoEntry(_ entry: DirectoryEntry) -> InfoEntry {
        InfoEntry(
            path: entry.path, name: entry.name, fileExtension: entry.fileExtension,
            kind: FTFoundation.EntryKind(rawValue: entry.kind.rawValue) ?? .other, isHidden: entry.isHidden,
            isSymlink: entry.isSymlink)
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
        let found = entry(at: path).map { [infoEntry($0)] } ?? []
        let metadata = infoMetadata(content.metadata(for: path)).map { [path: $0] } ?? [:]
        return InfoPreview.resolve(
            path: path, currentPath: folderPath, entries: found, metadataByPath: metadata, properties: properties)
    }

    // MARK: Properties (B-INFO-012 to 019)

    private func folderChanged() {
        // The folder reloaded or another one opened: what is shown stays, and is asked for again.
        if let path = targetPath { scheduleFetch(path, immediately: false) }
        update()
    }

    private func scheduleFetch(_ path: String, immediately: Bool) {
        fetchTimer?.cancel()
        fetchTimer = nil
        guard panelOpen || rowOpen, !folderPath.isEmpty else { return }
        if let cached = cache.first(where: { $0.path == path }) {
            properties = cached.item
            loading = false
        } else {
            loading = true
        }
        fetchTarget = path
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.fetch(path) }
        }
        fetchTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (immediately ? 0 : InfoMetrics.fetchDelay), execute: work)
    }

    private func fetch(_ path: String) {
        fetchTimer = nil
        let service = host.services.directoryService
        Task { @MainActor [weak self] in
            let item = await service.itemProperties(path: path)
            guard let self else { return }
            let mapped = InfoItem(
                path: item.path, name: item.name, fileExtension: item.fileExtension,
                kind: FTFoundation.EntryKind(rawValue: item.kind.rawValue) ?? .other, kindLabel: item.kindLabel,
                isHidden: item.isHidden, isSymlink: item.isSymlink, createdAt: item.createdAt,
                modifiedAt: item.modifiedAt, sizeBytes: item.sizeBytes,
                sizeStatus: FTFoundation.SizeStatus(rawValue: item.sizeStatus.rawValue) ?? .deferred,
                permissionMode: item.permissionMode)
            self.cache.removeAll { $0.path == path }
            self.cache.append((path, mapped))
            if self.cache.count > InfoMetrics.propertiesCacheLimit {
                self.cache.removeFirst(self.cache.count - InfoMetrics.propertiesCacheLimit)
            }
            // A response for a request that is no longer the latest is cached, not shown.
            guard self.fetchTarget == path else { return }
            self.loading = false
            self.properties = mapped
            self.update()
        }
    }

    // MARK: Volume (B-INFO-047 to 049)

    private func requestVolume(_ path: String) {
        guard volumeRequested != path else { return }
        volumeRequested = path
        Task { @MainActor [weak self] in
            let sizes = await Task.detached { VolumeInfo.sizes(atPath: path) }.value
            guard let self, self.volumeRequested == path else { return }
            self.volume = (path, InfoVolume(totalBytes: sizes.totalBytes, availableBytes: sizes.availableBytes))
            self.update()
        }
    }

    // MARK: Open With (B-INFO-065)

    private func requestLookup(_ path: String) {
        guard lookup?.path != path else { return }
        lookup = (path, nil, false)
        lookupTimer?.cancel()
        lookupPatience?.cancel()
        lookupGeneration += 1
        let generation = lookupGeneration
        let pinned = host.preferences.openWithApplications
        let patience = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.lookup?.path == path, self.lookupGeneration == generation else { return }
                self.lookup?.ready = true
                self.update()
            }
        }
        lookupPatience = patience
        DispatchQueue.main.asyncAfter(
            deadline: .now() + InfoMetrics.openWithDelay + InfoMetrics.openWithPatience, execute: patience)
        let start = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { @MainActor in
                    let answer = await SystemActions.openWithApplications(
                        paths: [path], pinnedAppPaths: pinned.map(\.appPath))
                    guard self.lookup?.path == path, self.lookupGeneration == generation else { return }
                    self.lookup = (path, answer, true)
                    self.update()
                }
            }
        }
        lookupTimer = start
        DispatchQueue.main.asyncAfter(deadline: .now() + InfoMetrics.openWithDelay, execute: start)
    }

    /// Always Open With changed what a kind opens in: every answer is forgotten and asked again.
    func forgetLookups() {
        OpenWithCatalog.shared.forget()
        let path = lookup?.path
        lookup = nil
        if let path { requestLookup(path) }
    }

    var openWithLookup: OpenWithLookup? { lookup?.value }

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
        let preferences = host.preferences
        let shortcuts = shortcutDisplay(preferences)
        panel.closeTooltip = Tooltips.format("Hide Info Panel", shortcutLabel: shortcuts.label(.toggleInfoPanel))
        let selection = selectionDetails()
        updateAutoSize(preferences)
        if panelOpen || rowOpen {
            if fetchTarget != targetPath || (properties == nil && !loading) {
                if let path = targetPath { scheduleFetch(path, immediately: false) }
            }
        } else {
            fetchTimer?.cancel()
            fetchTarget = nil
        }
        if panelOpen { panel.show(panelDisplay(preferences, shortcuts, selection)) }
        row.show(rowDisplay(selection))
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

    private func selectionDetails() -> SelectionDetails? {
        guard content.selection.paths.count > 1 else { return nil }
        let shown = Set(content.entries.map(\.path))
        let entries = content.selectedEntries.filter { shown.contains($0.path) }
        guard entries.count > 1 else { return nil }
        content.requestMetadata(for: entries.filter { !$0.isFolderSizeEligible }.map(\.path))
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
        if let selection {
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
                        rows: InfoPanelModel.selectionRows(
                            summary, hasFolderSize: hasFolders, folderSize: selection.size.folderSizeEntry),
                        folderSize: selection.size.folderSizeEntry)), wantsSpinner: false)
        }
        guard let resolved else {
            let wants = loading
            return InfoPanelDisplay(body: loading ? .blank : .empty, wantsSpinner: wants)
        }
        let item = resolved.item
        let isVolume = VolumePaths.isVolumeRootPath(item.path)
        if isVolume { requestVolume(item.path) }
        requestLookup(item.path)
        let isFile = item.kind == .file || item.kind == .symlinkFile
        let lookupForItem = lookup?.path == item.path ? lookup : nil
        let canAlways = OpenWithMenu.canAlwaysOpenWith(lookupForItem?.value)
        let opens: InfoPanelModel.OpensWithState =
            isFile && !(lookupForItem?.ready ?? false) ? .pending : (isFile && canAlways ? .available : .hidden)
        let folderPath = item.kind.isFolderSizeEligible ? item.path : nil
        let folderSize = folderPath.map { host.folderSizes.entry($0) }
        let content = InfoPanelModel.itemContent(
            item: item, pending: resolved.pending, volume: volume?.path == item.path ? volume?.value : nil,
            isVolumeRoot: isVolume, hasFolderSize: folderSize != nil, folderSize: folderSize, opensWith: opens,
            dates: .original)
        let app = isFile ? lookupForItem?.value?.defaultApp.map { InfoOpenApp(path: $0.path, name: $0.name) } : nil
        let trash = FavoriteLabel.trashPath(homePath: homePath)
        let canFavorite = item.path != trash
        let actionList = InfoPanelModel.quickActions(
            item: item, textEditorName: preferences.defaultTextEditor.appName,
            isFavorite: host.sidebarController.isFavorite(item.path), canFavorite: canFavorite, copied: copied,
            shortcut: { shortcuts.label($0) })
        return InfoPanelDisplay(
            body: .item(
                .init(
                    item: item, content: content, folderSize: folderSize, openApp: app, hasOpenWith: true,
                    actions: actionList, copied: copied)),
            wantsSpinner: resolved.pending || (loading && properties == nil))
    }

    private func rowDisplay(_ selection: SelectionDetails?) -> InfoRowDisplay? {
        if let selection {
            let lead = selection.entries.first { $0.path == content.selection.leadPath } ?? selection.entries[0]
            var facts: [InfoRowDisplay.Fact] = []
            if let entry = selection.size.folderSizeEntry {
                var tooltip: String?
                if case .ready(let size, let disk, let files, let folders) = entry {
                    let lines = InfoPanelModel.folderSizeLines(
                        sizeBytes: size, diskBytes: disk, fileCount: files, folderCount: folders)
                    tooltip = "\(lines.top) · \(lines.items)"
                }
                facts.append(.init(content: .folderSize(entry), tooltip: tooltip))
            } else if let total = selection.size.totalBytes {
                facts.append(.init(content: .text(SizeText.size(total)), tooltip: nil))
            }
            return InfoRowDisplay(
                name: InfoPanelModel.selectionName(
                    InfoSelection(
                        count: selection.entries.count, folderCount: 0, fileCount: 0, totalBytes: nil, parentPath: nil)),
                nameTooltip: nil, icon: lead.iconEntry, facts: facts)
        }
        let single = content.selectedEntries.first
        let active: InfoEntry?
        var iconEntry: IconEntry?
        if let single, content.selection.paths.count == 1 {
            active = infoEntry(single)
            iconEntry = single.iconEntry
        } else if !folderPath.isEmpty {
            active = InfoPreview.folderEntry(folderPath)
            iconEntry = IconEntry(path: folderPath, name: active?.name ?? "", kind: .directory)
        } else {
            return nil
        }
        guard let active else { return nil }
        let folderSize = active.kind.isFolderSizeEligible ? host.folderSizes.entry(active.path) : nil
        let facts = InfoPanelModel.rowFacts(
            entry: active, metadata: infoMetadata(content.metadata(for: active.path)),
            item: properties, folderSizeKnown: folderSize != nil, now: RelativeClock.shared.relativeNow,
            parseDate: { ISODate.parse($0) }, dates: .original)
        var list: [InfoRowDisplay.Fact] = [.init(content: .text(facts.kind), tooltip: facts.kind)]
        if facts.showsFolderSize, let folderSize {
            var tooltip: String?
            if case .ready(let size, let disk, let files, let folders) = folderSize {
                let lines = InfoPanelModel.folderSizeLines(
                    sizeBytes: size, diskBytes: disk, fileCount: files, folderCount: folders)
                tooltip = "\(lines.top) · \(lines.items)"
            }
            list.append(.init(content: .folderSize(folderSize), tooltip: tooltip))
        } else if let size = facts.size {
            list.append(.init(content: .text(size), tooltip: nil))
        }
        if let modified = facts.modified {
            list.append(.init(content: .text(modified), tooltip: facts.modifiedTooltip))
        }
        return InfoRowDisplay(name: active.name, nameTooltip: active.name, icon: iconEntry, facts: list)
    }

    // MARK: Folder sizes

    /// The folder paths the size controls work on now: the selected folders, or the one folder the views describe.
    private var sizeTargets: [String] {
        if let selection = selectionDetails() { return selection.size.folderPaths }
        if panelOpen, let item = resolved?.item, item.kind.isFolderSizeEligible { return [item.path] }
        if let single = content.selectedEntries.first, content.selection.paths.count == 1 {
            return single.isFolderSizeEligible ? [single.path] : []
        }
        return folderPath.isEmpty ? [] : [folderPath]
    }

    private func calculate(forced: Bool) {
        let targets = sizeTargets
        let sizes = host.folderSizes
        if targets.count == 1, let path = targets.first {
            forced ? sizes.recalculate(path) : sizes.calculate(path)
        } else if targets.count > 1 {
            sizes.calculate(targets, recalculate: forced)
        }
        update()
    }

    private func cancelCalculating() {
        let targets = sizeTargets
        if targets.count == 1, let path = targets.first {
            host.folderSizes.cancel(path)
        } else {
            host.folderSizes.cancel(targets)
        }
        update()
    }

    /// The Calculate Size command (B-INFO-160 to 164).
    func calculateSizeCommand() {
        let sizes = host.folderSizes
        let tree = host.focusedPane == .tree
        var targets: [String] = []
        if tree, let path = host.sidebarController.selectedTreeTargetPath {
            targets = [path]
            // The size would show nowhere else: the Info panel opens for it (B-INFO-164).
            if path != folderPath {
                targetOverride = path
                if !panelOpen { host.updatePanels { $0.propertiesOpen = true } }
            }
        } else {
            let selected = content.selectedEntries.filter(\.isFolderSizeEligible).map(\.path)
            if !selected.isEmpty {
                targets = selected
            } else if content.selection.paths.isEmpty, !folderPath.isEmpty, host.searchRootPath == nil {
                targets = [folderPath]
            }
        }
        if targets.count == 1, let path = targets.first {
            sizes.recalculate(path)
        } else if targets.count > 1 {
            sizes.calculate(targets)
        }
        update()
    }

    private func updateAutoSize(_ preferences: AppPreferences) {
        var selected: (path: String, kind: FTFoundation.EntryKind)?
        if let entry = content.selectedEntries.first, content.selection.paths.count == 1 {
            selected = (entry.path, FTFoundation.EntryKind(rawValue: entry.kind.rawValue) ?? .other)
        }
        let path =
            preferences.autoCalculateFolderSizes && targetOverride == nil
            ? AutoFolderSize.path(
                infoPanelOpen: panelOpen, selectedPaths: content.selection.paths, selected: selected,
                homePath: homePath) : nil
        auto.setPath(path)
    }

    // MARK: Quick actions and Open With

    private func quickAction(_ id: InfoPanelModel.QuickAction.ID) {
        guard let item = resolved?.item else { return }
        switch id {
        case .quickLook: host.perform(.quickLookSelection)
        case .edit: actions.edit(item.path)
        case .copyPath:
            if actions.copy(formatPathForShell(item.path), what: "Path") { flashCopied(.copyPath) }
        case .copyName:
            if actions.copy(item.name, what: "Name") { flashCopied(.copyName) }
        case .terminal: actions.openInTerminal(item.path)
        case .finder: actions.showInFinder(item.path)
        case .favorite: host.sidebarController.toggleFavorite(item.path)
        case .rootTree: host.sidebarController.rootTree(at: item.path)
        }
        update()
    }

    private func flashCopied(_ id: InfoPanelModel.QuickAction.ID) {
        copied = id
        copiedTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.copied = nil
                self?.update()
            }
        }
        copiedTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + InfoMetrics.copiedDelay, execute: work)
    }

    private var openMenuWatcher: Int?
    private var swappingMenu = false

    /// `.pull-down-menu`: under its button, 4 pt below, its right edge on the button's.
    private func showMenu(_ menu: AppMenuView, anchor: NSView, window: NSWindow, onClose: @escaping () -> Void) {
        guard let host = window.contentView else { return }
        let rect = anchor.convert(anchor.bounds, to: host)
        let top = (host.isFlipped ? rect.maxY : host.bounds.height - rect.minY) + 4
        let size = menu.fittingMenuSize
        AppMenuPresenter.shared.show(
            menu, in: window, at: NSPoint(x: rect.maxX - size.width, y: top), owner: anchor, onClose: onClose)
    }

    private func presentOpenWith(from anchor: NSView, changeDefault: Bool) {
        guard let item = resolved?.item, let window = anchor.window else { return }
        let pinned = host.preferences.openWithApplications
        let lookupValue = lookup?.path == item.path ? lookup?.value : nil
        let isFile = item.kind == .file || item.kind == .symlinkFile
        let always = isFile && OpenWithMenu.canAlwaysOpenWith(lookupValue)
        let kind = always ? lookupValue?.kinds.first : nil
        let defaultApp = lookupValue?.defaultApp
        func build(optionHeld: Bool) -> AppMenuView {
            let useAlways = changeDefault || (optionHeld && always)
            let list = OpenWithMenu.menuItems(lookup: lookupValue, pinned: pinned, always: useAlways)
            var items: [AppMenuItem] = []
            if useAlways && !changeDefault { items.append(AppMenuItem(title: "Always Open With", enabled: false)) }
            for entry in list {
                switch entry {
                case .separator: items.append(.separator)
                case .action(let action):
                    var menuItem = AppMenuItem(title: action.label)
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
            let menu = AppMenuView(
                items: items, style: .keyboard, identifier: "contextMenu.submenu",
                rowIdentifier: "infoPanel.openWithMenu.item", minWidth: 200)
            menu.activeIndex = nil
            return menu
        }
        let setOpen: (Bool) -> Void = { [weak self] open in
            if changeDefault { self?.panel.setOpensWithMenuOpen(open) } else { self?.panel.setOpenMenuOpen(open) }
        }
        let close: () -> Void = { [weak self] in
            if self?.swappingMenu == true { return }
            setOpen(false)
            if let watcher = self?.openMenuWatcher { WindowEventRouting.remove(watcher, from: window) }
            self?.openMenuWatcher = nil
        }
        showMenu(
            build(optionHeld: NSEvent.modifierFlags.contains(.option)), anchor: anchor, window: window, onClose: close)
        setOpen(true)
        guard !changeDefault, always else { return }
        // Option swaps the menu to Always Open With while it is open.
        var held = NSEvent.modifierFlags.contains(.option)
        openMenuWatcher = WindowEventRouting.add(window) { [weak self] event in
            guard event.type == .flagsChanged else { return false }
            let now = event.modifierFlags.contains(.option)
            guard now != held else { return false }
            held = now
            MainActor.assumeIsolated {
                self?.swappingMenu = true
                self?.showMenu(build(optionHeld: now), anchor: anchor, window: window, onClose: close)
                self?.swappingMenu = false
            }
            return false
        }
    }
}
