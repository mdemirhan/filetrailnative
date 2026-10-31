// Port of createPageBrowserWindow and showPageWindow in apps/desktop/src/main/main.ts (the window around a page of the
// renderer: Help, About, Acknowledgements, Settings)
import AppKit
import FTFoundation

/// A window whose title bar is transparent and whose content runs under it, with the traffic lights where the original
/// puts them. Escape closes it when `closesOnEscape` (the windows that are only read).
public final class PageWindow: NSWindow {
    public var closesOnEscape = false
    private let firstClickGate = FirstClickGate()

    public override func sendEvent(_ event: NSEvent) {
        if firstClickGate.keepsBack(event, in: self) { return }
        super.sendEvent(event)
    }

    public override func cancelOperation(_ sender: Any?) {
        if closesOnEscape { performClose(sender) } else { super.cancelOperation(sender) }
    }
}

/// What a page window is: its title and sizes.
public struct PageWindowSpec: Equatable, Sendable {
    public var title: String
    /// The content size (`useContentSize`), or the window's size for a window with no frame of its own to count.
    public var size: NSSize
    public var minSize: NSSize?
    public var resizable: Bool
    public var minimizable: Bool
    /// Where the traffic lights go, from the window's top left.
    public var trafficLights: NSPoint

    public init(
        title: String, size: NSSize, minSize: NSSize? = nil, resizable: Bool = true, minimizable: Bool = true,
        trafficLights: NSPoint = NSPoint(x: 16, y: 18)
    ) {
        self.title = title
        self.size = size
        self.minSize = minSize
        self.resizable = resizable
        self.minimizable = minimizable
        self.trafficLights = trafficLights
    }
}

/// A window of the app other than an explorer window, with the theme's background and a content view that follows the
/// theme while it is open.
@MainActor
public class PageWindowController: NSWindowController, NSWindowDelegate {
    public let model: AppearanceModel
    public let spec: PageWindowSpec
    private var observation: AppearanceModel.Observation?
    private var buttonSpacing: CGFloat?
    /// Told when the window closes, so its opener can forget it.
    public var onClose: () -> Void = {}
    /// Off, `present()` keeps the window off the screen (windowless tests: it is made, laid out and read).
    var ordersWindow = true
    /// Whether `present()` has been asked, shown on screen or not.
    private(set) var wasPresented = false

    public init(spec: PageWindowSpec, model: AppearanceModel = .shared) {
        self.spec = spec
        self.model = model
        var style: NSWindow.StyleMask = [.titled, .closable, .fullSizeContentView]
        if spec.resizable { style.insert(.resizable) }
        if spec.minimizable { style.insert(.miniaturizable) }
        let window = PageWindow(
            contentRect: NSRect(origin: .zero, size: spec.size), styleMask: style, backing: .buffered, defer: true)
        window.title = spec.title
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        // Not full-screenable, as `fullscreenable: false`.
        window.collectionBehavior.insert(.fullScreenNone)
        if let minSize = spec.minSize { window.contentMinSize = minSize }
        if !spec.minimizable { window.standardWindowButton(.miniaturizeButton)?.isEnabled = false }
        if !spec.resizable { window.standardWindowButton(.zoomButton)?.isEnabled = false }
        super.init(window: window)
        window.delegate = self
        model.register(pageWindow: window)
        observation = model.observe { [weak self] theme in self?.themeChanged(theme) }
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Shows the window in front, centered the first time.
    public func present() {
        wasPresented = true
        guard ordersWindow, let window else { return }
        if !window.isVisible, window.frameAutosaveName.isEmpty { window.center() }
        positionTrafficLights()
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        positionTrafficLights()
    }

    /// The theme changed: everything in the window redraws with it.
    func themeChanged(_ theme: Theme) {
        window?.contentView?.applyTheme(theme, throughSubviews: true)
    }

    // MARK: Traffic lights

    /// The traffic lights at `spec.trafficLights` from the top left (`trafficLightPosition`), as `hiddenInset` puts them.
    func positionTrafficLights() {
        guard let window else { return }
        let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        let buttons = types.compactMap { window.standardWindowButton($0) }
        guard buttons.count == 3, let container = buttons[0].superview else { return }
        let spacing = buttonSpacing ?? (buttons[1].frame.minX - buttons[0].frame.minX)
        buttonSpacing = spacing
        for (index, button) in buttons.enumerated() {
            button.setFrameOrigin(
                NSPoint(
                    x: spec.trafficLights.x + CGFloat(index) * spacing,
                    y: container.bounds.height - spec.trafficLights.y - button.frame.height))
        }
    }

    public func windowDidResize(_ notification: Notification) { positionTrafficLights() }
    public func windowDidBecomeKey(_ notification: Notification) { positionTrafficLights() }
    public func windowDidExitFullScreen(_ notification: Notification) { positionTrafficLights() }

    public func windowWillClose(_ notification: Notification) {
        observation?.cancel()
        onClose()
    }
}

extension ThemeFonts {
    /// The height of a line of this font with `line-height: normal`, as Chromium measures the system font: the ascent
    /// (0.952 em) and the descent (0.24 em), each rounded.
    public static func normalLineHeight(_ font: NSFont) -> CGFloat {
        (font.pointSize * 0.952).rounded() + (font.pointSize * 0.24).rounded()
    }
}
