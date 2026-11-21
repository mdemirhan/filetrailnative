// What Tab View Options and Window View Options share: a sheet laid out as Folder View Options is
import AppKit
import FTFoundation

/// A sheet of rows laid out as Folder View Options lays out its own: a header with a symbol, a title and what it is
/// for; groups titled as Settings titles them, each a card of rows with a hairline between each two; each row a
/// checkbox titled with its setting (or a name) and its control in a column that starts at the same place in every
/// row. Built again whole whenever something in it changes.
@MainActor
class SavedViewSheet: DialogPanelView {
    let stack = NSStackView()
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
        stack.edgeInsets = NSEdgeInsets(top: Self.margin, left: Self.margin, bottom: Self.margin, right: Self.margin)
        addSubview(stack)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func panelSize(in size: NSSize) -> NSSize {
        stack.layoutSubtreeIfNeeded()
        return NSSize(width: Self.width, height: min(size.height - 40, ceil(stack.fittingSize.height)))
    }

    override func layout() {
        super.layout()
        stack.frame = NSRect(x: 0, y: 0, width: Self.width, height: max(bounds.height, stack.fittingSize.height))
    }

    /// Takes everything off, to be built again.
    func clear() {
        for view in stack.arrangedSubviews { view.removeFromSuperview() }
    }

    func add(_ view: NSView, after spacing: Double? = nil) {
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
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

    func note(_ text: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.textColor = .secondaryLabelColor
        field.preferredMaxLayoutWidth = contentWidth - FolderViewPopover.controlColumn
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

    func popUp(
        _ titles: [String], selected: Int, width: Double = FolderViewPopover.popUpWidth,
        _ action: @escaping (Int) -> Void
    ) -> ClosurePopUp {
        let popup = ClosurePopUp(titles: titles, action: action)
        popup.selectItem(at: selected)
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
