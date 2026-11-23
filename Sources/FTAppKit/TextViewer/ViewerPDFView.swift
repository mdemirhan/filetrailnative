import AppKit
import PDFKit

/// A PDF shown by the viewer itself, as Preview shows one: its pages one under another, at the pane's width when it
/// opens. It zooms, fits a whole page in the pane, and goes a page at a time with ← and → while the page is no wider than
/// the pane.
final class ViewerPDFView: PDFView {
    /// The scale changed, or the page shown: the menus and the pane's bottom bar say so.
    var onChange: () -> Void = {}
    /// How the pages are sized: to the pane's width, a whole page in the pane, or a scale chosen.
    private(set) var fit = Fit.width
    /// The scale this view set last: one it didn't set came from a pinch.
    private var scaleSet: CGFloat?

    enum Fit { case width, page, none }

    override init(frame: NSRect) {
        super.init(frame: frame)
        displayMode = .singlePageContinuous
        displaysPageBreaks = true
        autoScales = true
        minScaleFactor = 0.1
        maxScaleFactor = 8
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(scaleChanged), name: .PDFViewScaleChanged, object: self)
        center.addObserver(self, selector: #selector(pageChanged), name: .PDFViewPageChanged, object: self)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Shows `document` at the pane's width, or where the one before was (`keepingPlace`: the same file read again).
    func show(_ document: PDFDocument?, keepingPlace: Bool) {
        let place = keepingPlace ? (page: currentPage.flatMap { self.document?.index(for: $0) }, fit, scaleFactor) : nil
        self.document = document
        guard let place, let document else {
            fitWidth()
            return
        }
        switch place.1 {
        case .width: fitWidth()
        case .page: fitPage()
        case .none: setScale(place.2)
        }
        if let index = place.page, index < document.pageCount, let page = document.page(at: index) { go(to: page) }
    }

    // MARK: Zoom

    /// Which of Zoom In, Zoom Out, Actual Size and Zoom to Fit would change what shows.
    var canZoomInNow: Bool { document != nil && canZoomIn }
    var canZoomOutNow: Bool { document != nil && canZoomOut }
    var isActualSize: Bool { abs(scaleFactor - 1) < 0.005 }
    var fitsPage: Bool { fit == .page && abs(scaleFactor - pageFitScale) < 0.005 }

    func zoomInStep() {
        let page = currentPage
        zoomIn(nil)
        fixedAfterZoom(on: page)
    }

    func zoomOutStep() {
        let page = currentPage
        zoomOut(nil)
        fixedAfterZoom(on: page)
    }

    func actualSize() {
        let page = currentPage
        setScale(1)
        fixedAfterZoom(on: page)
    }

    /// A whole page in the pane, the one most of the pane shows.
    func fitPage() {
        let page = currentPage
        autoScales = false
        fit = .page
        set(pageFitScale)
        if let page { go(to: page) }
        onChange()
    }

    private func fitWidth() {
        fit = .width
        scaleSet = nil
        autoScales = true
        onChange()
    }

    private func setScale(_ scale: CGFloat) {
        autoScales = false
        fit = .none
        set(scale)
    }

    private func set(_ scale: CGFloat) {
        let scale = min(max(scale, minScaleFactor), maxScaleFactor)
        scaleSet = scale
        scaleFactor = scale
    }

    private func fixedAfterZoom(on page: PDFPage?) {
        autoScales = false
        fit = .none
        scaleSet = scaleFactor
        if let page, currentPage != page { go(to: page) }
        onChange()
    }

    /// The scale at which the page shown fits the pane whole, its margins in.
    private var pageFitScale: CGFloat {
        guard let page = currentPage ?? document?.page(at: 0) else { return 1 }
        var size = page.bounds(for: displayBox).size
        if page.rotation % 180 != 0 { size = NSSize(width: size.height, height: size.width) }
        let margins = pageBreakMargins
        let room = NSSize(
            width: bounds.width - margins.left - margins.right, height: bounds.height - margins.top - margins.bottom)
        guard size.width > 0, size.height > 0, room.width > 0, room.height > 0 else { return 1 }
        return min(room.width / size.width, room.height / size.height)
    }

    override func layout() {
        super.layout()
        // A page kept whole in the pane stays whole as the pane is resized.
        if fit == .page, abs(scaleFactor - pageFitScale) > 0.005 { set(pageFitScale) }
    }

    @objc private func scaleChanged() {
        // A pinch: the scale is the one chosen from then on.
        if fit != .width, let scaleSet, abs(scaleSet - scaleFactor) > 0.005 {
            fit = .none
            self.scaleSet = scaleFactor
        } else if fit == .width, !autoScales {
            fit = .none
        }
        onChange()
    }

    @objc private func pageChanged() { onChange() }

    // MARK: Moving

    /// Moves the pages by `pages` of the pane's height, down or up (negative).
    func scroll(pages: CGFloat) {
        guard let scrollView = documentView?.enclosingScrollView, let document = scrollView.documentView else {
            _ = pages > 0 ? goToNextPage(nil) : goToPreviousPage(nil)
            return
        }
        let clip = scrollView.contentView
        var bounds = clip.bounds
        bounds.origin.y += (document.isFlipped ? 1 : -1) * bounds.height * pages
        clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
        scrollView.reflectScrolledClipView(clip)
    }

    /// The page after or before the one shown, while the page is no wider than the pane: wider, ← and → move it sideways
    /// as they would. False when they are left to the view.
    func stepPage(forward: Bool) -> Bool {
        guard let scrollView = documentView?.enclosingScrollView, let document = scrollView.documentView else {
            return false
        }
        if document.frame.width > scrollView.contentView.bounds.width + 1 { return false }
        if forward ? canGoToNextPage : canGoToPreviousPage {
            _ = forward ? goToNextPage(nil) : goToPreviousPage(nil)
        } else {
            NSSound.beep()
        }
        return true
    }
}
