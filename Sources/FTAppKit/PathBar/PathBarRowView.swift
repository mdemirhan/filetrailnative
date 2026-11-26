// The path bar, its editor and the status text
import AppKit
import FTFileSystem
import FTFoundation

/// The status bar under the content and the Info panel: 28 tall with a line on top, the path bar on its left and the status
/// text on its right.
final class PathBarRowView: NSView {
    /// The row's height: a large control's, 28.
    static var height: Double { WindowMetrics.standard.controlHeights.large }
    /// How far the Info Row reaches into the divider.
    static var reach: Double { WindowMetrics.standard.explorer.resizerWidth / 2 }
    /// Padding: 10 on each side.
    static let paddingInline = InfoMetrics.pathRowPaddingInline

    /// Opaque: the path bar lies over the bottom of the content and the Info panel.
    private let backdrop = ContentBackdrop()
    let status = TextBoxField(labelWithString: "")
    /// While the pane shows a file (the viewer): the file's line, language and format in place of the folder's path,
    /// its count and its size. The folder isn't on screen, so neither is a way to go elsewhere in it.
    var fileStatus: String? {
        didSet {
            guard fileStatus != oldValue else { return }
            if fileStatus != nil, isEditing { endEditing(restoreFocus: false) }
            let showsFile = fileStatus != nil
            pathBar.isHidden = showsFile || isEditing
            status.isHidden = showsFile || isEditing
            sizeSlider.isHidden = showsFile || !showsSizeSlider || isEditing
            sizeLabel.isHidden = showsFile || sizeLabel.isHidden
            folderViewButton.isHidden = showsFile || folderViewMark == nil || isEditing
            fileStatusLabel.isHidden = !showsFile
            fileStatusLabel.stringValue = fileStatus ?? ""
            needsLayout = true
        }
    }
    private let fileStatusLabel = TextBoxField(labelWithString: "")
    /// The view's size at the right of the bar: the Icons view's icon size, the Compact List's column width. The
    /// content pane sets its range and value for the view on screen.
    let sizeSlider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    /// The slider moved to a value; `done` once it is let go, or when a click or a key set it.
    var onSizeSlide: (Double, Bool) -> Void = { _, _ in }
    var showsSizeSlider = false {
        didSet {
            guard showsSizeSlider != oldValue else { return }
            sizeSlider.isHidden = !showsSizeSlider || isEditing
            hideSizeValue(animated: false)
            needsLayout = true
        }
    }
    static let sizeSliderWidth = 96.0
    /// The size the slider sets, in points ("64 pt"): it shows over the status text while the slider moves, and fades
    /// shortly after it stops.
    let sizeLabel = TextBoxField(labelWithString: "")
    /// How long the size stays after the slider last moved, in seconds.
    static let sizeValueLinger: TimeInterval = 1.2
    private var sizeValueHide: TimerToken?
    /// What waits out `sizeValueLinger`; tests move it by hand.
    var timers: any TimerScheduling = TaskTimerScheduler()
    var sizeValue = 0 {
        didSet {
            guard sizeValue != oldValue else { return }
            sizeLabel.stringValue = sizeText(sizeValue)
            needsLayout = true
        }
    }
    /// How the size reads: points, or the Previews view's count of previews.
    var sizeText: (Int) -> String = { "\($0) pt" } {
        didSet {
            sizeLabel.stringValue = sizeText(sizeValue)
            needsLayout = true
        }
    }
    /// The gap between the size and its slider.
    static let sizeLabelGap = 6.0

    /// The size shows, in place of the status text, until the slider has been still for `sizeValueLinger`.
    func flashSizeValue() {
        sizeValueHide?.cancel()
        sizeLabel.isHidden = false
        sizeLabel.alphaValue = 1
        status.alphaValue = 0
        sizeValueHide = timers.schedule(after: Self.sizeValueLinger) { [weak self] in
            self?.hideSizeValue(animated: true)
        }
    }

    func hideSizeValue(animated: Bool) {
        sizeValueHide?.cancel()
        sizeValueHide = nil
        guard !sizeLabel.isHidden else {
            status.alphaValue = 1
            return
        }
        guard animated else {
            sizeLabel.isHidden = true
            status.alphaValue = 1
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            sizeLabel.animator().alphaValue = 0
            status.animator().alphaValue = 1
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.sizeValueHide == nil else { return }
                self.sizeLabel.isHidden = true
            }
        }
    }
    /// How the folder's view shows beside the status text (View ▸ Folder View): in the accent when it is the folder's
    /// own, grey when it comes from a folder above, faint when the folder has none (it opens Folder View Options all
    /// the same), with a dot while something of it is unsaved.
    struct FolderViewMark: Equatable {
        enum Whose: Equatable {
            case noView, own, above
        }

        var whose: Whose
        var changed: Bool
        var tooltip: String
    }

    /// Nil: no folder is shown (search results, a pane that let go of its folder), and nothing shows.
    var folderViewMark: FolderViewMark? {
        didSet {
            guard folderViewMark != oldValue else { return }
            folderViewButton.mark = folderViewMark
            folderViewButton.isHidden = folderViewMark == nil || isEditing
            needsLayout = true
        }
    }
    /// The folder view's symbol was clicked.
    var onFolderViewClick: (NSView) -> Void = { _ in }
    let folderViewButton = FolderViewButton()
    /// The symbol's width.
    static let folderViewWidth = 18.0

    let pathBar = PathBarView()
    let editor = PathEditorView()
    private let folderMenu = PathFolderMenuController()
    private var interceptor: Int?
    private weak var interceptedWindow: NSWindow?
    /// Whether the window heard the pointer move before the bar expanded, to go back to once it folds.
    private var windowAcceptedMouseMoves = false

    /// The path the bar shows (the folder on screen).
    var path = "" {
        didSet {
            guard path != oldValue else { return }
            pathBar.cancelPendingClick()
            pathBar.setExpanded(false)
            folderMenu.close()
            if isEditing { endEditing(restoreFocus: false) }
            showSegments()
        }
    }

    /// What the startup disk is called.
    var startupDiskName: () -> String = { VolumePaths.defaultStartupDiskName }

    private(set) var isEditing = false
    var onNavigate: (String) -> Void = { _ in }
    /// Opens a path typed in the editor, which may spell a folder any way; without it a typed path goes to
    /// `onNavigate` as a path of the bar's own does.
    var onTyped: ((String) -> Void)?
    var onOpenInNewTab: (String) -> Void = { _ in }
    var onFocusContent: () -> Void = {}
    var requestFolders: (@MainActor (String) async throws -> [PathbarFolder])? {
        didSet { pathBar.hasFolderMenus = requestFolders != nil }
    }
    var requestSuggestions: @MainActor (String) async -> [PathSuggestionRow] {
        get { editor.requestSuggestions }
        set { editor.requestSuggestions = newValue }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setAccessibilityIdentifier("pathBarRow")
        backdrop.isLifted = true
        addSubview(backdrop)
        status.font = tabularFont(DesignTokens.typeScale.small)
        status.alignment = .left
        status.lineBreakMode = .byTruncatingTail
        status.setAccessibilityIdentifier("statusBar")
        sizeSlider.controlSize = .small
        sizeSlider.isContinuous = true
        sizeSlider.isHidden = true
        sizeSlider.setAccessibilityIdentifier("statusBar.sizeSlider")
        sizeSlider.target = self
        sizeSlider.action = #selector(sizeSlid(_:))
        sizeLabel.font = tabularFont(DesignTokens.typeScale.small)
        sizeLabel.alignment = .right
        sizeLabel.isHidden = true
        sizeLabel.setAccessibilityIdentifier("statusBar.sizeValue")
        addSubview(pathBar)
        addSubview(status)
        fileStatusLabel.font = tabularFont(DesignTokens.typeScale.small)
        fileStatusLabel.lineBreakMode = .byTruncatingTail
        fileStatusLabel.isHidden = true
        fileStatusLabel.setAccessibilityIdentifier("pathBarRow.fileStatus")
        addSubview(fileStatusLabel)
        addSubview(sizeSlider)
        addSubview(sizeLabel)
        folderViewButton.isHidden = true
        folderViewButton.setAccessibilityIdentifier("statusBar.folderView")
        folderViewButton.target = self
        folderViewButton.action = #selector(folderViewClicked(_:))
        addSubview(folderViewButton)
        addSubview(editor)
        editor.isHidden = true
        showSegments()
        pathBar.onNavigate = { [weak self] in self?.onNavigate($0) }
        pathBar.onOpenInNewTab = { [weak self] in self?.onOpenInNewTab($0) }
        pathBar.onEdit = { [weak self] in self?.beginEditing() }
        pathBar.onPress = { [weak self] in self?.onFocusContent() }
        pathBar.onExpandedChange = { [weak self] expanded in self?.expandedChanged(expanded) }
        pathBar.onSeparator = { [weak self] parent, active, button in
            guard let self, let request = self.requestFolders else { return }
            self.folderMenu.toggle(from: button, parent: parent, active: active.path, request: request)
        }
        folderMenu.onNavigate = { [weak self] path in
            self?.pathBar.setExpanded(false)
            self?.onNavigate(path)
        }
        editor.onSubmit = { [weak self] target in
            guard let self else { return }
            self.endEditing(restoreFocus: false)
            (self.onTyped ?? self.onNavigate)(target)
        }
        editor.onClose = { [weak self] in self?.endEditing(restoreFocus: true) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    /// The startup disk was renamed: the segments say its new name.
    func namesChanged() {
        showSegments()
    }

    private func showSegments() {
        let name = startupDiskName()
        let home = DiskPath.home.string
        pathBar.startupDiskName = name
        pathBar.homePath = home
        pathBar.segments = PathBarModel.segments(path, homePath: home, startupDiskName: name)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    @objc private func folderViewClicked(_ sender: NSButton) {
        onFolderViewClick(sender)
    }

    @objc private func sizeSlid(_ slider: NSSlider) {
        let dragging = NSApp.currentEvent?.type == .leftMouseDragged
        onSizeSlide(slider.doubleValue, !dragging)
        flashSizeValue()
    }

    // MARK: Editing

    func beginEditing() {
        guard !isEditing, fileStatus == nil else { return }
        isEditing = true
        folderMenu.close()
        pathBar.isHidden = true
        status.isHidden = true
        sizeSlider.isHidden = true
        folderViewButton.isHidden = true
        hideSizeValue(animated: false)
        editor.isHidden = false
        needsLayout = true
        layoutSubtreeIfNeeded()
        editor.open(currentPath: path)
    }

    private func endEditing(restoreFocus: Bool) {
        guard isEditing else { return }
        isEditing = false
        editor.close()
        editor.isHidden = true
        pathBar.isHidden = false
        status.isHidden = false
        sizeSlider.isHidden = !showsSizeSlider
        folderViewButton.isHidden = folderViewMark == nil
        needsLayout = true
        if restoreFocus { onFocusContent() }
    }

    // MARK: The expanded bar folds back

    private func expandedChanged(_ expanded: Bool) {
        guard let window else { return }
        if expanded {
            // The window hears the pointer move while the bar is expanded, to fold it once the pointer leaves.
            if interceptor == nil { windowAcceptedMouseMoves = window.acceptsMouseMovedEvents }
            window.acceptsMouseMovedEvents = true
            interceptedWindow = window
            interceptor = WindowEventRouting.add(window) { [weak self] event in
                MainActor.assumeIsolated { self?.watch(event) ?? false }
            }
        } else if let interceptor, let interceptedWindow {
            WindowEventRouting.remove(interceptor, from: interceptedWindow)
            self.interceptor = nil
            interceptedWindow.acceptsMouseMovedEvents = windowAcceptedMouseMoves
        }
    }

    private func watch(_ event: NSEvent) -> Bool {
        guard pathBar.expanded else { return false }
        switch event.type {
        case .mouseMoved, .leftMouseDown, .rightMouseDown:
            if pathBar.contains(windowPoint: event.locationInWindow) { return false }
            // A separator's menu belongs to the bar, though it is drawn outside it.
            if folderMenu.isOpen { return false }
            pathBar.setExpanded(false)
            return false
        default:
            return false
        }
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        let left = Self.paddingInline
        if fileStatus != nil {
            // Whatever showed them again meanwhile, the folder's path and its controls stay hidden under a file.
            for view in [pathBar, status, sizeSlider, sizeLabel, folderViewButton, editor] as [NSView] {
                view.isHidden = true
            }
            fileStatusLabel.isHidden = false
            let height = lineBox(fileStatusLabel.font)
            fileStatusLabel.frame = NSRect(
                x: left, y: 1 + ((bounds.height - 1 - height) / 2), width: max(0, bounds.width - left * 2),
                height: height)
            fileStatusLabel.textColor = ChromeColors.color(infoTheme.palette.textSecondary)
            backdrop.frame = NSRect(x: 0, y: 1, width: bounds.width, height: max(0, bounds.height - 1))
            needsDisplay = true
            return
        }
        let contentTop = 1.0
        let contentHeight = bounds.height - contentTop
        // The folder view's symbol takes the right end, where nothing that comes and goes (the slider) moves it, nor
        // the popover that hangs from it; the slider comes next, and the path bar and the status text share the rest.
        var right = bounds.width - Self.paddingInline
        if folderViewMark != nil && !isEditing {
            right -= Self.folderViewWidth
            folderViewButton.frame = NSRect(
                x: right, y: contentTop + ((contentHeight - Self.folderViewWidth) / 2), width: Self.folderViewWidth,
                height: Self.folderViewWidth)
            right -= InfoMetrics.pathRowGap
        }
        if showsSizeSlider && !isEditing {
            let height = sizeSlider.intrinsicContentSize.height
            right -= Self.sizeSliderWidth
            sizeSlider.frame = NSRect(
                x: right, y: contentTop + ((contentHeight - height) / 2), width: Self.sizeSliderWidth,
                height: height)
            // Over the end of the status text, right next to the slider; it takes no room of its own.
            // As wide as the size it shows, and at least the widest in points: "9 at a time" is wider than "600 pt".
            let labelWidth = ceil(
                max(textExtent("600 pt", sizeLabel.font), textExtent(sizeLabel.stringValue, sizeLabel.font)))
            let labelHeight = lineBox(sizeLabel.font)
            sizeLabel.frame = NSRect(
                x: right - Self.sizeLabelGap - labelWidth, y: contentTop + ((contentHeight - labelHeight) / 2),
                width: labelWidth, height: labelHeight)
            right -= InfoMetrics.pathRowGap
        }
        let width = max(0, right - left)
        if isEditing {
            // Where the segments were, short of the right end by its focus ring, which stays in the bar.
            editor.frame = NSRect(
                x: left, y: contentTop, width: max(0, width - DesignTokens.focusRingWidth), height: contentHeight)
        } else {
            let size = NSSize(width: 0, height: lineBox(status.font))
            let text: Double? = status.stringValue.isEmpty ? nil : textExtent(status.stringValue, status.font)
            let split = PathBarModel.rowLayout(contentWidth: width, statusWidth: text)
            pathBar.frame = NSRect(x: left, y: contentTop, width: split.path, height: contentHeight)
            let spacing = InfoMetrics.pathRowGap + InfoMetrics.statusMarginLeft
            status.isHidden = text == nil
            status.frame = NSRect(
                x: left + split.path + spacing, y: contentTop + ((contentHeight - size.height) / 2),
                width: split.status, height: size.height)
        }
        let theme = infoTheme
        status.textColor = ChromeColors.color(theme.palette.textSecondary)
        sizeLabel.textColor = status.textColor
        // Under the 1 pt edge drawn above it.
        backdrop.frame = NSRect(x: 0, y: 1, width: bounds.width, height: max(0, bounds.height - 1))
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        ChromeColors.color(infoTheme.palette.border).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }

    override func mouseDown(with event: NSEvent) { onFocusContent() }

    isolated deinit {
        folderMenu.close()
    }
}

/// The folder view's symbol in the status bar: a folder with a slider, in the accent for the folder's own view, the
/// label's color for one from a folder above and grey for none (it was faint, and easy to miss as the way to the
/// options), with an orange dot while something of it is unsaved.
final class FolderViewButton: NSButton {
    var mark: PathBarRowView.FolderViewMark? {
        didSet {
            guard mark != oldValue else { return }
            toolTip = mark?.tooltip
            setAccessibilityLabel(mark?.tooltip)
            switch mark?.whose {
            case .own: contentTintColor = .controlAccentColor
            case .above: contentTintColor = .labelColor
            case .noView, nil: contentTintColor = .secondaryLabelColor
            }
            needsDisplay = true
        }
    }

    init() {
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageOnly
        let configuration = NSImage.SymbolConfiguration(pointSize: 13.5, weight: .regular)
        image =
            (NSImage(systemSymbolName: "folder.badge.gearshape", accessibilityDescription: "Folder View")
            ?? NSImage(systemSymbolName: "folder", accessibilityDescription: "Folder View"))?
            .withSymbolConfiguration(configuration)
        contentTintColor = .secondaryLabelColor
        setButtonType(.momentaryChange)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard mark?.changed == true else { return }
        let dot = NSRect(x: bounds.maxX - 6, y: isFlipped ? 0 : bounds.maxY - 6, width: 6, height: 6)
        NSColor.windowBackgroundColor.setFill()
        NSBezierPath(ovalIn: dot.insetBy(dx: -1.5, dy: -1.5)).fill()
        NSColor.systemOrange.setFill()
        NSBezierPath(ovalIn: dot).fill()
    }
}
