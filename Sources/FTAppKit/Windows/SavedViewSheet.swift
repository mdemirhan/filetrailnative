// What Tab View Options and Window View Options share: a sheet laid out as Folder View Options is
import AppKit
import FTFoundation

/// A sheet of rows laid out as Folder View Options lays out its own: a header with a symbol, a title and what it is
/// for; groups titled as Settings titles them, each a card of rows with a hairline between each two; each row a
/// checkbox titled with its setting (or a name) and its control in a column that starts at the same place in every
/// row. Built again whole whenever something in it changes, the keyboard staying on the control it was on. A sheet
/// taller than the room under the toolbar scrolls, its buttons staying at its foot, so the window never cuts it. Tab
/// goes along each row, then down.
@MainActor
class SavedViewSheet: DialogPanelView {
    let stack = NSStackView()
    private let scroll = NSScrollView()
    private let document = SheetDocumentView()
    private var footerView: NSView?
    /// A hairline over the buttons while the rows scroll under them.
    private let footerLine = NSBox()
    static var width: Double { FolderViewPopover.width + 40 }
    static let margin = 20.0
    var contentWidth: Double { Self.width - 2 * Self.margin }
    /// What the sheet's controls are identified by.
    var identifierPrefix: String { "savedView" }

    init() {
        super.init(cornerRadius: GlassSurface.sheetRadius)
        setAccessibilityElement(true)
        setAccessibilityRole(.sheet)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: Self.margin, left: Self.margin, bottom: 4, right: Self.margin)
        document.addSubview(stack)
        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        addSubview(scroll)
        footerLine.boxType = .separator
        addSubview(footerLine)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// A footer's buttons: `leading` at its left, `trailing` at its right, the last of them the default.
    func footerRow(leading: [NSView], trailing: [NSView]) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8
        row.setViews(leading, in: .leading)
        row.setViews(trailing, in: .trailing)
        return row
    }

    /// The buttons along the sheet's foot, outside what scrolls.
    func setFooter(_ view: NSView) {
        footerView?.removeFromSuperview()
        footerView = view
        addSubview(view)
        needsLayout = true
    }

    /// The footer's room: its height with a margin above and below.
    private var footerRoom: Double {
        guard let footerView else { return 0 }
        return ceil(footerView.fittingSize.height) + 2 * Self.margin
    }

    /// Room left under the sheet, above the window's bottom edge.
    static let bottomInset = 24.0

    override func panelSize(in size: NSSize) -> NSSize {
        stack.layoutSubtreeIfNeeded()
        let whole = ceil(stack.fittingSize.height) + footerRoom
        // The sheet starts under the toolbar: what is left of the window below that is its room.
        let room = size.height - DialogLayout.sheetTop - Self.bottomInset
        return NSSize(width: Self.width, height: max(min(160, whole), min(room, whole)))
    }

    // MARK: The keyboard

    /// Along each row, left to right, then down: a row's controls are centered on one line, though not all of a
    /// height. The pane chooser counts as a control.
    override func focusOrder() -> [NSView] {
        var found = Self.focusable(in: self)
        func visit(_ view: NSView) {
            guard !view.isHidden else { return }
            if let segmented = view as? NSSegmentedControl, segmented.isEnabled { found.append(segmented) }
            for child in view.subviews { visit(child) }
        }
        visit(self)
        let frames = Dictionary(
            uniqueKeysWithValues: found.map { (ObjectIdentifier($0), $0.convert($0.bounds, to: self)) })
        return found.sorted { a, b in
            let ra = frames[ObjectIdentifier(a)] ?? .zero
            let rb = frames[ObjectIdentifier(b)] ?? .zero
            if abs(ra.midY - rb.midY) > 8 { return ra.midY < rb.midY }
            return ra.minX < rb.minX
        }
    }

    /// A control Tab lands on is scrolled into view.
    override func moveKeyboard(to view: NSView) {
        super.moveKeyboard(to: view)
        view.scrollToVisible(view.bounds.insetBy(dx: 0, dy: -8))
    }

    /// `build` run, and the keyboard put back on the control it was on: the same control, by its identifier, or else
    /// the one in its place in Tab's order.
    func rebuild(_ build: () -> Void) {
        let focused = focusedControl.flatMap { $0.isDescendant(of: self) ? $0 : nil }
        let identifier = focused?.accessibilityIdentifier() ?? ""
        let place = focused.flatMap { view in focusOrder().firstIndex { $0 === view } }
        let scrolled = scroll.contentView.bounds.origin
        build()
        layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: scrolled)
        scroll.reflectScrolledClipView(scroll.contentView)
        guard focused != nil, let window else { return }
        let order = focusOrder()
        let again =
            identifier.isEmpty ? nil : order.first { $0.accessibilityIdentifier() == identifier }
        if let view = again ?? place.flatMap({ order.indices.contains($0) ? order[$0] : nil }) {
            window.makeFirstResponder(view)
        }
    }

    /// `rebuild` once the event at hand is done: a field left by Tab has handed the keyboard on by then, and it
    /// stays where Tab put it.
    func rebuildSoon(_ build: @escaping () -> Void) {
        DispatchQueue.main.async { [weak self] in self?.rebuild(build) }
    }

    override func layout() {
        super.layout()
        let rows = ceil(stack.fittingSize.height)
        let footer = footerRoom
        if let footerView {
            footerView.frame = NSRect(
                x: Self.margin, y: bounds.height - footer + Self.margin, width: contentWidth,
                height: footer - 2 * Self.margin)
        }
        scroll.frame = NSRect(x: 0, y: 0, width: Self.width, height: max(0, bounds.height - footer))
        document.frame = NSRect(x: 0, y: 0, width: Self.width, height: rows)
        stack.frame = document.bounds
        footerLine.frame = NSRect(x: 0, y: scroll.frame.maxY, width: Self.width, height: 1)
        footerLine.isHidden = rows <= scroll.frame.height + 0.5
    }

    /// Takes everything off, to be built again.
    func clear() {
        for view in stack.arrangedSubviews { view.removeFromSuperview() }
    }

    func add(_ view: NSView, fullWidth: Bool = true, after spacing: Double? = nil) {
        stack.addArrangedSubview(view)
        if fullWidth { view.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true }
        if let spacing { stack.setCustomSpacing(spacing, after: view) }
    }

    /// The sheet's symbol, its title and, under it, what it is for.
    func header(symbol: String, title: String, subtitle: String) -> NSView {
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 22, weight: .regular)
        icon.contentTintColor = .controlAccentColor
        icon.widthAnchor.constraint(equalToConstant: 32).isActive = true
        let titleField = NSTextField(labelWithString: title)
        titleField.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        let name = NSTextField(labelWithString: subtitle)
        name.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        name.textColor = .secondaryLabelColor
        name.lineBreakMode = .byTruncatingMiddle
        let texts = NSStackView(views: [titleField, name])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 1
        let row = NSStackView(views: [icon, texts])
        row.orientation = .horizontal
        row.spacing = 10
        return row
    }

    // MARK: Pieces

    func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        return field
    }

    /// A note in the controls' column; `fullWidth`, one across the sheet.
    func note(_ text: String, fullWidth: Bool = false) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.textColor = .secondaryLabelColor
        field.preferredMaxLayoutWidth = fullWidth ? contentWidth : contentWidth - FolderViewPopover.controlColumn
        return field
    }

    func sectionTitle(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        field.textColor = .secondaryLabelColor
        return field
    }

    func separator() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        return line
    }

    func pair(_ first: NSView, _ second: NSView) -> NSView {
        let pair = NSStackView(views: [first, second])
        pair.orientation = .horizontal
        pair.spacing = 8
        return pair
    }

    /// A pop-up of `titles`, identified as `id` in the sheet so the keyboard finds it again once the sheet is built
    /// again.
    func popUp(
        _ titles: [String], selected: Int, width: Double = FolderViewPopover.popUpWidth, id: String? = nil,
        _ action: @escaping (Int) -> Void
    ) -> ClosurePopUp {
        let popup = ClosurePopUp(titles: titles, action: action)
        popup.selectItem(at: selected)
        if let id { popup.setAccessibilityIdentifier("\(identifierPrefix).\(id)") }
        popup.translatesAutoresizingMaskIntoConstraints = false
        popup.widthAnchor.constraint(equalToConstant: width).isActive = true
        return popup
    }

    /// Rows with a hairline between each two, as Folder View Options groups them.
    func card(_ rows: [NSView]) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        for (index, row) in rows.enumerated() {
            if index > 0 {
                let line = separator()
                stack.addArrangedSubview(line)
                line.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
            }
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        }
        return stack
    }

    /// A setting's row: a checkbox titled with its name and its control in the controls' column, dimmed while the
    /// setting isn't kept (`dims`).
    func keepRow(
        _ title: String, kept: Bool, _ control: NSView, dims: Bool = true, _ toggled: @escaping (Bool) -> Void
    ) -> NSView {
        let box = ClosureButton(checkboxWithTitle: title) { box in toggled(box.state == .on) }
        box.state = kept ? .on : .off
        box.setAccessibilityIdentifier("\(identifierPrefix).keep.\(title)")
        let row = row(box, control)
        if dims, !kept { enable(control, false) }
        return row
    }

    func enable(_ view: NSView, _ on: Bool) {
        for inner in [view] + view.subviews {
            (inner as? NSControl)?.isEnabled = on
            if let nested = inner as? NSStackView { for view in nested.arrangedSubviews { enable(view, on) } }
        }
    }

    func row(
        _ leading: NSView, _ control: NSView?, atEnd: Bool = false, stretch: Bool = false,
        height: Double = FolderViewPopover.rowHeight
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
                control.leadingAnchor.constraint(greaterThanOrEqualTo: leading.trailingAnchor, constant: 12).isActive =
                    true
            } else {
                control.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: FolderViewPopover.controlColumn)
                    .isActive = true
                leading.trailingAnchor.constraint(lessThanOrEqualTo: control.leadingAnchor, constant: -8).isActive =
                    true
                if stretch { control.trailingAnchor.constraint(equalTo: row.trailingAnchor).isActive = true }
            }
            leading.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        return row
    }

}

/// What the sheet's rows scroll in: top down, as the panel is.
private final class SheetDocumentView: NSView {
    override var isFlipped: Bool { true }
}
