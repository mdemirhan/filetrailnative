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
    /// Under the name while another window view has it, changed in place as the name is typed.
    private let nameNote = NSTextField(wrappingLabelWithString: "")
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
        nameNote.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        nameNote.textColor = .secondaryLabelColor
        nameNote.preferredMaxLayoutWidth = contentWidth
        nameNote.setAccessibilityIdentifier("windowViewOptions.nameNote")
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

    /// The screen's room for a window: the largest size that can be typed in.
    static func screenRoom(of window: NSWindow?) -> WindowView.Size? {
        guard let room = (window?.screen ?? NSScreen.main)?.visibleFrame.size else { return nil }
        return WindowView.Size(width: Int(room.width), height: Int(room.height))
    }

    @objc private func nameChanged() {
        draft.name = nameField.stringValue
        showNameNote()
        saveButton?.title = takenBy == nil ? "Save" : "Replace"
        saveButton?.isEnabled = canSave
        needsLayout = true
        superview?.needsLayout = true
    }

    private func showNameNote() {
        nameNote.stringValue =
            takenBy.map { "A window view called \u{201C}\($0.name)\u{201D} exists. Saving replaces it." } ?? ""
        nameNote.isHidden = takenBy == nil
    }

    private func save() {
        draft.name = SavedViewNames.clean(nameField.stringValue)
        onSave(draft)
    }

    /// The draft changed: the sheet shows it, the keyboard where it was.
    private func change(_ edit: (inout WindowViewDraft) -> Void) {
        edit(&draft)
        rebuild { build() }
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
        showNameNote()
        add(nameNote, after: 8)
        add(sectionTitle("Tabs"), after: 2)
        add(tabsCard(), after: 10)
        add(sectionTitle("Keep for This Window"), after: 2)
        add(card(windowRows()), after: 4)
        add(note("What isn\u{2019}t checked comes from the window you open it from.", fullWidth: true), after: 8)
        add(separator())
        let view = draft.windowView(id: draft.editingID ?? "")
        add(
            note(SavedViewText.parts(view, tabViews: tabViews).joined(separator: " \u{00B7} "), fullWidth: true),
            after: 8)
        setFooter(footer())
        needsLayout = true
        superview?.needsLayout = true
    }

    /// Number of Tabs, a row for each tab with its tab view, and the tab in front; past a few tabs the rows scroll.
    private func tabsCard() -> NSView {
        let counts = Array(1...AppPreferenceLimits.openTabsLimit)
        let number = popUp(
            counts.map { $0 == 1 ? "1 tab" : "\($0) tabs" }, selected: draft.tabs.count - 1, id: "count"
        ) { [weak self] index in
            self?.change { $0.setTabCount(counts[index]) }
        }
        var rows: [NSView] = [row(label("Number of Tabs"), number)]
        var tabRows: [NSView] = []
        let ids: [String?] = [nil] + tabViews.map(\.id)
        let titles = ["None: a New Tab"] + tabViews.map { MenuName.shortened($0.name) }
        for (index, id) in draft.tabs.enumerated() {
            let chosen = ids.firstIndex { $0 == id } ?? 0
            let popup = popUp(titles, selected: chosen, width: 220, id: "tab\(index + 1)") { [weak self] picked in
                self?.change { $0.setTab(index, to: ids[picked]) }
            }
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
        let front = popUp(draft.tabs.indices.map { "Tab \($0 + 1)" }, selected: draft.front, id: "front") {
            [weak self] index in
            self?.change { $0.front = index }
        }
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
        let sizePopUp = popUp(
            choices.map(\.1), selected: choices.firstIndex { $0.0 == draft.sizeChoice } ?? 0, id: "size"
        ) { [weak self] index in
            self?.change {
                $0.sizeChoice = choices[index].0
                $0.keepsSize = true
            }
        }
        var sizeControl: NSView = sizePopUp
        if draft.sizeChoice == .custom {
            let width = sizeField(draft.customSize.width, "windowViewOptions.width") { [weak self] value in
                self?.draft.customSize.width = value
            }
            let height = sizeField(draft.customSize.height, "windowViewOptions.height") { [weak self] value in
                self?.draft.customSize.height = value
            }
            let times = NSTextField(labelWithString: "\u{00D7}")
            let stack = NSStackView(views: [sizePopUp, width, times, height])
            stack.orientation = .horizontal
            stack.spacing = 6
            sizeControl = stack
        }
        let tree = popUp(["Shown", "Hidden"], selected: draft.folderTreeOpen ? 0 : 1, id: "folderTree") {
            [weak self] index in
            self?.change {
                $0.folderTreeOpen = index == 0
                $0.keepsFolderTree = true
            }
        }
        let info = popUp(["Shown", "Hidden"], selected: draft.propertiesOpen ? 0 : 1, id: "infoPanel") {
            [weak self] index in
            self?.change {
                $0.propertiesOpen = index == 0
                $0.keepsInfoPanel = true
            }
        }
        var rows = [
            keepRow("Size", kept: draft.keepsSize, sizeControl) { [weak self] on in self?.change { $0.keepsSize = on }
            }
        ]
        if draft.sizeChoice == .custom {
            let low = WindowViewDraft.smallestSize
            var range = "From \(low.width) \u{00D7} \(low.height)"
            if let high = draft.largestSize {
                range += " to \(high.width) \u{00D7} \(high.height), the screen\u{2019}s room"
            }
            rows.append(row(NSView(), note(range + "."), height: 26))
        }
        return rows + [
            keepRow("Folder Tree", kept: draft.keepsFolderTree, tree) { [weak self] on in
                self?.change { $0.keepsFolderTree = on }
            },
            keepRow("Info Panel", kept: draft.keepsInfoPanel, info) { [weak self] on in
                self?.change { $0.keepsInfoPanel = on }
            },
        ]
    }

    /// A width or a height typed in, in points: kept as it is typed, and shown held to what a window can be once the
    /// field is left.
    private func sizeField(_ value: Int, _ identifier: String, _ typed: @escaping (Int) -> Void) -> NSTextField {
        let field = ClosureField(string: "\(value)") { text in
            guard let number = Int(text.trimmingCharacters(in: .whitespaces)) else { return }
            typed(number)
        } ended: { [weak self] in
            self?.rebuildSoon { self?.build() }
        }
        field.formatter = Self.pointsFormatter
        field.alignment = .right
        field.setAccessibilityIdentifier(identifier)
        field.widthAnchor.constraint(equalToConstant: 56).isActive = true
        return field
    }

    #if DEBUG
        func buildForTesting() { build() }
        func changeForTesting(_ edit: (inout WindowViewDraft) -> Void) { change(edit) }
    #endif

    private func footer() -> NSView {
        let manage = ClosureButton(title: "All Window Views\u{2026}") { [weak self] in self?.onManage() }
        manage.bezelStyle = .push
        manage.setAccessibilityIdentifier("windowViewOptions.manage")
        let cancel = ClosureButton(title: "Cancel") { [weak self] in self?.onCancel() }
        cancel.bezelStyle = .push
        cancel.setAccessibilityIdentifier("windowViewOptions.cancel")
        let save = ClosureButton(title: takenBy == nil ? "Save" : "Replace") { [weak self] in self?.save() }
        save.bezelStyle = .push
        save.keyEquivalent = "\r"
        save.isEnabled = canSave
        save.setAccessibilityIdentifier("windowViewOptions.save")
        saveButton = save
        return footerRow(leading: [manage], trailing: [cancel, save])
    }
}

/// A field that tells what is typed as it is typed, and when it is left: by Tab, by a click elsewhere, by Return.
final class ClosureField: NSTextField {
    private var changed: (String) -> Void = { _ in }
    private var ended: () -> Void = {}

    convenience init(string: String, changed: @escaping (String) -> Void, ended: @escaping () -> Void) {
        self.init(string: string)
        self.changed = changed
        self.ended = ended
    }

    override func textDidChange(_ notification: Notification) {
        super.textDidChange(notification)
        changed(stringValue)
    }

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        ended()
    }
}

extension WindowViewOptionsSheet {
    /// Whole points, digits only.
    fileprivate static let pointsFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.allowsFloats = false
        formatter.minimum = 0
        formatter.maximum = 100_000
        return formatter
    }()
}
