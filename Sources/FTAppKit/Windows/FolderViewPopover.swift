// The folder view's popover: Folder Customization, with Save and Revert for what is changed on screen
import AppKit
import FTFoundation

/// The popover over the status bar's folder view symbol, laid out as macOS lays out its settings: a header with the
/// folder's icon and name; a row for each setting, a checkbox titled with its name and its control in a column that
/// starts at the same place in every row; Apply to Subfolders; and the buttons. What is changed in it, as anything
/// changed on screen, shows at once and is kept with Save; Revert drops it, and so does leaving the folder. A changed
/// setting has a dot by its name, and its tooltip says what is saved. Its height doesn't follow the view chosen: the
/// fourth row is the List's columns in the List, the size in the other views.
@MainActor
final class FolderViewPopover {
    private(set) weak var pane: BrowserPane?
    private weak var tab: MainWindowController?
    private let root = PopoverBackground()
    private var list: ToolbarListPopover?
    private let dismiss: () -> Void
    /// What Return does: the popover's default button, while it can be pressed.
    private var defaultAction: (() -> Void)?

    /// The popover's width, the margin round its content, and a setting's row.
    static let width = 440.0
    static let margin = 16.0
    static let rowHeight = 36.0
    /// Where every row's control starts, from the content's left edge.
    static let controlColumn = 128.0
    /// A pop-up's width, the same for every choice so it doesn't change as one is chosen; Sort By's direction is
    /// narrower, beside its field.
    static let popUpWidth = 160.0
    static let directionWidth = 110.0

    private var contentWidth: Double { Self.width - 2 * Self.margin }

    init(pane: BrowserPane, tab: MainWindowController, dismiss: @escaping () -> Void) {
        self.pane = pane
        self.tab = tab
        self.dismiss = dismiss
        root.setAccessibilityIdentifier("folderViewPopover")
        build()
    }

    func show(from anchor: NSView, in window: NSWindow) {
        let list = ToolbarListPopover(
            content: root, size: root.frame.size,
            key: { [weak self] event in self?.key(event) ?? false },
            dismiss: dismiss)
        self.list = list
        // The status bar is at the foot of the window: the popover goes up from it.
        list.show(from: anchor, in: window, above: anchor.window === window && !anchor.isHidden)
        // No control starts with the keyboard (and its ring): the popover is read first, then clicked.
        root.window?.makeFirstResponder(nil)
        // The popover's own material, its arrow included, takes the content's color, so it is one color throughout.
        for case let material as NSVisualEffectView in root.window?.contentView?.superview?.subviews ?? [] {
            material.material = .contentBackground
        }
    }

    func close() {
        list?.close()
        list = nil
    }

    /// The pane's folder view changed: the popover shows it as it is now.
    func refresh() {
        guard pane != nil else { return }
        build()
        list?.setSize(root.frame.size)
    }

    private func key(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 53:
            dismiss()
            return true
        case 36, 76:
            guard let defaultAction else { return false }
            defaultAction()
            return true
        default:
            return false
        }
    }

    #if DEBUG
        /// The popover's content, for tests and pictures of it.
        var contentView: NSView { root }
    #endif

    // MARK: Building

    private func build() {
        for view in root.subviews { view.removeFromSuperview() }
        defaultAction = nil
        guard let pane, let tab else { return }
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: Self.margin, left: Self.margin, bottom: Self.margin, right: Self.margin)
        buildOptions(pane, tab, into: stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.widthAnchor.constraint(equalToConstant: Self.width),
        ])
        stack.layoutSubtreeIfNeeded()
        root.frame.size = NSSize(width: Self.width, height: ceil(stack.fittingSize.height))
    }

    /// Takes the stack's width, less its margins.
    private func add(_ view: NSView, to stack: NSStackView, spacingAfter: Double? = nil) {
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        if let spacingAfter { stack.setCustomSpacing(spacingAfter, after: view) }
    }

    /// The folder's icon, the popover's title, and the folder's name (its path in the tooltip).
    private func header(_ title: String, _ pane: BrowserPane) -> NSView {
        let path = pane.shownFolderPath
        let icon = NSImageView(image: NSWorkspace.shared.icon(forFile: path))
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 32).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 32).isActive = true
        let titleField = NSTextField(labelWithString: title)
        titleField.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        let name = NSTextField(labelWithString: FolderViewText.name(path))
        name.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        name.textColor = .secondaryLabelColor
        name.lineBreakMode = .byTruncatingMiddle
        name.toolTip = path
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let texts = NSStackView(views: [titleField, name])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 1
        let row = NSStackView(views: [icon, texts])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        return row
    }

    /// A group's title over its rows, as Settings titles its groups.
    private func sectionTitle(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        field.textColor = .secondaryLabelColor
        return field
    }

    /// A group's rows, with a hairline between each two.
    private func card(_ rows: [NSView]) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        for (index, row) in rows.enumerated() {
            if index > 0 {
                let line = NSBox()
                line.boxType = .separator
                stack.addArrangedSubview(line)
                line.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
            }
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        }
        return stack
    }

    /// One row: what it is on the left and its control, centred in the row's height. The control starts at the
    /// controls' column, or with `atEnd` sits at the right end (a switch, a button).
    private func row(
        _ leading: NSView, _ control: NSView?, atEnd: Bool = false, height: Double = FolderViewPopover.rowHeight
    ) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: height).isActive = true
        for view in [leading] + (control.map { [$0] } ?? []) {
            view.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(view)
            view.centerYAnchor.constraint(equalTo: row.centerYAnchor).isActive = true
            view.topAnchor.constraint(greaterThanOrEqualTo: row.topAnchor, constant: 6).isActive = true
            view.bottomAnchor.constraint(lessThanOrEqualTo: row.bottomAnchor, constant: -6).isActive = true
        }
        leading.leadingAnchor.constraint(equalTo: row.leadingAnchor).isActive = true
        if let control {
            if atEnd {
                control.trailingAnchor.constraint(equalTo: row.trailingAnchor).isActive = true
                control.leadingAnchor.constraint(greaterThanOrEqualTo: leading.trailingAnchor, constant: 12)
                    .isActive = true
            } else {
                control.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: Self.controlColumn).isActive =
                    true
                leading.trailingAnchor.constraint(lessThanOrEqualTo: control.leadingAnchor, constant: -8).isActive =
                    true
            }
            leading.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        } else {
            leading.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor).isActive = true
        }
        return row
    }

    private func button(
        _ title: String, primary: Bool = false, enabled: Bool = true, _ action: @escaping () -> Void
    ) -> NSButton {
        let button = ClosureButton(title: title, action: action)
        button.bezelStyle = .push
        button.controlSize = .regular
        button.isEnabled = enabled
        if primary {
            button.keyEquivalent = "\r"
            if enabled { defaultAction = action }
        }
        return button
    }

    /// Buttons along the popover's foot: those of `leading` on the left, of `trailing` on the right.
    private func footer(_ leading: [NSView], _ trailing: [NSView]) -> NSView {
        let row = NSStackView(views: leading + [NSView()] + trailing)
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }

    /// A pop-up of a fixed width, so its width doesn't follow the choice.
    private func popUp(_ titles: [String], selected: Int, width: Double, _ action: @escaping (Int) -> Void)
        -> ClosurePopUp
    {
        let popup = ClosurePopUp(titles: titles, action: action)
        popup.selectItem(at: selected)
        popup.translatesAutoresizingMaskIntoConstraints = false
        popup.widthAnchor.constraint(equalToConstant: width).isActive = true
        return popup
    }

    /// A small dot by a setting's name while it is changed and not saved; its tooltip says what is saved.
    private func changedMark(_ tooltip: String) -> NSView {
        let dot = NSImageView(
            image: NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Not saved") ?? NSImage())
        dot.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 6, weight: .regular)
        dot.contentTintColor = .systemOrange
        dot.toolTip = tooltip
        return dot
    }

    /// A row's name with a dot after it while `changed`.
    private func named(_ name: NSView, changed: String?) -> NSView {
        guard let changed else { return name }
        let stack = NSStackView(views: [name, changedMark(changed)])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 5
        return stack
    }

    // MARK: Folder Customization

    private func buildOptions(_ pane: BrowserPane, _ tab: MainWindowController, into stack: NSStackView) {
        let view = pane.shownFolderView
        let fromAbove = view.map { !$0.use.own } ?? false
        let owner = view.map { FolderViewText.name($0.use.view.path) } ?? ""
        let here = FolderViewText.name(pane.shownFolderPath)
        let changed = view?.hasUnsavedChanges == true
        add(header("Folder Customization", pane), to: stack, spacingAfter: 12)
        // A folder whose settings come from a folder above says so, and that a change here is its own; the folder
        // above is changed there.
        if fromAbove, let view {
            let ownerPath = view.use.view.path
            let go = button("Go to \u{201C}\(owner)\u{201D}") { [weak self, weak pane] in
                self?.dismiss()
                pane?.go(to: URL(fileURLWithPath: ownerPath))
            }
            go.controlSize = .small
            let note = NSTextField(
                wrappingLabelWithString:
                    "These settings come from \u{201C}\(owner)\u{201D}. Changes here customize \u{201C}\(here)\u{201D} on its own."
            )
            note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            note.textColor = .secondaryLabelColor
            note.preferredMaxLayoutWidth = contentWidth - 130
            add(row(note, go, atEnd: true, height: 30), to: stack, spacingAfter: 8)
        }

        let current = pane.shownKeeps
        let keeps = view?.shown ?? FolderViewKeeps()
        let density = tab.preferences.density
        var rows: [NSView] = []
        for setting in Self.settings(for: pane.shownMode) {
            let control = valueControl(setting, pane: pane, current: current, density: density)
            let note =
                view.flatMap { view in
                    view.unsaved.contains(setting)
                        ? FolderViewText.saved(setting, of: view, mode: pane.shownMode, density: density) : nil
                }
            rows.append(keepRow(setting, control, pane: pane, kept: keeps, changed: note))
        }
        add(sectionTitle("Keep for This Folder"), to: stack, spacingAfter: 2)
        add(card(rows), to: stack, spacingAfter: 8)
        add(divider(), to: stack)

        let apply = ClosureSwitch(on: view?.shownSubfolders == true) { [weak pane] on in
            pane?.setFolderViewSubfolders(on)
        }
        apply.setAccessibilityIdentifier("folderViewPopover.subfolders")
        apply.setAccessibilityLabel("Apply to Subfolders")
        // With nothing kept there is nothing to apply, unless a view from above is there for the folders inside to
        // stop using; one already on can always be turned off.
        let keepsNothing = view?.shown.isEmpty ?? true
        let stopped = keepsNothing ? pane.viewStoppedForSubfolders : nil
        apply.isEnabled = pane.canApplyToSubfolders || apply.state == .on
        let does: String
        if let stopped {
            does =
                "Folders inside \u{201C}\(here)\u{201D} stop using the view of "
                + "\u{201C}\(FolderViewText.name(stopped.path))\u{201D}, unless they\u{2019}re customized on their own."
        } else if keepsNothing {
            does = "Check a setting above to have the folders inside \u{201C}\(here)\u{201D} look the same."
        } else {
            does =
                "Folders inside \u{201C}\(here)\u{201D} look the same, unless they\u{2019}re customized on their own."
        }
        let title = named(
            label("Apply to Subfolders"),
            changed: view?.subfoldersUnsaved == true
                ? (view?.savedSubfolders == true ? "Saved: on" : "Saved: off") : nil)
        add(
            row(
                titled(title, does, room: contentWidth - 64),
                apply, atEnd: true, height: 50), to: stack, spacingAfter: 8)
        add(divider(), to: stack)

        // The same buttons in every folder. Reset is on screen until Save, as every change here: nothing kept, and
        // Save removes the customization.
        let cleared = view.map { $0.shown.isEmpty && !$0.shownSubfolders } ?? true
        let reset = button("Reset", enabled: view?.isOwnSaved == true && !cleared) { [weak pane] in
            pane?.clearFolderViewOnScreen()
        }
        reset.toolTip = "Unchecks everything; Save removes this folder\u{2019}s customization."
        reset.setAccessibilityIdentifier("folderViewPopover.reset")
        let manage = button("All Customizations\u{2026}") { [weak self, weak tab] in
            self?.dismiss()
            tab?.performFolderViewCommand(.manageFolderViews)
        }
        manage.toolTip = "Every customized folder, in Folder Customizations"
        let revert = button("Revert", enabled: changed) { [weak pane] in pane?.revertFolderView() }
        revert.setAccessibilityIdentifier("folderViewPopover.revert")
        let save = button("Save", primary: true, enabled: changed) { [weak pane] in pane?.updateFolderView() }
        save.toolTip =
            fromAbove
            ? "Customizes \u{201C}\(here)\u{201D} on its own, as on screen."
            : "Saves this folder\u{2019}s customization."
        save.setAccessibilityIdentifier("folderViewPopover.update")
        add(footer([reset, manage], [revert, save]), to: stack)
    }

    /// The settings a view has rows for: always five, so the popover keeps its height as the view changes. Group By
    /// comes before Sort By, as in Finder's View Options. The fifth is the List's columns in the List, and the size in
    /// the others (the Previews count in Previews).
    static func settings(for mode: ExplorerViewMode) -> [FolderViewSetting] {
        [.view, .groupBy, .sort, .foldersFirst, mode == .details ? .columns : .size]
    }

    /// A setting's row: a checkbox titled with its name (a click on the name checks it, as anywhere on the Mac), a
    /// dot while it is changed, and its control in the controls' column, dimmed while the setting isn't kept.
    private func keepRow(
        _ setting: FolderViewSetting, _ control: NSView?, pane: BrowserPane, kept: FolderViewKeeps, changed: String?
    ) -> NSView {
        let keep = ClosureButton(checkboxWithTitle: title(of: setting, pane.shownMode)) { [weak pane] box in
            pane?.setFolderViewKeeps(setting, box.state == .on)
        }
        keep.state = kept.keeps(setting) ? .on : .off
        keep.setAccessibilityIdentifier("folderViewPopover.keep.\(setting.rawValue)")
        if !kept.keeps(setting) {
            for inner in (control.map { [$0] + $0.subviews } ?? []) {
                (inner as? NSControl)?.isEnabled = false
            }
        }
        return row(named(keep, changed: changed), control)
    }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        return field
    }

    /// What a setting's row is called, in the view on screen.
    private func title(of setting: FolderViewSetting, _ mode: ExplorerViewMode) -> String {
        switch setting {
        case .view: "View"
        case .groupBy: "Group By"
        case .sort: "Sort By"
        case .foldersFirst: "Folders First"
        case .columns: "Column Visibility and Order"
        case .size:
            switch mode {
            case .icons: "Icon Size"
            case .list: "Column Width"
            case .previews: "Previews"
            case .details: "Size"
            }
        }
    }

    /// A hairline between groups.
    private func divider() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        return line
    }

    /// The toolbar's symbol for a view.
    private static func icon(of mode: ExplorerViewMode) -> CommandIcon {
        switch mode {
        case .icons: .icons
        case .details: .details
        case .list: .list
        case .previews: .previews
        }
    }

    /// The sizes the pop-up offers for the view on screen, each as it reads: every step of the slider, and the size
    /// on screen where it is between two (a default of the Compact List is).
    static func sizeChoices(_ mode: ExplorerViewMode, current: Int) -> [(value: Int, title: String)] {
        switch mode {
        case .icons:
            let steps = Array(
                stride(
                    from: AppPreferenceLimits.iconSizeRange.lowerBound,
                    through: AppPreferenceLimits.iconSizeRange.upperBound, by: AppPreferenceLimits.iconSizeStep))
            return Set(steps + [current]).sorted().map { ($0, "\($0) pt") }
        case .list:
            let steps = Array(
                stride(
                    from: AppPreferenceLimits.compactListWidthRange.lowerBound,
                    through: AppPreferenceLimits.compactListWidthRange.upperBound,
                    by: AppPreferenceLimits.compactListWidthStep))
            return Set(steps + [current]).sorted().map { ($0, "\($0) pt") }
        case .previews:
            return PreviewGrid.counts.map { count in
                let shape = PreviewGrid.shape(count)
                return (
                    count,
                    count == 1 ? "1 at a time" : "\(count) at a time (\(shape.columns) \u{00D7} \(shape.rows))"
                )
            }
        case .details:
            return []
        }
    }

    /// The control that shows and sets a setting's value; nil for the List's columns, which the List's header sets.
    private func valueControl(
        _ setting: FolderViewSetting, pane: BrowserPane, current: FolderViewKeeps, density: Density
    ) -> NSView? {
        switch setting {
        case .view:
            // The four views with the toolbar's symbols; Previews' count is the size row's.
            let modes = ExplorerViewMode.menuOrder
            let popup = popUp(
                modes.map(\.menuName), selected: modes.firstIndex(of: current.view ?? .details) ?? 0,
                width: Self.popUpWidth
            ) { [weak pane] index in
                pane?.setFolderViewValue(.view) { $0.view = modes[index] }
            }
            for (index, mode) in modes.enumerated() {
                popup.item(at: index)?.image = NSImage(
                    systemSymbolName: Self.icon(of: mode).symbolName, accessibilityDescription: nil)
            }
            popup.setAccessibilityIdentifier("folderViewPopover.view")
            return popup
        case .groupBy:
            // None, then every field a folder groups by, as View ▸ Group By has them.
            let fields = [GroupByPreference.none] + GroupByPreference.menuOrder
            let control = popUp(
                fields.map(\.title), selected: fields.firstIndex(of: current.groupBy ?? .none) ?? 0,
                width: Self.popUpWidth
            ) { [weak pane] index in
                pane?.setFolderViewValue(.groupBy) { $0.groupBy = fields[index] }
            }
            control.setAccessibilityIdentifier("folderViewPopover.groupBy")
            return control
        case .sort:
            let sort = current.sort ?? FolderViewSort(by: .name, direction: .asc)
            // Every field, as View ▸ Sort By has them: a folder may be ordered by a column it doesn't show.
            let fields = SortByPreference.menuOrder
            let field = popUp(
                fields.map(\.title), selected: fields.firstIndex(of: sort.by) ?? 0, width: Self.popUpWidth
            ) { [weak pane] index in
                pane?.setFolderViewValue(.sort) {
                    $0.sort = FolderViewSort(by: fields[index], direction: sort.direction)
                }
            }
            field.setAccessibilityIdentifier("folderViewPopover.sort")
            let direction = popUp(
                ["Ascending", "Descending"], selected: sort.direction == .asc ? 0 : 1, width: Self.directionWidth
            ) { [weak pane] index in
                pane?.setFolderViewValue(.sort) {
                    $0.sort = FolderViewSort(by: sort.by, direction: index == 0 ? .asc : .desc)
                }
            }
            direction.setAccessibilityIdentifier("folderViewPopover.direction")
            let pair = NSStackView(views: [field, direction])
            pair.orientation = .horizontal
            pair.spacing = 8
            return pair
        case .foldersFirst:
            let control = popUp(
                ["Before Files", "Mixed with Files"], selected: current.foldersFirst == false ? 1 : 0,
                width: Self.popUpWidth
            ) { [weak pane] index in
                pane?.setFolderViewValue(.foldersFirst) { $0.foldersFirst = index == 0 }
            }
            control.setAccessibilityIdentifier("folderViewPopover.foldersFirst")
            return control
        case .columns:
            return nil
        case .size:
            let mode = pane.shownMode
            guard let size = current.size, mode != .details else { return nil }
            let now =
                switch mode {
                case .icons: size.iconSizes[density]
                case .list: size.compactListWidths[density]
                default: size.previewCounts[density]
                }
            let choices = Self.sizeChoices(mode, current: now)
            let popup = popUp(
                choices.map(\.title), selected: choices.firstIndex { $0.value == now } ?? 0, width: Self.popUpWidth
            ) { [weak pane] index in
                let value = choices[index].value
                pane?.setFolderViewValue(.size) { keeps in
                    switch mode {
                    case .icons: keeps.size?.iconSizes[density] = value
                    case .list: keeps.size?.compactListWidths[density] = value
                    default: keeps.size?.previewCounts[density] = value
                    }
                }
            }
            popup.setAccessibilityIdentifier("folderViewPopover.size")
            return popup
        }
    }

    /// A row's name with an explanation under it, wrapped to `room`, what the row leaves beside its control.
    private func titled(_ name: NSView, _ detail: String, room: Double) -> NSView {
        let line = NSTextField(wrappingLabelWithString: detail)
        line.preferredMaxLayoutWidth = room
        line.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        line.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [name, line])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        return stack
    }

    private func titled(_ name: NSTextField, _ detail: String) -> NSView {
        titled(name as NSView, detail, room: contentWidth - 96)
    }
}

/// A switch that runs a closure with its new state.
final class ClosureSwitch: NSSwitch {
    private var run: (Bool) -> Void = { _ in }

    convenience init(on: Bool, action: @escaping (Bool) -> Void) {
        self.init(frame: .zero)
        state = on ? .on : .off
        controlSize = .small
        run = action
        target = self
        self.action = #selector(fire)
    }

    @objc private func fire() { run(state == .on) }
}

/// A button that runs a closure, for the popovers built in code.
final class ClosureButton: NSButton {
    private var run: (ClosureButton) -> Void = { _ in }

    convenience init(title: String, action: @escaping () -> Void) {
        self.init(frame: .zero)
        self.title = title
        run = { _ in action() }
        target = self
        self.action = #selector(fire)
    }

    convenience init(checkboxWithTitle title: String, action: @escaping (ClosureButton) -> Void) {
        self.init(frame: .zero)
        setButtonType(.switch)
        self.title = title
        run = action
        target = self
        self.action = #selector(fire)
    }

    @objc private func fire() { run(self) }
}

/// A pop-up button that runs a closure with the item chosen.
final class ClosurePopUp: NSPopUpButton {
    private var run: (Int) -> Void = { _ in }

    convenience init(titles: [String], action: @escaping (Int) -> Void) {
        self.init(frame: .zero, pullsDown: false)
        addItems(withTitles: titles)
        run = action
        target = self
        self.action = #selector(fire)
    }

    @objc private func fire() { run(indexOfSelectedItem) }
}

/// The popover's content on one color: white in the light appearance, the system's matching gray in the dark.
final class PopoverBackground: NSView {
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        dirtyRect.fill()
    }
}
