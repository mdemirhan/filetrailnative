// Port of FavoriteIconPicker, useSettingsMenu and ApplicationPopup of apps/desktop/src/renderer/components/SettingsView.tsx:
// the icon grid in a system popover, the app pop-up's menu a system menu (D-022)
import AppKit
import FTFoundation

/// The icon of an app at a path, as macOS draws it.
@MainActor
enum SettingsAppIcon {
    static func image(_ path: String) -> NSImage { NSWorkspace.shared.icon(forFile: path) }
}

/// The panels of Settings: the favorite icon grid, in a system popover, one at a time. It takes Escape before the window
/// does, closes on a press elsewhere and when the window goes to the back, and gives the keyboard back to the control
/// that opened it (B-DLG-168, 203, 209). The app menus are system menus (`menus`).
@MainActor
final class SettingsPopovers {
    private(set) var view: NSView?
    private var popover: AnchoredPopover?
    private weak var owner: NSView?
    /// A presenter of its own: Settings isn't an explorer window, and its tests run beside theirs.
    let menus = AppMenuPresenter()

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

    /// The control moved (`resize` and `scroll` listeners).
    func update() {
        if let owner { popover?.reposition(for: owner) }
    }

    /// Closes the panel; with `returnFocus` the control that opened it takes the keyboard.
    func close(returnFocus: Bool) {
        menus.close()
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
        if let window = event.window ?? owner?.window, menus.intercept(event, in: window) { return true }
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
    /// has it, as the original's row selects itself when the button in it is focused.
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
    /// under the pointer: the release that follows at the same place is still on the button (260).
    func beginPress(at location: NSPoint) {
        let before = convert(location, from: nil)
        focusForPress()
        let after = convert(location, from: nil)
        pressShift = NSSize(width: after.x - before.x, height: after.y - before.y)
    }

    /// A press takes the keyboard as the button goes down, as Chromium focuses a clicked button: its row is selected
    /// and the list shows the accent before the grid opens.
    func focusForPress() {
        window?.makeFirstResponder(self)
        onFocusChange()
        revealRow()
    }

    /// The row the press focused, cut by the page's edge, is brought into view: the page goes as far as it can toward
    /// centring it, as Chromium scrolls a focused element in (260: the original's page goes to its end). A row wholly
    /// in view stays where it is.
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

/// A cell of the icon grid: 30 by 30, accent-filled when it is the favorite's icon. The other icons keep
/// `.file-icon-favorite`'s neutral color; only the chosen one takes the accent's ink.
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
        // `.file-icon.favorite`: 18 by 18.
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

/// An app chosen in Settings, shown as a pop-up button with the app's icon (`ApplicationPopup`).
final class SettingsAppPopup: SettingsControlView, SettingsSized {
    private(set) var application: ApplicationSelection
    let defaultApplication: ApplicationSelection
    private let nameText = FlushTextField(labelWithString: "")
    var isExpanded: () -> Bool = { false }
    private static var font: NSFont { ThemeFonts.sans(DesignTokens.typeScale.body) }

    init(label: String, application: ApplicationSelection, defaultApplication: ApplicationSelection, theme: Theme) {
        self.application = application
        self.defaultApplication = defaultApplication
        super.init(theme: theme)
        nameText.font = Self.font
        nameText.lineBreakMode = .byTruncatingTail
        addSubview(nameText)
        setAccessibilityElement(true)
        setAccessibilityRole(.popUpButton)
        setAccessibilityLabel(label)
        setAccessibilityIdentifier("settings.appPopup")
        update(application)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var acceptsFirstResponder: Bool { true }

    func update(_ application: ApplicationSelection) {
        self.application = application
        nameText.stringValue = application.appName
        nameText.textColor = NSColor(theme.palette.textPrimary)
        setAccessibilityValue(application.appName)
        needsLayout = true
        needsDisplay = true
    }

    override func applyTheme(_ theme: Theme) {
        super.applyTheme(theme)
        nameText.textColor = NSColor(theme.palette.textPrimary)
    }

    var isDefault: Bool { application.appPath == defaultApplication.appPath }

    /// The apps the menu offers: the one in use, then the default when it is another.
    var choices: [(application: ApplicationSelection, isDefault: Bool)] {
        isDefault ? [(defaultApplication, true)] : [(application, false), (defaultApplication, true)]
    }

    var preferredSize: NSSize {
        let natural =
            SettingsMetrics.appPopupPaddingLeading + SettingsMetrics.appIconSize + SettingsMetrics.appPopupGap
            + SettingsGlyph.textWidth(application.appName, Self.font) + SettingsMetrics.popupPaddingTrailing
        return NSSize(
            width: min(SettingsMetrics.appPopupMaxWidth, max(SettingsMetrics.popupMinWidth, natural)),
            height: CGFloat(DesignTokens.controlHeights.regular))
    }

    override func layout() {
        super.layout()
        let x = SettingsMetrics.appPopupPaddingLeading + SettingsMetrics.appIconSize + SettingsMetrics.appPopupGap
        let height = nameText.intrinsicContentSize.height
        nameText.frame = NSRect(
            x: x, y: ((bounds.height - height) / 2).rounded(),
            width: max(0, bounds.width - x - SettingsMetrics.popupPaddingTrailing),
            height: height)
    }

    override func draw(_ dirtyRect: NSRect) {
        SettingsGlyph.bezel(in: bounds, theme: theme, hovering: isHovering, pressed: isPressed || isExpanded())
        let size = SettingsMetrics.appIconSize
        SettingsAppIcon.image(application.appPath).draw(
            in: NSRect(
                x: SettingsMetrics.appPopupPaddingLeading, y: (bounds.height - size) / 2, width: size, height: size),
            from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        SettingsGlyph.popupChevron(in: bounds, theme: theme)
    }

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " || event.keyCode == 36 || event.keyCode == 125 {
            press()
        } else {
            super.keyDown(with: event)
        }
    }
}
