import AppKit
import FTFoundation

/// The bar over a file in a pane. It holds only what applies now: the file's name and whether it has unsaved edits;
/// for a file in place, the steps to the previous and next file and its place among the folder's files, first, so the
/// steps stay where they are whatever the name or the count is, and a click after click goes on; for a file beside
/// the list, Follow; Save while there are edits; Source or Preview for Markdown; Read or Edit; and the viewer's own
/// menu (⋯), which holds the rest with its keys. The system's controls at the regular size, as the panes' bars have
/// them.
final class ViewerHeaderView: NSView {
    struct State: Equatable {
        var name: String
        var mode: ViewerPreference.Mode
        var isText: Bool
        var isEditing: Bool
        var isDirty: Bool
        var hasPreview: Bool
        var showsPreview: Bool
        var languageID: String
        var position: Position?
        var settings: TextViewerSettings
        /// The keys chosen in Settings → Shortcuts for Save, Next File and Previous File, as the menu writes them.
        var keys = Keys()
    }

    struct Keys: Equatable {
        var save: String?
        var next: String?
        var previous: String?
    }

    struct Position: Equatable {
        var index: Int
        var count: Int
    }

    /// What the bar and its menu ask of the viewer.
    enum Action {
        case previous, next
        case follow(Bool)
        case save, revert
        case editing(Bool)
        case preview(Bool)
        case language(String)
        case find
        case openInEditor, close
        case settings((inout TextViewerSettings) -> Void)
    }

    var onAction: (Action) -> Void = { _ in }

    static var height: Double { DesignTokens.paneContentTop + 24 + 8 + 1 }

    private let backdrop = ContentBackdrop()
    private let nameLabel = FlushTextField(labelWithString: "")
    private let editedLabel = FlushTextField(labelWithString: "Edited")
    private let previousButton = NSButton()
    private let nextButton = NSButton()
    private let positionLabel = FlushTextField(labelWithString: "")
    private let followButton = NSButton(checkboxWithTitle: "Follow", target: nil, action: nil)
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private let previewSwitch = NSSegmentedControl(
        labels: ["Source", "Preview"], trackingMode: .selectOne, target: nil, action: nil)
    private let editSwitch = NSSegmentedControl(
        labels: ["Read", "Edit"], trackingMode: .selectOne, target: nil, action: nil)
    private let menuButton = ViewerMenuButton(frame: .zero, pullsDown: true)
    private var state: State?
    /// The controls the state shows; layout leaves out those that don't fit.
    private var stateShown = Set<ObjectIdentifier>()
    private var managed: [NSView] {
        [
            editedLabel, previousButton, positionLabel, nextButton, followButton, saveButton, previewSwitch, editSwitch,
            menuButton,
        ]
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityIdentifier("textViewer.header")
        addSubview(backdrop)
        nameLabel.font = ThemeFonts.sans(DesignTokens.typeScale.body, .semibold)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.setAccessibilityIdentifier("textViewer.name")
        editedLabel.font = ThemeFonts.sans(DesignTokens.typeScale.callout)
        positionLabel.font = ThemeFonts.sans(DesignTokens.typeScale.callout)
        positionLabel.setAccessibilityIdentifier("textViewer.position")
        for label in [nameLabel, editedLabel, positionLabel] { addSubview(label) }

        configure(previousButton, symbol: "chevron.up", tip: "Previous File (⌥⌘[)", action: #selector(previous))
        configure(nextButton, symbol: "chevron.down", tip: "Next File (⌥⌘])", action: #selector(next))
        previousButton.setAccessibilityIdentifier("textViewer.previous")
        nextButton.setAccessibilityIdentifier("textViewer.next")
        followButton.target = self
        followButton.action = #selector(followChanged)
        followButton.toolTip = "Show the file selected in the other pane as the selection moves"
        followButton.setAccessibilityIdentifier("textViewer.follow")
        addSubview(followButton)
        saveButton.bezelStyle = .push
        saveButton.controlSize = .regular
        saveButton.target = self
        saveButton.action = #selector(save)
        saveButton.toolTip = "Save (⌘S)"
        saveButton.setAccessibilityIdentifier("textViewer.save")
        addSubview(saveButton)

        for control in [previewSwitch, editSwitch] {
            control.controlSize = .regular
            control.segmentStyle = .rounded
            control.target = self
            addSubview(control)
        }
        previewSwitch.action = #selector(previewChanged)
        previewSwitch.setAccessibilityIdentifier("textViewer.preview")
        editSwitch.action = #selector(editChanged)
        editSwitch.setAccessibilityIdentifier("textViewer.edit")
        editSwitch.setToolTip("Show the text without changing it", forSegment: 0)
        editSwitch.setToolTip("Change the text; Save writes it", forSegment: 1)

        menuButton.controlSize = .regular
        menuButton.bezelStyle = .push
        menuButton.toolTip = "Save, other files, find, language and the viewer’s look"
        menuButton.setAccessibilityIdentifier("textViewer.menu")
        menuButton.setAccessibilityLabel("Viewer")
        addSubview(menuButton)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    private func configure(_ button: NSButton, symbol: String, tip: String, action: Selector) {
        button.bezelStyle = .push
        button.controlSize = .regular
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        button.imagePosition = .imageOnly
        button.toolTip = tip
        button.setAccessibilityLabel(tip)
        button.target = self
        button.action = action
        addSubview(button)
    }

    func update(_ next: State) {
        guard next != state else { return }
        state = next
        nameLabel.stringValue = next.name
        editedLabel.isHidden = !next.isDirty
        let inPlace = next.mode == .inPlace
        previousButton.isHidden = !inPlace || next.position == nil
        nextButton.isHidden = previousButton.isHidden
        positionLabel.isHidden = previousButton.isHidden
        if let position = next.position {
            positionLabel.stringValue =
                "\(FormatLocale.count(position.index + 1)) of \(FormatLocale.count(position.count))"
        }
        followButton.isHidden = inPlace
        followButton.state = next.mode == .following ? .on : .off
        saveButton.isHidden = !next.isDirty
        previewSwitch.isHidden = !next.hasPreview || next.isEditing
        previewSwitch.selectedSegment = next.showsPreview ? 1 : 0
        editSwitch.isHidden = !next.isText
        editSwitch.selectedSegment = next.isEditing ? 1 : 0
        menuButton.menu = viewerMenu(next)
        stateShown = Set(managed.filter { !$0.isHidden }.map(ObjectIdentifier.init))
        needsLayout = true
    }

    // MARK: The viewer's menu

    private func viewerMenu(_ state: State) -> NSMenu {
        let menu = NSMenu()
        let title = NSMenuItem()
        title.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "Viewer")
        menu.addItem(title)
        func add(_ title: String, _ action: Action, key: String? = nil, enabled: Bool = true, on: Bool = false) {
            let item = ClosureMenuItem(title: title) { [weak self] in self?.onAction(action) }
            // The key is written beside the title, not given to the item: a pop-up button's menu takes its items' keys
            // wherever the keyboard is in the window, so ⌘S in the list saved and ⌘F found in the text. The viewer
            // takes its keys itself while it has the keyboard (`ViewerRootView`).
            if let key, !key.isEmpty { item.attributedTitle = Self.titleWithKey(title, key: key) }
            item.isEnabled = enabled
            item.state = on ? .on : .off
            menu.addItem(item)
        }
        menu.autoenablesItems = false
        add("Save", .save, key: state.keys.save, enabled: state.isDirty)
        add("Revert to Saved", .revert, enabled: state.isDirty)
        if state.mode == .inPlace {
            menu.addItem(.separator())
            add("Next File", .next, key: state.keys.next, enabled: state.position != nil)
            add("Previous File", .previous, key: state.keys.previous, enabled: state.position != nil)
        }
        if state.isText {
            menu.addItem(.separator())
            add("Find…", .find, key: "⌘F")
            let language = NSMenuItem(title: "Language", action: nil, keyEquivalent: "")
            language.submenu = NSMenu()
            for each in TextLanguage.all {
                let item = ClosureMenuItem(title: each.name) { [weak self] in self?.onAction(.language(each.id)) }
                item.state = each.id == state.languageID ? .on : .off
                language.submenu?.addItem(item)
            }
            menu.addItem(language)
        }
        menu.addItem(.separator())
        menu.addItem(appearanceItem(state.settings))
        add("Bigger Text", .settings { $0.fontSize = min(TextViewerSettings.fontSizes.upperBound, $0.fontSize + 1) })
        add("Smaller Text", .settings { $0.fontSize = max(TextViewerSettings.fontSizes.lowerBound, $0.fontSize - 1) })
        add("Wrap Lines", .settings { $0.wrapLines.toggle() }, on: state.settings.wrapLines)
        add("Line Numbers", .settings { $0.lineNumbers.toggle() }, on: state.settings.lineNumbers)
        menu.addItem(.separator())
        add("Open in Text Editor", .openInEditor)
        add("Close Viewer", .close, key: "⎋")
        return menu
    }

    private func appearanceItem(_ settings: TextViewerSettings) -> NSMenuItem {
        let item = NSMenuItem(title: "Appearance", action: nil, keyEquivalent: "")
        let menu = NSMenu()
        func add(_ title: String, on: Bool, _ change: @escaping (inout TextViewerSettings) -> Void) {
            let entry = ClosureMenuItem(title: title) { [weak self] in self?.onAction(.settings(change)) }
            entry.state = on ? .on : .off
            menu.addItem(entry)
        }
        for appearance in TextViewerAppearance.allCases {
            add(appearance.label, on: settings.viewerAppearance == appearance) { $0.viewerAppearance = appearance }
        }
        menu.addItem(.sectionHeader(title: "Light Theme"))
        for theme in TextViewerTheme.light {
            add(theme.name, on: settings.lightTheme == theme.id) { $0.lightTheme = theme.id }
        }
        menu.addItem(.sectionHeader(title: "Dark Theme"))
        for theme in TextViewerTheme.dark {
            add(theme.name, on: settings.darkTheme == theme.id) { $0.darkTheme = theme.id }
        }
        item.submenu = menu
        return item
    }

    @objc private func previous() { onAction(.previous) }
    @objc private func next() { onAction(.next) }
    @objc private func followChanged() { onAction(.follow(followButton.state == .on)) }
    @objc private func save() { onAction(.save) }
    @objc private func previewChanged() { onAction(.preview(previewSwitch.selectedSegment == 1)) }
    @objc private func editChanged() { onAction(.editing(editSwitch.selectedSegment == 1)) }

    override func draw(_ dirtyRect: NSRect) {
        ChromeColors.color(infoTheme.palette.borderLight).setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    override func layout() {
        super.layout()
        let palette = infoTheme.palette
        nameLabel.textColor = ChromeColors.color(palette.textPrimary)
        for label in [editedLabel, positionLabel] {
            label.textColor = ChromeColors.color(palette.textSecondary)
        }
        backdrop.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - 1))
        let centerY = DesignTokens.paneContentTop + 12
        let gap = 8.0
        func place(_ view: NSView, x: Double, width: Double) {
            let height = view is NSTextField ? view.intrinsicContentSize.height : 24
            view.frame = NSRect(x: x, y: (centerY - height / 2).rounded(), width: width, height: height)
        }
        func fitting(_ view: NSView) -> Double { Double(ceil(view.fittingSize.width)) }
        func width(of view: NSView) -> Double {
            if view === menuButton { return 44 }
            if view === previousButton || view === nextButton { return 28 }
            return fitting(view)
        }
        // The name keeps at least this much; what doesn't fit beside it is left out, Source or Preview first, then
        // the place among the folder's files. The ⋯ menu holds all of it.
        let nameMinimum = 90.0
        let rightViews: [NSView] = [menuButton, editSwitch, saveButton, previewSwitch]
        // The steps to the previous and next file come first, at a place that doesn't move: after them the count and
        // the name, whose widths change from file to file.
        let beforeName: [NSView] = [previousButton, nextButton, positionLabel]
        let afterName: [NSView] = [editedLabel, followButton]
        var shown = stateShown
        func total(_ views: [NSView]) -> Double {
            views.filter { shown.contains(ObjectIdentifier($0)) }.reduce(0) { $0 + width(of: $1) + gap }
        }
        for view in [previewSwitch, positionLabel, previousButton, nextButton] as [NSView] {
            if 24 + total(rightViews) + total(beforeName) + total(afterName) + nameMinimum <= Double(bounds.width) {
                break
            }
            shown.remove(ObjectIdentifier(view))
        }
        for view in managed { view.isHidden = !shown.contains(ObjectIdentifier(view)) }

        var right = Double(bounds.width) - 12
        for view in rightViews where shown.contains(ObjectIdentifier(view)) {
            let size = width(of: view)
            right -= size
            place(view, x: right, width: size)
            right -= gap
        }
        var left = 14.0
        for view in beforeName where shown.contains(ObjectIdentifier(view)) {
            let size = width(of: view)
            place(view, x: left, width: size)
            left += size + gap
        }
        let available = max(40, right - left - total(afterName))
        let nameWidth = min(fitting(nameLabel), available)
        place(nameLabel, x: left, width: nameWidth)
        left += nameWidth + gap
        for view in afterName where shown.contains(ObjectIdentifier(view)) {
            let size = width(of: view)
            place(view, x: left, width: size)
            left += size + gap
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
        needsDisplay = true
    }
}

/// The viewer's ⋯ menu. Its items' keys are only written beside their titles (`titleWithKey`), so a key pressed in
/// the list (⌘F, Find Files; ⌘S) never reaches an item of this menu.
final class ViewerMenuButton: NSPopUpButton {
    override func performKeyEquivalent(with event: NSEvent) -> Bool { false }
}

extension ViewerHeaderView {
    /// "Save" with "⌘S" at the menu's right edge, in the secondary color, as a menu shows an item's key.
    static func titleWithKey(_ title: String, key glyphs: String) -> NSAttributedString {
        let font = NSFont.menuFont(ofSize: 0)
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [NSTextTab(textAlignment: .right, location: 230)]
        let text = NSMutableAttributedString(
            string: title + "\t", attributes: [.font: font, .paragraphStyle: paragraph])
        text.append(
            NSAttributedString(
                string: glyphs,
                attributes: [.font: font, .paragraphStyle: paragraph, .foregroundColor: NSColor.secondaryLabelColor]))
        return text
    }
}

/// A menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let run: () -> Void

    init(title: String, run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func fire() { run() }
}

/// Over the text when another app changed the file while it has edits.
final class ViewerConflictBar: NSView {
    /// Another app changed the file under the edits, or the file went.
    enum Kind: Equatable {
        case changed
        /// What happened to the file: Save puts it back where it was.
        case gone(String)
    }

    static let height = 34.0
    var onKeepMine: () -> Void = {}
    var onUseDisk: () -> Void = {}
    private static let changedText = "Another app changed this file. Your edits haven’t been saved."
    private let label = FlushTextField(labelWithString: changedText)
    private let useDisk = NSButton(title: "Use the File on Disk", target: nil, action: nil)
    private let keepMine = NSButton(title: "Keep Mine", target: nil, action: nil)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setAccessibilityIdentifier("textViewer.conflict")
        label.font = ThemeFonts.sans(DesignTokens.typeScale.callout)
        label.lineBreakMode = .byTruncatingTail
        for button in [useDisk, keepMine] {
            button.bezelStyle = .push
            button.controlSize = .regular
            button.target = self
            addSubview(button)
        }
        useDisk.action = #selector(useDiskPressed)
        keepMine.action = #selector(keepMinePressed)
        keepMine.keyEquivalent = ""
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    /// Shown as `kind` says: a file that went has no file on disk to use, nor anything to keep edits over.
    func show(_ kind: Kind) {
        switch kind {
        case .changed:
            label.stringValue = Self.changedText
            useDisk.isHidden = false
            keepMine.isHidden = false
        case .gone(let text):
            label.stringValue = text
            useDisk.isHidden = true
            keepMine.isHidden = true
        }
        isHidden = false
        needsLayout = true
    }

    @objc private func useDiskPressed() { onUseDisk() }
    @objc private func keepMinePressed() { onKeepMine() }

    override func layout() {
        super.layout()
        layer?.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.18).cgColor
        label.textColor = ChromeColors.color(infoTheme.palette.textPrimary)
        var right = Double(bounds.width) - 10
        for button in [keepMine, useDisk] where !button.isHidden {
            let width = Double(ceil(button.fittingSize.width))
            right -= width
            button.frame = NSRect(x: right, y: 5, width: width, height: 24)
            right -= 8
        }
        let height = label.intrinsicContentSize.height
        label.frame = NSRect(x: 14, y: (Self.height - height) / 2, width: max(0, right - 14), height: height)
    }
}

/// What the viewer shows in place of text: nothing selected, a folder, a file too large, one that can't be read.
final class ViewerMessageView: NSView {
    enum Kind {
        case empty
        case folder(String)
        case tooLarge(String, Int64)
        case unreadable(String)
        /// The file went while shown, and what the title says of it.
        case gone(TextViewerController.GoneFile, String)
    }

    var theme: TextViewerTheme? {
        didSet { needsLayout = true }
    }
    var onOpenInEditor: () -> Void = {}
    private let icon = NSImageView()
    private let title = FlushTextField(labelWithString: "")
    private let detail = FlushTextField(wrappingLabelWithString: "")
    private let button = NSButton(title: "Open in Text Editor", target: nil, action: nil)

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityIdentifier("textViewer.message")
        title.font = ThemeFonts.sans(DesignTokens.typeScale.title3, .semibold)
        title.alignment = .center
        detail.font = ThemeFonts.sans(DesignTokens.typeScale.callout)
        detail.alignment = .center
        button.bezelStyle = .push
        button.target = self
        button.action = #selector(openInEditor)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 40, weight: .light)
        for view in [icon, title, detail, button] { addSubview(view) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    @objc private func openInEditor() { onOpenInEditor() }

    func show(_ kind: Kind) {
        button.isHidden = true
        switch kind {
        case .empty:
            icon.image = NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil)
            title.stringValue = "No File Selected"
            detail.stringValue = "Select a file in the other pane to see it here."
        case .folder(let name):
            icon.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
            title.stringValue = name
            detail.stringValue = "A folder. Select a file in it to see it here."
        case .tooLarge(let name, let size):
            icon.image = NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil)
            title.stringValue = "“\(name)” is too large to view here"
            let limit = SizeText.size(ViewerFile.viewLimit)
            detail.stringValue =
                "It is \(SizeText.size(size)). Files up to \(limit) are shown."
            button.isHidden = false
        case .unreadable(let text):
            icon.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
            title.stringValue = "Can’t Show This File"
            detail.stringValue = text
        case .gone(let how, let text):
            icon.image = NSImage(systemSymbolName: how == .trashed ? "trash" : "doc", accessibilityDescription: nil)
            title.stringValue = text
            detail.stringValue = "It isn’t where it was any more."
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let text = theme.map { NSColor($0.text) } ?? .labelColor
        let secondary = theme.map { NSColor($0.gutterText) } ?? .secondaryLabelColor
        title.textColor = text
        detail.textColor = secondary
        icon.contentTintColor = secondary
        let width = min(Double(bounds.width) - 40, 420)
        let detailHeight = Double(
            detail.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 400)).height ?? 18)
        let total = 52 + 12 + 22 + 6 + detailHeight + (button.isHidden ? 0 : 36)
        var y = max(20, (Double(bounds.height) - total) / 2)
        let x = (Double(bounds.width) - width) / 2
        icon.frame = NSRect(x: (Double(bounds.width) - 52) / 2, y: y, width: 52, height: 52)
        y += 64
        title.frame = NSRect(x: x, y: y, width: width, height: 22)
        y += 28
        detail.frame = NSRect(x: x, y: y, width: width, height: detailHeight)
        y += detailHeight + 12
        let buttonWidth = Double(ceil(button.fittingSize.width))
        button.frame = NSRect(x: (Double(bounds.width) - buttonWidth) / 2, y: y, width: buttonWidth, height: 24)
    }
}
