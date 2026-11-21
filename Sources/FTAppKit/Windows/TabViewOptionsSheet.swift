// Tab View Options: the sheet that saves a tab view, laid out as Folder View Options is
import AppKit
import FTFoundation

/// The sheet over a tab that saves what it keeps as a tab view, or changes one saved. Its rows are Folder View
/// Options' (a checkbox titled with each setting, its control in a column that starts at the same place in every row,
/// the fifth row following the view chosen in its group), with the tab's own rows and each pane's folder and folder
/// views on top. A value chosen is kept from then on. With two panes kept, one pane's rows show at a time, chosen
/// above them, so the sheet keeps its height.
@MainActor
final class TabViewOptionsSheet: SavedViewSheet {
    private(set) var draft: TabViewDraft
    /// The tab views kept, to say which name is taken.
    private let saved: [TabView]
    private let density: Density
    private let subtitle: String
    /// The pane group shown while two are kept.
    private(set) var shownGroup = TabViewDraft.PaneGroup.left
    private let nameField = NSTextField()
    private var saveButton: NSButton?

    /// Cancel, Escape.
    var onCancel: () -> Void = {}
    /// Save, with the name typed and what is kept.
    var onSave: (TabViewDraft) -> Void = { _ in }
    /// All Tab Views….
    var onManage: () -> Void = {}
    /// Choose Folder…, for a pane group: the folder chosen, or nil.
    var chooseFolder: (@escaping (String?) -> Void) -> Void = { $0(nil) }

    init(draft: TabViewDraft, saved: [TabView], density: Density, subtitle: String) {
        self.draft = draft
        self.saved = saved
        self.density = density
        self.subtitle = subtitle
        super.init()
        setAccessibilityElement(true)
        setAccessibilityRole(.sheet)
        setAccessibilityIdentifier("tabViewOptions")
        nameField.stringValue = draft.name
        nameField.placeholderString = "Tab view name"
        nameField.setAccessibilityIdentifier("tabViewOptions.name")
        nameField.target = self
        nameField.action = #selector(nameChanged)
        NotificationCenter.default.addObserver(
            self, selector: #selector(nameChanged), name: NSControl.textDidChangeNotification, object: nameField)
        build()
        applyTheme(theme)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var initialResponder: NSView? { nameField }
    override var identifierPrefix: String { "tabViewOptions" }

    override func handleKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 53:
            onCancel()
            return true
        case 36, 76:
            guard canSave else { return false }
            save()
            return true
        default:
            return false
        }
    }

    // MARK: State

    /// The tab view another has this name: Save replaces it.
    var takenBy: TabView? {
        guard let index = SavedViewNames.index(named: draft.name, in: saved),
            saved[index].id != draft.editingID
        else { return nil }
        return saved[index]
    }

    var canSave: Bool { !SavedViewNames.clean(draft.name).isEmpty && !draft.keeps.isEmpty }

    @objc private func nameChanged() {
        draft.name = nameField.stringValue
        saveButton?.title = takenBy == nil ? "Save" : "Replace"
        saveButton?.isEnabled = canSave
        noteChanged()
    }

    private func save() {
        draft.name = SavedViewNames.clean(nameField.stringValue)
        onSave(draft)
    }

    /// The draft changed: the sheet shows it.
    private func change(_ edit: (inout TabViewDraft) -> Void) {
        edit(&draft)
        if !draft.paneGroups.contains(shownGroup) { shownGroup = draft.paneGroups[0] }
        build()
    }

    private func noteChanged() {
        // The name's note comes and goes with what is typed: the sheet is built again around the field, which keeps
        // the keyboard.
        let editor = window?.firstResponder
        build()
        if let editor, editor !== window?.firstResponder { window?.makeFirstResponder(nameField) }
    }

    // MARK: Building

    private func build() {
        clear()
        add(header())
        add(row(label("Name"), nameField, stretch: true), after: 4)
        if let taken = takenBy {
            add(note("A tab view called \u{201C}\(taken.name)\u{201D} exists. Saving replaces it."), after: 8)
        }
        add(sectionTitle("Keep for This Tab"), after: 2)
        add(card(tabRows()), after: 10)
        let groups = draft.paneGroups
        if groups.count == 2 {
            let chooser = NSSegmentedControl(
                labels: ["Left Pane", "Right Pane"], trackingMode: .selectOne, target: self,
                action: #selector(groupChosen(_:)))
            chooser.controlSize = .small
            chooser.selectedSegment = shownGroup == .right ? 1 : 0
            chooser.setAccessibilityIdentifier("tabViewOptions.pane")
            add(row(sectionTitle(shownGroup.title), chooser, atEnd: true, height: 22), after: 2)
        } else {
            add(sectionTitle(groups[0].title), after: 2)
        }
        let group = groups.contains(shownGroup) ? shownGroup : groups[0]
        add(card(paneRows(group)), after: 8)
        add(folderViewsRow(group), after: 8)
        add(separator())
        add(note(SavedViewText.parts(draft.keeps).joined(separator: " \u{00B7} ")), after: 8)
        setFooter(footer())
        needsLayout = true
        superview?.needsLayout = true
    }

    private func header() -> NSView {
        header(symbol: "rectangle.split.2x1", title: "Tab View Options", subtitle: subtitle)
    }

    // MARK: The tab's rows

    private func tabRows() -> [NSView] {
        let panes = popUp(["One", "Two"], selected: draft.panes == 2 ? 1 : 0) { [weak self] index in
            self?.change {
                $0.panes = index == 1 ? 2 : 1
                $0.keepsPanes = true
            }
        }
        panes.setAccessibilityIdentifier("tabViewOptions.panes")
        var rows = [
            keepRow("Panes", kept: draft.keepsPanes, panes) { [weak self] on in self?.change { $0.keepsPanes = on } }
        ]
        rows.append(dividerRow())
        let hidden = popUp(["Shown", "Hidden"], selected: draft.hidden ? 0 : 1) { [weak self] index in
            self?.change {
                $0.hidden = index == 0
                $0.keepsHidden = true
            }
        }
        rows.append(
            keepRow("Hidden Files", kept: draft.keepsHidden, hidden) { [weak self] on in
                self?.change { $0.keepsHidden = on }
            })
        return rows
    }

    /// Even, the share now, the left pane's width now, what the tab view keeps, or a share typed in. Dimmed, not gone,
    /// while the tab view doesn't keep two panes, so the sheet keeps its height.
    private func dividerRow() -> NSView {
        var choices: [(TabViewDraft.Divider, String)] = [
            (.even, "Even"),
            (.shareNow, "As Now: \(SavedViewText.dividerText(.share(draft.shareNow)))"),
            (.widthNow, "As Now: \(SavedViewText.dividerText(.leftWidth(draft.widthNow)).capitalizedFirst)"),
        ]
        if let saved = draft.savedDivider, saved != .even {
            choices.append((.saved, "Saved: \(SavedViewText.dividerText(saved).capitalizedFirst)"))
        }
        choices.append((.custom, "Custom"))
        let popup = popUp(choices.map(\.1), selected: choices.firstIndex { $0.0 == draft.divider } ?? 1) {
            [weak self] index in
            self?.change {
                $0.divider = choices[index].0
                $0.keepsDivider = true
            }
        }
        popup.setAccessibilityIdentifier("tabViewOptions.divider")
        var control: NSView = popup
        if draft.divider == .custom {
            let field = NSTextField(string: "\(Int((draft.customShare * 100).rounded()))")
            field.alignment = .right
            field.setAccessibilityIdentifier("tabViewOptions.customShare")
            field.widthAnchor.constraint(equalToConstant: 44).isActive = true
            field.target = self
            field.action = #selector(customShareTyped(_:))
            let percent = NSTextField(labelWithString: "% for the left pane")
            percent.textColor = .secondaryLabelColor
            let pair = NSStackView(views: [popup, field, percent])
            pair.orientation = .horizontal
            pair.spacing = 6
            control = pair
        }
        let two = draft.keepsPanes && draft.panes == 2
        let row = keepRow("Divider", kept: draft.keepsDivider && two, control) { [weak self] on in
            self?.change { $0.keepsDivider = on }
        }
        if !two { enable(row, false) }
        return row
    }

    /// A share typed in: a whole percent, held within what a drag of the divider allows.
    @objc private func customShareTyped(_ field: NSTextField) {
        let percent = Double(field.integerValue)
        change {
            $0.customShare = percent / 100
            $0.keepsDivider = true
        }
    }

    @objc private func groupChosen(_ control: NSSegmentedControl) {
        shownGroup = control.selectedSegment == 1 ? .right : .left
        build()
    }

    // MARK: A pane's rows

    private func paneRows(_ group: TabViewDraft.PaneGroup) -> [NSView] {
        let pane = draft[group]
        var rows: [NSView] = [folderRow(group)]
        let values = pane.values
        let modes = ExplorerViewMode.menuOrder
        let view = popUp(modes.map(\.menuName), selected: modes.firstIndex(of: values.view ?? .details) ?? 0) {
            [weak self] index in
            self?.change { $0[group].set(.view) { $0.view = modes[index] } }
        }
        for (index, mode) in modes.enumerated() {
            view.item(at: index)?.image = NSImage(
                systemSymbolName: Self.symbol(of: mode), accessibilityDescription: nil)
        }
        rows.append(settingRow(.view, view, group))
        let fields = [GroupByPreference.none] + GroupByPreference.menuOrder
        let reversed = values.groupReversed == true
        let groupField = popUp(fields.map(\.title), selected: fields.firstIndex(of: values.groupBy ?? .none) ?? 0) {
            [weak self] index in
            self?.change {
                $0[group].set(.groupBy) {
                    $0.groupBy = fields[index]
                    $0.groupReversed = fields[index] != .none && reversed ? true : nil
                }
            }
        }
        let groupDirection = popUp(["In Order", "Reversed"], selected: reversed ? 1 : 0, width: 110) {
            [weak self] index in
            self?.change { $0[group].set(.groupBy) { $0.groupReversed = index == 1 ? true : nil } }
        }
        groupDirection.isEnabled = (values.groupBy ?? .none) != .none
        rows.append(settingRow(.groupBy, pair(groupField, groupDirection), group))
        let sort = values.sort ?? FolderViewSort(by: .name, direction: .asc)
        let sortFields = SortByPreference.menuOrder
        let sortField = popUp(sortFields.map(\.title), selected: sortFields.firstIndex(of: sort.by) ?? 0) {
            [weak self] index in
            self?.change {
                $0[group].set(.sort) { $0.sort = FolderViewSort(by: sortFields[index], direction: sort.direction) }
            }
        }
        let sortDirection = popUp(["Ascending", "Descending"], selected: sort.direction == .asc ? 0 : 1, width: 110) {
            [weak self] index in
            self?.change {
                $0[group].set(.sort) { $0.sort = FolderViewSort(by: sort.by, direction: index == 0 ? .asc : .desc) }
            }
        }
        rows.append(settingRow(.sort, pair(sortField, sortDirection), group))
        let first = popUp(["Before Files", "Mixed with Files"], selected: values.foldersFirst == false ? 1 : 0) {
            [weak self] index in
            self?.change { $0[group].set(.foldersFirst) { $0.foldersFirst = index == 0 } }
        }
        rows.append(settingRow(.foldersFirst, first, group))
        rows.append(fifthRow(group))
        return rows
    }

    /// Folder View Options' fifth row: the List's columns in the List, the size in the other views.
    private func fifthRow(_ group: TabViewDraft.PaneGroup) -> NSView {
        let values = draft[group].values
        let mode = values.view ?? .details
        guard mode != .details, let size = values.size else {
            return settingRow(.columns, note("As the List\u{2019}s header shows them now"), group)
        }
        let density = density
        let now =
            switch mode {
            case .icons: size.iconSizes[density]
            case .list: size.compactListWidths[density]
            default: size.previewCounts[density]
            }
        let choices = FolderViewPopover.sizeChoices(mode, current: now)
        let popup = popUp(choices.map(\.title), selected: choices.firstIndex { $0.value == now } ?? 0) {
            [weak self] index in
            let value = choices[index].value
            self?.change {
                $0[group].set(.size) { keeps in
                    switch mode {
                    case .icons: keeps.size?.iconSizes[density] = value
                    case .list: keeps.size?.compactListWidths[density] = value
                    default: keeps.size?.previewCounts[density] = value
                    }
                }
            }
        }
        return settingRow(.size, popup, group, title: Self.sizeTitle(mode))
    }

    /// The pane's folder: unchecked, the pane stays on the tab's folder; checked, the folders shown now, the one
    /// saved, and Choose Folder….
    private func folderRow(_ group: TabViewDraft.PaneGroup) -> NSView {
        let pane = draft[group]
        var paths = draft.foldersNow.map(\.path)
        var titles = draft.foldersNow.map { "\(NodePath.basename($0.path)) \u{2014} \($0.pane)" }
        if let folder = pane.folder, !paths.contains(folder) {
            paths.append(folder)
            titles.append(NodePath.basename(folder))
        }
        let selected = pane.folder.flatMap { paths.firstIndex(of: $0) } ?? 0
        let popup = popUp(titles + ["Choose Folder\u{2026}"], selected: selected, width: 220) { [weak self] index in
            guard let self else { return }
            if paths.indices.contains(index) {
                change {
                    $0[group].folder = paths[index]
                    $0[group].keepsFolder = true
                }
            } else {
                chooseFolder { [weak self] chosen in
                    guard let chosen else {
                        self?.build()
                        return
                    }
                    self?.change {
                        $0[group].folder = chosen
                        $0[group].keepsFolder = true
                    }
                }
            }
        }
        popup.setAccessibilityIdentifier("tabViewOptions.folder")
        let control: NSView = pane.keepsFolder ? popup : note("Stays on the tab\u{2019}s folder")
        return keepRow("Folder", kept: pane.keepsFolder, control, dims: false) { [weak self] on in
            self?.change { $0[group].keepsFolder = on }
        }
    }

    /// How folders with a view of their own are treated in the pane, with what the choice does under it.
    private func folderViewsRow(_ group: TabViewDraft.PaneGroup) -> NSView {
        let choices: [(FolderViewsChoice, String, String)] = [
            (.folderFirst, "Folder\u{2019}s View First", "A folder with a view of its own shows it, as in any pane."),
            (
                .tabViewFirst, "Tab View First",
                "What this tab view keeps comes first in the folder it opens; the folder\u{2019}s view gives the rest."
            ),
            (.notUsed, "Not Used", "A folder\u{2019}s own view isn\u{2019}t used in the folder this tab view opens."),
        ]
        let now = draft[group].folderViews
        let popup = popUp(choices.map(\.1), selected: choices.firstIndex { $0.0 == now } ?? 0) { [weak self] index in
            self?.change { $0[group].folderViews = choices[index].0 }
        }
        popup.setAccessibilityIdentifier("tabViewOptions.folderViews")
        let detail = choices.first { $0.0 == now }?.2 ?? ""
        let name = label("Folder Views")
        let line = NSTextField(wrappingLabelWithString: detail)
        line.preferredMaxLayoutWidth = contentWidth - 190
        line.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        line.textColor = .secondaryLabelColor
        let texts = NSStackView(views: [name, line])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 1
        return row(texts, popup, atEnd: true, height: 50)
    }

    private func settingRow(
        _ setting: FolderViewSetting, _ control: NSView, _ group: TabViewDraft.PaneGroup, title: String? = nil
    ) -> NSView {
        let kept = draft[group].kept.contains(setting)
        return keepRow(title ?? Self.title(of: setting), kept: kept, control) { [weak self] on in
            self?.change { $0[group].keep(setting, on) }
        }
    }

    // MARK: Footer

    private func footer() -> NSView {
        let reset = ClosureButton(title: "Reset") { [weak self] in self?.change { $0.reset() } }
        reset.bezelStyle = .push
        reset.toolTip = "Unchecks everything"
        let manage = ClosureButton(title: "All Tab Views\u{2026}") { [weak self] in self?.onManage() }
        manage.bezelStyle = .push
        let cancel = ClosureButton(title: "Cancel") { [weak self] in self?.onCancel() }
        cancel.bezelStyle = .push
        let save = ClosureButton(title: takenBy == nil ? "Save" : "Replace") { [weak self] in self?.save() }
        save.bezelStyle = .push
        save.keyEquivalent = "\r"
        save.isEnabled = canSave
        save.setAccessibilityIdentifier("tabViewOptions.save")
        saveButton = save
        let row = NSStackView(views: [reset, manage, NSView(), cancel, save])
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }

    // MARK: Words

    static func title(of setting: FolderViewSetting) -> String {
        switch setting {
        case .view: "View"
        case .groupBy: "Group By"
        case .sort: "Sort By"
        case .foldersFirst: "Folders First"
        case .columns: "Column Visibility and Order"
        case .size: "Size"
        }
    }

    static func sizeTitle(_ mode: ExplorerViewMode) -> String {
        switch mode {
        case .icons: "Icon Size"
        case .list: "Column Width"
        case .previews: "Previews"
        case .details: "Size"
        }
    }

    private static func symbol(of mode: ExplorerViewMode) -> String {
        switch mode {
        case .icons: CommandIcon.icons.symbolName
        case .details: CommandIcon.details.symbolName
        case .list: CommandIcon.list.symbolName
        case .previews: CommandIcon.previews.symbolName
        }
    }
}

extension String {
    /// The text with its first letter a capital: "left pane 420 pt" as a choice reads it.
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
