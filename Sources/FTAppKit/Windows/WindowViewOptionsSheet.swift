// Window View Options: the sheet that saves a window view, made of tab views
import AppKit
import FTFoundation

/// The sheet over a window that saves it as a window view: how many tabs, the tab view each opens with (or none),
/// the tab in front, and under "Keep for This Window" the window's size (as now, saved, typed, maximized or full
/// screen), folder tree and Info panel, each kept only if checked. What a tab looks like is its tab view's: the sheet
/// doesn't repeat Tab View Options. Its controls are made once; `refresh` shows the draft in them.
@MainActor
final class WindowViewOptionsSheet: SavedViewSheet {
    private(set) var draft: WindowViewDraft
    private let saved: [WindowView]
    private let tabViews: [TabView]
    /// A saved window view's settings, as the sheet shows them, for the one chosen by name.
    private let load: (WindowView) -> WindowViewDraft
    /// Each tab pop-up's items: no tab view, then the tab views; and where each tab view is among them.
    private let tabViewIDs: [String?]
    private let tabViewPlaces: [String: Int]

    /// Save, with the name typed and what is kept.
    var onSave: (WindowViewDraft) -> Void = { _ in }

    /// The tabs shown before their list scrolls.
    static let tabsShown = 6

    /// The size choices offered now, in the Size pop-up's order.
    private var sizeChoices: [WindowViewDraft.SizeChoice] = []
    /// The number of tabs the list was last laid out for.
    private var tabsLaidOut = 0

    private let subtitle = NSTextField(labelWithString: "")

    // MARK: Tabs

    private lazy var countPopUp = popUp(
        (1...AppPreferenceLimits.openTabsLimit).map { $0 == 1 ? "1 tab" : "\($0) tabs" }, label: "Number of Tabs",
        id: "count"
    ) { [weak self] index in
        self?.change { $0.setTabCount(index + 1) }
    }
    /// A row for every tab the window can have, made once: the ones past the number of tabs are hidden.
    private lazy var tabRows: [(row: NSView, popup: ClosurePopUp)] = {
        let titles = ["None: a New Tab"] + tabViews.map { MenuName.shortened($0.name) }
        return (0..<AppPreferenceLimits.openTabsLimit).map { index in
            let popup = popUp(titles, label: "Tab \(index + 1)", width: 220, id: "tab\(index + 1)") {
                [weak self] picked in
                guard let self else { return }
                let id = tabViewIDs[picked]
                change { $0.setTab(index, to: id) }
            }
            return (plainRow("Tab \(index + 1)", popup), popup)
        }
    }()
    private lazy var tabList = card(tabRows.map(\.row))
    private lazy var tabDocument: SheetDocumentView = {
        let document = SheetDocumentView()
        document.addSubview(tabList)
        return document
    }()
    private lazy var tabScroll: NSScrollView = {
        let scroll = NSScrollView()
        scroll.documentView = tabDocument
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        return scroll
    }()
    private lazy var tabScrollHeight: NSLayoutConstraint = {
        let height = tabScroll.heightAnchor.constraint(equalToConstant: FolderViewPopover.rowHeight)
        height.isActive = true
        return height
    }()
    private lazy var frontPopUp = popUp(label: "Front Tab", id: "front") { [weak self] index in
        self?.change { $0.front = index }
    }

    // MARK: The window's own

    private lazy var sizePopUp = popUp(label: "Size", id: "size") { [weak self] index in
        guard let self, sizeChoices.indices.contains(index) else { return }
        let choice = sizeChoices[index]
        change {
            $0.sizeChoice = choice
            $0.keepsSize = true
        }
    }
    /// Each kept as it is typed, and shown held to what a window can be once its field is left.
    private lazy var widthField = numberField(
        label: "Width in points", id: "width", width: 56,
        changed: { [weak self] value in self?.change { $0.customSize.width = value } },
        ended: { [weak self] in self?.refresh() })
    private lazy var heightField = numberField(
        label: "Height in points", id: "height", width: 56,
        changed: { [weak self] value in self?.change { $0.customSize.height = value } },
        ended: { [weak self] in self?.refresh() })
    /// The fields and their words, shown with Custom.
    private lazy var customViews: [NSView] = {
        let points = NSTextField(labelWithString: "pt")
        points.textColor = .secondaryLabelColor
        return [widthField, NSTextField(labelWithString: "\u{00D7}"), heightField, points]
    }()
    private lazy var sizeRow: KeepRow = {
        let control = NSStackView(views: [sizePopUp] + customViews)
        control.orientation = .horizontal
        control.spacing = 6
        return keepRow("Size", control) { [weak self] on in self?.change { $0.keepsSize = on } }
    }()
    /// Narrower with a size typed beside it, so the fields and their words fit the row.
    private lazy var sizeWidth = sizePopUp.constraints.first { $0.firstAttribute == .width }
    private lazy var rangeNote = note("")
    private lazy var rangeRow = row(NSView(), rangeNote, height: 26)
    private lazy var treePopUp = popUp(["Shown", "Hidden"], label: "Folder Tree", id: "folderTree") {
        [weak self] index in
        self?.change {
            $0.folderTreeOpen = index == 0
            $0.keepsFolderTree = true
        }
    }
    private lazy var treeRow = keepRow("Folder Tree", treePopUp) { [weak self] on in
        self?.change { $0.keepsFolderTree = on }
    }
    private lazy var infoPopUp = popUp(["Shown", "Hidden"], label: "Info Panel", id: "infoPanel") {
        [weak self] index in
        self?.change {
            $0.propertiesOpen = index == 0
            $0.keepsInfoPanel = true
        }
    }
    private lazy var infoRow = keepRow("Info Panel", infoPopUp) { [weak self] on in
        self?.change { $0.keepsInfoPanel = on }
    }
    private lazy var windowCard = card([sizeRow.view, rangeRow, treeRow.view, infoRow.view])

    // MARK: Made once

    init(
        draft: WindowViewDraft, saved: [WindowView], tabViews: [TabView],
        load: @escaping (WindowView) -> WindowViewDraft
    ) {
        self.draft = draft
        self.saved = saved
        self.tabViews = tabViews
        self.load = load
        tabViewIDs = [nil] + tabViews.map(\.id)
        tabViewPlaces = Dictionary(
            tabViews.enumerated().map { ($1.id, $0 + 1) }, uniquingKeysWith: { first, _ in first })
        super.init(
            identifierPrefix: "windowViewOptions", kind: "window view", names: saved.map(\.name), name: draft.name,
            placeholder: "Window view name")
        add(header(symbol: "macwindow", title: "Window View Options", subtitle: subtitle))
        addName()
        add(sectionTitle("Tabs"), after: 2)
        add(card([plainRow("Number of Tabs", countPopUp), tabScroll, plainRow("Front Tab", frontPopUp)]), after: 10)
        add(sectionTitle("Keep for This Window"), after: 2)
        add(windowCard, after: 4)
        add(note("What isn\u{2019}t checked comes from the window you open it from.", fullWidth: true), after: 8)
        addSummary()
        setFooter(manageTitle: "All Window Views\u{2026}")
        refresh()
        applyTheme(theme)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: State

    var takenBy: WindowView? {
        guard let index = SavedViewNames.index(named: draft.name, in: saved), saved[index].id != draft.editingID
        else { return nil }
        return saved[index]
    }

    override var takenName: String? { takenBy?.name }
    override var canSave: Bool { !SavedViewNames.clean(draft.name).isEmpty }

    override func nameTyped(_ name: String) { change { $0.name = name } }

    /// A saved window view chosen by name: its settings fill the sheet in, if asked to, to change it; else the sheet
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
    private func change(_ edit: (inout WindowViewDraft) -> Void) {
        edit(&draft)
        refresh()
    }

    // MARK: Showing the draft

    /// Every control shows the draft. Nothing is made or taken away; a field being typed in keeps what is typed.
    private func refresh() {
        let count = draft.tabs.count
        Self.set(subtitle, count == 1 ? "1 tab" : "\(count) tabs")
        refreshName(draft.name)
        refreshTabs()
        refreshSize()
        treePopUp.selectItem(at: draft.folderTreeOpen ? 0 : 1)
        treeRow.show(kept: draft.keepsFolderTree)
        infoPopUp.selectItem(at: draft.propertiesOpen ? 0 : 1)
        infoRow.show(kept: draft.keepsInfoPanel)
        let view = draft.windowView(id: draft.editingID ?? "")
        Self.set(summary, SavedViewText.parts(view, tabViews: tabViews).joined(separator: " \u{00B7} "))
        contentChanged()
    }

    private func refreshTabs() {
        let count = draft.tabs.count
        countPopUp.selectItem(at: count - 1)
        for (index, tab) in tabRows.enumerated() where index < count {
            tab.popup.selectItem(at: draft.tabs[index].flatMap { tabViewPlaces[$0] } ?? 0)
        }
        Self.show(frontPopUp, titles: (1...count).map { "Tab \($0)" }, selected: draft.front)
        guard count != tabsLaidOut else { return }
        tabsLaidOut = count
        for (index, tab) in tabRows.enumerated() { tabList.set(tab.row, shown: index < count) }
        // Rows of one height and the hairlines between them: past `tabsShown`, the list scrolls.
        let rows = Double(count)
        let listHeight = rows * FolderViewPopover.rowHeight + rows - 1
        let shown = Double(min(count, Self.tabsShown))
        tabScrollHeight.constant = shown * FolderViewPopover.rowHeight + shown - 1
        tabDocument.frame = NSRect(x: 0, y: 0, width: contentWidth, height: listHeight)
        tabList.frame = tabDocument.bounds
    }

    private func refreshSize() {
        var choices: [(WindowViewDraft.SizeChoice, String)] = [
            (.now, "As Now: \(draft.sizeNow.width) \u{00D7} \(draft.sizeNow.height)")
        ]
        if let size = draft.savedSize, size != draft.sizeNow {
            choices.append((.saved, "Saved: \(size.width) \u{00D7} \(size.height)"))
        }
        choices += [(.custom, "Custom"), (.maximized, "Maximized"), (.fullScreen, "Full Screen")]
        sizeChoices = choices.map(\.0)
        Self.show(sizePopUp, titles: choices.map(\.1), selected: sizeChoices.firstIndex(of: draft.sizeChoice) ?? 0)
        sizeRow.show(kept: draft.keepsSize)
        let custom = draft.sizeChoice == .custom
        let width: CGFloat = custom ? 120 : FolderViewPopover.popUpWidth
        if sizeWidth?.constant != width { sizeWidth?.constant = width }
        for view in customViews { Self.set(view, hidden: !custom) }
        widthField.show("\(draft.customSize.width)")
        heightField.show("\(draft.customSize.height)")
        windowCard.set(rangeRow, shown: draft.sizeChoice != .now && draft.sizeChoice != .saved)
        Self.set(rangeNote, rangeText)
    }

    /// What the Size choice does, under it.
    private var rangeText: String {
        switch draft.sizeChoice {
        case .maximized: return "Fills the screen beside the menu bar and the Dock."
        case .fullScreen: return "Opens in full screen, in a space of its own."
        case .now, .saved, .custom:
            let low = WindowViewDraft.smallestSize
            var text = "From \(low.width) \u{00D7} \(low.height) pt"
            if let high = draft.largestSize {
                text += " to \(high.width) \u{00D7} \(high.height) pt, the most this screen gives a window"
            }
            return text + "."
        }
    }

    #if DEBUG
        func changeForTesting(_ edit: (inout WindowViewDraft) -> Void) { change(edit) }
        var tabRowsShown: Int { tabRows.filter { !$0.row.isHidden }.count }
        var tabListHeight: Double { tabScrollHeight.constant }
    #endif
}
