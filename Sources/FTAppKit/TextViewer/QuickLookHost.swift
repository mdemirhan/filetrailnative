import AppKit
import Quartz
import WebKit

/// Quick Look's preview of a file that is neither text, a picture nor a PDF. Quick Look stops the app when its view is
/// closed out of a window, or closed twice, so the view is closed here while it is still in its window, as it leaves it
/// or as the window closes, and made again if the file is shown in a window once more. Nothing closes it on the way out
/// of memory, when it is no longer in a window.
///
/// What it shows is Quick Look's own: a web view for a Word document or a spreadsheet, a text view for RTF, pages drawn
/// by Quick Look for a presentation. The keyboard, the page keys, the slides and the zoom reach those by what Quick
/// Look's view answers to, some of it not in its headers (`QuickLookPrivate`); a macOS without it shows the preview as
/// before, with none of them.
final class QuickLookHost: NSView {
    private(set) var preview: QLPreviewView?
    /// Told once Quick Look shows what it made of the file, or shows another: what the keys and the zoom reach changed.
    var onLoad: () -> Void = {}
    /// Told as the page or slide shown changes.
    var onPageChange: () -> Void = {}
    private var loadObservation: QuickLookLoadObservation?

    /// The file shown, or none.
    var item: URL? {
        didSet {
            guard item != oldValue else { return }
            show()
        }
    }

    private func show() {
        guard let item else {
            preview?.previewItem = nil
            return
        }
        guard window != nil else { return }
        if preview == nil, let made = QLPreviewView(frame: bounds, style: .normal) {
            made.shouldCloseWithWindow = false
            made.autoresizingMask = [.width, .height]
            addSubview(made)
            preview = made
            loadObservation = QuickLookLoadObservation(made) { [weak self] key in
                if key == QuickLookLoadObservation.pageKey { self?.onPageChange() } else { self?.onLoad() }
            }
        }
        preview?.previewItem = item as NSURL
    }

    private func closePreview() {
        guard let preview else { return }
        self.preview = nil
        loadObservation = nil
        if preview.window != nil { preview.close() }
        preview.removeFromSuperview()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window {
            closePreview()
            NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: nil)
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowWillClose(_:)), name: NSWindow.willCloseNotification, object: window)
        show()
    }

    @objc private func windowWillClose(_ note: Notification) {
        closePreview()
    }

    // MARK: The keyboard

    /// What takes the keyboard: the part of the preview Quick Look gives it to (a document's web view, its text, its
    /// pages), or its view while it loads. The viewer gives it on once Quick Look has loaded (`onLoad`); Quick Look's
    /// own way of doing so would take it from the list beside a viewer that follows it.
    var keyboardView: NSView? {
        guard let preview else { return nil }
        if let inner = QuickLookPrivate.object(preview, "_previewFirstResponder") as? NSView,
            inner.isDescendant(of: preview)
        {
            return inner
        }
        return preview
    }

    /// A web view Quick Look shows the file in: a Word document, a spreadsheet, HTML.
    private var webView: WKWebView? { preview.flatMap { Self.first(WKWebView.self, in: $0) } }
    /// A scroll view Quick Look shows the file in: RTF, an archive's list.
    private var scrollView: NSScrollView? { preview.flatMap { Self.first(NSScrollView.self, in: $0) } }

    private static func first<View: NSView>(_ type: View.Type, in view: NSView) -> View? {
        if let found = view as? View { return found }
        for child in view.subviews {
            if let found = first(type, in: child) { return found }
        }
        return nil
    }

    // MARK: Pages and slides

    /// The pages Quick Look shows one after another, a presentation's slides: 0 for a file it shows otherwise.
    var pageCount: Int {
        guard webView == nil, scrollView == nil, let preview else { return 0 }
        return QuickLookPrivate.int(preview, "numberOfPages") ?? 0
    }

    /// The page or slide shown, from 0.
    var currentPage: Int? { preview.flatMap { QuickLookPrivate.int($0, "currentPage") } }

    /// Shows page `index`, from 0; false where there are no pages to go to.
    func go(toPage index: Int) -> Bool {
        guard let preview, pageCount > 1, (0..<pageCount).contains(index) else { return false }
        QuickLookPrivate.set(preview, "currentPage", index)
        return true
    }

    /// The next slide or page, or one before (`by` negative); false when there are none to step through.
    func step(by count: Int) -> Bool {
        guard let preview, pageCount > 1, let page = QuickLookPrivate.int(preview, "currentPage") else { return false }
        let next = min(max(page + count, 0), pageCount - 1)
        if next == page {
            NSSound.beep()
        } else {
            QuickLookPrivate.set(preview, "currentPage", next)
        }
        return true
    }

    /// Moves what is shown by `pages` of its height, down or up (negative); a presentation steps a slide. False when
    /// nothing in the preview scrolls.
    func scroll(pages: CGFloat) -> Bool {
        if let webView {
            let script =
                "window.scrollBy({top: (window.visualViewport ? visualViewport.height : innerHeight) * (\(pages)), "
                + "behavior: 'instant'})"
            webView.evaluateJavaScript(script)
            return true
        }
        if let scrollView, let document = scrollView.documentView {
            let clip = scrollView.contentView
            var bounds = clip.bounds
            bounds.origin.y += (document.isFlipped ? 1 : -1) * bounds.height * pages
            clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
            scrollView.reflectScrolledClipView(clip)
            return true
        }
        return step(by: pages > 0 ? 1 : -1)
    }

    // MARK: Zoom

    /// How far a document can be zoomed, 1 being as Quick Look shows it.
    static let zooms: ClosedRange<CGFloat> = 0.5...5
    /// Each Zoom In and Zoom Out.
    static let zoomStep: CGFloat = 1.25

    /// The zoom now, nil where the preview has none (a presentation's pages, a movie).
    var zoom: CGFloat? {
        if let webView { return webView.pageZoom }
        if let scrollView { return scrollView.magnification }
        return nil
    }

    /// The zoom at which a document's page is as wide as the pane. Quick Look shows a Word document's pages at a width
    /// of their own, centered in a wider pane; a spreadsheet or a Pages document fills the pane already, at 1.
    var fitZoom: CGFloat? {
        guard zoom != nil else { return nil }
        guard let webView, let centering = webView.superview,
            QuickLookPrivate.double(centering, "scale") != nil,
            let page = (QuickLookPrivate.object(webView, "pageSize") as? NSValue)?.sizeValue, page.width > 0
        else { return 1 }
        return min(max(bounds.width / page.width, Self.zooms.lowerBound), Self.zooms.upperBound)
    }

    /// Zooms the preview; false where it can't be. A web view's page keeps its layout and is drawn larger, as wide as
    /// the pane allows: Quick Look's centering view widens it as its page grows, past which it scrolls sideways.
    func setZoom(_ wanted: CGFloat) -> Bool {
        let value = min(max(wanted, Self.zooms.lowerBound), Self.zooms.upperBound)
        if let webView {
            if let centering = webView.superview { QuickLookPrivate.set(centering, "scale", value) }
            webView.pageZoom = value
            return true
        }
        if let scrollView {
            scrollView.allowsMagnification = true
            scrollView.minMagnification = Self.zooms.lowerBound
            scrollView.maxMagnification = Self.zooms.upperBound
            let visible = scrollView.contentView.bounds
            scrollView.setMagnification(value, centeredAt: NSPoint(x: visible.midX, y: visible.midY))
            return true
        }
        return false
    }
}

/// What Quick Look's view answers to beyond its headers, the calls Finder's Quick Look uses: each is asked whether it
/// is there before it is used, as a call to one that isn't would stop the app.
enum QuickLookPrivate {
    static func object(_ target: NSObject, _ getter: String) -> Any? {
        guard target.responds(to: NSSelectorFromString(getter)) else { return nil }
        return target.value(forKey: getter)
    }

    static func int(_ target: NSObject, _ getter: String) -> Int? {
        (object(target, getter) as? NSNumber)?.intValue
    }

    static func double(_ target: NSObject, _ getter: String) -> Double? {
        (object(target, getter) as? NSNumber)?.doubleValue
    }

    static func set(_ target: NSObject, _ key: String, _ value: Any) {
        let setter = "set" + key.prefix(1).uppercased() + key.dropFirst() + ":"
        guard target.responds(to: NSSelectorFromString(setter)) else { return }
        target.setValue(value, forKey: key)
    }
}

/// Watches which of Quick Look's ways of showing a file its view uses, which changes once it has read the file, and the
/// page it shows. Quick Look changes them on the main thread.
private final class QuickLookLoadObservation: NSObject, @unchecked Sendable {
    static let loadKey = "displayedDisplayBundle"
    static let pageKey = "currentPage"
    private let preview: QLPreviewView
    private let keys: [String]
    private let onChange: @MainActor (String) -> Void

    @MainActor
    init?(_ preview: QLPreviewView, onChange: @escaping @MainActor (String) -> Void) {
        keys = [Self.loadKey, Self.pageKey].filter { preview.responds(to: NSSelectorFromString($0)) }
        guard keys.contains(Self.loadKey) else { return nil }
        self.preview = preview
        self.onChange = onChange
        super.init()
        for key in keys { preview.addObserver(self, forKeyPath: key, options: [], context: nil) }
    }

    deinit {
        for key in keys { preview.removeObserver(self, forKeyPath: key) }
    }

    override func observeValue(
        forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        // After its change: the views it shows the file in are in place once this returns.
        let key = keyPath ?? ""
        Task { @MainActor [weak self] in self?.onChange(key) }
    }
}
