import AppKit
import PDFKit

/// A PDF shown by the viewer itself, as Preview shows one: its pages one under another, at the pane's width when it
/// opens and again with Zoom to Fit, kept so as the pane is resized. It zooms, and goes a page at a time with ← and →
/// while the page is no wider than the pane.
final class ViewerPDFView: PDFView {
    /// The scale changed, or the page shown: the menus and the pane's bottom bar say so.
    var onChange: () -> Void = {}
    /// How the pages are sized: to the pane's width, or a scale chosen.
    private(set) var fit = Fit.width
    /// The scale this view set last: one it didn't set came from a pinch.
    private var scaleSet: CGFloat?
    /// ↑ and ↓ glide, as a web view's do; PDFKit's own move a line for each key repeat.
    private lazy var keyScroller = ViewerKeyScroller { [weak self] in self?.documentView?.enclosingScrollView }

    enum Fit { case width, none }

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
        keyScroller.stop()
        let place = keepingPlace ? (page: currentPage.flatMap { self.document?.index(for: $0) }, fit, scaleFactor) : nil
        self.document = document
        guard let place, let document else {
            fitWidth()
            toTop()
            return
        }
        switch place.1 {
        case .width: fitWidth()
        case .none: setScale(place.2)
        }
        if let index = place.page, index < document.pageCount, let page = document.page(at: index) { go(to: page) }
    }

    // MARK: Zoom

    /// Which of Zoom In, Zoom Out, Actual Size and Zoom to Fit would change what shows.
    var canZoomInNow: Bool { document != nil && canZoomIn }
    var canZoomOutNow: Bool { document != nil && canZoomOut }
    var isActualSize: Bool { abs(scaleFactor - 1) < 0.005 }
    var fitsWidth: Bool { fit == .width && autoScales }

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

    /// The pages as wide as the pane, as a PDF opens, on the page the pane shows most of.
    func fitWidth() {
        let page = currentPage
        fit = .width
        scaleSet = nil
        autoScales = true
        if let page, currentPage != page { go(to: page) }
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

    /// A plain arrow key, before PDFKit sees it: true when it glides the pages.
    func arrowKeyDown(_ event: NSEvent) -> Bool {
        document != nil && keyScroller.keyDown(event)
    }

    func arrowKeyUp(_ event: NSEvent) { keyScroller.keyUp(event) }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { keyScroller.stop() }
        super.viewWillMove(toWindow: newWindow)
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

    // MARK: Find

    /// The matches found of what is looked for, in the order of the pages, and the one shown.
    private(set) var matches: [PDFSelection] = []
    private(set) var matchIndex: Int?
    /// Looking for text, which is done a page at a time off the main thread.
    private(set) var isFinding = false
    /// The matches or the one shown changed.
    var onFindChange: () -> Void = {}
    private var findObservers: [NSObjectProtocol] = []

    /// Looks for `text`, without regard to case or accents; the first match is shown once found. Empty stops.
    func find(_ text: String) {
        stopFinding()
        guard let document, !text.isEmpty else {
            onFindChange()
            return
        }
        let center = NotificationCenter.default
        findObservers = [
            center.addObserver(forName: .PDFDocumentDidFindMatch, object: document, queue: .main) { [weak self] note in
                // Told on the main queue, as asked.
                nonisolated(unsafe) let note = note
                MainActor.assumeIsolated {
                    self?.found(note.userInfo?["PDFDocumentFoundSelection"] as? PDFSelection)
                }
            },
            center.addObserver(forName: .PDFDocumentDidEndFind, object: document, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.endedFinding() }
            },
        ]
        isFinding = true
        document.beginFindString(text, withOptions: [.caseInsensitive, .diacriticInsensitive])
        onFindChange()
    }

    private func found(_ selection: PDFSelection?) {
        guard let selection else { return }
        selection.color = NSColor.findHighlightColor.withAlphaComponent(0.55)
        matches.append(selection)
        // Marked a page's worth at a time, not one by one, which would draw the pages again for each.
        if matches.count == 1 || matches.count % 50 == 0 { highlightedSelections = matches }
        if matchIndex == nil { showMatch(0) } else { onFindChange() }
    }

    private func endedFinding() {
        isFinding = false
        highlightedSelections = matches.isEmpty ? nil : matches
        onFindChange()
    }

    /// The next match, or the one before; it goes round at the ends. Beeps with none.
    func stepMatch(forward: Bool) {
        guard !matches.isEmpty else {
            NSSound.beep()
            return
        }
        let index = matchIndex.map { ($0 + (forward ? 1 : -1) + matches.count) % matches.count } ?? 0
        showMatch(index)
    }

    private func showMatch(_ index: Int) {
        matchIndex = index
        let match = matches[index]
        setCurrentSelection(match, animate: false)
        go(to: match)
        onFindChange()
    }

    /// Stops looking, and takes the marks away.
    func stopFinding() {
        for observer in findObservers { NotificationCenter.default.removeObserver(observer) }
        findObservers = []
        if isFinding { document?.cancelFindString() }
        isFinding = false
        matches = []
        matchIndex = nil
        highlightedSelections = nil
        clearSelection()
    }

    // MARK: The zoom kept for the next file

    /// The zoom chosen, to show the next PDF at: nil while it is at the pane's width, as a PDF opens.
    var keptZoom: KeptZoom? {
        switch fit {
        case .width: nil
        case .none: .scale(scaleFactor)
        }
    }

    func apply(_ kept: KeptZoom?) {
        switch kept {
        case nil, .fit: break
        case .scale(let scale):
            setScale(scale)
            toTop()
            onChange()
        }
    }

    /// The top of the first page, at its left edge. PDFKit keeps another place as the scale it opens at is set: the
    /// first page's top was cut off by about a sixth of its height.
    private func toTop() {
        layoutDocumentView()
        guard let scrollView = documentView?.enclosingScrollView, let pages = scrollView.documentView else { return }
        let clip = scrollView.contentView
        var bounds = clip.bounds
        bounds.origin = NSPoint(
            x: pages.bounds.minX, y: pages.isFlipped ? pages.bounds.minY : pages.bounds.maxY - bounds.height)
        clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
        scrollView.reflectScrolledClipView(clip)
    }
}

/// A zoom kept from one file to the next of its kind as the viewer steps through a folder: a fit, or a scale.
enum KeptZoom: Equatable {
    case fit
    case scale(CGFloat)
}
