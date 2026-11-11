// The icon grid in a system popover, and the app pop-up
import AppKit
import FTFoundation

/// The icon of an app at a path, as macOS draws it.
@MainActor
enum SettingsAppIcon {
    static func image(_ path: String) -> NSImage { NSWorkspace.shared.icon(forFile: path) }
}

/// The panels of Settings: the favorite icon grid, in a system popover, one at a time. It takes Escape before the window
/// does, closes on a press elsewhere and when the window goes to the back, and gives the keyboard back to the control
/// that opened it.
@MainActor
final class SettingsPopovers {
    private(set) var view: NSView?
    private var popover: AnchoredPopover?
    private weak var owner: NSView?

    var isOpen: Bool { view != nil }

    func isOpen(from owner: NSView) -> Bool { view != nil && self.owner === owner }

    /// The window of the open popover, whose keys go through `handle` too.
    var window: NSWindow? { popover?.window }

    /// Shows `view` in a popover under `owner`.
    func show(_ content: NSView, owner: NSView) {
        close(returnFocus: false)
        view = content
        self.owner = owner
        let popover = AnchoredPopover(content: content, size: content.frame.size)
        self.popover = popover
        if let window = owner.window { popover.show(from: owner, in: window) }
        owner.needsDisplay = true
    }

    /// The control moved: the window was resized or the page scrolled.
    func update() {
        if let owner { popover?.reposition(for: owner) }
    }

    /// Closes the panel; with `returnFocus` the control that opened it takes the keyboard.
    func close(returnFocus: Bool) {
        guard view != nil else { return }
        view = nil
        popover?.close()
        popover = nil
        let owner = self.owner
        self.owner = nil
        owner?.needsDisplay = true
        if returnFocus, let owner { owner.window?.makeFirstResponder(owner) }
    }

    /// An event on its way to the window: true when the panel took it.
    func handle(_ event: NSEvent) -> Bool {
        guard let view else { return false }
        switch event.type {
        case .leftMouseDown, .rightMouseDown:
            if event.window === view.window, view.bounds.contains(view.convert(event.locationInWindow, from: nil)) {
                return false
            }
            if let owner, owner.bounds.contains(owner.convert(event.locationInWindow, from: nil)) { return false }
            close(returnFocus: false)
            return false
        case .keyDown:
            if event.keyCode == 53 {
                close(returnFocus: true)
                return true
            }
            return false
        default:
            return false
        }
    }
}

// MARK: Favorite icons

/// A favorite's icon, which is also the button that chooses another one.
final class FavoriteIconButton: SettingsControlView {
    var icon: FavoriteIconID { didSet { needsDisplay = true } }
    /// The row under it is selected in a list with the keyboard: the icon takes the row's text color.
    var onSelection = false { didSet { needsDisplay = true } }
    /// Tells whether the grid it opened is open, for its look.
    var isExpanded: () -> Bool = { false }
    /// Told when it has taken or left the keyboard, once the window says so: the row it is in is selected while it
    /// has it.
    var onFocusChange: () -> Void = {}

    init(icon: FavoriteIconID, name: String, theme: Theme) {
        self.icon = icon
        super.init(theme: theme)
        frame.size = NSSize(width: SettingsMetrics.favoriteButtonSize, height: SettingsMetrics.favoriteButtonSize)
        toolTip = "Choose Icon"
        setAccessibilityElement(true)
        setAccessibilityRole(.popUpButton)
        setAccessibilityLabel("Favorite icon for \(name)")
        setAccessibilityIdentifier("settings.favoriteIcon")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        DispatchQueue.main.async { [weak self] in self?.onFocusChange() }
        return true
    }

    override func resignFirstResponder() -> Bool {
        DispatchQueue.main.async { [weak self] in self?.onFocusChange() }
        return true
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        beginPress(at: event.locationInWindow)
        super.mouseDown(with: event)
    }

    /// The press goes down at `location`, in the window. It may scroll the page, so the button remembers how far it went
    /// under the pointer: the release that follows at the same place is still on the button.
    func beginPress(at location: NSPoint) {
        let before = convert(location, from: nil)
        focusForPress()
        let after = convert(location, from: nil)
        pressShift = NSSize(width: after.x - before.x, height: after.y - before.y)
    }

    /// A press takes the keyboard as the button goes down: its row is selected
    /// and the list shows the accent before the grid opens.
    func focusForPress() {
        window?.makeFirstResponder(self)
        onFocusChange()
        revealRow()
    }

    /// The row the press focused, cut by the page's edge, is brought into view: the page goes as far as it can toward
    /// centring it. A row wholly in view stays where it is.
    private func revealRow() {
        let row = superview ?? self
        guard let scroll = row.enclosingScrollView, let document = scroll.documentView else { return }
        let clip = scroll.contentView
        let visible = clip.bounds
        let rect = row.convert(row.bounds, to: clip)
        guard rect.minY < visible.minY || rect.maxY > visible.maxY else { return }
        let end = max(0, document.frame.height - visible.height)
        let y = min(max(0, rect.midY - visible.height / 2), end)
        clip.scroll(to: NSPoint(x: visible.minX, y: y))
        scroll.reflectScrolledClipView(clip)
    }

    override func draw(_ dirtyRect: NSRect) {
        if isHovering || isExpanded() {
            let radius = CGFloat(DesignTokens.radii.xs)
            NSColor(theme.palette.bgHover).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        }
        let size = SettingsMetrics.listIconSize
        let rect = NSRect(x: (bounds.width - size) / 2, y: (bounds.height - size) / 2, width: size, height: size)
        SidebarIcons.drawFavorite(
            icon, in: rect, color: NSColor(onSelection ? theme.accent.onSelection : theme.palette.iconNeutral))
    }

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " || event.keyCode == 36 {
            press()
        } else {
            super.keyDown(with: event)
        }
    }
}

/// A cell of the icon grid: 30 by 30, accent-filled when it is the favorite's icon. The other icons keep the
/// neutral color of a favorite's icon; only the chosen one takes the accent's ink.
final class FavoriteIconCell: SettingsControlView {
    let icon: FavoriteIconID
    let isSelected: Bool

    init(icon: FavoriteIconID, selected: Bool, owner: String, theme: Theme) {
        self.icon = icon
        isSelected = selected
        super.init(theme: theme)
        toolTip = icon.label
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("\(owner): \(icon.label)")
        setAccessibilityValue(selected ? 1 : 0)
        setAccessibilityIdentifier("settings.favoriteIcon.choice")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func draw(_ dirtyRect: NSRect) {
        let radius = CGFloat(DesignTokens.radii.control)
        if isSelected {
            NSColor(theme.accent.solid).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        } else if isHovering {
            NSColor(theme.palette.bgHover).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        }
        // A favorite's icon: 18 by 18.
        let size = SettingsMetrics.gridIconSize
        let rect = NSRect(x: (bounds.width - size) / 2, y: (bounds.height - size) / 2, width: size, height: size)
        SidebarIcons.drawFavorite(icon, in: rect, color: NSColor(iconColor))
    }

    var iconColor: RGBA { isSelected ? theme.accent.onSolid : theme.palette.iconNeutral }
}

/// The grid of icons a favorite can have: 6 columns of 30, 4 apart, 6 of padding, on the popover's background.
final class FavoriteIconGrid: ThemedView {
    private(set) var cells: [FavoriteIconCell] = []
    var onChoose: (FavoriteIconID) -> Void = { _ in }

    static var size: NSSize {
        let columns = CGFloat(SettingsMetrics.iconGridColumns)
        let rows = ceil(CGFloat(FavoriteIconID.allCases.count) / columns)
        let cell = SettingsMetrics.iconGridCell
        let gap = SettingsMetrics.iconGridGap
        let padding = SettingsMetrics.iconGridPadding
        return NSSize(
            width: 2 * padding + columns * cell + (columns - 1) * gap,
            height: 2 * padding + rows * cell + (rows - 1) * gap)
    }

    init(selected: FavoriteIconID, owner: String, theme: Theme) {
        super.init(frame: NSRect(origin: .zero, size: Self.size), theme: theme)
        fill = { _ in .clear }
        borderColor = nil
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("\(owner) options")
        setAccessibilityIdentifier("settings.iconGrid")
        let columns = SettingsMetrics.iconGridColumns
        let cell = SettingsMetrics.iconGridCell
        let step = cell + SettingsMetrics.iconGridGap
        let inset = SettingsMetrics.iconGridPadding
        for (index, icon) in FavoriteIconID.allCases.enumerated() {
            let view = FavoriteIconCell(icon: icon, selected: icon == selected, owner: owner, theme: theme)
            view.frame = NSRect(
                x: inset + CGFloat(index % columns) * step, y: inset + CGFloat(index / columns) * step, width: cell,
                height: cell)
            view.onPress = { [weak self] in self?.onChoose(icon) }
            cells.append(view)
            addSubview(view)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

// MARK: App pop-up

/// An app chosen in Settings: the system's pop-up button, its menu the app in use and the default (each with its
/// icon), then Choose….
final class SettingsAppPopup: NSPopUpButton, SettingsSized {
    /// What a choice in the menu asks for.
    enum Pick {
        /// The default app, chosen while another is in use.
        case defaultApplication
        /// Choose…: another app, from a picker.
        case other
    }

    private(set) var application: ApplicationSelection
    let defaultApplication: ApplicationSelection
    /// The icons of the app in use and of the default, looked up when the app changes rather than on each draw.
    private var icon = NSImage()
    private let defaultIcon: NSImage
    var onPick: (Pick) -> Void = { _ in }

    init(label: String, application: ApplicationSelection, defaultApplication: ApplicationSelection) {
        self.application = application
        self.defaultApplication = defaultApplication
        defaultIcon = Self.menuIcon(defaultApplication.appPath)
        super.init(frame: .zero, pullsDown: false)
        autoenablesItems = false
        font = ThemeFonts.sans(DesignTokens.typeScale.body)
        target = self
        action = #selector(chose(_:))
        setAccessibilityLabel(label)
        setAccessibilityIdentifier("settings.appPopup")
        icon = Self.menuIcon(application.appPath)
        rebuild()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Tab comes here whatever the system's keyboard navigation setting says.
    override var acceptsFirstResponder: Bool { isEnabled }
    override var canBecomeKeyView: Bool { acceptsFirstResponder }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private static func menuIcon(_ path: String) -> NSImage {
        let image = (SettingsAppIcon.image(path).copy() as? NSImage) ?? NSImage()
        image.size = NSSize(width: SettingsMetrics.appIconSize, height: SettingsMetrics.appIconSize)
        return image
    }

    func update(_ application: ApplicationSelection) {
        if application.appPath != self.application.appPath { icon = Self.menuIcon(application.appPath) }
        self.application = application
        rebuild()
    }

    var isDefault: Bool { application.appPath == defaultApplication.appPath }

    /// The apps the menu offers: the one in use, then the default when it is another.
    var choices: [(application: ApplicationSelection, isDefault: Bool)] {
        isDefault ? [(defaultApplication, true)] : [(application, false), (defaultApplication, true)]
    }

    /// The menu's items: the apps, a separator and Choose…, the app in use chosen.
    private func rebuild() {
        removeAllItems()
        for choice in choices {
            let item = NSMenuItem(title: choice.application.appName, action: nil, keyEquivalent: "")
            item.image = choice.isDefault && !isDefault ? defaultIcon : icon
            item.toolTip = choice.application.appPath
            item.representedObject = choice.isDefault
            menu?.addItem(item)
        }
        menu?.addItem(.separator())
        menu?.addItem(NSMenuItem(title: "Choose…", action: nil, keyEquivalent: ""))
        selectItem(at: 0)
    }

    var preferredSize: NSSize {
        let size = cell?.cellSize ?? intrinsicContentSize
        return NSSize(
            width: min(SettingsMetrics.appPopupMaxWidth, max(SettingsMetrics.popupMinWidth, ceil(size.width))),
            height: ceil(size.height))
    }

    /// Chooses the item at `index` of the menu, as the menu does.
    func choose(at index: Int) {
        guard itemArray.indices.contains(index), !itemArray[index].isSeparatorItem else { return }
        selectItem(at: index)
        chose(self)
    }

    @objc private func chose(_ sender: Any?) {
        let index = indexOfSelectedItem
        // The button goes on showing the app in use until the preferences say otherwise.
        selectItem(at: 0)
        if index == numberOfItems - 1 {
            onPick(.other)
        } else if index > 0, !isDefault {
            onPick(.defaultApplication)
        }
    }

    override func keyDown(with event: NSEvent) {
        // Return and the up and down arrows open the menu, as Space does.
        if event.keyCode == 36 || event.keyCode == 125 || event.keyCode == 126 {
            performClick(nil)
        } else {
            super.keyDown(with: event)
        }
    }
}
