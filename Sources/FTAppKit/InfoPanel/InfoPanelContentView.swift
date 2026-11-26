import AppKit
import FTFileSystem
import FTFoundation

/// Which of the panel's sections are folded: one set for the app while it runs, so a section folded in one window
/// or the panel popped out stays folded in every other and for every item.
@MainActor
enum InfoSectionFolds {
    private static var folded = Set(InfoSection.ID.allCases.filter(\.foldedAtFirst))
    /// Told when a section is folded or opened, so every panel lays out again.
    static let changed = Notification.Name("InfoSectionFolds.changed")

    static func isFolded(_ id: InfoSection.ID) -> Bool { folded.contains(id) }

    static func toggle(_ id: InfoSection.ID) {
        if folded.remove(id) == nil { folded.insert(id) }
        NotificationCenter.default.post(name: changed, object: nil)
    }

    /// Back to how the app starts: a test seam.
    static func reset() { folded = Set(InfoSection.ID.allCases.filter(\.foldedAtFirst)) }
}

/// A section's title: a click folds the section or opens it, the chevron saying which. Sharing & Permissions has
/// Edit… at its right end, which opens the permissions popover.
final class InfoSectionTitleView: NSView {
    let id: InfoSection.ID
    let title = TextBoxField(labelWithString: "")
    /// Sharing & Permissions' Edit….
    let edit: TextLinkView?
    var onToggle: () -> Void = {}
    var onEdit: () -> Void = {}
    private var isHovered = false { didSet { needsDisplay = true } }
    static let chevronBox = 10.0
    static let gap = 4.0

    init(_ id: InfoSection.ID) {
        self.id = id
        edit = id == .permissions ? TextLinkView(identifier: "infoPanel.permissions.edit") : nil
        super.init(frame: .zero)
        title.stringValue = id.title
        title.font = ChromeColors.font(size: DesignTokens.typeScale.small, weight: 600)
        title.setAccessibilityIdentifier("infoPanel.section.title")
        addSubview(title)
        if let edit {
            edit.text = "Edit\u{2026}"
            edit.font = ChromeColors.font(size: DesignTokens.typeScale.small, weight: 400)
            edit.toolTip = "Change the permissions"
            edit.onClick = { [weak self] in self?.onEdit() }
            addSubview(edit)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.disclosureTriangle)
        setAccessibilityIdentifier("infoPanel.section.\(id.rawValue)")
        setAccessibilityLabel(id.title)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    var isFolded: Bool { InfoSectionFolds.isFolded(id) }

    override func layout() {
        super.layout()
        let height = lineBox(title.font)
        let x = Self.chevronBox + Self.gap
        var right = bounds.width
        if let edit {
            let width = ceil(edit.naturalWidth)
            edit.frame = NSRect(
                x: bounds.width - width, y: (bounds.height - edit.naturalHeight) / 2, width: width,
                height: edit.naturalHeight)
            right = edit.frame.minX - 8
        }
        title.frame = NSRect(
            x: x, y: (bounds.height - height) / 2,
            width: max(0, min(textExtent(title.stringValue, title.font), right - x)),
            height: height)
        title.textColor = NSColor(isHovered ? infoTheme.palette.textPrimary : infoTheme.palette.textSecondary)
        setAccessibilityValue(isFolded ? 0 : 1)
    }

    override func draw(_ dirtyRect: NSRect) {
        let box = Self.chevronBox
        let rect = NSRect(x: 0, y: (bounds.height - box) / 2, width: box, height: box)
        SymbolGlyph.draw(
            isFolded ? "chevron.right" : "chevron.down", in: rect.insetBy(dx: 1, dy: 1),
            color: NSColor(infoTheme.palette.textDim), weight: .semibold)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(
            NSTrackingArea(
                rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsLayout = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsLayout = true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    /// The whole title takes the click, its text too; Edit… takes its own.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if let edit, let hit, hit === edit || hit.isDescendant(of: edit) { return edit }
        return hit == nil ? nil : self
    }
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onToggle() }
    }

    override func accessibilityPerformPress() -> Bool {
        onToggle()
        return true
    }
}

/// How full a disk is: a thin bar with the used part in the accent, over the row's text.
final class InfoUsageView: NSView, TextStyleSource {
    let text = TextBoxField(labelWithString: "")
    var fraction = 0.0 { didSet { needsDisplay = true } }
    var styleTextField: NSTextField? { text }
    static let barHeight = 6.0
    static let barGap = 4.0

    override init(frame: NSRect) {
        super.init(frame: frame)
        text.alignment = .right
        text.isSelectable = true
        text.setAccessibilityIdentifier("infoPanel.row.value")
        addSubview(text)
        setAccessibilityElement(true)
        setAccessibilityRole(.levelIndicator)
        setAccessibilityIdentifier("infoPanel.usage")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let line = lineBox(text.font)
        text.frame = NSRect(x: 0, y: Self.barHeight + Self.barGap, width: bounds.width, height: line)
        setAccessibilityValue(text.stringValue)
    }

    override func draw(_ dirtyRect: NSRect) {
        let theme = infoTheme
        let track = NSRect(x: 0, y: 1, width: bounds.width, height: Self.barHeight)
        let radius = Self.barHeight / 2
        NSColor(theme.palette.bgHover).setFill()
        NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()
        var used = track
        used.size.width = max(Self.barHeight, track.width * min(1, max(0, fraction)))
        NSColor(theme.accent.solid).setFill()
        NSBezierPath(roundedRect: used, xRadius: radius, yRadius: radius).fill()
    }

    /// Its text takes clicks, to be selected; the bar doesn't.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === text ? hit : nil
    }
}

/// The panel's scrolled content, laid out from the display: the hero, Open, the sections and the quick actions.
final class InfoPanelContentView: NSView {
    weak var owner: InfoPanelView?
    var iconStore: FileIconStore? {
        didSet { opensWith.iconStore = iconStore }
    }
    /// Where the hero's preview comes from: the Icons view's, so a picture it already has is drawn at once.
    var thumbnailStore: ThumbnailStore? = IconThumbnails.store
    private var body = InfoPanelDisplay.Body.blank
    private let heroIcon = InfoIconView()
    private let name = TextBoxField(wrappingLabelWithString: "")
    private let subtitle = TextBoxField(labelWithString: "")
    private let open = SplitOpenButton()
    private let opensWith = OpensWithPopupView()
    private let cell = InfoPanelSizeView(identifier: "infoPanel.folderSize")
    private let emptyLabel = TextBoxField(wrappingLabelWithString: "Select a file or folder to show its info.")
    private var sectionViews: [SectionViews] = []
    private var foldObserver: NSObjectProtocol?

    private var dividers: [Double] = []
    /// Each row's band, top to bottom, for its right-click menu.
    private var rowBands: [(range: ClosedRange<Double>, row: InfoRow)] = []
    private var nameBand: ClosedRange<Double>?
    /// The load of the Open button's app icon: the next item's takes it back, so an older answer can't land after a
    /// newer one.
    private var openIconHandle: LoadHandle?
    private var openIconPath: String?

    private struct RowViews {
        var row: InfoRow
        var label: TextBoxField
        var value: NSView
        var extra: TextBoxField?
        var detail: TextBoxField?
        /// Where's copy button.
        var copy: InfoIconButton?
        /// The box of a value that is not plain text, which automation names.
        var box: RowValueBox?
    }

    private struct SectionViews {
        var id: InfoSection.ID
        var title: InfoSectionTitleView
        var rows: [RowViews]
    }

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        heroIcon.setAccessibilityIdentifier("infoPanel.heroIcon")
        heroIcon.pixelSide = NativeIconPixels.heroSide
        name.setAccessibilityIdentifier("infoPanel.name")
        subtitle.setAccessibilityIdentifier("infoPanel.subtitle")
        emptyLabel.setAccessibilityIdentifier("infoPanel.empty")
        name.alignment = .center
        name.maximumNumberOfLines = 2
        name.lineBreakMode = .byTruncatingTail
        name.font = ChromeColors.font(size: DesignTokens.typeScale.title3, weight: 600)
        subtitle.alignment = .center
        subtitle.font = tabularFont(DesignTokens.typeScale.callout)
        subtitle.lineBreakMode = .byTruncatingTail
        name.isSelectable = true
        subtitle.isSelectable = true
        emptyLabel.font = ChromeColors.font(size: DesignTokens.typeScale.callout, weight: 600)
        for view in [heroIcon, name, subtitle, open, emptyLabel, opensWith, cell] as [NSView] { addSubview(view) }
        open.onMain = { [weak self] in self?.owner?.onOpen() }
        open.onChevron = { [weak self] in
            guard let self else { return }
            self.owner?.onOpenWithMenu(self.open)
        }
        opensWith.onClick = { [weak self] in
            guard let self else { return }
            self.owner?.onOpensWithMenu(self.opensWith)
        }
        cell.onCalculate = { [weak self] in self?.owner?.onCalculate() }
        cell.onRecalculate = { [weak self] in self?.owner?.onRecalculate() }
        cell.onCancel = { [weak self] in self?.owner?.onCancel() }
        cell.onSizeChange = { [weak self] in
            self?.relayout()
        }
        cell.isHidden = true
        opensWith.isHidden = true
        foldObserver = NotificationCenter.default.addObserver(
            forName: InfoSectionFolds.changed, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.foldsChanged() }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    isolated deinit {
        if let foldObserver { NotificationCenter.default.removeObserver(foldObserver) }
    }

    func setOpenMenuOpen(_ value: Bool) { open.setMenuOpen(value) }
    func setOpensWithMenuOpen(_ value: Bool) { opensWith.setMenuOpen(value) }

    private func foldsChanged() {
        for section in sectionViews { section.title.needsDisplay = true }
        owner?.needsLayout = true
        relayout()
    }

    // MARK: Building

    /// What the rows are, not their values: the same shape is updated in place.
    private static func shape(_ sections: [InfoSection]) -> [String] {
        sections.flatMap { section in
            [section.id.rawValue]
                + section.rows.map { row in
                    let kind: String
                    switch row.value {
                    case .text: kind = "text"
                    case .folderSize: kind = "size"
                    case .permissions: kind = "permissions"
                    case .place: kind = "place"
                    case .originalLink: kind = "original"
                    case .opensWith: kind = "opens"
                    case .tags: kind = "tags"
                    case .fitting: kind = "fitting"
                    case .usage: kind = "usage"
                    }
                    return "\(row.label)|\(kind)|\(row.detail != nil)|\(row.copyText != nil)|\(row.wraps)"
                }
        }
    }

    private func sections(of body: InfoPanelDisplay.Body) -> [InfoSection]? {
        switch body {
        case .item(let item): item.content.sections
        case .selection(let selection): selection.sections
        case .blank, .empty: nil
        }
    }

    /// The same item, or several items again, with the same rows: the values change where they are, and what is
    /// selected in them stays. Anything else is built anew.
    private func updatesInPlace(_ next: InfoPanelDisplay.Body) -> Bool {
        switch (body, next) {
        case (.item(let old), .item(let new)) where old.item.path == new.item.path: break
        case (.selection, .selection): break
        default: return false
        }
        guard let oldSections = sections(of: body), let newSections = sections(of: next),
            Self.shape(oldSections) == Self.shape(newSections)
        else { return false }
        let rows = newSections.flatMap(\.rows)
        var index = 0
        for sectionIndex in sectionViews.indices {
            for rowIndex in sectionViews[sectionIndex].rows.indices {
                let row = rows[index]
                index += 1
                let views = sectionViews[sectionIndex].rows[rowIndex]
                guard views.row != row else { continue }
                sectionViews[sectionIndex].rows[rowIndex].row = row
                updateValue(views, row)
            }
        }
        return true
    }

    private func updateValue(_ views: RowViews, _ row: InfoRow) {
        switch row.value {
        case .text(let text), .place(let text):
            if let field = views.value as? NSTextField, field.stringValue != text {
                field.stringValue = text
                field.toolTip = row.wraps ? nil : (row.copyText ?? text)
            }
        case .fitting(let full, _):
            if let field = views.value as? NSTextField {
                field.stringValue = full
                field.toolTip = full
            }
        case .usage(let fraction, let text):
            if let usage = views.value as? InfoUsageView {
                usage.fraction = fraction
                usage.text.stringValue = text
            }
        case .originalLink(let text, _):
            (views.value as? TextLinkView)?.text = text
        case .tags(let tags):
            (views.value as? InfoTagsView)?.tags = tags
            views.box?.sample.stringValue = tags.summary
        case .permissions(let words, let octal, _):
            (views.value as? NSTextField)?.stringValue = words
            views.extra?.stringValue = octal
        case .folderSize, .opensWith:
            break
        }
        if let detail = views.detail, let text = row.detail, detail.stringValue != text {
            detail.stringValue = text
            detail.toolTip = text
        }
    }

    func apply(_ next: InfoPanelDisplay.Body) {
        if updatesInPlace(next) {
            body = next
            applyHeader(next)
            if case .item(let item) = next, let entry = item.folderSize { cell.update(entry) }
            if case .selection(let selection) = next, let entry = selection.folderSize { cell.update(entry) }
            if case .item(let item) = next {
                opensWith.kindLabel = item.item.kindLabel
                if opensWith.app != item.openApp { opensWith.app = item.openApp }
            }
            applyColors()
            needsLayout = true
            return
        }
        body = next
        for section in sectionViews {
            section.title.removeFromSuperview()
            for views in section.rows {
                views.label.removeFromSuperview()
                if views.value !== cell, views.value !== opensWith { views.value.removeFromSuperview() }
                views.extra?.removeFromSuperview()
                views.detail?.removeFromSuperview()
                views.copy?.removeFromSuperview()
                views.box?.removeFromSuperview()
            }
        }
        sectionViews = []
        cell.isHidden = true
        opensWith.isHidden = true
        switch next {
        case .blank, .empty:
            break
        case .item(let item):
            applyHeader(next)
            buildSections(
                item.content.sections, folderSize: item.folderSize, opensWith: item.openApp,
                kind: item.item.kindLabel)
        case .selection(let selection):
            applyHeader(next)
            buildSections(selection.sections, folderSize: selection.folderSize, opensWith: nil, kind: "")
        }
        if case .item(let item) = next, let entry = item.folderSize { cell.update(entry) }
        if case .selection(let selection) = next, let entry = selection.folderSize { cell.update(entry) }
        applyColors()
        needsLayout = true
    }

    /// The hero and Open: the icon and the preview load only for another item, the app's icon only for another app.
    private func applyHeader(_ next: InfoPanelDisplay.Body) {
        switch next {
        case .item(let item):
            buildHeroIcon(item.item)
            name.stringValue = item.item.name
            name.toolTip = item.item.name
            subtitle.stringValue = item.content.subtitle
            open.title = item.openApp.map { "Open in \($0.name)" } ?? "Open"
            open.toolTip = open.title
            loadOpenIcon(item.openApp)
        case .selection(let selection):
            let contains = InfoPanelModel.selectionContains(selection.summary)
            heroIcon.showStack(
                back: contains == "files" ? .file : .folder, front: contains == "folders" ? .folder : .file,
                store: iconStore)
            name.stringValue = InfoPanelModel.selectionName(selection.summary)
            name.toolTip = nil
            subtitle.stringValue = InfoPanelModel.selectionSubtitle(selection.summary)
        case .blank, .empty:
            break
        }
    }

    private func buildHeroIcon(_ item: InfoItem) {
        let kind: IconEntryKind
        switch item.kind {
        case .directory: kind = .directory
        case .file: kind = .file
        case .symlinkDirectory: kind = .symlinkDirectory
        case .symlinkFile: kind = .symlinkFile
        case .alias: kind = .alias
        case .aliasDirectory: kind = .aliasDirectory
        case .bundle: kind = .bundle
        case .other: kind = .other
        }
        heroIcon.show(
            IconEntry(path: item.path, name: item.name, extension: item.fileExtension, kind: kind), store: iconStore,
            deferLoad: true)
        // The file's own picture where Quick Look has one, as the Icons view shows it: read for the one item shown.
        let version = "\(item.modifiedAt?.timeIntervalSince1970 ?? 0)/\(item.sizeBytes ?? -1)"
        heroIcon.showPreview(path: item.path, kind: kind, version: version, store: thumbnailStore)
    }

    private func loadOpenIcon(_ app: InfoOpenApp?) {
        open.reservesIcon = app != nil
        guard app?.path != openIconPath || app == nil else { return }
        openIconPath = app?.path
        openIconHandle?.cancel()
        openIconHandle = nil
        guard let app, let iconStore else {
            open.appIcon = nil
            return
        }
        openIconHandle = iconStore.load(.app(path: app.path)) { [weak self] image in
            self?.open.appIcon = image.map(NativeIconPixels.image)
        }
    }

    private func buildSections(
        _ sections: [InfoSection], folderSize: FolderSizeEntry?, opensWith app: InfoOpenApp?, kind: String
    ) {
        for section in sections {
            let title = InfoSectionTitleView(section.id)
            title.onToggle = { InfoSectionFolds.toggle(section.id) }
            title.onEdit = { [weak self, weak title] in
                guard let title else { return }
                self?.owner?.onEditPermissions(title)
            }
            addSubview(title)
            let rows = section.rows.map { buildRow($0, folderSize: folderSize, opensWith: app, kind: kind) }
            sectionViews.append(SectionViews(id: section.id, title: title, rows: rows))
        }
    }

    private func valueField(_ text: String, wraps: Bool) -> TextBoxField {
        let field = wraps ? TextBoxField(wrappingLabelWithString: text) : TextBoxField(labelWithString: text)
        field.alignment = .right
        field.lineBreakMode = wraps ? .byWordWrapping : .byTruncatingTail
        field.maximumNumberOfLines = wraps ? 0 : 1
        field.toolTip = wraps ? nil : text
        // Text can be selected, with the system's right-click menu on it, as every plain text of the panel can.
        field.isSelectable = true
        field.setAccessibilityIdentifier("infoPanel.row.value")
        addSubview(field)
        return field
    }

    private func buildRow(_ row: InfoRow, folderSize: FolderSizeEntry?, opensWith app: InfoOpenApp?, kind: String)
        -> RowViews
    {
        let label = TextBoxField(labelWithString: row.label)
        label.font = tabularFont(DesignTokens.typeScale.callout)
        label.setAccessibilityIdentifier("infoPanel.row.label")
        addSubview(label)
        var extra: TextBoxField?
        var box: RowValueBox?
        var copy: InfoIconButton?
        let value: NSView
        switch row.value {
        case .text(let text):
            value = valueField(text, wraps: row.wraps)
        case .fitting(let full, _):
            // Which of the two shows is chosen as the row is laid out, by the room it has.
            let field = TextBoxField(labelWithString: full)
            field.alignment = .right
            field.lineBreakMode = .byTruncatingTail
            field.isSelectable = true
            field.toolTip = full
            field.setAccessibilityIdentifier("infoPanel.row.value")
            addSubview(field)
            value = field
        case .usage(let fraction, let text):
            let usage = InfoUsageView()
            usage.fraction = fraction
            usage.text.stringValue = text
            addSubview(usage)
            value = usage
        case .folderSize:
            cell.isHidden = false
            value = cell
            box = RowValueBox()
            box?.sample.stringValue = "Calculate"
        case .permissions(let words, let octal, let symbolic):
            let field = TextBoxField(labelWithString: words)
            field.alignment = .right
            field.setAccessibilityIdentifier("infoPanel.row.words")
            box = RowValueBox()
            box?.sample.stringValue = words
            let code = TextBoxField(labelWithString: octal)
            code.font =
                NSFont(name: "Menlo-Regular", size: DesignTokens.typeScale.small)
                ?? ThemeFonts.mono(DesignTokens.typeScale.small)
            code.toolTip = symbolic
            code.setAccessibilityIdentifier("infoPanel.row.code")
            addSubview(field)
            addSubview(code)
            extra = code
            value = field
        case .place(let text):
            // One line: what is cut short is the top of the disk, so the folder it is in stays.
            let field = TextBoxField(labelWithString: text)
            field.alignment = .right
            field.lineBreakMode = .byTruncatingHead
            field.isSelectable = true
            field.toolTip = row.copyText ?? text
            field.setAccessibilityIdentifier("infoPanel.where")
            addSubview(field)
            value = field
            if let copyText = row.copyText {
                let button = InfoIconButton(
                    glyph: .copy, iconSize: InfoMetrics.copyIcon, cornerRadius: DesignTokens.radii.xs,
                    identifier: "infoPanel.where.copy", label: "Copy Path")
                button.tooltip = "Copy Path"
                button.onClick = { [weak self] in self?.owner?.onCopyText(copyText, "Path") }
                addSubview(button)
                copy = button
            }
        case .originalLink(let text, let path):
            let link = TextLinkView(identifier: "infoPanel.original")
            box = RowValueBox()
            box?.sample.stringValue = text
            link.text = text
            link.toolTip = path
            link.font = ThemeFonts.sans(DesignTokens.typeScale.callout)
            link.onClick = { [weak self] in self?.owner?.onShowOriginal(path) }
            addSubview(link)
            value = link
        case .opensWith:
            opensWith.isHidden = false
            opensWith.kindLabel = kind
            opensWith.app = app
            value = opensWith
            box = RowValueBox()
            box?.sample.stringValue = app?.name ?? "None"
        case .tags(let tags):
            let view = InfoTagsView()
            view.tags = tags
            view.onClick = { [weak self, weak view] in
                guard let view else { return }
                self?.owner?.onEditTags(view)
            }
            box = RowValueBox()
            box?.sample.stringValue = tags.summary
            addSubview(view)
            value = view
        }
        if let box { addSubview(box) }
        var detail: TextBoxField?
        if let text = row.detail {
            let field = TextBoxField(labelWithString: text)
            field.alignment = .right
            field.lineBreakMode = .byTruncatingMiddle
            field.isSelectable = true
            field.toolTip = text
            field.font = tabularFont(DesignTokens.typeScale.callout)
            field.setAccessibilityIdentifier("infoPanel.row.detail")
            addSubview(field)
            detail = field
        }
        return RowViews(row: row, label: label, value: value, extra: extra, detail: detail, copy: copy, box: box)
    }

    // MARK: Copy

    override func menu(for event: NSEvent) -> NSMenu? {
        let y = Double(convert(event.locationInWindow, from: nil).y)
        let menu = NSMenu()
        menu.autoenablesItems = false
        if let nameBand, nameBand.contains(y), !name.stringValue.isEmpty, !name.isHidden {
            let text = name.stringValue
            menu.addItem(copyItem("Copy Name", text: text, what: "Name"))
            return menu
        }
        guard let band = rowBands.first(where: { $0.range.contains(y) }) else { return nil }
        let text = band.row.textToCopy
        guard !text.isEmpty, text != InfoPanelModel.pending else { return nil }
        menu.addItem(copyItem("Copy \(band.row.label)", text: text, what: band.row.label))
        return menu
    }

    private func copyItem(_ title: String, text: String, what: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(copyFromMenu(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = [text, what]
        item.setAccessibilityIdentifier("infoPanel.copyMenu.item")
        return item
    }

    @objc private func copyFromMenu(_ sender: NSMenuItem) {
        guard let parts = sender.representedObject as? [String], parts.count == 2 else { return }
        owner?.onCopyText(parts[0], parts[1])
    }

    /// The text a row's right-click Copy copies, by its label: a test seam.
    func copyText(forRow label: String) -> String? {
        rowBands.first { $0.row.label == label }?.row.textToCopy
    }

    // MARK: Colors

    func applyColors() {
        let theme = infoTheme
        let palette = theme.palette
        name.textColor = NSColor(palette.textPrimary)
        subtitle.textColor = NSColor(palette.textSecondary)
        emptyLabel.textColor = NSColor(palette.getInfoMetaValue)
        let mutedColor = mixColor(palette.getInfoMetaValueMuted, 45, with: palette.getInfoMetaValue)
        for section in sectionViews {
            section.title.needsLayout = true
            for views in section.rows {
                let muted = views.row.muted
                views.label.textColor = NSColor(palette.textSecondary)
                views.extra?.textColor = NSColor(palette.textSecondary)
                views.detail?.textColor = NSColor(palette.textSecondary)
                if let box = views.box {
                    box.sample.textColor = NSColor(muted ? mutedColor : palette.textPrimary)
                    box.sample.font = ChromeColors.font(size: DesignTokens.typeScale.callout, weight: muted ? 600 : 400)
                }
                if let field = views.value as? NSTextField {
                    field.textColor = NSColor(muted ? mutedColor : palette.textPrimary)
                    field.font = ChromeColors.font(size: DesignTokens.typeScale.callout, weight: muted ? 600 : 400)
                } else if let usage = views.value as? InfoUsageView {
                    usage.text.textColor = NSColor(palette.textPrimary)
                    usage.text.font = ChromeColors.font(size: DesignTokens.typeScale.callout)
                    usage.needsDisplay = true
                } else if let link = views.value as? TextLinkView {
                    link.applyStyle()
                } else if let tags = views.value as? InfoTagsView {
                    tags.font = ChromeColors.font(size: DesignTokens.typeScale.callout, weight: 400)
                    tags.textColor = NSColor(palette.textPrimary)
                    tags.mutedColor = NSColor(mutedColor)
                }
            }
        }
        needsDisplay = true
    }

    // MARK: Layout

    private func lineHeight(_ font: NSFont?) -> Double {
        lineBox(font)
    }

    private func textWidth(_ field: NSTextField) -> Double {
        textExtent(field.stringValue, field.font)
    }

    func relayout() {
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    override func layout() {
        super.layout()
        applyColors()
        let inset = InfoMetrics.panelInset
        let width = max(0, bounds.width - 2 * inset)
        var y = 0.0
        dividers = []
        rowBands = []
        nameBand = nil
        let isEmpty: Bool
        var hasHero = false
        switch body {
        case .blank: isEmpty = false
        case .empty: isEmpty = true
        default:
            isEmpty = false
            hasHero = true
        }
        emptyLabel.isHidden = !isEmpty
        for view in [heroIcon, name, subtitle] as [NSView] { view.isHidden = !hasHero }
        open.isHidden = true
        if isEmpty {
            // The empty message, 18 from the top.
            let height = ceil(
                emptyLabel.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 1000)).height ?? 0)
            emptyLabel.frame = NSRect(x: inset, y: 18, width: width, height: height)
            frame.size.height = max(superview?.bounds.height ?? 0, 18 + height + 18)
            return
        }
        guard hasHero else { return }
        // The hero: padding 8 8 14, a 6 gap.
        let heroPad = 8.0
        y += heroPad
        let boxSide = InfoMetrics.heroIconBox
        var iconSide = 96.0
        if case .selection = body { iconSide = InfoMetrics.heroStackBox }
        heroIcon.inset = (boxSide - iconSide) / 2
        heroIcon.frame = NSRect(x: inset + (width - boxSide) / 2, y: y, width: boxSide, height: boxSide)
        y += boxSide + InfoMetrics.heroGap
        let nameWidth = max(0, width - 2 * heroPad)
        let nameLine = (name.font?.pointSize ?? 15) * 1.3
        let nameParagraph = NSMutableParagraphStyle()
        nameParagraph.alignment = .center
        nameParagraph.minimumLineHeight = nameLine
        nameParagraph.maximumLineHeight = nameLine
        nameParagraph.lineBreakMode = .byTruncatingTail
        let nameFont = name.font ?? ChromeColors.font(size: 15, weight: 600)
        name.attributedStringValue = NSAttributedString(
            string: name.stringValue,
            attributes: [
                .font: nameFont, .foregroundColor: NSColor(infoTheme.palette.textPrimary),
                .paragraphStyle: nameParagraph,
            ])
        // Measured wrapped by word, as it is drawn: a truncating line break never wraps, so it would measure one line.
        let wrapped = (nameParagraph.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
        wrapped.lineBreakMode = .byWordWrapping
        let measured = (name.stringValue as NSString).boundingRect(
            with: NSSize(width: nameWidth, height: 10000), options: [.usesLineFragmentOrigin],
            attributes: [.font: nameFont, .paragraphStyle: wrapped])
        let lines = min(2, max(1, Int((measured.height / nameLine).rounded(.up))))
        let nameHeight = Double(lines) * nameLine
        let nameShown = min(nameWidth, max(ceil(measured.width), textExtent(name.stringValue, nameFont)))
        name.frame = NSRect(x: inset + (width - nameShown) / 2, y: y, width: nameShown, height: nameHeight)
        nameBand = y...(y + nameHeight)
        y += nameHeight + InfoMetrics.heroGap
        let subtitleHeight = lineHeight(subtitle.font)
        let subtitleShown = min(nameWidth, textExtent(subtitle.stringValue, subtitle.font))
        subtitle.frame = NSRect(
            x: inset + (width - subtitleShown) / 2, y: y, width: subtitleShown, height: subtitleHeight)
        y += subtitleHeight + 14

        if case .item = body {
            open.isHidden = false
            open.frame = NSRect(x: inset, y: y, width: width, height: InfoMetrics.openButtonHeight)
            y += InfoMetrics.openButtonHeight + 18
        }
        let bodyLine = lineHeight(ChromeColors.font(size: DesignTokens.typeScale.callout))
        for (sectionIndex, section) in sectionViews.enumerated() {
            if sectionIndex > 0 { y += InfoMetrics.sectionGap - InfoMetrics.rowPaddingBlock }
            let titleHeight = max(lineHeight(section.title.title.font), InfoSectionTitleView.chevronBox)
            section.title.frame = NSRect(x: inset, y: y, width: width, height: titleHeight)
            section.title.needsLayout = true
            y += titleHeight + InfoMetrics.sectionTitleGap
            let folded = InfoSectionFolds.isFolded(section.id)
            for (index, views) in section.rows.enumerated() {
                let hidden = folded
                for view in [views.label, views.value, views.extra, views.detail, views.copy, views.box]
                    .compactMap({ $0 }) as [NSView]
                {
                    // The folder size cell and the pop-up are shared: shown again by the row that has them.
                    view.isHidden = hidden
                }
                if hidden { continue }
                let top = y + InfoMetrics.rowPaddingBlock
                let rowHeight = layoutRow(views, top: top, inset: inset, width: width, bodyLine: bodyLine)
                rowBands.append(
                    ((top - InfoMetrics.rowPaddingBlock)...(top + rowHeight + InfoMetrics.rowPaddingBlock), views.row))
                y = top + rowHeight + InfoMetrics.rowPaddingBlock
                if index < section.rows.count - 1 {
                    dividers.append(y)
                    y += 1
                }
            }
            if folded { y += InfoMetrics.rowPaddingBlock }
        }
        y += InfoMetrics.sectionGap
        frame.size.height = y + 18 - InfoMetrics.sectionGap
        needsDisplay = true
    }

    /// Lays out one row from `top`; its height.
    private func layoutRow(_ views: RowViews, top: Double, inset: Double, width: Double, bodyLine: Double) -> Double {
        let label = views.label
        let labelWidth = textWidth(label)
        let maxValue = max(0, width - labelWidth - InfoMetrics.rowGap)
        label.frame = NSRect(x: inset, y: top, width: labelWidth, height: bodyLine)
        var valueHeight = bodyLine
        var valueWidth: Double
        switch views.value {
        case let field as NSTextField:
            if case .fitting(let full, let short) = views.row.value {
                field.stringValue = textExtent(full, field.font) <= maxValue ? full : short
            }
            valueWidth = textWidth(field)
            if let extra = views.extra { valueWidth += 6 + textWidth(extra) }
            if views.copy != nil { valueWidth += InfoMetrics.copyButton + 4 }
        case let link as TextLinkView:
            // Not its whole-point `naturalWidth`: the value ends at the panel's edge.
            valueWidth = textExtent(link.text, link.font)
            if views.copy != nil { valueWidth += InfoMetrics.copyButton + 4 }
        case let popup as OpensWithPopupView:
            valueWidth = popup.naturalWidth
        case let sizeCell as InfoPanelSizeView:
            // One line in every state, so the rows under it stay put while the folder is measured.
            valueWidth = sizeCell.naturalWidth
        case let tags as InfoTagsView:
            // As wide as its chips, up to what the row has: the rest go on the lines under it.
            valueWidth = tags.naturalWidth
        case is InfoUsageView:
            valueWidth = maxValue
        default: valueWidth = 0
        }
        valueWidth = min(valueWidth, maxValue)
        let valueX = inset + width - valueWidth
        switch views.value {
        case let field as NSTextField:
            if let extra = views.extra {
                let codeWidth = textWidth(extra)
                let codeHeight = lineHeight(extra.font)
                field.frame = NSRect(x: valueX, y: top, width: max(0, valueWidth - 6 - codeWidth), height: bodyLine)
                // Baselines line up: the code is smaller.
                let baselineShift = (field.font?.ascender ?? 0) - (extra.font?.ascender ?? 0)
                extra.frame = NSRect(
                    x: inset + width - codeWidth, y: top + baselineShift, width: codeWidth, height: codeHeight)
            } else if case .fitting = views.row.value {
                field.frame = NSRect(x: valueX, y: top, width: valueWidth, height: bodyLine)
            } else if case .place = views.row.value {
                // One line, its copy button at the row's end.
                let copyWidth = views.copy != nil ? InfoMetrics.copyButton + 4 : 0
                field.frame = NSRect(x: valueX, y: top, width: max(0, valueWidth - copyWidth), height: bodyLine)
                if let copy = views.copy {
                    let side = InfoMetrics.copyButton
                    copy.frame = NSRect(
                        x: inset + width - side, y: top + (bodyLine - side) / 2, width: side, height: side)
                }
            } else {
                // A value longer than the row wraps onto the lines under it: nothing is cut short.
                let measured = ceil(
                    (field.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: maxValue, height: 10000)).height)
                        .map { Double($0) } ?? bodyLine)
                let wraps = textWidth(field) > maxValue + 0.5
                valueHeight = wraps ? max(bodyLine, measured) : bodyLine
                let shownWidth = wraps ? maxValue : valueWidth
                field.frame = NSRect(x: inset + width - shownWidth, y: top, width: shownWidth, height: valueHeight)
            }
        case let link as TextLinkView:
            let copyWidth = views.copy != nil ? InfoMetrics.copyButton + 4 : 0
            link.frame = NSRect(x: valueX, y: top, width: max(0, valueWidth - copyWidth), height: bodyLine)
            if let copy = views.copy {
                let side = InfoMetrics.copyButton
                copy.frame = NSRect(x: inset + width - side, y: top + (bodyLine - side) / 2, width: side, height: side)
            }
        case let popup as OpensWithPopupView:
            // The pop-up is 4 taller than its line of text: 2 above and 2 below.
            popup.frame = NSRect(x: valueX, y: top - 2, width: valueWidth, height: bodyLine + 4)
        case let tags as InfoTagsView:
            // The tags take as many lines as they need: every one shows.
            valueHeight = max(bodyLine, Double(tags.height(width: CGFloat(valueWidth))))
            tags.frame = NSRect(x: valueX, y: top, width: valueWidth, height: valueHeight)
        case let usage as InfoUsageView:
            valueHeight = InfoUsageView.barHeight + InfoUsageView.barGap + bodyLine
            usage.frame = NSRect(x: valueX, y: top, width: valueWidth, height: valueHeight)
        default:
            views.value.frame = NSRect(x: valueX, y: top, width: valueWidth, height: bodyLine)
        }
        views.box?.frame = NSRect(x: valueX, y: top, width: valueWidth, height: bodyLine)
        var height = valueHeight
        if let detail = views.detail {
            let shown = min(width, textWidth(detail))
            detail.frame = NSRect(x: inset + width - shown, y: top + height, width: shown, height: bodyLine)
            height += bodyLine
        }
        return height
    }

    override func draw(_ dirtyRect: NSRect) {
        let palette = infoTheme.palette
        ChromeColors.color(palette.borderLight).setFill()
        for y in dividers {
            NSRect(x: InfoMetrics.panelInset, y: y, width: bounds.width - 2 * InfoMetrics.panelInset, height: 1).fill()
        }
    }
}
