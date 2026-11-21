// Window View Options: the sheet that saves a window view, made of tab views
import AppKit
import FTFoundation

/// The sheet over a window that saves it as a window view: how many tabs, the tab view each opens with (or none),
/// the tab in front, and under "Keep for This Window" the window's size, folder tree and Info panel, each kept only if
/// checked. What a tab looks like is its tab view's: the sheet doesn't repeat Tab View Options.
@MainActor
final class WindowViewOptionsSheet: SavedViewSheet {
    private(set) var draft: WindowViewDraft
    private let saved: [WindowView]
    private let tabViews: [TabView]
    private let nameField = NSTextField()
    private var saveButton: NSButton?

    var onCancel: () -> Void = {}
    var onSave: (WindowViewDraft) -> Void = { _ in }
    var onManage: () -> Void = {}

    override var identifierPrefix: String { "windowViewOptions" }
    override var initialResponder: NSView? { nameField }

    init(draft: WindowViewDraft, saved: [WindowView], tabViews: [TabView]) {
        self.draft = draft
        self.saved = saved
        self.tabViews = tabViews
        super.init()
        setAccessibilityIdentifier("windowViewOptions")
        nameField.stringValue = draft.name
        nameField.placeholderString = "Window view name"
        nameField.setAccessibilityIdentifier("windowViewOptions.name")
        NotificationCenter.default.addObserver(
            self, selector: #selector(nameChanged), name: NSControl.textDidChangeNotification, object: nameField)
        build()
        applyTheme(theme)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

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

    var takenBy: WindowView? {
        guard let index = SavedViewNames.index(named: draft.name, in: saved), saved[index].id != draft.editingID
        else { return nil }
        return saved[index]
    }

    var canSave: Bool { !SavedViewNames.clean(draft.name).isEmpty }

    @objc private func nameChanged() {
        draft.name = nameField.stringValue
        let field = window?.firstResponder
        build()
        if field != nil { window?.makeFirstResponder(nameField) }
    }

    private func save() {
        draft.name = SavedViewNames.clean(nameField.stringValue)
        onSave(draft)
    }

    private func change(_ edit: (inout WindowViewDraft) -> Void) {
        edit(&draft)
        build()
    }

    // MARK: Building

    private func build() {
        clear()
        let count = draft.tabs.count
        add(
            header(
                symbol: "macwindow", title: "Window View Options",
                subtitle: count == 1 ? "1 tab" : "\(count) tabs"))
        add(row(label("Name"), nameField, stretch: true), after: 4)
        if let taken = takenBy {
            add(note("A window view called \u{201C}\(taken.name)\u{201D} exists. Saving replaces it."), after: 8)
        }
        add(sectionTitle("Tabs"), after: 2)
        add(tabsCard(), after: 10)
        add(sectionTitle("Keep for This Window"), after: 2)
        add(card(windowRows()), after: 4)
        add(note("What isn\u{2019}t checked comes from the window you open it from."), after: 8)
        add(separator())
        let view = draft.windowView(id: draft.editingID ?? "")
        add(note(SavedViewText.parts(view, tabViews: tabViews).joined(separator: " \u{00B7} ")), after: 8)
        setFooter(footer())
        needsLayout = true
        superview?.needsLayout = true
    }

    /// Number of Tabs, a row for each tab with its tab view, and the tab in front; past a few tabs the rows scroll.
    private func tabsCard() -> NSView {
        let counts = Array(1...AppPreferenceLimits.openTabsLimit)
        let number = popUp(counts.map { $0 == 1 ? "1 tab" : "\($0) tabs" }, selected: draft.tabs.count - 1) {
            [weak self] index in
            self?.change { $0.setTabCount(counts[index]) }
        }
        number.setAccessibilityIdentifier("windowViewOptions.count")
        var rows: [NSView] = [row(label("Number of Tabs"), number)]
        var tabRows: [NSView] = []
        let ids: [String?] = [nil] + tabViews.map(\.id)
        let titles = ["None: a New Tab"] + tabViews.map { MenuName.shortened($0.name) }
        for (index, id) in draft.tabs.enumerated() {
            let chosen = ids.firstIndex { $0 == id } ?? 0
            let popup = popUp(titles, selected: chosen, width: 220) { [weak self] picked in
                self?.change { $0.setTab(index, to: ids[picked]) }
            }
            popup.setAccessibilityIdentifier("windowViewOptions.tab\(index + 1)")
            tabRows.append(row(label("Tab \(index + 1)"), popup))
        }
        let list = card(tabRows)
        if draft.tabs.count > 6 {
            let scroll = NSScrollView()
            scroll.documentView = list
            scroll.hasVerticalScroller = true
            scroll.drawsBackground = false
            scroll.translatesAutoresizingMaskIntoConstraints = false
            scroll.heightAnchor.constraint(equalToConstant: 6 * FolderViewPopover.rowHeight).isActive = true
            list.translatesAutoresizingMaskIntoConstraints = false
            list.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
            rows.append(scroll)
        } else {
            rows.append(list)
        }
        let front = popUp(draft.tabs.indices.map { "Tab \($0 + 1)" }, selected: draft.front) { [weak self] index in
            self?.change { $0.front = index }
        }
        front.setAccessibilityIdentifier("windowViewOptions.front")
        rows.append(row(label("Front Tab"), front))
        return card(rows)
    }

    private func windowRows() -> [NSView] {
        var choices: [(WindowViewDraft.SizeChoice, String)] = [
            (.now, "As Now: \(draft.sizeNow.width) \u{00D7} \(draft.sizeNow.height)")
        ]
        if let size = draft.savedSize, size != draft.sizeNow {
            choices.append((.saved, "Saved: \(size.width) \u{00D7} \(size.height)"))
        }
        choices.append((.custom, "Custom"))
        let sizePopUp = popUp(choices.map(\.1), selected: choices.firstIndex { $0.0 == draft.sizeChoice } ?? 0) {
            [weak self] index in
            self?.change {
                $0.sizeChoice = choices[index].0
                $0.keepsSize = true
            }
        }
        sizePopUp.setAccessibilityIdentifier("windowViewOptions.size")
        var sizeControl: NSView = sizePopUp
        if draft.sizeChoice == .custom {
            let width = sizeField(draft.customSize.width, "windowViewOptions.width") { [weak self] value in
                self?.change { $0.customSize.width = value }
            }
            let height = sizeField(draft.customSize.height, "windowViewOptions.height") { [weak self] value in
                self?.change { $0.customSize.height = value }
            }
            let times = NSTextField(labelWithString: "\u{00D7}")
            let stack = NSStackView(views: [sizePopUp, width, times, height])
            stack.orientation = .horizontal
            stack.spacing = 6
            sizeControl = stack
        }
        let tree = popUp(["Shown", "Hidden"], selected: draft.folderTreeOpen ? 0 : 1) { [weak self] index in
            self?.change {
                $0.folderTreeOpen = index == 0
                $0.keepsFolderTree = true
            }
        }
        let info = popUp(["Shown", "Hidden"], selected: draft.propertiesOpen ? 0 : 1) { [weak self] index in
            self?.change {
                $0.propertiesOpen = index == 0
                $0.keepsInfoPanel = true
            }
        }
        return [
            keepRow("Size", kept: draft.keepsSize, sizeControl) { [weak self] on in self?.change { $0.keepsSize = on }
            },
            keepRow("Folder Tree", kept: draft.keepsFolderTree, tree) { [weak self] on in
                self?.change { $0.keepsFolderTree = on }
            },
            keepRow("Info Panel", kept: draft.keepsInfoPanel, info) { [weak self] on in
                self?.change { $0.keepsInfoPanel = on }
            },
        ]
    }

    /// A width or a height typed in, in points.
    private func sizeField(_ value: Int, _ identifier: String, _ typed: @escaping (Int) -> Void) -> NSTextField {
        let field = ClosureField(string: "\(value)", action: typed)
        field.alignment = .right
        field.setAccessibilityIdentifier(identifier)
        field.widthAnchor.constraint(equalToConstant: 56).isActive = true
        return field
    }

    private func footer() -> NSView {
        let manage = ClosureButton(title: "All Window Views\u{2026}") { [weak self] in self?.onManage() }
        manage.bezelStyle = .push
        let cancel = ClosureButton(title: "Cancel") { [weak self] in self?.onCancel() }
        cancel.bezelStyle = .push
        let save = ClosureButton(title: takenBy == nil ? "Save" : "Replace") { [weak self] in self?.save() }
        save.bezelStyle = .push
        save.keyEquivalent = "\r"
        save.isEnabled = canSave
        save.setAccessibilityIdentifier("windowViewOptions.save")
        saveButton = save
        let row = NSStackView(views: [manage, NSView(), cancel, save])
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }
}

/// A field that runs a closure with the whole number typed, once it is entered.
final class ClosureField: NSTextField {
    private var run: (Int) -> Void = { _ in }

    convenience init(string: String, action: @escaping (Int) -> Void) {
        self.init(string: string)
        run = action
        target = self
        self.action = #selector(fire)
    }

    @objc private func fire() { run(integerValue) }
}
