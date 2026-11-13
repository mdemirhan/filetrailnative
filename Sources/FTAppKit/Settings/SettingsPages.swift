import AppKit
import FTFoundation

/// What a page asks of its window: the pickers, the pop-ups, a notice.
@MainActor
protocol SettingsPageHost: AnyObject {
    var store: SettingsStore { get }
    var popovers: SettingsPopovers { get }
    var services: SettingsServices { get }
    var pageWindow: NSWindow? { get }
    func showNotice(_ text: String)
    func pageLayoutChanged()
    /// The color picker for the custom accent.
    var openColorPicker: ColorPicker { get }
}

/// One tab's page: its groups, top to bottom, each told when the preferences change.
@MainActor
final class SettingsPageView: NSView {
    let tab: SettingsTab
    private(set) var blocks: [any SettingsBlock] = []
    private var refreshers: [(AppPreferences) -> Void] = []
    private weak var host: (any SettingsPageHost)?
    let theme: Theme
    /// The Shortcuts tab's view, whose search field goes beside the title.
    private(set) var shortcuts: ShortcutSettingsView?

    init(tab: SettingsTab, host: any SettingsPageHost, theme: Theme) {
        self.tab = tab
        self.host = host
        self.theme = theme
        super.init(frame: .zero)
        setAccessibilityIdentifier("settings.page")
        switch tab {
        case .general: buildGeneral()
        case .browsing: buildBrowsing()
        case .search: buildSearch()
        case .files: buildFiles()
        case .shortcuts: buildShortcuts()
        }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    private var store: SettingsStore? { host?.store }
    private var preferences: AppPreferences { store?.preferences ?? .defaults() }

    private func update(_ change: (inout AppPreferences) -> Void) { store?.update(change) }

    private func add(_ block: any SettingsBlock) {
        blocks.append(block)
        addSubview(block)
    }

    private func onRefresh(_ refresher: @escaping (AppPreferences) -> Void) { refreshers.append(refresher) }

    /// The preferences changed: every control shows them.
    func refresh() {
        let current = preferences
        for refresher in refreshers { refresher(current) }
    }

    /// Lays the groups out `width` wide; the page's height.
    func arrange(width: CGFloat) -> CGFloat {
        var y: CGFloat = 0
        for (index, block) in blocks.enumerated() {
            let height = block.arrange(width: width)
            block.frame = NSRect(x: 0, y: y, width: width, height: height)
            y += height
            // Sections are 20 apart; the Shortcuts list ends with its footer.
            if !(block is ShortcutSettingsView) || index < blocks.count - 1 { y += SettingsMetrics.sectionGap }
        }
        return y
    }

    // MARK: Building blocks

    private func section(_ title: String?, note: String? = nil, footer: SystemButton? = nil) -> SettingsSectionView {
        let view = SettingsSectionView(title: title, note: note, footer: footer, theme: theme)
        add(view)
        return view
    }

    private func row(_ title: String, _ description: String? = nil, _ control: any SettingsSized) -> SettingsRowView {
        SettingsRowView(title: title, description: description, control: control, theme: theme)
    }

    private func toggle(
        _ section: SettingsSectionView, _ title: String, _ description: String?,
        _ keyPath: WritableKeyPath<AppPreferences, Bool>
    ) {
        let control = SettingsSwitch(label: title, isOn: preferences[keyPath: keyPath], theme: theme)
        control.onChange = { [weak self] value in self?.update { $0[keyPath: keyPath] = value } }
        section.card.add(row(title, description, control))
        onRefresh { control.isOn = $0[keyPath: keyPath] }
    }

    private func popup<Value: RawRepresentable & Equatable & Sendable>(
        _ section: SettingsSectionView, _ title: String, _ description: String?, label: String,
        options: [(Value, String)], _ keyPath: WritableKeyPath<AppPreferences, Value>
    ) where Value.RawValue == String {
        let control = SettingsPopup(
            label: label, options: options.map { .init(value: $0.0.rawValue, title: $0.1) },
            value: preferences[keyPath: keyPath].rawValue, theme: theme)
        control.onChange = { [weak self] raw in
            guard let value = Value(rawValue: raw) else { return }
            self?.update { $0[keyPath: keyPath] = value }
        }
        section.card.add(row(title, description, control))
        onRefresh { control.update(options: control.options, value: $0[keyPath: keyPath].rawValue) }
    }

    // MARK: General

    private func buildGeneral() {
        let restore = SystemButton(title: "Restore Defaults", theme: theme)
        restore.setAccessibilityLabel("Restore the default appearance")
        let appearance = section("Appearance", footer: restore)
        restore.target = self
        restore.action = #selector(restoreAppearance(_:))
        let picker = AppearancePicker(theme: preferences.theme, appTheme: theme)
        picker.onChange = { [weak self] value in self?.update { $0.theme = value } }
        appearance.card.add(row("Theme", nil, picker))
        let accent = AccentSelector(accent: preferences.accent, theme: theme)
        accent.onChange = { [weak self] value in self?.update { $0.accent = value } }
        accent.openColorPicker = { [weak self] start, picked in self?.host?.openColorPicker(start, picked) }
        appearance.card.add(row("Accent color", nil, accent))
        // The Zoom row is not drawn.
        onRefresh {
            picker.update($0.theme)
            accent.update($0.accent)
        }

        let behavior = section("Behavior")
        toggle(
            behavior, "Reopen the last folder and tabs", "Otherwise File Trail opens one tab in your home folder.",
            \.restoreSessionOnStartup)
        toggle(behavior, "Show notifications", "When a copy, a move or the Trash finishes.", \.notificationsEnabled)
        toggle(
            behavior, "Mark copied and cut items",
            "They keep a mark in the tree and the list while they are on the clipboard.",
            \.markClipboardItems)
        toggle(
            behavior, "Calculate folder sizes automatically",
            "In the Info panel and Info Row, for a folder in your home folder or an app.", \.autoCalculateFolderSizes)
    }

    @objc private func restoreAppearance(_ sender: Any?) {
        update { SettingsValues.resetAppearance(&$0) }
    }

    // MARK: Browsing

    private func buildBrowsing() {
        let views = section("Views")
        let density = SettingsPopup(
            label: "Sizes", options: Density.allCases.map { .init(value: $0.rawValue, title: $0.settingsLabel) },
            value: Density.standard.rawValue, theme: theme)
        density.onChange = { [weak self] raw in
            guard let value = Density(rawValue: raw) else { return }
            self?.update { $0.density = value }
        }
        views.card.add(
            row(
                "Sizes",
                "Default is File Trail’s own sizes. Match Finder uses Finder’s text and icon sizes, and the folder "
                    + "tree follows the sidebar size in System Settings → Appearance.", density))
        onRefresh { preferences in
            density.update(
                options: Density.allCases.map { .init(value: $0.rawValue, title: $0.settingsLabel) },
                value: preferences.density.rawValue)
        }
        toggle(
            views, "Expand folders with a single click", "In the folder tree, a click also opens or closes the folder.",
            \.singleClickExpandTreeItems)

        let columns = section("Columns in List View", note: "Drag the columns into the order you want.")
        columns.card.add(
            columnList(
                label: "Columns in List view", name: DetailColumnKey.name.label,
                labels: { DetailColumnKey(rawValue: $0.rawValue)?.label ?? $0.rawValue },
                defaultOrder: AppPreferenceLimits.defaultDetailColumnOrder, order: \.detailColumnOrder,
                visible: { $0.detailColumns[$1] }, toggle: { $0.detailColumns[$1].toggle() }), fullWidth: true)

        let favorites = section("Favorites")
        popup(
            favorites, "Show favorites", nil, label: "Show favorites",
            options: [(FavoritesPlacement.integrated, "In the folder tree"), (.separate, "In their own section")],
            \.favoritesPlacement)
        favorites.card.add(favoritesList(), fullWidth: true)
    }

    /// Name first and fixed, the other columns checked and in their order.
    private func columnList<Key: Hashable & RawRepresentable>(
        label: String, name: String, labels: @escaping (Key) -> String, defaultOrder: [Key],
        order: WritableKeyPath<AppPreferences, [Key]>, visible: @escaping (AppPreferences, Key) -> Bool,
        toggle: @escaping (inout AppPreferences, Key) -> Void
    ) -> SettingsListView where Key.RawValue == String {
        // A checked box that can't be changed: the box dims; the name beside it stays as it is.
        let fixedCheckbox = SettingsCheckbox(label: name, isChecked: true)
        fixedCheckbox.isEnabled = false
        let list = SettingsListView(
            label: label, keys: .columns,
            fixedRow: SettingsListRow.Spec(
                name: name, trailingNote: "Always first", draggable: false, disabled: true,
                leading: fixedCheckbox,
                height: SettingsMetrics.columnRowHeight),
            theme: theme)
        let up = SettingsListBarButton(.moveUp, label: "Move Up", tooltip: "Move Up")
        let down = SettingsListBarButton(.moveDown, label: "Move Down", tooltip: "Move Down")
        let restore = SettingsListBarButton(.text("Restore Defaults"), label: "Restore the default column order")
        list.setBar([.segments([up, down]), .spacer, .button(restore)])
        let move: (Int, Int) -> Void = { [weak self] from, to in
            self?.update { $0[keyPath: order] = SettingsValues.move($0[keyPath: order], from: from, to: to) }
        }
        list.onMove = move
        list.onToggle = { [weak self] index in
            self?.update { preferences in
                let keys = preferences[keyPath: order]
                if keys.indices.contains(index) { toggle(&preferences, keys[index]) }
            }
        }
        let syncBar = { [weak list, weak self] in
            guard let list, let self else { return }
            let keys = self.preferences[keyPath: order]
            let index = list.selectedIndex
            up.isEnabled = (index ?? 0) > 0
            down.isEnabled = index.map { $0 < keys.count - 1 } ?? false
            restore.isEnabled = keys != defaultOrder
            let selected = index.flatMap { keys.indices.contains($0) ? labels(keys[$0]) : nil }
            up.label = selected.map { "Move \($0) Up" } ?? "Move Up"
            down.label = selected.map { "Move \($0) Down" } ?? "Move Down"
        }
        list.onSelectionChange = syncBar
        up.onPress = { [weak list] in
            guard let list, let index = list.selectedIndex else { return }
            list.move(index, to: index - 1)
        }
        down.onPress = { [weak list] in
            guard let list, let index = list.selectedIndex else { return }
            list.move(index, to: index + 1)
        }
        restore.onPress = { [weak self] in self?.update { $0[keyPath: order] = defaultOrder } }
        onRefresh { [weak list] preferences in
            guard let list else { return }
            list.setRows(
                preferences[keyPath: order].enumerated().map { index, key in
                    let checkbox = SettingsCheckbox(label: "Show \(labels(key))", isChecked: visible(preferences, key))
                    checkbox.onPress = { [weak list] in list?.onToggle(index) }
                    return SettingsListRow.Spec(
                        name: labels(key), key: key.rawValue, leading: checkbox,
                        height: SettingsMetrics.columnRowHeight)
                })
        }
        return list
    }

    private func favoritesList() -> SettingsListView {
        let list = SettingsListView(label: "Favorites", keys: .items, theme: theme)
        let add = SettingsListBarButton(.add, label: "Add Favorite", tooltip: "Add Favorite")
        let remove = SettingsListBarButton(.remove, label: "Remove", tooltip: "Remove")
        let change = SettingsListBarButton(.text("Change…"), label: "Change")
        let restore = SettingsListBarButton(.text("Restore Defaults"), label: "Restore the default favorites")
        list.setBar([.segments([add, remove]), .button(change), .spacer, .button(restore)])
        let home = store?.homePath ?? ""
        let name: (FavoritePreference) -> String = {
            FavoriteLabel.label(for: $0.path, homePath: home, startupDiskName: StartupDisk.shared.name)
        }
        list.onSelectionChange = { [weak list, weak self] in
            guard let list, let self else { return }
            let favorites = self.preferences.favorites
            let selected = list.selectedIndex.flatMap { favorites.indices.contains($0) ? favorites[$0] : nil }
            remove.isEnabled = selected != nil
            change.isEnabled = selected != nil
            remove.label = selected.map { "Remove \(name($0))" } ?? "Remove"
            change.label = selected.map { "Change \(name($0))" } ?? "Change"
        }
        list.onMove = { [weak self] from, to in
            self?.update { $0.favorites = SettingsValues.move($0.favorites, from: from, to: to) }
        }
        list.onRemove = { [weak self] index in
            self?.update { if $0.favorites.indices.contains(index) { $0.favorites.remove(at: index) } }
        }
        list.onChange = { [weak self] index in self?.browseFavorite(index) }
        add.onPress = { [weak self] in self?.addFavorite() }
        remove.onPress = { [weak list] in
            guard let list, let index = list.selectedIndex else { return }
            list.onRemove(index)
        }
        change.onPress = { [weak list] in
            guard let list, let index = list.selectedIndex else { return }
            list.onChange(index)
        }
        restore.onPress = { [weak self] in
            guard let self else { return }
            self.update { $0.favorites = Favorites.defaults(homePath: home) }
        }
        onRefresh { [weak self, weak list] preferences in
            guard let self, let list else { return }
            list.setRows(
                preferences.favorites.enumerated().map { index, favorite in
                    let label = name(favorite)
                    let button = FavoriteIconButton(icon: favorite.icon, name: label, theme: self.theme)
                    button.onPress = { [weak self, weak button] in
                        guard let self, let button else { return }
                        self.toggleIconGrid(from: button, favoriteIndex: index, owner: "Favorite icon for \(label)")
                    }
                    button.onFocusChange = { [weak list, weak button] in
                        guard let list, let button else { return }
                        if button.window?.firstResponder === button, button.isDescendant(of: list) {
                            list.select(index)
                        } else {
                            list.focusMoved()
                        }
                    }
                    return SettingsListRow.Spec(name: label, path: favorite.path, leading: button)
                })
        }
        return list
    }

    private func toggleIconGrid(from button: FavoriteIconButton, favoriteIndex: Int, owner: String) {
        guard let popovers = host?.popovers else { return }
        if popovers.isOpen(from: button) {
            popovers.close(returnFocus: false)
            return
        }
        button.isExpanded = { [weak popovers, weak button] in
            guard let popovers, let button else { return false }
            return popovers.isOpen(from: button)
        }
        let grid = FavoriteIconGrid(selected: button.icon, owner: owner, theme: theme)
        grid.onChoose = { [weak self, weak popovers] icon in
            popovers?.close(returnFocus: true)
            self?.update { if $0.favorites.indices.contains(favoriteIndex) { $0.favorites[favoriteIndex].icon = icon } }
        }
        popovers.show(grid, owner: button)
    }

    private func addFavorite() {
        guard let store else { return }
        let home = store.homePath
        Task { @MainActor [weak self] in
            guard let self, let path = await self.pickDirectory(home.isEmpty ? nil : home) else { return }
            if Favorites.contains(self.preferences.favorites, path: path) {
                self.sayAlreadyFavorite(path)
                return
            }
            self.update { preferences in
                guard !Favorites.contains(preferences.favorites, path: path) else { return }
                preferences.favorites.append(Favorites.create(path: path, homePath: home))
            }
        }
    }

    /// A folder chosen for Add or Change… is a favorite already: nothing changes, and the notice says why.
    private func sayAlreadyFavorite(_ path: String) {
        let name = FavoriteLabel.label(
            for: path, homePath: store?.homePath ?? "", startupDiskName: StartupDisk.shared.name)
        host?.showNotice(SettingsText.alreadyFavorite(name))
    }

    private func browseFavorite(_ index: Int) {
        guard preferences.favorites.indices.contains(index) else { return }
        let current = preferences.favorites[index]
        Task { @MainActor [weak self] in
            guard let self, let path = await self.pickDirectory(current.path) else { return }
            if path != current.path && self.preferences.favorites.contains(where: { $0.path == path }) {
                self.sayAlreadyFavorite(path)
                return
            }
            self.update { preferences in
                // Known by its path, which no other favorite has: the list may have changed while the picker was open.
                guard let position = preferences.favorites.firstIndex(where: { $0.path == current.path }) else {
                    return
                }
                let taken = preferences.favorites.enumerated().contains {
                    $0.offset != position && $0.element.path == path
                }
                guard !taken else { return }
                preferences.favorites[position] = FavoritePreference(
                    path: path, icon: preferences.favorites[position].icon)
            }
        }
    }

    private func pickDirectory(_ defaultPath: String?) async -> String? {
        guard let host else { return nil }
        do {
            return try await host.services.pickDirectory(defaultPath, host.pageWindow)
        } catch {
            host.showNotice(SettingsText.chooseFolderFailed)
            return nil
        }
    }

    private func pickApplication(_ failure: String) async -> ApplicationSelection? {
        guard let host else { return nil }
        do {
            return try await host.services.pickApplication(host.pageWindow)
        } catch {
            host.showNotice(failure)
            return nil
        }
    }

    // MARK: Search

    private func buildSearch() {
        let searches = section(
            "New Searches",
            note:
                "New windows start with these, and a change here applies to the tab on screen too. The search "
                + "field’s menu changes them for its tab.")
        popup(
            searches, "Search in", nil, label: "Search in",
            options: [(SearchMatchScopePreference.name, "Names"), (.path, "Full Paths")], \.searchMatchScope)
        popup(
            searches, "Match as", "Glob and Regex read the words as a pattern.", label: "Match as",
            options: SearchPatternModePreference.allCases.map { ($0, $0.label) }, \.searchPatternMode)
        toggle(searches, "Search subfolders", nil, \.searchRecursive)
        toggle(searches, "Skip .git folders", "Matters only while hidden files are shown.", \.searchSkipGitFolders)
        toggle(
            searches, "Skip files ignored by Git", "Inside a repository, leave out what its .gitignore excludes.",
            \.searchSkipGitIgnored)

        let columns = section(
            "Columns in Search Results",
            note: "For search results in List view. Drag the columns into the order you want.")
        columns.card.add(
            columnList(
                label: "Columns in search results", name: SearchColumnKey.name.label,
                labels: { SearchColumnKey(rawValue: $0.rawValue)?.label ?? $0.rawValue },
                defaultOrder: AppPreferenceLimits.defaultSearchColumnOrder, order: \.searchColumnOrder,
                visible: { $0.searchColumns[$1] }, toggle: { $0.searchColumns[$1].toggle() }), fullWidth: true)
    }

    // MARK: Files

    private func buildFiles() {
        let opening = section("Opening Files")
        popup(
            opening, "Double-click a file to", "Folders always open.", label: "Double-click a file to",
            options: [(FileActivationAction.open, "Open"), (.edit, "Edit")], \.fileActivationAction)
        let returnKey = SettingsPopup(
            label: "Return key",
            options: [
                .init(value: ReturnKeyAction.rename.rawValue, title: "Renames"), .init(value: "open", title: "Opens"),
            ],
            value: preferences.returnKeyAction.rawValue, theme: theme)
        returnKey.onChange = { [weak self] raw in
            guard let value = ReturnKeyAction(rawValue: raw) else { return }
            self?.update { $0.returnKeyAction = value }
        }
        let returnRow = row("Return key", " ", returnKey)
        opening.card.add(returnRow)
        onRefresh { preferences in
            returnKey.update(options: returnKey.options, value: preferences.returnKeyAction.rawValue)
            let display = ShortcutDisplay(
                shortcuts: ShortcutCommands.resolve(preferences.shortcutOverrides),
                returnKeyAction: preferences.returnKeyAction)
            returnRow.setDescription(SettingsValues.returnKeyDescription(display))
        }
        popup(
            opening, "Open disk images in", "Where a disk opens when you open its disk image.",
            label: "Open disk images in", options: [(DiskImageOpensIn.window, "New Window"), (.tab, "New Tab")],
            \.diskImageOpensIn)
        let limit = SettingsNumberField(
            value: preferences.openItemLimit, unit: "items", label: "Open and Edit item limit", theme: theme)
        limit.onChange = { [weak self] value in self?.update { $0.openItemLimit = value } }
        opening.card.add(row("Ask before opening more than", "Opening or editing more at once asks first.", limit))
        onRefresh { limit.update(value: $0.openItemLimit) }

        let editor = appPopup(
            "Text editor", default: AppPreferenceLimits.defaultTextEditor, current: { $0.defaultTextEditor },
            failure: SettingsText.chooseTextEditorFailed,
            set: { $0.defaultTextEditor = $1 ?? AppPreferenceLimits.defaultTextEditor })
        opening.card.add(row("Text editor", nil, editor))
        let terminal = appPopup(
            "Terminal", default: AppPreferenceLimits.defaultTerminalApplication,
            current: { $0.terminalApp ?? AppPreferenceLimits.defaultTerminalApplication },
            failure: SettingsText.chooseTerminalFailed, set: { $0.terminalApp = $1 })
        opening.card.add(row("Terminal", nil, terminal))

        let openWith = section(
            "First in Open With",
            note: "Listed first in Open With, after the app an item opens in, for the items each app can open.")
        openWith.card.add(openWithList(), fullWidth: true)
    }

    /// The app in use, the default, Choose…; choosing the default clears the custom app.
    private func appPopup(
        _ label: String, default defaultApp: ApplicationSelection,
        current: @escaping (AppPreferences) -> ApplicationSelection, failure: String,
        set: @escaping (inout AppPreferences, ApplicationSelection?) -> Void
    ) -> SettingsAppPopup {
        let popup = SettingsAppPopup(label: label, application: current(preferences), defaultApplication: defaultApp)
        popup.onPick = { [weak self] pick in
            switch pick {
            case .defaultApplication:
                self?.update { set(&$0, nil) }
            case .other:
                Task { @MainActor [weak self] in
                    guard let self, let app = await self.pickApplication(failure) else { return }
                    self.update { set(&$0, app) }
                }
            }
        }
        onRefresh { popup.update(current($0)) }
        return popup
    }

    private func openWithList() -> SettingsListView {
        let list = SettingsListView(label: "First in Open With", keys: .items, theme: theme)
        let add = SettingsListBarButton(.add, label: "Add app to Open With", tooltip: "Add app to Open With")
        let remove = SettingsListBarButton(.remove, label: "Remove", tooltip: "Remove")
        let change = SettingsListBarButton(.text("Change…"), label: "Change")
        list.setBar([.segments([add, remove]), .button(change), .spacer])
        list.onSelectionChange = { [weak list, weak self] in
            guard let list, let self else { return }
            let apps = self.preferences.openWithApplications
            let selected = list.selectedIndex.flatMap { apps.indices.contains($0) ? apps[$0] : nil }
            remove.isEnabled = selected != nil
            change.isEnabled = selected != nil
            remove.label = selected.map { "Remove \($0.appName)" } ?? "Remove"
            change.label = selected.map { "Change \($0.appName)" } ?? "Change"
        }
        // Each app is known by its id, so moving, removing and changing stay right as the list changes.
        let id: (Int) -> String? = { [weak self] index in
            guard let apps = self?.preferences.openWithApplications, apps.indices.contains(index) else { return nil }
            return apps[index].id
        }
        list.onMove = { [weak self] from, to in
            guard let entry = id(from) else { return }
            self?.update {
                let index = $0.openWithApplications.firstIndex { $0.id == entry } ?? -1
                $0.openWithApplications = SettingsValues.move($0.openWithApplications, from: index, to: to)
            }
        }
        list.onRemove = { [weak self] index in
            guard let entry = id(index) else { return }
            self?.update { $0.openWithApplications.removeAll { $0.id == entry } }
        }
        list.onChange = { [weak self] index in
            guard let entry = id(index) else { return }
            Task { @MainActor [weak self] in
                guard let self, let app = await self.pickApplication(SettingsText.chooseAppFailed) else { return }
                self.update { preferences in
                    for position in preferences.openWithApplications.indices
                    where preferences.openWithApplications[position].id == entry {
                        preferences.openWithApplications[position].appPath = app.appPath
                        preferences.openWithApplications[position].appName = app.appName
                    }
                }
            }
        }
        add.onPress = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, let app = await self.pickApplication(SettingsText.chooseAppFailed) else { return }
                self.update {
                    $0.openWithApplications.append(
                        OpenWithApplication(
                            id: SettingsValues.openWithApplicationID(), appPath: app.appPath, appName: app.appName))
                }
            }
        }
        remove.onPress = { [weak list] in
            guard let list, let index = list.selectedIndex else { return }
            list.onRemove(index)
        }
        change.onPress = { [weak list] in
            guard let list, let index = list.selectedIndex else { return }
            list.onChange(index)
        }
        onRefresh { [weak self, weak list] preferences in
            guard let self, let list else { return }
            let missing = self.store?.missingOpenWithAppPaths ?? []
            list.setRows(
                preferences.openWithApplications.map { app in
                    let icon = SettingsAppIconView(path: app.appPath)
                    return SettingsListRow.Spec(
                        name: app.appName, path: app.appPath, missing: missing.contains(app.appPath), leading: icon)
                })
        }
        return list
    }

    // MARK: Shortcuts

    private func buildShortcuts() {
        let view = ShortcutSettingsView(
            overrides: preferences.shortcutOverrides, returnKeyAction: preferences.returnKeyAction, theme: theme)
        view.onChange = { [weak self] overrides in self?.update { $0.shortcutOverrides = overrides } }
        view.onLayoutChange = { [weak self] in self?.host?.pageLayoutChanged() }
        shortcuts = view
        add(view)
        onRefresh { view.update(overrides: $0.shortcutOverrides, returnKeyAction: $0.returnKeyAction) }
    }
}

/// An app's icon in a list row, 20 by 20.
final class SettingsAppIconView: NSView {
    let path: String
    /// Looked up once, not on each draw.
    private lazy var icon = SettingsAppIcon.image(path)

    init(path: String) {
        self.path = path
        super.init(frame: NSRect(x: 0, y: 0, width: SettingsMetrics.listIconSize, height: SettingsMetrics.listIconSize))
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        icon.draw(
            in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}
