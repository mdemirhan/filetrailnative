// Port of apps/desktop/src/renderer/components/InlineRenameField.tsx
import AppKit
import FTFoundation

/// The rename going on in a list, as the panes are told of it.
struct InlineRenameState: Equatable {
    var path: String
    /// Why the last attempt was refused; the field stays open so the name can be fixed.
    var error: String?
    /// Goes up with every refusal: two names can be refused for the same reason in a row, and the field must hear of
    /// the second one too.
    var refusalCount = 0
    /// One rename of one item: a field drawn again for it carries on with what was typed.
    var sessionID: Int
}

/// What has been typed into a rename, kept outside the field: the list shows only the rows in view and draws a row again
/// when it moves (a re-sort, an item added before it), so the field can be replaced while the name is being edited. The
/// new one carries on from here.
@MainActor
enum RenameDrafts {
    struct Draft: Equatable {
        var value: String
        var selection: NSRange
    }

    private static var drafts: [(key: Int, draft: Draft)] = []

    static func draft(for key: Int?) -> Draft? {
        guard let key else { return nil }
        return drafts.first { $0.key == key }?.draft
    }

    static func keep(_ draft: Draft, for key: Int?) {
        guard let key else { return }
        drafts.removeAll { $0.key == key }
        drafts.append((key, draft))
        while drafts.count > SelectionLayout.Rename.maxKeptDrafts { drafts.removeFirst() }
    }

    static func forget(_ key: Int?) {
        guard let key else { return }
        drafts.removeAll { $0.key == key }
    }
}

/// The cell of the rename field: the text starts 5 pt in from the field's edge, and is centered in its height.
final class RenameFieldCell: NSTextFieldCell {
    private func area(_ rect: NSRect) -> NSRect {
        // The cell draws its text 2 pt in from this rectangle on each side; the rectangle is made narrower to leave 5.
        var area = rect.insetBy(dx: CGFloat(SelectionLayout.Rename.paddingInline) - 2, dy: 0)
        let height = ceil(
            attributedStringValue.boundingRect(with: NSSize(width: 10_000, height: 10_000), options: [.usesFontLeading])
                .height)
        area.origin.y += ((area.height - height) / 2).rounded()
        area.size.height = height
        return area
    }

    override func drawingRect(forBounds rect: NSRect) -> NSRect { area(rect) }
    override func titleRect(forBounds rect: NSRect) -> NSRect { area(rect) }

    override func edit(
        withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, event: NSEvent?
    ) {
        super.edit(
            withFrame: area(rect), in: controlView, editor: textObj, delegate: delegate, event: event)
    }

    override func select(
        withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, start selStart: Int,
        length selLength: Int
    ) {
        super.select(
            withFrame: area(rect), in: controlView, editor: textObj, delegate: delegate, start: selStart,
            length: selLength)
    }
}

/// The reason a name was refused, shown under the field (`.inline-rename-error`).
final class RenameErrorView: NSView {
    private let text = ListLabel()
    private var theme = AppearanceModel.shared.theme

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    init() {
        super.init(frame: .zero)
        text.lineBreakMode = .byWordWrapping
        text.cell?.wraps = true
        text.usesSingleLineMode = false
        text.maximumNumberOfLines = 0
        text.preferredMaxLayoutWidth = CGFloat(SelectionLayout.Rename.errorMaxWidth)
        setAccessibilityIdentifier("rename.error")
        setAccessibilityRole(.staticText)
        addSubview(text)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The size the box takes for `message`.
    func configure(message: String, theme: Theme) -> NSSize {
        self.theme = theme
        let layout = SelectionLayout.Rename.self
        let font = ThemeFonts.sans(DesignTokens.typeScale.small)
        text.font = font
        text.textColor = NSColor(theme.palette.dangerText)
        text.stringValue = message
        text.setAccessibilityLabel(message)
        let padding = CGFloat(layout.errorPaddingHorizontal) * 2 + CGFloat(layout.errorBorderWidth) * 2
        let maxText = CGFloat(layout.errorMaxWidth) - padding
        let lineHeight = (CGFloat(font.pointSize) * CGFloat(layout.errorLineHeight))
        let bound = (message as NSString).boundingRect(
            with: NSSize(width: maxText, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin], attributes: [.font: font])
        let lines = max(1, (bound.height / max(1, font.ascender - font.descender + font.leading)).rounded())
        let textWidth = min(maxText, ceil(bound.width))
        let textHeight = lines * lineHeight
        let size = NSSize(
            width: textWidth + padding,
            height: textHeight + CGFloat(layout.errorPaddingVertical) * 2 + CGFloat(layout.errorBorderWidth) * 2)
        text.frame = NSRect(
            x: CGFloat(layout.errorPaddingHorizontal) + CGFloat(layout.errorBorderWidth),
            y: CGFloat(layout.errorPaddingVertical) + CGFloat(layout.errorBorderWidth), width: textWidth,
            height: textHeight)
        needsDisplay = true
        return size
    }

    override func draw(_ dirtyRect: NSRect) {
        let layout = SelectionLayout.Rename.self
        let shape = NSBezierPath(
            roundedRect: bounds.insetBy(
                dx: CGFloat(layout.errorBorderWidth) / 2, dy: CGFloat(layout.errorBorderWidth) / 2),
            xRadius: CGFloat(DesignTokens.radii.control), yRadius: CGFloat(DesignTokens.radii.control))
        NSColor(theme.palette.contextMenuBg).setFill()
        shape.fill()
        NSColor(theme.palette.danger.withAlpha(layout.errorBorderAlpha)).setStroke()
        shape.lineWidth = CGFloat(layout.errorBorderWidth)
        shape.stroke()
    }
}

/// The name of a list item, edited in place like Finder: Return (or clicking elsewhere) applies the new name and Escape
/// leaves it as it was. A file's extension starts outside the selection, so typing replaces the name and keeps the type.
final class InlineRenameField: NSTextField, NSTextFieldDelegate {
    override class var cellClass: AnyClass? {
        get { RenameFieldCell.self }
        set {}
    }

    private let originalName: String
    private let draftKey: Int?
    private let isFolder: Bool
    private let stem: String
    private var theme: Theme
    /// Set once a name has been handed over, so the blur that follows does not submit again.
    private var submitted = false
    /// The name the last error is about; it is not sent again until it has been edited.
    private var refusedName: String?
    private var shownRefusalCount = 0
    private var errorView: RenameErrorView?
    private let ring = CALayer()
    private let ringClip = CALayer()
    /// The List's row cell is no taller than the field and cuts the ring off above and below it (`.details-name`).
    var ringClippedToHeight = false {
        didSet { updateRing() }
    }

    private(set) var error: String?
    var onSubmit: (String) -> Void = { _ in }
    var onCancel: () -> Void = {}

    init(name: String, fileExtension: String, isFolder: Bool, draftKey: Int?, font: NSFont, theme: Theme) {
        originalName = name
        self.draftKey = draftKey
        self.isFolder = isFolder
        stem = DisplayName.split(name, extension: fileExtension).stem
        self.theme = theme
        super.init(frame: .zero)
        isEditable = true
        isSelectable = true
        isBordered = false
        drawsBackground = false
        focusRingType = .none
        usesSingleLineMode = true
        cell?.isScrollable = true
        cell?.wraps = false
        lineBreakMode = .byClipping
        self.font = font
        stringValue = RenameDrafts.draft(for: draftKey)?.value ?? name
        delegate = self
        wantsLayer = true
        layer?.cornerRadius = CGFloat(DesignTokens.radii.xs)
        layer?.masksToBounds = false
        ringClip.masksToBounds = true
        ringClip.addSublayer(ring)
        layer?.addSublayer(ringClip)
        setAccessibilityLabel("Rename \(name)")
        setAccessibilityIdentifier("rename.field")
        applyTheme(theme)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    /// A list adds its row views when it lays them out, which for a row that has just come (a new folder's) or scrolled
    /// back is after the field went in: they would cover it. Sorted, not added again: that would end the editing.
    static func keepOnTop(in list: NSView) {
        list.sortSubviews(
            { first, second, _ in
                if first is InlineRenameField { return .orderedDescending }
                return second is InlineRenameField ? .orderedAscending : .orderedSame
            }, context: nil)
    }

    // The row underneath selects, opens and drags on these; the field keeps them.
    override func rightMouseDown(with event: NSEvent) { super.rightMouseDown(with: event) }

    func applyTheme(_ theme: Theme) {
        self.theme = theme
        textColor = NSColor(theme.palette.textPrimary)
        layer?.backgroundColor = NSColor(theme.palette.bgBase).cgColor
        updateRing()
    }

    /// The edge and the ring: the focus ring of every text field, or the red ring of a refused name.
    private func updateRing() {
        let layout = SelectionLayout.Rename.self
        let ringWidth = CGFloat(layout.ringWidth)
        let reach = ringClippedToHeight ? 0 : ringWidth
        ringClip.frame = bounds.insetBy(dx: -ringWidth, dy: -reach)
        ring.frame = ringClip.bounds.insetBy(dx: 0, dy: reach - ringWidth)
        ring.cornerRadius = CGFloat(DesignTokens.radii.xs) + ringWidth
        ring.borderWidth = ringWidth
        let color =
            error != nil ? theme.palette.danger.withAlpha(layout.invalidRingAlpha) : theme.accent.solid.withAlpha(0.5)
        ring.borderColor = NSColor(color).cgColor
        let edge = error != nil ? theme.palette.danger : theme.palette.borderActive
        layer?.borderWidth = CGFloat(layout.edgeWidth)
        layer?.borderColor = NSColor(edge).cgColor
    }

    override func layout() {
        super.layout()
        updateRing()
    }

    // MARK: Editing

    /// Takes the keyboard and selects the name without its extension (a folder's whole name), or carries on where a
    /// draft of this rename left off.
    func beginEditing() {
        guard let window else { return }
        window.makeFirstResponder(self)
        guard let editor = currentEditor() else { return }
        if let kept = RenameDrafts.draft(for: draftKey) {
            editor.selectedRange = NSRange(
                location: min(kept.selection.location, (stringValue as NSString).length),
                length: min(kept.selection.length, max(0, (stringValue as NSString).length - kept.selection.location)))
            return
        }
        let length = isFolder ? (originalName as NSString).length : (stem as NSString).length
        editor.selectedRange = NSRange(location: 0, length: length)
    }

    private func rememberDraft() {
        guard let editor = currentEditor() else { return }
        RenameDrafts.keep(RenameDrafts.Draft(value: stringValue, selection: editor.selectedRange), for: draftKey)
    }

    func controlTextDidChange(_ notification: Notification) {
        rememberDraft()
        hideError()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        // Return and Escape while text is being composed (Japanese, Chinese, Korean input) confirm or cancel the
        // composition, not the rename.
        if textView.hasMarkedText() { return false }
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            commit(.enter)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            submitted = true
            cancel()
            return true
        default:
            return false
        }
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        rememberDraft()
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        // Leaving the field (a click elsewhere) commits a changed name just as Return does.
        commit(.blur)
    }

    private func commit(_ trigger: InlineRenameRules.Trigger) {
        if submitted { return }
        let draft = stringValue
        switch InlineRenameRules.decide(draft: draft, original: originalName, refused: refusedName, trigger: trigger) {
        case .cancel: cancel()
        case .keepOpen: break
        case .submit:
            submitted = true
            onSubmit(draft)
        }
    }

    private func cancel() {
        submitted = true
        RenameDrafts.forget(draftKey)
        hideError()
        onCancel()
    }

    /// Ends the field without committing or cancelling (its item left the list).
    func close() {
        submitted = true
        RenameDrafts.forget(draftKey)
        hideError()
    }

    // MARK: Refusals

    /// A refused name hands the keyboard back to the field, with the explanation under it. `count` goes up with every
    /// refusal, so a second one that reads the same as the first is still heard.
    func showRefusal(_ message: String?, count: Int) {
        guard message != error || count != shownRefusalCount else { return }
        error = message
        shownRefusalCount = count
        updateRing()
        guard let message else {
            hideError()
            return
        }
        submitted = false
        refusedName = stringValue
        // A field still being typed in keeps its editor: taking the keyboard again would end that editing first, and
        // the blur would cancel the rename it is refusing.
        if currentEditor() == nil { window?.makeFirstResponder(self) }
        presentError(message)
    }

    private func presentError(_ message: String) {
        guard let host = window?.contentView else { return }
        let view = errorView ?? RenameErrorView()
        errorView = view
        let size = view.configure(message: message, theme: theme)
        place(view, size: size, in: host)
        if view.superview !== host { host.addSubview(view, positioned: .above, relativeTo: nil) }
        view.isHidden = false
    }

    /// The window or the pane changed size: the box on screen stays under the field (B-SEL-134). One that scrolling
    /// hid stays hidden.
    func repositionError() {
        guard isShowingError, let view = errorView, let host = window?.contentView else { return }
        place(view, size: view.frame.size, in: host)
    }

    private func place(_ view: RenameErrorView, size: NSSize, in host: NSView) {
        let field = host.convert(bounds, from: self)
        let layout = SelectionLayout.Rename.self
        let belowTop = host.isFlipped ? field.maxY : field.minY
        var left = Double(field.minX)
        var top =
            Double(belowTop)
            + (host.isFlipped ? Double(layout.errorGap) : -Double(layout.errorGap) - Double(size.height))
        // Kept inside the window.
        let placed = MenuPlacement.keepInViewport(
            left: left, top: host.isFlipped ? top : Double(host.bounds.height) - top - Double(size.height),
            width: Double(size.width), height: Double(size.height), viewportWidth: Double(host.bounds.width),
            viewportHeight: Double(host.bounds.height))
        left = placed.left
        top = host.isFlipped ? placed.top : Double(host.bounds.height) - placed.top - Double(size.height)
        view.frame = NSRect(x: left, y: top, width: Double(size.width), height: Double(size.height))
    }

    /// Scrolling moves the row away from the explanation, so it is dropped until the next try.
    func hideError() {
        errorView?.isHidden = true
    }

    /// The reason box is on screen.
    var isShowingError: Bool { errorView.map { !$0.isHidden && $0.superview != nil } ?? false }

    func removeFromWindow() {
        errorView?.removeFromSuperview()
        errorView = nil
        removeFromSuperview()
    }
}
