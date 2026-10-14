// Port of the .content-pathbar-row of apps/desktop/src/renderer/components/ContentPane.tsx (:677-857): the path bar, its
// editor and the status text
import AppKit
import FTFoundation

/// The row under the list: 28 tall with a line on top, the path bar on its left and the status text on its right. It starts
/// in the half of the divider past the hairline (4 pt left of the content), so its line reaches the hairline, and keeps its
/// contents where they were.
final class PathBarRowView: NSView {
    /// `.content-pathbar-row { height: 28px }`.
    static var height: Double { WindowMetrics.standard.controlHeights.large }
    /// How far it reaches into the divider.
    static var reach: Double { WindowMetrics.standard.explorer.resizerWidth / 2 }
    /// Padding: 10 on each side, plus the reach on the left.
    static let paddingInline = InfoMetrics.pathRowPaddingInline

    let status = NSTextField(labelWithString: "")
    let pathBar = PathBarView()
    let editor = PathEditorView()
    private let folderMenu = PathFolderMenuController()
    private var interceptor: Int?
    private weak var interceptedWindow: NSWindow?

    /// The path the bar shows (the folder on screen).
    var path = "" {
        didSet {
            guard path != oldValue else { return }
            pathBar.cancelPendingClick()
            pathBar.setExpanded(false)
            folderMenu.close()
            if isEditing { endEditing(restoreFocus: false) }
            pathBar.segments = PathBarModel.segments(path)
        }
    }

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
        status.font = tabularFont(DesignTokens.typeScale.small)
        status.alignment = .left
        status.lineBreakMode = .byTruncatingTail
        status.setAccessibilityIdentifier("statusBar")
        addSubview(pathBar)
        addSubview(status)
        addSubview(editor)
        editor.isHidden = true
        pathBar.segments = PathBarModel.segments(path)
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

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    // MARK: Editing

    func beginEditing() {
        guard !isEditing else { return }
        isEditing = true
        folderMenu.close()
        pathBar.isHidden = true
        status.isHidden = true
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
        needsLayout = true
        if restoreFocus { onFocusContent() }
    }

    // MARK: The expanded bar folds back

    private func expandedChanged(_ expanded: Bool) {
        guard let window else { return }
        if expanded {
            window.acceptsMouseMovedEvents = true
            interceptedWindow = window
            interceptor = WindowEventRouting.add(window) { [weak self] event in
                MainActor.assumeIsolated { self?.watch(event) ?? false }
            }
        } else if let interceptor, let interceptedWindow {
            WindowEventRouting.remove(interceptor, from: interceptedWindow)
            self.interceptor = nil
        }
    }

    private func watch(_ event: NSEvent) -> Bool {
        guard pathBar.expanded else { return false }
        switch event.type {
        case .mouseMoved, .leftMouseDown, .rightMouseDown:
            if pathBar.contains(windowPoint: event.locationInWindow) { return false }
            // A separator's menu belongs to the bar, though it is drawn outside it.
            if let menu = window?.contentView?.hitTest(event.locationInWindow)?.enclosingMenuItemView, menu { return false }
            pathBar.setExpanded(false)
            return false
        default:
            return false
        }
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        let left = Self.reach + Self.paddingInline
        let width = max(0, bounds.width - left - Self.paddingInline)
        let contentTop = 1.0
        let contentHeight = bounds.height - contentTop
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
                x: left + split.path + spacing, y: contentTop + ((contentHeight - size.height) / 2), width: split.status,
                height: size.height)
        }
        let theme = infoTheme
        status.textColor = ChromeColors.color(theme.palette.textSecondary)
        layer?.backgroundColor = ChromeColors.color(theme.palette.bgBase).cgColor
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

extension NSView {
    /// Whether the view is inside a path bar folder menu.
    fileprivate var enclosingMenuItemView: Bool? {
        var current: NSView? = self
        while let view = current {
            if view is PathFolderMenuView { return true }
            current = view.superview
        }
        return false
    }
}
