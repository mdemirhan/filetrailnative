// The path bar, its editor and the status text
import AppKit
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
            sizeLabel.stringValue = "\(sizeValue) pt"
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
        addSubview(sizeSlider)
        addSubview(sizeLabel)
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
            self.onNavigate(target)
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
        pathBar.startupDiskName = name
        pathBar.segments = PathBarModel.segments(path, homePath: NSHomeDirectory(), startupDiskName: name)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    @objc private func sizeSlid(_ slider: NSSlider) {
        let dragging = NSApp.currentEvent?.type == .leftMouseDragged
        onSizeSlide(slider.doubleValue, !dragging)
        flashSizeValue()
    }

    // MARK: Editing

    func beginEditing() {
        guard !isEditing else { return }
        isEditing = true
        folderMenu.close()
        pathBar.isHidden = true
        status.isHidden = true
        sizeSlider.isHidden = true
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
        let contentTop = 1.0
        let contentHeight = bounds.height - contentTop
        // The slider takes the right end; the path bar and the status text share what is left of it.
        var right = bounds.width - Self.paddingInline
        if showsSizeSlider && !isEditing {
            let height = sizeSlider.intrinsicContentSize.height
            right -= Self.sizeSliderWidth
            sizeSlider.frame = NSRect(
                x: right, y: contentTop + ((contentHeight - height) / 2), width: Self.sizeSliderWidth,
                height: height)
            // Over the end of the status text, right next to the slider; it takes no room of its own.
            let labelWidth = ceil(textExtent("600 pt", sizeLabel.font))
            let labelHeight = lineBox(sizeLabel.font)
            sizeLabel.frame = NSRect(
                x: right - Self.sizeLabelGap - labelWidth, y: contentTop + ((contentHeight - labelHeight) / 2),
                width: labelWidth, height: labelHeight)
            right -= InfoMetrics.pathRowGap
        }
        let width = max(0, right - left)
        if isEditing {
            editor.frame = NSRect(x: left, y: contentTop, width: width, height: contentHeight)
        } else {
            let size = NSSize(width: 0, height: lineBox(status.font))
            let natural: Double? = status.stringValue.isEmpty ? nil : textExtent(status.stringValue, status.font)
            let split = PathBarModel.rowLayout(contentWidth: width, statusWidth: natural)
            pathBar.frame = NSRect(x: left, y: contentTop, width: split.path, height: contentHeight)
            let spacing = InfoMetrics.pathRowGap + InfoMetrics.statusMarginLeft
            status.isHidden = natural == nil
            status.frame = NSRect(
                x: left + split.path + spacing, y: contentTop + ((contentHeight - size.height) / 2),
                width: split.status,
                height: size.height)
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
