import AppKit
import Quartz

/// Quick Look's preview of a file that is neither text nor a picture. Quick Look stops the app when its view is closed
/// out of a window, or closed twice, so the view is closed here while it is still in its window, as it leaves it or as
/// the window closes, and made again if the file is shown in a window once more. Nothing closes it on the way out of
/// memory, when it is no longer in a window.
final class QuickLookHost: NSView {
    private(set) var preview: QLPreviewView?

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
        }
        preview?.previewItem = item as NSURL
    }

    private func closePreview() {
        guard let preview else { return }
        self.preview = nil
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
}
