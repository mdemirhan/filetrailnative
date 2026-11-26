// The permissions popover: Read, Write and Run or Open for the owner, the group and everyone, the mode, and the
// Locked and Hidden flags of the items the Info panel describes, written as they are changed
import AppKit
import FTFileSystem
import FTFoundation
import FTOperations

/// The permissions popover. A box clicked sets that permission on every item (one on only some shows –), and clicked
/// again clears it; a mode typed and Return sets the nine bits of every item. Each change is written at once, after
/// the ones before it, as Tags… writes: there is no Done. Esc, or a click outside, closes it. Everything changed while
/// it is open is one Undo (`PermissionsVisit`).
@MainActor
final class PermissionsPopover: NSObject, NSPopoverDelegate {
    /// The one shown: opening another closes it.
    private(set) static var shown: PermissionsPopover?

    private let popover = NSPopover()
    let paths: [String]
    private(set) var read: PermissionsRead
    /// This time it is open, for Undo.
    let visit = PermissionsVisit()
    private let change: @MainActor (PermissionsChange, [String], PermissionsVisit) async -> PermissionsRead?
    private let readAgain: @MainActor ([String]) async -> PermissionsRead
    /// Asks before a change takes away your own Open of a folder, naming what you couldn't open; true to go ahead.
    var confirmLockOut: @MainActor (_ what: String) async -> Bool = { _ in true }
    /// Stops listening to the Undo history once it closes.
    var stopListening: (() -> Void)?
    private var writing: Task<Void, Never>?

    let view: PermissionsPopoverView

    /// `read`: the items as read before it opens. `change` writes a change and answers the items read again (nil when
    /// nothing could be written); `readAgain` reads them after something else changed them (an Undo).
    init(
        paths: [String], read: PermissionsRead, title: String,
        change: @escaping @MainActor (PermissionsChange, [String], PermissionsVisit) async -> PermissionsRead?,
        readAgain: @escaping @MainActor ([String]) async -> PermissionsRead
    ) {
        self.paths = paths
        self.read = read
        self.change = change
        self.readAgain = readAgain
        view = PermissionsPopoverView(title: title)
        super.init()
        view.owner = self
        view.show(read)
        let controller = NSViewController()
        controller.view = view
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        popover.contentSize = view.frame.size
    }

    var checklist: PermissionsChecklist { read.checklist }
    var canChange: Bool { read.refusal == nil && checklist.canChange }

    /// Shows it at `rect` of `anchor`, closing the one shown before.
    func show(relativeTo rect: NSRect, of anchor: NSView) {
        Self.shown?.close()
        guard anchor.window?.isVisible == true else { return }
        Self.shown = self
        popover.show(relativeTo: rect, of: anchor, preferredEdge: .minX)
        view.window?.makeFirstResponder(view)
    }

    func close() {
        popover.close()
        ended()
    }

    var isShown: Bool { popover.isShown }

    nonisolated func popoverDidClose(_ notification: Notification) {
        MainActor.assumeIsolated { ended() }
    }

    private func ended() {
        if Self.shown === self { Self.shown = nil }
        stopListening?()
        stopListening = nil
    }

    // MARK: Changes

    /// A box was clicked: on every item when it is off on any, else off every item.
    func toggle(who: Int, what: Int) {
        make(.bit(who: who, what: what, on: checklist.state(who: who, what: what) != .on))
    }

    func toggleLocked() {
        make(.locked(checklist.lockedState != .on))
    }

    func toggleHidden() {
        make(.hidden(checklist.hiddenState != .on))
    }

    /// Return in the Mode field: false when what is typed isn't a mode.
    @discardableResult
    func typeMode(_ text: String) -> Bool {
        guard let mode = PermissionsChecklist.parseMode(text) else { return false }
        make(.mode(mode))
        return true
    }

    /// Shown at once and written after the changes before it; one that would keep you out of a folder of yours asks
    /// first.
    private func make(_ change: PermissionsChange) {
        guard canChange else {
            view.show(read)
            return
        }
        guard checklist.locksYouOut(change) else {
            apply(change)
            return
        }
        // Shown as it was while the question is up, and kept open by it: its answer is a click in the window.
        view.show(read)
        popover.behavior = .applicationDefined
        let what = lockOutName(change)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let agreed = await self.confirmLockOut(what)
            self.popover.behavior = .transient
            if agreed { self.apply(change) }
        }
    }

    /// The folder you couldn't open, “Projects”, or how many.
    private func lockOutName(_ change: PermissionsChange) -> String {
        let folders = checklist.items.filter { item in
            item.isFolder && item.isYours && item.mode & 0o100 != 0 && change.applied(to: item.mode) & 0o100 == 0
        }
        guard folders.count == 1 else { return "these \(FormatLocale.count(folders.count)) folders" }
        return "\u{201C}\(ClipboardSummary.leafName(folders[0].path))\u{201D}"
    }

    private func apply(_ change: PermissionsChange) {
        read.checklist = checklist.applying(change)
        view.show(read)
        let previous = writing
        // The write keeps what it needs itself: a change still waiting its turn when the popover closes is written
        // all the same, as it showed it.
        let write = self.change
        let paths = paths
        let visit = visit
        writing = Task { @MainActor [weak self] in
            await previous?.value
            let readBack = await write(change, paths, visit)
            guard let self, let readBack else { return }
            self.read = readBack
            self.view.show(readBack)
        }
    }

    /// Something else changed the items (an Undo or Redo): they are read again, after the writes asked for.
    func itemsChanged() {
        let previous = writing
        let readAgain = readAgain
        let paths = paths
        writing = Task { @MainActor [weak self] in
            await previous?.value
            let readBack = await readAgain(paths)
            guard let self else { return }
            self.read = readBack
            self.view.show(readBack)
        }
    }

    /// The writes asked for so far, done (tests).
    func waitForWrites() async {
        await writing?.value
    }
}

/// The popover's content: the items' name, the grid of permissions, the mode, the two flags and the note.
@MainActor
final class PermissionsPopoverView: NSView, NSTextFieldDelegate {
    weak var owner: PermissionsPopover?
    let title: NSTextField
    let subtitle = NSTextField(labelWithString: "")
    /// The column heads: Read, Write and Run, Open or Run/Open.
    let heads = ["Read", "Write", "Run"].map { NSTextField(labelWithString: $0) }
    let rowNames = ["Owner", "Group", "Everyone"].map { NSTextField(labelWithString: $0) }
    /// The owner's and the group's names, under their rows.
    let whoNames = [NSTextField(labelWithString: ""), NSTextField(labelWithString: "")]
    /// By row (owner, group, everyone), then column (read, write, run or open).
    let boxes: [[NSButton]]
    let modeLabel = NSTextField(labelWithString: "Mode")
    let modeField = NSTextField(string: "")
    let letters = NSTextField(labelWithString: "")
    let lockedBox = NSButton(checkboxWithTitle: "Locked", target: nil, action: nil)
    let hiddenBox = NSButton(checkboxWithTitle: "Hidden flag", target: nil, action: nil)
    let note = NSTextField(wrappingLabelWithString: "")

    static let note = "Changes are written as you make them. \u{2318}Z undoes them."
    static let width: CGFloat = 300
    static let inset: CGFloat = 14
    static let nameColumn: CGFloat = 110
    static let boxRow: CGFloat = 34

    init(title text: String) {
        title = NSTextField(labelWithString: text)
        let who = ["owner", "group", "everyone"]
        let what = ["read", "write", "run"]
        boxes = (0..<3).map { row in
            (0..<3).map { column in
                let box = NSButton(checkboxWithTitle: "", target: nil, action: nil)
                box.allowsMixedState = true
                box.setAccessibilityIdentifier("permissionsPopover.\(who[row]).\(what[column])")
                return box
            }
        }
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: Self.height))
        setAccessibilityIdentifier("permissionsPopover")
        title.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        title.alignment = .center
        title.lineBreakMode = .byTruncatingMiddle
        title.setAccessibilityIdentifier("permissionsPopover.title")
        subtitle.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        subtitle.textColor = .secondaryLabelColor
        subtitle.alignment = .center
        subtitle.setAccessibilityIdentifier("permissionsPopover.subtitle")
        for head in heads {
            head.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            head.textColor = .secondaryLabelColor
            head.alignment = .center
        }
        for name in whoNames {
            name.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            name.textColor = .secondaryLabelColor
            name.lineBreakMode = .byTruncatingTail
        }
        whoNames[0].setAccessibilityIdentifier("permissionsPopover.ownerName")
        whoNames[1].setAccessibilityIdentifier("permissionsPopover.groupName")
        for (row, line) in boxes.enumerated() {
            for (column, box) in line.enumerated() {
                box.tag = row * 3 + column
                box.target = self
                box.action = #selector(boxClicked(_:))
                box.setAccessibilityLabel("\(rowNames[row].stringValue) \(heads[column].stringValue)")
            }
        }
        modeField.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        modeField.delegate = self
        modeField.placeholderString = "644"
        modeField.setAccessibilityIdentifier("permissionsPopover.mode")
        modeField.setAccessibilityLabel("Mode")
        letters.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        letters.textColor = .secondaryLabelColor
        letters.setAccessibilityIdentifier("permissionsPopover.letters")
        lockedBox.allowsMixedState = true
        lockedBox.target = self
        lockedBox.action = #selector(lockedClicked)
        lockedBox.setAccessibilityIdentifier("permissionsPopover.locked")
        hiddenBox.allowsMixedState = true
        hiddenBox.target = self
        hiddenBox.action = #selector(hiddenClicked)
        hiddenBox.setAccessibilityIdentifier("permissionsPopover.hidden")
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .secondaryLabelColor
        note.setAccessibilityIdentifier("permissionsPopover.note")
        let views: [NSView] =
            [title, subtitle] + heads + rowNames + whoNames + boxes.flatMap { $0 }
            + [modeLabel, modeField, letters, lockedBox, hiddenBox, note]
        for view in views { addSubview(view) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    static var height: CGFloat {
        inset + 18 + 16 + 12 + 16 + 3 * boxRow + 12 + 24 + 10 + 2 * 20 + 10 + 30 + inset
    }

    override func layout() {
        super.layout()
        let inset = Self.inset
        let width = bounds.width - 2 * inset
        var y = inset
        title.frame = NSRect(x: inset, y: y, width: width, height: 18)
        y += 18
        subtitle.frame = NSRect(x: inset, y: y, width: width, height: 16)
        y += 16 + 12
        let columnWidth = (width - Self.nameColumn) / 3
        func columnX(_ column: Int) -> CGFloat { inset + Self.nameColumn + CGFloat(column) * columnWidth }
        for (column, head) in heads.enumerated() {
            head.frame = NSRect(x: columnX(column), y: y, width: columnWidth, height: 16)
        }
        y += 16
        for row in 0..<3 {
            let named = row < 2
            let nameHeight: CGFloat = 17
            let top = y + (Self.boxRow - (named ? 2 * nameHeight - 3 : nameHeight)) / 2
            rowNames[row].frame = NSRect(x: inset, y: top, width: Self.nameColumn - 6, height: nameHeight)
            if named {
                whoNames[row].frame = NSRect(
                    x: inset, y: top + nameHeight - 3, width: Self.nameColumn - 6, height: nameHeight - 2)
            }
            for column in 0..<3 {
                let box = boxes[row][column]
                let size = box.intrinsicContentSize
                box.frame = NSRect(
                    x: columnX(column) + (columnWidth - size.width) / 2, y: y + (Self.boxRow - size.height) / 2,
                    width: size.width, height: size.height)
            }
            y += Self.boxRow
        }
        y += 12
        modeLabel.sizeToFit()
        modeLabel.frame.origin = NSPoint(x: inset, y: y + (24 - modeLabel.frame.height) / 2)
        modeField.frame = NSRect(x: inset + Self.nameColumn, y: y, width: 64, height: 24)
        letters.frame = NSRect(
            x: modeField.frame.maxX + 10, y: y + 4, width: max(0, inset + width - modeField.frame.maxX - 10),
            height: 17)
        y += 24 + 10
        lockedBox.frame = NSRect(x: inset, y: y, width: width, height: 20)
        y += 20
        hiddenBox.frame = NSRect(x: inset, y: y, width: width, height: 20)
        y += 20 + 10
        note.frame = NSRect(x: inset, y: y, width: width, height: 30)
    }

    /// The items as they are: every box, the mode and the letters; all of it disabled, and why, when they can't be
    /// changed.
    func show(_ read: PermissionsRead) {
        let checklist = read.checklist
        let enabled = read.refusal == nil && checklist.canChange
        subtitle.stringValue = checklist.items.isEmpty ? "" : checklist.itemsLine
        heads[2].stringValue = checklist.thirdColumn
        whoNames[0].stringValue = checklist.items.isEmpty ? "" : checklist.owner
        whoNames[1].stringValue = checklist.items.isEmpty ? "" : checklist.group
        for (row, line) in boxes.enumerated() {
            for (column, box) in line.enumerated() {
                box.state = Self.state(checklist.items.isEmpty ? .off : checklist.state(who: row, what: column))
                box.isEnabled = enabled
                box.setAccessibilityLabel("\(rowNames[row].stringValue) \(heads[column].stringValue)")
            }
        }
        lockedBox.state = Self.state(checklist.items.isEmpty ? .off : checklist.lockedState)
        hiddenBox.state = Self.state(checklist.items.isEmpty ? .off : checklist.hiddenState)
        lockedBox.isEnabled = enabled
        hiddenBox.isEnabled = enabled
        // What is being typed stays until Return.
        if modeField.currentEditor() == nil {
            modeField.stringValue = checklist.items.isEmpty ? "" : checklist.modeText
        }
        modeField.isEnabled = enabled
        letters.stringValue = checklist.items.isEmpty ? "" : checklist.letters
        note.stringValue = read.refusal?.text ?? (enabled ? Self.note : "")
        needsLayout = true
    }

    private static func state(_ state: PermissionsState) -> NSControl.StateValue {
        switch state {
        case .on: .on
        case .off: .off
        case .mixed: .mixed
        }
    }

    @objc private func boxClicked(_ sender: NSButton) {
        owner?.toggle(who: sender.tag / 3, what: sender.tag % 3)
    }

    @objc private func lockedClicked() {
        owner?.toggleLocked()
    }

    @objc private func hiddenClicked() {
        owner?.toggleHidden()
    }

    override func cancelOperation(_ sender: Any?) {
        owner?.close()
    }

    // MARK: The Mode field

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            if owner?.typeMode(modeField.stringValue) == true {
                window?.makeFirstResponder(self)
                if let owner { modeField.stringValue = owner.checklist.modeText }
            } else {
                NSSound.beep()
                textView.selectAll(nil)
            }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            owner?.close()
            return true
        default:
            return false
        }
    }
}

extension MainWindowController {
    /// The permissions popover for `paths`, hung from `anchor` (the Info panel's Sharing & Permissions title). Items
    /// in the Trash are shown without being changeable.
    func editPermissions(_ paths: [String], from anchor: NSView) {
        guard !paths.isEmpty else { return }
        let home = trashHomePath
        let inTrash = paths.contains {
            Paths.isInsideTrash($0, homePath: home) || $0 == FavoriteLabel.trashPath(homePath: home)
        }
        let title =
            paths.count == 1 ? ClipboardSummary.leafName(paths[0]) : "\(FormatLocale.count(paths.count)) Items"
        let coordinator = contextMenus
        // The place is taken now, in the window's content, which stays: the Info panel builds its rows again as the
        // items change.
        guard let host = anchor.window?.contentView else { return }
        let rect = anchor.convert(anchor.bounds, to: host)
        Task { @MainActor [weak self] in
            let read = await BlockingWork.run(qos: .userInitiated) { PermissionsReader.read(paths, inTrash: inTrash) }
            guard let self else { return }
            let popover = PermissionsPopover(
                paths: paths, read: read, title: title,
                change: { change, paths, visit in
                    await coordinator.changePermissions(change, paths: paths, visit: visit)
                },
                readAgain: { paths in
                    await BlockingWork.run(qos: .userInitiated) { PermissionsReader.read(paths, inTrash: inTrash) }
                })
            popover.confirmLockOut = { what in await coordinator.confirmLockOut(what) }
            if let history = AppWriteOperations.current?.undoHistory {
                popover.stopListening = history.onChange { [weak popover] in popover?.itemsChanged() }
            }
            popover.show(relativeTo: rect, of: host)
            self.shownPermissionsPopover?(popover)
        }
    }

    /// This window changed the permissions of the items at `paths`: the panes showing them read them again, and the
    /// Info panel too.
    func permissionsChanged(_ paths: [String]) {
        let changed = Set(paths.map(DiskPath.init))
        for pane in panes where pane.loaded && !pane.folderPath.isEmpty {
            let folder = DiskPath(pane.folderPath)
            if paths.contains(where: { DiskPath(NodePath.dirname($0)) == folder }) || changed.contains(folder) {
                pane.reload(changedPaths: paths)
            }
        }
        infoController?.itemsChanged()
    }
}
