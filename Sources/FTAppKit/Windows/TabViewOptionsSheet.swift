// Tab View Options: the sheet that saves a tab view, laid out as Folder View Options is
import AppKit
import FTFoundation

/// The sheet over a tab that saves what it keeps as a tab view, or changes one saved. Its rows are Folder View
/// Options' (a checkbox titled with each setting, its control in a column that starts at the same place in every row,
/// the fifth row following the view chosen in its group), with the tab's own rows and each pane's folder and folder
/// views on top. A value chosen is kept from then on. With two panes kept, one pane's rows show at a time, chosen
/// above them, so the sheet keeps its height; either pane can show the viewer beside the other's list instead, with
/// the viewer's own Follow and Read or Edit.
///
/// Its controls are made once; `refresh` shows the draft in them, hiding the rows that don't apply.
@MainActor
final class TabViewOptionsSheet: SavedViewSheet {
    private(set) var draft: TabViewDraft
    /// The tab views kept, to say which name is taken and to choose one by name.
    private let saved: [TabView]
    private let density: Density
    /// A saved tab view over this tab, for one chosen by its name.
    private let load: (TabView) -> TabViewDraft
    /// The pane group shown while two are kept.
    private(set) var shownGroup = TabViewDraft.PaneGroup.left

    /// Save, with the name typed and what is kept.
    var onSave: (TabViewDraft) -> Void = { _ in }
    /// Choose Folder…, for a pane group: the folder chosen, or nil.
    var chooseFolder: (@escaping (String?) -> Void) -> Void = { $0(nil) }

    /// What the pop-ups whose items change offer now, in their order.
    private var dividerChoices: [TabViewDraft.Divider] = []
    private var folderPaths: [String] = []
    private var sizeValues: [Int] = []

    private static let modes = ExplorerViewMode.menuOrder
    private static let groupFields = [GroupByPreference.none] + GroupByPreference.menuOrder
    private static let sortFields = SortByPreference.menuOrder
    private static let folderViewsChoices: [(choice: FolderViewsChoice, title: String, detail: String)] = [
        (.folderFirst, "Folder\u{2019}s View First", "A folder with a view of its own shows it, as in any pane."),
        (
            .tabViewFirst, "Tab View First",
            "What this tab view keeps comes first in the folder it opens; the folder\u{2019}s view gives the rest."
        ),
        (.notUsed, "Not Used", "A folder\u{2019}s own view isn\u{2019}t used in the folder this tab view opens."),
    ]

    // MARK: The tab's rows

    private lazy var panesPopUp = popUp(["One", "Two"], label: "Panes", id: "panes") { [weak self] index in
        self?.change {
            $0.panes = index == 1 ? 2 : 1
            $0.keepsPanes = true
        }
    }
    private lazy var panesRow = keepRow("Panes", panesPopUp) { [weak self] on in self?.change { $0.keepsPanes = on } }

    private lazy var dividerPopUp = popUp(label: "Divider", id: "divider") { [weak self] index in
        guard let self, dividerChoices.indices.contains(index) else { return }
        let choice = dividerChoices[index]
        change {
            $0.divider = choice
            $0.keepsDivider = true
        }
    }
    /// Narrower with a share typed beside it, so the field and its words fit the row.
    private lazy var dividerWidth = dividerPopUp.constraints.first { $0.firstAttribute == .width }
    /// Kept as it is typed; held within what a drag of the divider allows once the field is left.
    private lazy var shareField = numberField(
        label: "Left pane\u{2019}s share in percent", id: "customShare", width: 44,
        changed: { [weak self] percent in
            self?.change {
                $0.customShare = Double(percent) / 100
                $0.keepsDivider = true
            }
        }, ended: { [weak self] in self?.refresh() })
    private lazy var percent: NSTextField = {
        let field = NSTextField(labelWithString: "% for the left pane")
        field.textColor = .secondaryLabelColor
        return field
    }()
    private lazy var dividerRow = keepRow("Divider", pair(dividerPopUp, shareField, percent)) { [weak self] on in
        self?.change { $0.keepsDivider = on }
    }

    private lazy var hiddenPopUp = popUp(["Shown", "Hidden"], label: "Hidden Files", id: "hidden") {
        [weak self] index in
        self?.change {
            $0.hidden = index == 0
            $0.keepsHidden = true
        }
    }
    private lazy var hiddenRow = keepRow("Hidden Files", hiddenPopUp) { [weak self] on in
        self?.change { $0.keepsHidden = on }
    }

    // MARK: Which pane's rows

    private lazy var paneChooser: NSSegmentedControl = {
        let chooser = NSSegmentedControl(
            labels: ["Left Pane", "Right Pane"], trackingMode: .selectOne, target: self,
            action: #selector(groupChosen(_:)))
        chooser.setAccessibilityIdentifier("tabViewOptions.pane")
        chooser.setAccessibilityLabel("Pane")
        return chooser
    }()
    private lazy var paneTitle = sectionTitle("")
    private lazy var paneNote = note("", fullWidth: true)

    // MARK: A pane's rows

    private lazy var folderPopUp = popUp(label: "Folder", width: 220, id: "folder") { [weak self] index in
        self?.folderChosen(index)
    }
    private lazy var folderNote = note("Stays on the tab\u{2019}s folder")
    private lazy var folderRow = keepRow("Folder", NSStackView(views: [folderPopUp, folderNote])) { [weak self] on in
        self?.changePane { $0.keepsFolder = on }
    }

    private lazy var viewPopUp = popUp(label: "View", id: "view") { [weak self] index in
        guard let self else { return }
        let group = shownGroup
        change { draft in
            if Self.modes.indices.contains(index) {
                draft.setViewer(group, nil)
                draft[group].set(.view) { $0.view = Self.modes[index] }
            } else {
                draft.setViewer(group, draft[group].viewer ?? PaneViewer())
            }
        }
    }
    private lazy var viewRow = keepRow("View", viewPopUp) { [weak self] on in self?.changePane { $0.keep(.view, on) } }

    private lazy var groupPopUp = popUp(Self.groupFields.map(\.title), label: "Group By", id: "groupBy") {
        [weak self] index in
        self?.changePane { pane in
            let reversed = pane.values.groupReversed == true
            pane.set(.groupBy) {
                $0.groupBy = Self.groupFields[index]
                $0.groupReversed = Self.groupFields[index] != .none && reversed ? true : nil
            }
        }
    }
    private lazy var groupOrderPopUp = popUp(
        ["In Order", "Reversed"], label: "Group order", width: 110, id: "groupOrder"
    ) { [weak self] index in
        self?.changePane { $0.set(.groupBy) { $0.groupReversed = index == 1 ? true : nil } }
    }
    private lazy var groupRow = keepRow(Self.title(of: .groupBy), pair(groupPopUp, groupOrderPopUp)) {
        [weak self] on in
        self?.changePane { $0.keep(.groupBy, on) }
    }

    private lazy var sortPopUp = popUp(Self.sortFields.map(\.title), label: "Sort By", id: "sortBy") {
        [weak self] index in
        self?.changePane { pane in
            let direction = pane.values.sort?.direction ?? .asc
            pane.set(.sort) { $0.sort = FolderViewSort(by: Self.sortFields[index], direction: direction) }
        }
    }
    private lazy var sortOrderPopUp = popUp(
        ["Ascending", "Descending"], label: "Sort order", width: 110, id: "sortOrder"
    ) { [weak self] index in
        self?.changePane { pane in
            let by = pane.values.sort?.by ?? .name
            pane.set(.sort) { $0.sort = FolderViewSort(by: by, direction: index == 0 ? .asc : .desc) }
        }
    }
    private lazy var sortRow = keepRow(Self.title(of: .sort), pair(sortPopUp, sortOrderPopUp)) { [weak self] on in
        self?.changePane { $0.keep(.sort, on) }
    }

    private lazy var firstPopUp = popUp(
        ["Before Files", "Mixed with Files"], label: "Folders First", id: "foldersFirst"
    ) { [weak self] index in
        self?.changePane { $0.set(.foldersFirst) { $0.foldersFirst = index == 0 } }
    }
    private lazy var firstRow = keepRow(Self.title(of: .foldersFirst), firstPopUp) { [weak self] on in
        self?.changePane { $0.keep(.foldersFirst, on) }
    }

    /// The List's columns: the checkbox's title on a line of its own, and under it what is kept.
    private lazy var columnsBox: ClosureButton = {
        let box = ClosureButton(checkboxWithTitle: Self.title(of: .columns)) { [weak self] box in
            self?.changePane { $0.keep(.columns, box.state == .on) }
        }
        box.setAccessibilityIdentifier("tabViewOptions.keep.\(Self.title(of: .columns))")
        return box
    }()
    private lazy var columnsDetail: NSTextField = {
        let field = NSTextField(labelWithString: "As the List\u{2019}s header shows them now")
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        return field
    }()
    private lazy var columnsRow: NSView = {
        let lines = NSStackView(views: [columnsBox, indented(columnsDetail)])
        lines.orientation = .vertical
        lines.alignment = .leading
        lines.spacing = 2
        return row(lines, nil, height: 50)
    }()

    private lazy var sizePopUp = popUp(label: "Size", id: "size") { [weak self] index in
        guard let self, sizeValues.indices.contains(index) else { return }
        let value = sizeValues[index]
        let density = density
        changePane { pane in
            let mode = pane.values.view ?? .details
            pane.set(.size) { keeps in
                switch mode {
                case .icons: keeps.size?.iconSizes[density] = value
                case .list: keeps.size?.compactListWidths[density] = value
                default: keeps.size?.previewCounts[density] = value
                }
            }
        }
    }
    private lazy var sizeRow = keepRow("Size", sizePopUp) { [weak self] on in self?.changePane { $0.keep(.size, on) } }

    // MARK: The viewer's rows

    private lazy var followPopUp = popUp(["On", "Off"], label: "Follow", id: "follow") { [weak self] index in
        self?.changeViewer { $0.follows = index == 0 }
    }
    private lazy var followRow = plainRow("Follow", followPopUp, indented: true)
    private lazy var readEditPopUp = popUp(["Read", "Edit"], label: "Read or Edit", id: "readEdit") {
        [weak self] index in
        self?.changeViewer { $0.editing = index == 1 }
    }
    private lazy var readEditRow = plainRow("Read or Edit", readEditPopUp, indented: true)
    private lazy var viewerNote = note("")
    private lazy var viewerNoteRow = row(NSView(), viewerNote, height: 30)

    private lazy var paneCard = card([
        folderRow.view, viewRow.view, groupRow.view, sortRow.view, firstRow.view, columnsRow, sizeRow.view,
        followRow, readEditRow, viewerNoteRow,
    ])

    // MARK: Folder views

    private lazy var folderViewsPopUp = popUp(
        Self.folderViewsChoices.map(\.title), label: "Folder Views", id: "folderViews"
    ) { [weak self] index in
        self?.changePane { $0.folderViews = Self.folderViewsChoices[index].choice }
    }
    private lazy var folderViewsDetail: NSTextField = {
        let field = NSTextField(wrappingLabelWithString: "")
        field.preferredMaxLayoutWidth = contentWidth - 190
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.textColor = .secondaryLabelColor
        return field
    }()
    private lazy var folderViewsRow: NSView = {
        let texts = NSStackView(views: [label("Folder Views"), folderViewsDetail])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 1
        return row(texts, folderViewsPopUp, atEnd: true, height: 50)
    }()

    // MARK: Made once

    /// `startsOn`: the pane group shown first while two are kept, the pane the keyboard is in. `load`: a saved tab
    /// view over this tab, for one chosen by its name.
    init(
        draft: TabViewDraft, saved: [TabView], density: Density, subtitle: String,
        startsOn: TabViewDraft.PaneGroup = .left, load: @escaping (TabView) -> TabViewDraft
    ) {
        self.draft = draft
        self.saved = saved
        self.density = density
        self.load = load
        shownGroup = draft.paneGroups.contains(startsOn) ? startsOn : draft.paneGroups[0]
        super.init(
            identifierPrefix: "tabViewOptions", kind: "tab view", names: saved.map(\.name), name: draft.name,
            placeholder: "Tab view name")
        add(
            header(
                symbol: "rectangle.split.2x1", title: "Tab View Options",
                subtitle: NSTextField(labelWithString: subtitle)))
        addName()
        add(sectionTitle("Keep for This Tab"), after: 2)
        add(card([panesRow.view, dividerRow.view, hiddenRow.view]), after: 10)
        add(paneChooser, fullWidth: false, after: 4)
        add(paneTitle, after: 4)
        add(paneNote, after: 6)
        add(paneCard, after: 8)
        add(folderViewsRow, after: 8)
        addSummary()
        let reset = ClosureButton(title: "Reset") { [weak self] in self?.change { $0.reset() } }
        reset.bezelStyle = .push
        reset.toolTip = "Unchecks everything"
        reset.setAccessibilityIdentifier("tabViewOptions.reset")
        setFooter(manageTitle: "All Tab Views\u{2026}", leading: [reset])
        refresh()
        applyTheme(theme)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: State

    /// The tab view another has this name: Save replaces it.
    var takenBy: TabView? {
        guard let index = SavedViewNames.index(named: draft.name, in: saved), saved[index].id != draft.editingID
        else { return nil }
        return saved[index]
    }

    override var takenName: String? { takenBy?.name }
    override var canSave: Bool { !SavedViewNames.clean(draft.name).isEmpty && !draft.keeps.isEmpty }

    override func nameTyped(_ name: String) { change { $0.name = name } }

    /// A saved tab view chosen by name: its settings fill the sheet in, if asked to, to change it; else the sheet
    /// keeps what it has, to save in its place.
    override func namePicked(_ index: Int) {
        guard saved.indices.contains(index) else { return }
        let view = saved[index]
        Task { @MainActor [weak self] in
            guard let self, await askToLoad(view.name) else { return }
            draft = load(view)
            refresh()
        }
    }

    override func save() {
        draft.name = SavedViewNames.clean(nameBox.stringValue)
        onSave(draft)
    }

    /// The draft changed: the controls show it.
    private func change(_ edit: (inout TabViewDraft) -> Void) {
        edit(&draft)
        refresh()
    }

    /// The rows of the pane group shown changed.
    private func changePane(_ edit: (inout TabViewDraft.Pane) -> Void) {
        let group = shownGroup
        change { edit(&$0[group]) }
    }

    /// The viewer of the pane group shown changed: Follow or Read or Edit.
    private func changeViewer(_ edit: (inout PaneViewer) -> Void) {
        let group = shownGroup
        change { draft in
            var viewer = draft[group].viewer ?? PaneViewer()
            edit(&viewer)
            draft.setViewer(group, viewer)
        }
    }

    @objc private func groupChosen(_ control: NSSegmentedControl) {
        shownGroup = control.selectedSegment == 1 ? .right : .left
        refresh()
    }

    /// A folder chosen in the Folder pop-up: one shown now or saved, or Choose Folder….
    private func folderChosen(_ index: Int) {
        if folderPaths.indices.contains(index) {
            let path = folderPaths[index]
            changePane {
                $0.folder = path
                $0.keepsFolder = true
            }
            return
        }
        let group = shownGroup
        chooseFolder { [weak self] chosen in
            guard let self else { return }
            guard let chosen else {
                refresh()
                return
            }
            change {
                $0[group].folder = chosen
                $0[group].keepsFolder = true
            }
        }
    }

    // MARK: Showing the draft

    /// Every control shows the draft and the pane group shown. Nothing is made or taken away; a field being typed in
    /// keeps what is typed.
    private func refresh() {
        if !draft.paneGroups.contains(shownGroup) { shownGroup = draft.paneGroups[0] }
        refreshName(draft.name)
        refreshTabRows()
        refreshPaneHeader()
        let pane = draft[shownGroup]
        let showsViewer = TabViewDraft.offersViewer(shownGroup) && pane.viewer != nil
        refreshView(pane, showsViewer: showsViewer)
        refreshFolder(pane, shown: !showsViewer)
        refreshSettings(pane, shown: !showsViewer)
        refreshViewer(pane, shown: showsViewer)
        refreshFolderViews(pane, shown: !showsViewer)
        Self.set(summary, SavedViewText.parts(draft.keeps).joined(separator: " \u{00B7} "))
        contentChanged()
    }

    private func refreshTabRows() {
        panesPopUp.selectItem(at: draft.panes == 2 ? 1 : 0)
        panesRow.show(kept: draft.keepsPanes)
        // The divider's choices: what the tab has now, and what the tab view being edited keeps.
        var choices: [(TabViewDraft.Divider, String)] = [
            (.even, "Even"),
            (.shareNow, "As Now: \(SavedViewText.dividerText(.share(draft.shareNow)))"),
            (.widthNow, "As Now: \(SavedViewText.dividerText(.leftWidth(draft.widthNow)).capitalizedFirst)"),
        ]
        if let saved = draft.savedDivider, saved != .even {
            choices.append((.saved, "Saved: \(SavedViewText.dividerText(saved).capitalizedFirst)"))
        }
        choices.append((.custom, "Custom"))
        dividerChoices = choices.map(\.0)
        Self.show(
            dividerPopUp, titles: choices.map(\.1), selected: dividerChoices.firstIndex(of: draft.divider) ?? 1)
        let custom = draft.divider == .custom
        let width: CGFloat = custom ? 120 : FolderViewPopover.popUpWidth
        if dividerWidth?.constant != width { dividerWidth?.constant = width }
        Self.set(shareField, hidden: !custom)
        Self.set(percent, hidden: !custom)
        shareField.show("\(Int((draft.customShare * 100).rounded()))")
        let two = draft.keepsPanes && draft.panes == 2
        dividerRow.show(kept: draft.keepsDivider && two, available: two)
        hiddenPopUp.selectItem(at: draft.hidden ? 0 : 1)
        hiddenRow.show(kept: draft.keepsHidden)
    }

    private func refreshPaneHeader() {
        let groups = draft.paneGroups
        Self.set(paneChooser, hidden: groups.count != 2)
        let segment = shownGroup == .right ? 1 : 0
        if paneChooser.selectedSegment != segment { paneChooser.selectedSegment = segment }
        Self.set(paneTitle, hidden: groups.count == 2)
        Self.set(paneTitle, groups[0].title)
        Self.set(paneNote, Self.groupNote(shownGroup))
    }

    private func refreshView(_ pane: TabViewDraft.Pane, showsViewer: Bool) {
        let offersViewer = TabViewDraft.offersViewer(shownGroup)
        Self.show(
            viewPopUp, titles: Self.modes.map(\.menuName) + (offersViewer ? ["Viewer"] : []),
            selected: showsViewer ? Self.modes.count : Self.modes.firstIndex(of: pane.values.view ?? .details) ?? 0
        ) { popup in
            for (index, mode) in Self.modes.enumerated() {
                popup.item(at: index)?.image = NSImage(
                    systemSymbolName: Self.symbol(of: mode), accessibilityDescription: nil)
            }
            if popup.numberOfItems > Self.modes.count {
                popup.item(at: Self.modes.count)?.image = NSImage(
                    systemSymbolName: "doc.text", accessibilityDescription: nil)
            }
        }
        viewRow.show(kept: pane.kept.contains(.view))
    }

    private func refreshFolder(_ pane: TabViewDraft.Pane, shown: Bool) {
        paneCard.set(folderRow.view, shown: shown)
        guard shown else { return }
        var paths = draft.foldersNow.map(\.path)
        var titles = draft.foldersNow.map { "\(NodePath.basename($0.path)) \u{2014} \($0.pane)" }
        if let folder = pane.folder, !paths.contains(folder) {
            paths.append(folder)
            titles.append(NodePath.basename(folder))
        }
        folderPaths = paths
        Self.show(
            folderPopUp, titles: titles + ["Choose Folder\u{2026}"],
            selected: pane.folder.flatMap { paths.firstIndex(of: $0) } ?? 0)
        Self.set(folderPopUp, hidden: !pane.keepsFolder)
        Self.set(folderNote, hidden: pane.keepsFolder)
        folderRow.show(kept: pane.keepsFolder, dims: false)
    }

    /// Group By, Sort By, Folders First and the fifth row: the List's columns, or the size the view has.
    private func refreshSettings(_ pane: TabViewDraft.Pane, shown: Bool) {
        for row in [groupRow, sortRow, firstRow] { paneCard.set(row.view, shown: shown) }
        let values = pane.values
        let mode = values.view ?? .details
        let showsColumns = shown && (mode == .details || values.size == nil)
        paneCard.set(columnsRow, shown: showsColumns)
        paneCard.set(sizeRow.view, shown: shown && !showsColumns)
        guard shown else { return }

        let grouped = values.groupBy ?? .none
        groupPopUp.selectItem(at: Self.groupFields.firstIndex(of: grouped) ?? 0)
        groupOrderPopUp.selectItem(at: values.groupReversed == true ? 1 : 0)
        groupRow.show(kept: pane.kept.contains(.groupBy))
        let ordersGroups = pane.kept.contains(.groupBy) && grouped != .none
        if groupOrderPopUp.isEnabled != ordersGroups { groupOrderPopUp.isEnabled = ordersGroups }
        let sort = values.sort ?? FolderViewSort(by: .name, direction: .asc)
        sortPopUp.selectItem(at: Self.sortFields.firstIndex(of: sort.by) ?? 0)
        sortOrderPopUp.selectItem(at: sort.direction == .asc ? 0 : 1)
        sortRow.show(kept: pane.kept.contains(.sort))
        firstPopUp.selectItem(at: values.foldersFirst == false ? 1 : 0)
        firstRow.show(kept: pane.kept.contains(.foldersFirst))

        let columnsKept = pane.kept.contains(.columns)
        columnsBox.state = columnsKept ? .on : .off
        columnsDetail.textColor = columnsKept ? .secondaryLabelColor : .tertiaryLabelColor
        guard !showsColumns, let size = values.size else { return }
        let now =
            switch mode {
            case .icons: size.iconSizes[density]
            case .list: size.compactListWidths[density]
            default: size.previewCounts[density]
            }
        let choices = FolderViewPopover.sizeChoices(mode, current: now)
        sizeValues = choices.map(\.value)
        Self.show(sizePopUp, titles: choices.map(\.title), selected: choices.firstIndex { $0.value == now } ?? 0)
        let title = Self.sizeTitle(mode)
        if sizeRow.box.title != title {
            sizeRow.box.title = title
            sizeRow.box.setAccessibilityIdentifier("tabViewOptions.keep.\(title)")
            sizePopUp.setAccessibilityLabel(title)
        }
        sizeRow.show(kept: pane.kept.contains(.size))
    }

    private func refreshViewer(_ pane: TabViewDraft.Pane, shown: Bool) {
        for row in [followRow, readEditRow, viewerNoteRow] { paneCard.set(row, shown: shown) }
        guard shown, let viewer = pane.viewer else { return }
        followPopUp.selectItem(at: viewer.follows ? 0 : 1)
        readEditPopUp.selectItem(at: viewer.editing ? 1 : 0)
        let kept = pane.kept.contains(.view)
        SavedViewSheet.enable(followPopUp, kept)
        SavedViewSheet.enable(readEditPopUp, kept)
        let other = shownGroup == .left ? "right" : "left"
        Self.set(
            viewerNote,
            viewer.follows
                ? "Shows the file the \(other) pane selects, as the selection moves."
                : "Shows the file the \(other) pane selects as the tab view is applied, and stays on it.")
    }

    private func refreshFolderViews(_ pane: TabViewDraft.Pane, shown: Bool) {
        Self.set(folderViewsRow, hidden: !shown)
        guard shown else { return }
        let choice = Self.folderViewsChoices.firstIndex { $0.choice == pane.folderViews } ?? 0
        folderViewsPopUp.selectItem(at: choice)
        Self.set(folderViewsDetail, Self.folderViewsChoices[choice].detail)
    }

    // MARK: Words

    /// What a pane group's rows do.
    static func groupNote(_ group: TabViewDraft.PaneGroup) -> String {
        switch group {
        case .left, .right:
            "What the tab view sets in the pane chosen above. Rows left unchecked stay as the pane has them."
        case .onePane: "What the tab view sets in the pane. Rows left unchecked stay as the pane has them."
        case .activePane:
            "Panes isn\u{2019}t kept: these go to the pane that is active as the tab view is applied. Rows left "
                + "unchecked stay as the pane has them."
        }
    }

    static func title(of setting: FolderViewSetting) -> String {
        switch setting {
        case .view: "View"
        case .groupBy: "Group By"
        case .sort: "Sort By"
        case .foldersFirst: "Folders First"
        case .columns: "Column Visibility, Order and Sizes"
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

    #if DEBUG
        func changeForTesting(_ edit: (inout TabViewDraft) -> Void) { change(edit) }
        func showGroupForTesting(_ group: TabViewDraft.PaneGroup) {
            shownGroup = group
            refresh()
        }
    #endif
}

extension String {
    /// The text with its first letter a capital: "left pane 420 pt" as a choice reads it.
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
