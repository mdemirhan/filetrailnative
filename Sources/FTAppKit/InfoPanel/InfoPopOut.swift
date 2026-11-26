import AppKit
import FTFoundation

/// The Info panel in a window of its own: one for the app, beside its windows, an ordinary window that goes behind
/// them as Finder's Inspector does. It describes what the window in front selects: that tab's `InfoController` shows
/// into it (`owner`), and another tab takes it over as it comes to the front. Whether the panel is there or in each
/// window, and whether it is shown, are preferences (`infoPanelPoppedOut`, `infoPanelPopOutShown`): ⌘I shows it the
/// way it was last shown.
@MainActor
final class InfoPopOut: NSObject, NSWindowDelegate {
    static let shared = InfoPopOut()

    let panel = InfoPanelView()
    private(set) var window: InfoPopOutWindow?
    /// The tab whose selection it describes: the one in front, or the last one that was.
    weak var owner: MainWindowController?
    /// The controller whose callbacks the panel calls now.
    weak var wiredBy: InfoController?

    static let defaultSize = NSSize(width: 320, height: 640)
    static let minimumSize = NSSize(width: 260, height: 320)

    override init() {
        super.init()
        panel.isPoppedOut = true
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            // After the activation's own ordering: a click that activated the app brings its window up first.
            DispatchQueue.main.async { MainActor.assumeIsolated { InfoPopOut.shared.appBecameActive() } }
        }
    }

    private var activationObserver: NSObjectProtocol?

    /// The app came to the front from another (⌘Tab, the Dock, a click on one of its windows): the window comes up
    /// with the explorer window it describes, rather than stay behind it or behind another app's windows. Between the
    /// app's own windows it goes behind them as before.
    func appBecameActive() {
        guard let window,
            Self.comesForwardOnActivation(
                isVisible: window.isVisible, isMiniaturized: window.isMiniaturized, key: NSApp.keyWindow,
                described: owner?.window, popOut: window)
        else { return }
        window.orderFront(nil)
    }

    /// Only while it is on screen (not in the Dock, not hidden with the tab it described), and only when the window
    /// with the keyboard is the one it describes: not over Settings, a sheet or an alert in front.
    static func comesForwardOnActivation(
        isVisible: Bool, isMiniaturized: Bool, key: NSWindow?, described: NSWindow?, popOut: NSWindow
    ) -> Bool {
        guard isVisible, !isMiniaturized, let key, let described else { return false }
        return key === described && key !== popOut
    }

    /// On screen or in the Dock: a minimized window is still shown, so nothing brings it back by itself.
    var isShown: Bool { window.map { $0.isVisible || $0.isMiniaturized } ?? false }
    /// Whether it has the keyboard: ⌘I hides it then, and otherwise brings it to the front.
    var isKey: Bool { window?.isKeyWindow == true }

    /// Shows or hides it as the preferences say. `host` is the tab asking: it takes the window over when nothing
    /// holds it.
    func sync(_ preferences: AppPreferences, host: MainWindowController) {
        let wanted = preferences.infoPanelPoppedOut && preferences.infoPanelPopOutShown
        if wanted, owner == nil { owner = host }
        // Never while the app is hidden: it comes back with the app's windows.
        if wanted, !isShown, !NSApp.isHidden {
            show(beside: (owner ?? host).window, focus: false)
        } else if !wanted, isShown {
            hide()
        }
    }

    /// The tab came to the front: the window describes its selection from now on.
    /// The tab it describes went: it hides, the preference staying, until another tab takes it (`follow`, `sync`),
    /// rather than show an item no window has.
    func ownerGone(_ tab: MainWindowController) {
        guard owner === tab else { return }
        owner = nil
        wiredBy = nil
        window?.orderOut(nil)
    }

    func follow(_ tab: MainWindowController) {
        guard owner !== tab else { return }
        let previous = owner
        owner = tab
        previous?.infoController?.update()
        tab.infoController?.update()
    }

    /// On screen, in front of the app's windows; with `focus`, with the keyboard.
    func show(beside reference: NSWindow?, focus: Bool) {
        let window = self.window ?? makeWindow(beside: reference)
        // In the Dock: ⌘I brings it back; nothing else takes it out.
        if window.isMiniaturized {
            guard focus else { return }
            window.deminiaturize(nil)
        }
        if focus {
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFront(nil)
        }
    }

    func hide() {
        window?.saveFrame(usingName: Self.frameName)
        window?.orderOut(nil)
    }

    private func makeWindow(beside reference: NSWindow?) -> InfoPopOutWindow {
        let window = InfoPopOutWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView], backing: .buffered,
            defer: false)
        window.title = "Info"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isFloatingPanel = false
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.minSize = Self.minimumSize
        // Resized and moved, never zoomed or full screen: a panel beside the app's windows.
        // It comes to the Space in front, and beside a window in full screen: it follows the window it describes.
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .fullScreenDisallowsTiling]
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        panel.autoresizingMask = [.width, .height]
        window.contentView = panel
        window.delegate = self
        window.setAccessibilityIdentifier("infoPopOut")
        // Where it was last; the first time, beside the window it is opened from.
        if !window.setFrameUsingName(Self.frameName) {
            window.setFrame(
                Self.frame(beside: reference?.frame, screen: (reference?.screen ?? NSScreen.main)?.visibleFrame),
                display: false)
        }
        window.setFrameAutosaveName(Self.frameName)
        self.window = window
        return window
    }

    static let frameName = "InfoPanel"

    /// Its first place: right of `reference` where there is room on the screen, else left of it, else over its right
    /// edge; as tall as it.
    static func frame(beside reference: NSRect?, screen: NSRect?) -> NSRect {
        let size = defaultSize
        guard let reference, let screen else { return NSRect(origin: .zero, size: size) }
        let height = min(reference.height, screen.height)
        let gap = 8.0
        let x: Double
        if reference.maxX + gap + size.width <= screen.maxX {
            x = reference.maxX + gap
        } else if reference.minX - gap - size.width >= screen.minX {
            x = reference.minX - gap - size.width
        } else {
            x = max(screen.minX, reference.maxX - size.width)
        }
        return NSRect(x: x, y: max(screen.minY, reference.maxY - height), width: size.width, height: height)
    }

    // MARK: NSWindowDelegate

    /// Its size and place are kept as they change, so it opens again where it was, as large as it was.
    func windowDidResize(_ notification: Notification) { window?.saveFrame(usingName: Self.frameName) }
    func windowDidMove(_ notification: Notification) { window?.saveFrame(usingName: Self.frameName) }
    func windowShouldZoom(_ window: NSWindow, toFrame newFrame: NSRect) -> Bool { false }

    /// Its close button hides it, as ⌘I does: the preference says it is hidden.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if let owner {
            owner.updatePreferences { $0.infoPanelPopOutShown = false }
        } else {
            sender.orderOut(nil)
        }
        return false
    }
}

/// The window: never the main window, so the explorer window in front stays the one the menus act on and the one it
/// describes.
final class InfoPopOutWindow: NSPanel {
    override var canBecomeMain: Bool { false }
    override var canBecomeKey: Bool { true }

    /// Tab and Shift-Tab give the keyboard back to the explorer window it describes.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 48,
            event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
            let main = InfoPopOut.shared.owner?.window
        {
            main.makeKeyAndOrderFront(nil)
            return
        }
        super.sendEvent(event)
    }
}
