// Tab View Options: the sheet that saves a tab view, its parts in a sidebar
import AppKit
import FTFoundation

/// The sheet over a tab that saves what it keeps as a tab view, or changes one saved. The Name is in its header; a
/// sidebar lists its parts (the tab, then each pane's Folder, View, Viewer and Search Results, under the pane), and one part's
/// rows show beside it. The sheet is as tall as its tallest part, so it keeps one height whichever is shown. Its rows
/// are Folder View Options' (a checkbox titled with each setting and its control in a column that starts at the same
/// place in every row). A value chosen is kept from then on.
///
/// Its controls are made once; `refresh` shows the draft in them. The pane parts' controls are one set, showing the
/// pane chosen in the sidebar.
@MainActor
final class TabViewOptionsSheet: SavedViewSheet {
    override class var width: Double { 720 }
    override var rowsWidth: Double { contentWidth - Self.sidebarWidth - Self.sidebarGap }
    override var controlColumn: Double { 150 }

    private(set) var draft: TabViewDraft
    /// The tab views kept, to say which name is taken and to choose one by name.
    private let saved: [TabView]
    private let density: Density
    /// A saved tab view over this tab, for one chosen by its name.
    private let load: (TabView) -> TabViewDraft
    /// Whether the sheet is for a tab view being edited: Columns then reads "as saved".
    private let editing: Bool

    /// The pane whose parts show, and which of its parts; or the tab's own part.
    enum Part: String, CaseIterable { case tab, folder, view, viewer, search }
    private(set) var shownGroup = TabViewDraft.PaneGroup.left
    private(set) var shownPart = Part.view

    /// Save, with the name typed and what is kept.
    var onSave: (TabViewDraft) -> Void = { _ in }
    /// Choose Folder…, for a pane group: the folder chosen, or nil.
    var chooseFolder: (@escaping (String?) -> Void) -> Void = { $0(nil) }

    /// What the pop-ups whose items change offer now, in their order.
    private var dividerChoices: [TabViewDraft.Divider] = []
    private var folderPaths: [String] = []
    private var sizeValues: [ViewSizeKind: [Int]] = [:]

    private static let modes = ExplorerViewMode.menuOrder
    private static let groupFields = [GroupByPreference.none] + GroupByPreference.menuOrder
    private static let sortFields = SortByPreference.menuOrder
    private let subtitle = NSTextField(labelWithString: "")
    private lazy var sidebar: SheetSidebar = {
        let sidebar = SheetSidebar(identifier: "tabViewOptions.parts")
        sidebar.chosen = { [weak self] id in self?.partChosen(id) }
        return sidebar
    }()
    private lazy var body = sidebarBody(sidebar, pages: [tabPage, folderPage, viewPage, viewerPage, searchPage])

    // MARK: The tab's part

    private lazy var panesPopUp = popUp(["One", "Two"], label: "Panes", id: "panes") { [weak self] index in
        self?.change {
            $0.panes = index == 1 ? 2 : 1
            $0.keepsPanes = true
        }
    }
    private lazy var panesRow = keepRow("Panes", panesPopUp) { [weak self] on in self?.change { $0.keepsPanes = on } }

    /// With one pane: whether the second pane the tab keeps closed is forgotten, so Two Panes opens a new one.
    private lazy var forgetBox: ClosureButton = {
        let box = ClosureButton(checkboxWithTitle: "Forget the Second Pane") { [weak self] box in
            self?.change { $0.forgetsSecondPane = box.state == .on }
        }
        box.setAccessibilityIdentifier("tabViewOptions.forgetSecondPane")
        return box
    }()
    private lazy var forgetRow: NSView = {
        let detail = note(
            "The tab forgets the second pane it had, so Two Panes opens a new one rather than bringing it back.")
        let lines = NSStackView(views: [forgetBox, indented(detail)])
        lines.orientation = .vertical
        lines.alignment = .leading
        lines.spacing = 2
        return row(indented(lines), nil, height: 50)
    }()
    private lazy var tabCard = card([panesRow.view, forgetRow, dividerRow.view, hiddenRow.view])
    private static let tabPageNote =
        "What the tab view sets for the tab. Rows left unchecked stay as the tab has them."
    private lazy var tabPage = page(Self.tabPageNote, [(tabCard, 0)])

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

    // MARK: A pane's Folder

    private lazy var folderPopUp = popUp(label: "Folder", width: 220, id: "folder") { [weak self] index in
        self?.folderChosen(index)
    }
    private lazy var folderNote = note("Stays on the tab\u{2019}s folder")
    private lazy var folderRow = keepRow("Folder", NSStackView(views: [folderPopUp, folderNote])) { [weak self] on in
        self?.changePane { $0.keepsFolder = on }
    }
    private lazy var folderPage = page("", [(card([folderRow.view]), 0)])

    // MARK: A pane's View

    private lazy var viewPopUp = popUp(Self.modes.map(\.menuName), label: "Starts In", id: "view") {
        [weak self] index in
        self?.changePane { $0.set(.view) { $0.view = Self.modes[index] } }
    }
    private lazy var viewRow = keepRow("Starts In", viewPopUp) { [weak self] on in
        self?.changePane { $0.keep(.view, on) }
    }

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
    private lazy var groupRow = keepRow("Group By", pair(groupPopUp, groupOrderPopUp)) { [weak self] on in
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
    private lazy var sortRow = keepRow("Sort By", pair(sortPopUp, sortOrderPopUp)) { [weak self] on in
        self?.changePane { $0.keep(.sort, on) }
    }

    private lazy var firstPopUp = popUp(
        ["Before Files", "Mixed with Files"], label: "Folders First", id: "foldersFirst"
    ) { [weak self] index in
        self?.changePane { $0.set(.foldersFirst) { $0.foldersFirst = index == 0 } }
    }
    private lazy var firstRow = keepRow("Folders First", firstPopUp) { [weak self] on in
        self?.changePane { $0.keep(.foldersFirst, on) }
    }

    /// Each view's size: the pop-up and the row, by the view.
    private lazy var sizePopUps: [ViewSizeKind: ClosurePopUp] = Dictionary(
        uniqueKeysWithValues: ViewSizeKind.allCases.map { size in
            let popup = popUp(label: Self.sizeTitle(size), id: "size.\(size.rawValue)") { [weak self] index in
                guard let self, let value = sizeValues[size]?[index] else { return }
                let density = density
                changePane { $0.set(size, value, at: density) }
            }
            return (size, popup)
        })
    private lazy var sizeRows: [ViewSizeKind: KeepRow] = Dictionary(
        uniqueKeysWithValues: ViewSizeKind.allCases.map { size in
            let row = keepRow(Self.sizeTitle(size), sizePopUps[size]!) { [weak self] on in
                self?.changePane { $0.keep(size, on) }
            }
            return (size, row)
        })

    /// The List's columns: which show, in order, as the pane has them now or as saved, under the checkbox's title.
    private lazy var columnsNames: NSTextField = {
        let field = NSTextField(wrappingLabelWithString: "")
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.preferredMaxLayoutWidth = rowsWidth - controlColumn
        field.setAccessibilityIdentifier("tabViewOptions.columns")
        return field
    }()
    private lazy var columnsSource: NSTextField = {
        let field = NSTextField(labelWithString: "")
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.textColor = .tertiaryLabelColor
        return field
    }()
    private lazy var columnsRow: KeepRow = {
        let lines = NSStackView(views: [columnsNames, columnsSource])
        lines.orientation = .vertical
        lines.alignment = .leading
        lines.spacing = 1
        return keepRow("Columns", lines) { [weak self] on in self?.changePane { $0.keep(.columns, on) } }
    }()

    /// Opens the Viewer, with what it opens beside.
    private lazy var opensViewerDetail = note("")
    private lazy var opensViewerRow = keepRow("Opens the Viewer", opensViewerDetail) { [weak self] on in
        guard let self else { return }
        let group = shownGroup
        change { $0.setOpensViewer(group, on) }
    }
    private lazy var editPopUp = popUp(["Read", "Edit"], label: "Read or Edit", id: "readEdit") { [weak self] index in
        self?.changePane {
            $0.viewer.editing = index == 1
            $0.keepsEditing = true
        }
    }
    private lazy var editRow = keepRow("Read or Edit", editPopUp) { [weak self] on in
        self?.changePane { $0.keepsEditing = on }
    }
    private lazy var followPopUp = popUp(["On", "Off"], label: "Follow", id: "follow") { [weak self] index in
        self?.changePane {
            $0.viewer.follows = index == 0
            $0.keepsFollows = true
        }
    }
    private lazy var followRow = keepRow("Follow", followPopUp) { [weak self] on in
        self?.changePane { $0.keepsFollows = on }
    }

    private lazy var viewPage = page(
        "",
        [
            (card([viewRow.view]), 12),
            (sectionTitle("In Every View"), 2),
            (card([groupRow.view, sortRow.view, firstRow.view]), 12),
            (sectionTitle("Each View\u{2019}s Options"), 2),
            (
                card([
                    sizeRows[.icons]!.view, columnsRow.view, sizeRows[.compactList]!.view,
                    sizeRows[.previews]!.view,
                ]), 12
            ),
        ])

    // MARK: A pane's Viewer

    private lazy var viewerPage = page("", [(card([opensViewerRow.view, editRow.view, followRow.view]), 0)])

    // MARK: A pane's Search Results

    private lazy var searchResultsBox: ClosureButton = {
        let box = ClosureButton(checkboxWithTitle: "Search View") { [weak self] box in
            self?.changePane { $0.keepsSearchResults = box.state == .on }
        }
        box.setAccessibilityIdentifier("tabViewOptions.keep.Search View")
        return box
    }()
    private lazy var searchResultsDetail: NSTextField = {
        let field = NSTextField(wrappingLabelWithString: "")
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.preferredMaxLayoutWidth = rowsWidth - 20
        field.setAccessibilityIdentifier("tabViewOptions.searchResultsDetail")
        return field
    }()
    private lazy var searchResultsRow: NSView = {
        let lines = NSStackView(views: [searchResultsBox, indented(searchResultsDetail)])
        lines.orientation = .vertical
        lines.alignment = .leading
        lines.spacing = 2
        return row(lines, nil, height: 50)
    }()
    private lazy var searchPage = page("", [(card([searchResultsRow]), 0)])

    // MARK: Made once

    /// `startsOn`: the pane shown first while two are kept, the pane the keyboard is in. `load`: a saved tab view over
    /// this tab, for one chosen by its name.
    init(
        draft: TabViewDraft, saved: [TabView], density: Density, subtitle: String,
        startsOn: TabViewDraft.PaneGroup = .left, load: @escaping (TabView) -> TabViewDraft
    ) {
        self.draft = draft
        self.saved = saved
        self.density = density
        self.load = load
        editing = draft.editingID != nil
        shownGroup = draft.paneGroups.contains(startsOn) ? startsOn : draft.paneGroups[0]
        super.init(
            identifierPrefix: "tabViewOptions", kind: "tab view", names: saved.map(\.name), name: draft.name,
            placeholder: "Tab view name")
        self.subtitle.stringValue = subtitle
        addHeaderWithName(symbol: "rectangle.split.2x1", title: "Tab View Options", subtitle: self.subtitle)
        add(body, after: 14)
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

    /// The rows of the pane shown changed.
    private func changePane(_ edit: (inout TabViewDraft.Pane) -> Void) {
        let group = shownGroup
        change { edit(&$0[group]) }
    }

    /// A part chosen in the sidebar: "tab", or a pane's ("left.view").
    private func partChosen(_ id: String) {
        let pieces = id.split(separator: ".").map(String.init)
        if pieces.count == 2, let part = Part(rawValue: pieces[1]),
            let group = draft.paneGroups.first(where: { Self.key(of: $0) == pieces[0] })
        {
            shownGroup = group
            shownPart = part
        } else {
            shownPart = .tab
        }
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

    /// Every control shows the draft and the part shown. Nothing is made or taken away; a field being typed in keeps
    /// what is typed.
    private func refresh() {
        if !draft.paneGroups.contains(shownGroup) { shownGroup = draft.paneGroups[0] }
        refreshName(draft.name)
        refreshSidebar()
        refreshTabRows()
        let pane = draft[shownGroup]
        refreshFolder(pane)
        refreshView(pane)
        refreshSettings(pane)
        refreshSizes(pane)
        refreshViewer(pane)
        refreshSearchResults(pane)
        body.show(page: Part.allCases.firstIndex(of: shownPart) ?? 0)
        Self.set(summary, SavedViewText.parts(draft.keeps).joined(separator: " \u{00B7} "))
        contentChanged()
    }

    private func refreshSidebar() {
        var rows: [SheetSidebar.Row] = [.item(id: "tab", title: "Tab", symbol: "macwindow")]
        for group in draft.paneGroups {
            let key = Self.key(of: group)
            rows += [
                .heading(group.title),
                .item(id: "\(key).folder", title: "Folder", symbol: "folder"),
                .item(id: "\(key).view", title: "View", symbol: "square.grid.2x2"),
                .item(id: "\(key).viewer", title: "Viewer", symbol: "doc.text"),
                .item(id: "\(key).search", title: "Search Results", symbol: "magnifyingglass"),
            ]
        }
        sidebar.show(rows, selected: shownPart == .tab ? "tab" : "\(Self.key(of: shownGroup)).\(shownPart.rawValue)")
    }

    private func refreshTabRows() {
        // With the panes not kept, the pane pages are the active pane's: said once here, which one that is.
        if let line = tabPage.arrangedSubviews.first as? NSTextField {
            let activePane =
                draft.paneGroups.contains(.activePane)
                ? " The active pane is whichever pane is active when the tab view is applied." : ""
            Self.set(line, Self.tabPageNote + activePane)
        }
        panesPopUp.selectItem(at: draft.panes == 2 ? 1 : 0)
        panesRow.show(kept: draft.keepsPanes)
        tabCard.set(forgetRow, shown: draft.keepsPanes && draft.panes == 1)
        let forgets: NSControl.StateValue = draft.forgetsSecondPane ? .on : .off
        if forgetBox.state != forgets { forgetBox.state = forgets }
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

    private func refreshFolder(_ pane: TabViewDraft.Pane) {
        if let line = folderPage.arrangedSubviews.first as? NSTextField {
            let pane = Self.paneWords(shownGroup)
            Self.set(line, "The folder \(pane) goes to.")
        }
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

    private func refreshView(_ pane: TabViewDraft.Pane) {
        if let line = viewPage.arrangedSubviews.first as? NSTextField {
            let pane = Self.paneWords(shownGroup)
            Self.set(line, "What \(pane) starts with. Rows left unchecked stay as the pane has them.")
        }
        Self.show(
            viewPopUp, titles: Self.modes.map(\.menuName),
            selected: Self.modes.firstIndex(of: pane.values.view ?? .details) ?? 0
        ) { popup in
            for (index, mode) in Self.modes.enumerated() {
                popup.item(at: index)?.image = NSImage(
                    systemSymbolName: Self.symbol(of: mode), accessibilityDescription: nil)
            }
        }
        viewRow.show(kept: pane.kept.contains(.view))
    }

    /// Group By, Sort By and Folders First: the pane's, in every view.
    private func refreshSettings(_ pane: TabViewDraft.Pane) {
        let values = pane.values
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
    }

    /// Each view's options: its size, and the List's columns.
    private func refreshSizes(_ pane: TabViewDraft.Pane) {
        for size in ViewSizeKind.allCases {
            guard let popup = sizePopUps[size], let row = sizeRows[size] else { continue }
            let now = pane.values.size?[size][density] ?? size.defaults[density]
            let choices = FolderViewPopover.sizeChoices(size.view, current: now)
            sizeValues[size] = choices.map(\.value)
            Self.show(popup, titles: choices.map(\.title), selected: choices.firstIndex { $0.value == now } ?? 0)
            row.show(kept: pane.sizesKept.contains(size))
        }
        let columns = pane.values.columns
        let names =
            ["Name"]
            + (columns.map { columns in
                columns.order.filter { columns.visibility[$0] }.compactMap {
                    DetailColumnKey(rawValue: $0.rawValue)?.label
                }
            } ?? [])
        Self.set(columnsNames, names.joined(separator: ", "))
        let kept = pane.kept.contains(.columns)
        Self.set(columnsSource, editing && kept ? "As saved" : "As this pane has them now")
        columnsRow.show(kept: kept, dims: false)
        columnsNames.textColor = kept ? .labelColor : .secondaryLabelColor
    }

    /// Opens the Viewer (in one of two panes only), Read or Edit and Follow.
    private func refreshViewer(_ pane: TabViewDraft.Pane) {
        if let line = viewerPage.arrangedSubviews.first as? NSTextField {
            let pane = Self.paneWords(shownGroup)
            Self.set(line, "How a viewer in \(pane) starts. Rows left unchecked stay as the pane has them.")
        }
        // What it shows: with two panes, the other pane's selection while Follow is on and that pane shows a list.
        let two = shownGroup == .left || shownGroup == .right
        let other = shownGroup == .left ? "right" : "left"
        Self.set(
            opensViewerDetail,
            two
                ? "Opens over this pane\u{2019}s list. With Follow on, it shows the file selected in the \(other) "
                    + "pane; otherwise, the file selected here."
                : "Opens over this pane\u{2019}s list, on the file selected in it.")
        opensViewerRow.show(kept: pane.opensViewer, dims: false)
        editPopUp.selectItem(at: pane.viewer.editing ? 1 : 0)
        editRow.show(kept: pane.keepsEditing)
        followPopUp.selectItem(at: pane.viewer.follows ? 0 : 1)
        followRow.show(kept: pane.keepsFollows)
    }

    private func refreshSearchResults(_ pane: TabViewDraft.Pane) {
        if let line = searchPage.arrangedSubviews.first as? NSTextField {
            Self.set(line, "How \(Self.paneWords(shownGroup)) shows search results, kept whole.")
        }
        let state: NSControl.StateValue = pane.keepsSearchResults ? .on : .off
        if searchResultsBox.state != state { searchResultsBox.state = state }
        Self.set(
            searchResultsDetail,
            "View, sort, groups, columns and sizes, "
                + (editing && pane.keepsSearchResults ? "as saved." : "as results show in this pane now."))
        searchResultsDetail.textColor = pane.keepsSearchResults ? .secondaryLabelColor : .tertiaryLabelColor
    }

    // MARK: Words

    /// A pane group as the sidebar's ids name it.
    private static func key(of group: TabViewDraft.PaneGroup) -> String {
        switch group {
        case .left: "left"
        case .right: "right"
        case .onePane: "pane"
        case .activePane: "active"
        }
    }

    /// A pane group as a page's first line says it.
    static func paneWords(_ group: TabViewDraft.PaneGroup) -> String {
        switch group {
        case .left: "the left pane"
        case .right: "the right pane"
        case .onePane: "the pane"
        case .activePane: "the active pane"
        }
    }

    static func sizeTitle(_ size: ViewSizeKind) -> String {
        switch size {
        case .icons: "Icon Size"
        case .compactList: "Column Width"
        case .previews: "Previews at a Time"
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
        func showGroupForTesting(_ group: TabViewDraft.PaneGroup, part: Part = .view) {
            shownGroup = group
            shownPart = part
            refresh()
        }
    #endif
}

extension String {
    /// The text with its first letter a capital: "left pane 420 pt" as a choice reads it.
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
