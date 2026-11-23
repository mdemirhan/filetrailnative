import AppKit
import FTFileSystem
import FTFoundation

/// A file shown in a pane: its text with colors, read or edited, or Quick Look's preview of a file that isn't text. It
/// takes the place of the pane's list (`ContentPaneController.showViewer`).
@MainActor
final class TextViewerController: NSViewController, NSTextViewDelegate {
    typealias Mode = ViewerPreference.Mode

    var mode: Mode {
        didSet { refreshChrome() }
    }
    /// The pane was opened for the viewer, and closes with it.
    var ownsPane = false
    private(set) var path: String?
    private(set) var file: ViewerFile?
    /// How the file shown went while it was shown: moved to the Trash, or nowhere it can be found. Nil while it is
    /// there.
    private(set) var gone: GoneFile?

    enum GoneFile: Equatable, Sendable {
        /// Found in the Trash.
        case trashed
        /// Not found: deleted, moved to another disk, or renamed or moved by another app on a disk that can't tell
        /// where a file went (exFAT, FAT32). Which of these isn't known, and the viewer doesn't say.
        case missing
    }
    private(set) var isEditing = false
    private(set) var isDirty = false
    /// The text as the file has it: Undo back to it leaves nothing to save.
    private var savedText: NSString = ""
    /// Markdown shows its preview while reading.
    private(set) var showsPreview = true
    /// The file's place among the folder's files, for a file in place: "3 of 12".
    var position: (index: Int, count: Int)? {
        didSet { refreshChrome() }
    }
    var settings: TextViewerSettings {
        didSet { if settings != oldValue { applyLook() } }
    }

    /// Esc in Read, Close Viewer: the pane shows its folder again.
    var onClose: () -> Void = {}
    var onPrevious: () -> Void = {}
    var onNext: () -> Void = {}
    /// Follow turned on or off, for a viewer beside the list.
    var onFollowChange: (Bool) -> Void = { _ in }
    /// What the menus show changed: the file, Read or Edit, unsaved edits, the mode.
    var onStateChange: () -> Void = {}
    var onSettingsChange: (TextViewerSettings) -> Void = { _ in }
    /// Read or Edit chosen by hand: the pane's from then on.
    var onEditingChosen: (Bool) -> Void = { _ in }
    /// What a file opens to, Edit or Read, where nothing else says: its pane's.
    var opensForEditing: Bool
    var onOpenInEditor: (String) -> Void = { _ in }
    var onFocusChange: () -> Void = {}
    /// The line, column, language and format, for the pane's bottom bar.
    var onStatusChange: (String) -> Void = { _ in }
    /// Tab in Read: on to the next pane, as Tab in a list.
    var onTab: () -> Void = {}
    /// The file shown was moved or renamed, by this app or another: the path it was shown by, and the one it has now.
    var onMoved: (_ from: String, _ to: String) -> Void = { _, _ in }
    /// The file shown went: to the Trash, deleted, or moved to another disk.
    var onGone: () -> Void = {}
    /// The command of the app's own keys a key press is, if any: the page keys move the text; Save, Next File and
    /// Previous File are the viewer's.
    var commandForKey: (NSEvent) -> ShortcutCommandID? = { _ in nil }
    /// A command's key as Settings → Shortcuts has it, written as the menus write it ("⌘S"), for the ⋯ menu.
    var keyLabel: (ShortcutCommandID) -> String? = { ShortcutDisplay.defaults.label($0) }
    /// Nil until the first is told: even an empty one hides the folder's path.
    private var lastStatus: String?

    private var language = TextLanguage.plainText
    private var format = TextFormat()
    private var indentation: Indentation?
    private var knownModified: Date?
    private var loadNumber = 0
    private var stopWatching: (@Sendable () -> Void)?
    private var themeObservation: AppearanceModel.Observation?

    private let header = ViewerHeaderView()
    private let body = NSView()
    private let conflictBar = ViewerConflictBar()
    let scrollView = NSScrollView()
    let textView: ViewerTextView
    private var ruler: LineNumberRuler!
    private var coloring: SyntaxColoring!
    private let previewScroll = NSScrollView()
    /// TextKit 1, as a Markdown table is drawn with `NSTextTable`, which TextKit 2 doesn't lay out. It takes the keys
    /// of the text in Read: Return is Edit, and the page keys move it.
    let previewView = ViewerTextView(usingTextLayoutManager: false)
    /// The pictures the Markdown names, read from the disk as the Preview finds them: the text shows first, and the
    /// Preview is drawn again with them.
    private var previewImages = MarkdownImages()
    /// The file was read again after it changed on disk: its pictures are read again too, and the ones read before
    /// stay in the Preview until then, so it keeps its place.
    private var previewImagesAreStale = false
    /// Where the source and the Preview were after the last switch between them, and the text's changes then: one
    /// switched back to, with nothing scrolled or changed since, is where it was.
    private var switchPlace: (source: CGFloat, preview: CGFloat, changes: Int)?
    /// The text's changes, typed or read again.
    private var changes = 0
    /// The file whose pictures are being read (its `loadNumber`), so one read goes at a time.
    private var readingImagesFor: Int?
    /// What the Markdown Preview shows.
    var previewText: NSAttributedString { previewView.attributedString() }
    let quickLook = QuickLookHost()
    private let message = ViewerMessageView()
    /// A picture is drawn by the viewer itself; other files that aren't text by Quick Look's view.
    private let imageView = NSImageView()

    /// `opensForEditing`: its pane's Read or Edit.
    init(mode: Mode, settings: TextViewerSettings, opensForEditing: Bool) {
        self.mode = mode
        self.settings = settings
        self.opensForEditing = opensForEditing
        let storage = NSTextStorage()
        let manager = NSLayoutManager()
        manager.allowsNonContiguousLayout = true
        storage.addLayoutManager(manager)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        manager.addTextContainer(container)
        textView = ViewerTextView(frame: .zero, textContainer: container)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    isolated deinit {
        stopWatching?()
    }

    override func loadView() {
        let root = ViewerRootView()
        root.setAccessibilityIdentifier("textViewer")
        root.onLayout = { [weak self] in self?.layoutViews() }
        view = root

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.isVerticallyResizable = true
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        textView.delegate = self
        textView.setAccessibilityIdentifier("textViewer.text")
        textView.onCancel = { [weak self] in self?.cancel() ?? false }
        textView.onTab = { [weak self] in self?.onTab() }
        // Return and Esc switch for this file only; the Read and Edit switch is what a next file opens in.
        textView.onEdit = { [weak self] in self?.setEditing(true) }
        textView.commandForKey = { [weak self] event in self?.commandForKey(event) }
        textView.onFocusChange = { [weak self] in self?.onFocusChange() }

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.borderType = .noBorder
        // The pane's own room: no inset for a title bar the viewer isn't under.
        scrollView.automaticallyAdjustsContentInsets = false
        previewScroll.automaticallyAdjustsContentInsets = false
        ruler = LineNumberRuler(textView: textView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        coloring = SyntaxColoring(textView: textView, language: .plainText, theme: currentTheme)
        coloring.onLinesChanged = { [weak self] in
            self?.ruler.linesChanged()
            self?.refreshFooter()
        }
        ruler.coloring = coloring

        previewView.isEditable = false
        previewView.isSelectable = true
        previewView.setAccessibilityIdentifier("textViewer.previewText")
        previewView.onCancel = { [weak self] in self?.cancel() ?? false }
        previewView.onTab = { [weak self] in self?.onTab() }
        previewView.onEdit = { [weak self] in self?.setEditing(true) }
        previewView.commandForKey = { [weak self] event in self?.commandForKey(event) }
        previewView.onFocusChange = { [weak self] in self?.onFocusChange() }
        previewView.textContainerInset = NSSize(width: 24, height: 18)
        previewView.isVerticallyResizable = true
        previewView.minSize = .zero
        previewView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        previewView.autoresizingMask = [.width]
        previewView.textContainer?.widthTracksTextView = true
        previewScroll.documentView = previewView
        previewScroll.hasVerticalScroller = true
        previewScroll.autohidesScrollers = true

        body.wantsLayer = true
        // The line numbers draw past the text's last line otherwise, over the pane's bottom bar.
        body.clipsToBounds = true
        body.addSubview(scrollView)
        body.addSubview(previewScroll)
        body.addSubview(message)
        body.addSubview(imageView)
        body.addSubview(quickLook)
        quickLook.isHidden = true
        imageView.imageScaling = .scaleProportionallyDown
        imageView.isHidden = true
        imageView.setAccessibilityIdentifier("textViewer.image")
        root.addSubview(header)
        root.addSubview(conflictBar)
        root.addSubview(body)
        conflictBar.isHidden = true
        conflictBar.onKeepMine = { [weak self] in self?.keepMine() }
        conflictBar.onUseDisk = { [weak self] in self?.useFileOnDisk() }

        header.onAction = { [weak self] action in self?.perform(action) }
        root.onKey = { [weak self] event in self?.handleKey(event) ?? false }
        root.onCancel = { [weak self] in self?.cancel() ?? false }
        root.onTab = { [weak self] in self?.onTab() }
        root.onFocusChange = { [weak self] in self?.onFocusChange() }
        message.onOpenInEditor = { [weak self] in
            if let path = self?.path { self?.onOpenInEditor(path) }
        }
        themeObservation = AppearanceModel.shared.observe { [weak self] _ in self?.applyLook() }
        applyLook()
        showMessage(.empty)
    }

    // MARK: Showing a file

    var fileName: String? { path.map(NodePath.basename) }

    /// What is read, saved and watched: the file shown, or the original of a symbolic link or an alias shown.
    private var filePath: String? { file?.path ?? path }
    var isText: Bool {
        if case .text = file?.content { return true }
        return false
    }
    /// Whether the file's text has the keyboard, as its source or as Markdown's Preview.
    var textHasKeyboard: Bool {
        guard let responder = view.window?.firstResponder else { return false }
        return responder === textView || responder === previewView
    }
    /// Whether the keyboard is anywhere in the viewer: its text, its preview, its find bar, or the viewer itself.
    var hasKeyboard: Bool {
        guard let responder = view.window?.firstResponder as? NSView else { return false }
        return responder.isDescendant(of: view)
    }
    /// Whether the keyboard is in the viewer but not in its text, its preview or its find bar.
    private var keyboardOutsideText: Bool {
        guard let responder = view.window?.firstResponder as? NSView else { return false }
        return responder === view || responder.isDescendant(of: quickLook) || responder.isDescendant(of: imageView)
            || responder.isDescendant(of: message)
    }

    /// What takes the keyboard when the pane is focused: the text or its Preview while it shows, else the viewer itself,
    /// so Esc and Tab still reach it over a picture, Quick Look's preview or a message.
    var keyboardView: NSView {
        if !scrollView.isHidden { return textView }
        if !previewScroll.isHidden { return previewView }
        return view
    }

    /// A page or part of one in the text shown, the source or the Preview: in Edit the caret moves with it. False when
    /// no text shows.
    @discardableResult
    func page(_ pages: CGFloat) -> Bool {
        if !scrollView.isHidden {
            textView.page(pages)
        } else if !previewScroll.isHidden {
            previewView.page(pages)
        } else {
            return false
        }
        return true
    }

    /// Esc. In Edit it goes to Read, keeping the keyboard. In Read it closes the viewer, in place and beside the list:
    /// the pane shows its folder again.
    private func cancel() -> Bool {
        if isEditing {
            setEditing(false)
        } else {
            onClose()
        }
        return true
    }

    /// Shows `path`, read off the main actor; nil shows nothing. A file already shown with edits is the caller's to ask
    /// about first (`confirmLeave`).
    /// `editing`: Read or Edit; nil for the pane's.
    func show(_ path: String?, focus: Bool = false, editing: Bool? = nil) {
        let editing = editing ?? opensForEditing
        loadNumber += 1
        let number = loadNumber
        stopWatching?()
        stopWatching = nil
        conflictBar.isHidden = true
        gone = nil
        self.path = path
        // Nothing is known of the new file until it is read: the old one's kind isn't kept meanwhile.
        file = nil
        previewImages = MarkdownImages()
        previewImagesAreStale = false
        switchPlace = nil
        isDirty = false
        isEditing = false
        textView.isEditable = false
        guard let path else {
            showMessage(.empty)
            refreshChrome()
            return
        }
        refreshChrome()
        Task { [weak self] in
            let file = await ViewerFile.read(path)
            guard let self, number == self.loadNumber else { return }
            self.apply(file, keepingPlace: false)
            self.watch(file.path)
            // The text, or the viewer itself for a file that isn't text, so Esc and Tab reach it.
            if focus { self.view.window?.makeFirstResponder(self.keyboardView) }
            guard case .text = file.content else { return }
            // Read or Edit, as chosen last.
            if editing { self.setEditing(true, focus: focus) }
        }
    }

    /// The file read again after another app changed it, keeping the place in it.
    private func reload() {
        guard let path = filePath else { return }
        let number = loadNumber
        Task { [weak self] in
            let file = await ViewerFile.read(path)
            guard let self, number == self.loadNumber else { return }
            self.apply(file, keepingPlace: true)
        }
    }

    private func apply(_ file: ViewerFile, keepingPlace: Bool) {
        self.file = file
        knownModified = file.modified
        switch file.content {
        case .text(let text, let format, let language, let indentation):
            self.format = format
            self.indentation = indentation
            self.language = language
            // Read again after the file: a picture changed on disk shows as it is now.
            if keepingPlace { previewImagesAreStale = true }
            let place = keepingPlace ? (textView.selectedRange(), scrollView.contentView.bounds.origin) : nil
            setText(text)
            savedText = text as NSString
            if let place {
                textView.setSelectedRange(NSRange(location: min(place.0.location, text.utf16.count), length: 0))
                scrollView.contentView.scroll(to: place.1)
                scrollView.reflectScrolledClipView(scrollView.contentView)
            } else {
                textView.setSelectedRange(NSRange(location: 0, length: 0))
                // The top, by its first character: the clip view's own origin is offset beside the line numbers.
                textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
            }
            showBody(language.hasPreview && showsPreview && !isEditing ? .preview : .text)
        case .other:
            if let image = file.image {
                imageView.image = image
                showBody(.image)
            } else {
                showBody(.quickLook)
            }
        case .folder:
            showMessage(.folder(fileName ?? ""))
        case .tooLarge(let size):
            showMessage(.tooLarge(fileName ?? "", size))
        case .unreadable(let text):
            showMessage(.unreadable(text))
        }
        refreshChrome()
    }

    private func setText(_ text: String) {
        changes += 1
        coloring.ignoresEdits = true
        textView.string = text
        coloring.ignoresEdits = false
        textView.undoManager?.removeAllActions(withTarget: textView.textStorage as Any)
        textView.undoManager?.removeAllActions()
        coloring.colorLimit = 10 * 1024 * 1024
        coloring.setLanguage(language)
        textView.typingAttributes = typingAttributes
        textView.textStorage?.setAttributes(
            typingAttributes, range: NSRange(location: 0, length: textView.string.utf16.count))
        coloring.recolorAll()
    }

    private enum Body { case text, preview, quickLook, image, message }

    private func showBody(_ shown: Body) {
        // Hiding the text or the Preview takes the keyboard from it: the viewer keeps it.
        let keyboard =
            view.window.map {
                $0.firstResponder === textView || $0.firstResponder === previewView || $0.firstResponder === view
            } ?? false
        scrollView.isHidden = shown != .text
        previewScroll.isHidden = shown != .preview
        message.isHidden = shown != .message
        imageView.isHidden = shown != .image
        if shown != .image { imageView.image = nil }
        if shown == .preview { renderPreview() }
        let quickLookItem = shown == .quickLook ? filePath.map { DiskPath($0).url(isDirectory: false) } : nil
        quickLook.item = quickLookItem
        quickLook.isHidden = quickLookItem == nil
        // The keyboard follows what is shown, between the text and the viewer itself.
        if keyboard, let window = view.window, window.firstResponder !== keyboardView {
            window.makeFirstResponder(keyboardView)
        }
        view.needsLayout = true
    }

    private func showMessage(_ kind: ViewerMessageView.Kind) {
        message.show(kind)
        showBody(.message)
    }

    private func renderPreview() {
        let fileURL = filePath.map { DiskPath($0).url(isDirectory: false) }
        let rendered = MarkdownRendering.render(
            textView.string, theme: currentTheme, fontSize: settings.fontSize, file: fileURL, images: previewImages)
        previewView.textStorage?.setAttributedString(rendered.text)
        previewView.backgroundColor = NSColor(currentTheme.background)
        if previewImagesAreStale, let fileURL {
            readImages(MarkdownImages.named(in: textView.string, file: fileURL), again: true)
        } else {
            readImages(rendered.untried, again: false)
        }
    }

    /// The pictures the Preview names and hasn't read, read off the main actor, one read at a time; the Preview is
    /// drawn again with them, where it was. `again`: every picture the file names, read in place of those read
    /// before.
    private func readImages(_ urls: [URL], again: Bool) {
        guard readingImagesFor != loadNumber else { return }
        if again { previewImagesAreStale = false }
        guard !urls.isEmpty else {
            if again { previewImages = MarkdownImages() }
            return
        }
        let number = loadNumber
        let spent = again ? 0 : previewImages.bytes
        readingImagesFor = number
        Task { [weak self] in
            let read = await Task.detached(priority: .userInitiated) { MarkdownImages.read(urls, spent: spent) }
                .value
            guard let self else { return }
            if self.readingImagesFor == number { self.readingImagesFor = nil }
            guard number == self.loadNumber else { return }
            if again { self.previewImages = read } else { self.previewImages.add(read) }
            guard !self.previewScroll.isHidden else { return }
            let place = self.previewScroll.contentView.bounds.origin
            self.renderPreview()
            self.previewScroll.contentView.scroll(to: place)
            self.previewScroll.reflectScrolledClipView(self.previewScroll.contentView)
        }
    }

    // MARK: Read and Edit

    /// Read or Edit. `chosen`: by the person, so the next file the pane opens opens the same way.
    func setEditing(_ editing: Bool, focus: Bool = true, chosen: Bool = false) {
        if chosen {
            opensForEditing = editing
            onEditingChosen(editing)
        }
        guard isText, editing != isEditing else { return }
        isEditing = editing
        textView.isEditable = editing
        if language.hasPreview {
            let fromPreview = !previewScroll.isHidden
            showKeepingPlace(editing || !showsPreview ? .text : .preview)
            // Edit begins on what was being read.
            if editing && fromPreview { textView.caretOnScreen() }
        }
        if editing && focus { view.window?.makeFirstResponder(textView) }
        textView.needsDisplay = true
        refreshChrome()
    }

    func setPreview(_ preview: Bool) {
        showsPreview = preview
        if language.hasPreview && !isEditing { showKeepingPlace(preview ? .preview : .text) }
        refreshChrome()
    }

    /// The source or the Preview, the other one's place kept: the line at the top of the one shown is at the top of
    /// the other, by the lines of the Markdown each piece of the Preview comes from.
    private func showKeepingPlace(_ shown: Body) {
        let fromSource = !scrollView.isHidden
        let fromPreview = !previewScroll.isHidden
        guard shown == .text && fromPreview || shown == .preview && fromSource else {
            showBody(shown)
            return
        }
        let sourceClip = scrollView.contentView
        let previewClip = previewScroll.contentView
        let before = (fromSource ? sourceClip : previewClip).bounds.origin.y
        let line =
            fromSource
            ? coloring.line(at: textView.firstCharacterShown) + 1
            : MarkdownRendering.sourceLine(at: previewView.firstCharacterShown, in: previewView.attributedString())
        showBody(shown)
        view.layoutSubtreeIfNeeded()
        if let place = switchPlace, place.changes == changes, before == (fromSource ? place.source : place.preview) {
            let (scroll, clip) = fromSource ? (previewScroll, previewClip) : (scrollView, sourceClip)
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: fromSource ? place.preview : place.source))
            scroll.reflectScrolledClipView(clip)
        } else if let line, fromSource {
            // Its text is new: laid out whole, as it is drawn, so it is as tall as the way to the line.
            if let manager = previewView.layoutManager, let container = previewView.textContainer {
                manager.ensureLayout(for: container)
                previewView.sizeToFit()
            }
            let shown = previewView.attributedString()
            previewView.scrollLineToTop(MarkdownRendering.location(ofSourceLine: line, in: shown))
        } else if let line {
            // The source, hidden behind the Preview, is laid out as far as it was ever shown: laid out in parts, it
            // places a line it hasn't reached by a guess, which the page keys and the scrolling then correct by jumps.
            // A Markdown file is laid out whole, as its Preview is.
            if let manager = textView.layoutManager, let container = textView.textContainer {
                manager.ensureLayout(for: container)
                textView.sizeToFit()
            }
            let starts = coloring.lineStarts
            textView.scrollLineToTop(starts[max(0, min(line - 1, starts.count - 1))])
        }
        switchPlace = (sourceClip.bounds.origin.y, previewClip.bounds.origin.y, changes)
    }

    func setLanguage(_ id: String) {
        guard let chosen = TextLanguage.with(id: id) else { return }
        language = chosen
        coloring.setLanguage(chosen)
        if isText && !isEditing { showBody(chosen.hasPreview && showsPreview ? .preview : .text) }
        refreshChrome()
    }

    func textDidChange(_ notification: Notification) {
        changes += 1
        let text = (textView.textStorage?.string ?? "") as NSString
        let dirty = text.length != savedText.length || !text.isEqual(to: savedText as String)
        if dirty != isDirty {
            isDirty = dirty
            refreshChrome()
        }
        refreshFooter()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        refreshFooter()
    }

    /// Save, from the bar, its menu or the key: writes the text over the file. A file that went while shown is never
    /// written back unasked: the question says so, and Save there puts it back where it was. False when it is asked.
    @discardableResult
    func save() -> Bool {
        guard let gone else { return write() }
        guard isText, let window = view.window else { return false }
        let title = Self.goneTitle(gone, fileName ?? "")
        Task { [weak self] in
            let answer = await InWindowAlerts.ask(
                title: title, message: "Save puts it back where it was, with your changes.",
                buttons: [
                    AlertButtonSpec("Cancel", .plain, answer: false),
                    AlertButtonSpec("Save", .default, answer: true),
                ], escape: false, in: window)
            guard answer, let self, self.gone != nil else { return }
            self.write()
        }
        return false
    }

    /// "“Notes.txt” was moved to the Trash." or "“Notes.txt” is no longer there."
    static func goneTitle(_ gone: GoneFile, _ name: String) -> String {
        switch gone {
        case .trashed: "\u{201C}\(name)\u{201D} was moved to the Trash."
        case .missing: "\u{201C}\(name)\u{201D} is no longer there."
        }
    }

    /// Writes the text over the file, or where the file was if it went. A failure says why and keeps the edits.
    @discardableResult
    private func write() -> Bool {
        guard let path = filePath, isText else { return false }
        do {
            knownModified = try ViewerFile.write(textView.string, as: format, to: path)
            savedText = NSString(string: textView.string)
            isDirty = false
            conflictBar.isHidden = true
            // What is written is the file from now on: put in place of the one there, or back where one was.
            file?.identity = ViewerFileIdentity(path: path)
            gone = nil
            refreshChrome()
            return true
        } catch {
            if let window = view.window {
                InWindowAlerts.notice(
                    title: "“\(fileName ?? "")” couldn’t be saved.", message: error.localizedDescription, in: window)
            }
            return false
        }
    }

    private enum LeaveAnswer: Equatable, Sendable { case save, discard, cancel }

    /// Whether the file may be left: true at once without edits; with edits, after Save or Don't Save.
    func confirmLeave() async -> Bool {
        guard isDirty, let window = view.window else { return true }
        // A file that went says so: Save puts it back where it was.
        let title = gone.map { Self.goneTitle($0, fileName ?? "") + " Save your changes where it was?" }
        let answer = await InWindowAlerts.ask(
            title: title ?? "Save changes to “\(fileName ?? "")”?",
            message: "Your changes are lost if you don’t save them.",
            buttons: [
                AlertButtonSpec("Don’t Save", .plain, answer: LeaveAnswer.discard),
                AlertButtonSpec("Cancel", .plain, answer: LeaveAnswer.cancel),
                AlertButtonSpec("Save", .default, answer: LeaveAnswer.save),
            ], escape: .cancel, in: window)
        switch answer {
        case .save: return write()
        case .discard:
            isDirty = false
            refreshChrome()
            return true
        case .cancel: return false
        }
    }

    // MARK: The bar and the viewer's keys

    private func perform(_ action: ViewerHeaderView.Action) {
        switch action {
        case .previous: onPrevious()
        case .next: onNext()
        case .follow(let on): onFollowChange(on)
        case .save: save()
        case .revert: revertToSaved()
        case .editing(let editing): setEditing(editing, chosen: true)
        case .preview(let preview): setPreview(preview)
        case .language(let id): setLanguage(id)
        case .find: showFind()
        case .openInEditor: if let path { onOpenInEditor(path) }
        case .close: onClose()
        case .settings(let change):
            var next = settings
            change(&next)
            settings = next
            onSettingsChange(next)
        }
    }

    /// ⌘S, ⌘F, and for a file in place ⌥⌘] and ⌥⌘[, while the keyboard is in the viewer.
    private func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .shift, .control])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        switch commandForKey(event) {
        case .saveViewerFile:
            if isDirty { save() } else { NSSound.beep() }
            return true
        case .nextViewerFile where mode == .inPlace:
            onNext()
            return true
        case .previousViewerFile where mode == .inPlace:
            onPrevious()
            return true
        default:
            break
        }
        switch (flags, key) {
        case ([], "\u{1b}") where keyboardOutsideText:
            // Quick Look's preview, a picture or a message has the keyboard: Esc is the viewer's, before the view
            // with the keyboard can keep it.
            return cancel()
        case ([.command], "f") where isText:
            showFind()
            return true
        default:
            return false
        }
    }

    func showFind() {
        guard isText else { return }
        if previewScroll.isHidden == false { showBody(.text) }
        view.window?.makeFirstResponder(textView)
        let item = NSMenuItem()
        item.tag = Int(NSTextFinder.Action.showFindInterface.rawValue)
        textView.performTextFinderAction(item)
    }

    /// The file as it is on disk in place of the edits, as one change Undo takes back.
    func revertToSaved() {
        guard isDirty else { return }
        guard let gone else {
            useFileOnDisk()
            return
        }
        // Nothing on disk to go back to: the edits go, and the viewer says the file went.
        isDirty = false
        conflictBar.isHidden = true
        showMessage(.gone(gone, Self.goneTitle(gone, fileName ?? "")))
        refreshChrome()
    }

    // MARK: Changes on disk

    private func watch(_ path: String) {
        // The original's real path, as the watch's events spell the folder's names. A name that differs only by its
        // letter case or the way its accents are stored is let through: the file renamed to one is told of by its new
        // name, and whether it is the file is found by asking the disk.
        let folder = NodePath.dirname(path)
        let name = Self.nameAnySpelling(NodePath.basename(path))
        stopWatching = FSEventsFolderWatcher.watchFolder(
            path: folder,
            onChange: { [weak self] changed in
                guard changed.map({ Self.nameAnySpelling($0) == name }) ?? true else { return }
                self?.changedOnDisk()
            }, onFail: {},
            // The watch starts a moment after the file was read, and tells only of what changes from then on: a
            // change made in that moment is found by the file's date.
            onStart: { [weak self] in self?.changedOnDisk() })
    }

    /// A name with its letter case and the way its accents are stored set aside: what a disk that ignores them takes
    /// for one name.
    private static func nameAnySpelling(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.lowercased()
    }

    /// Something changed in the file's folder: the file changed where it is, was moved or renamed, or went.
    private func changedOnDisk() {
        guard let path = filePath else { return }
        guard access(path, F_OK) == 0 else {
            fileLeft(path)
            return
        }
        if gone != nil {
            // A file is there again (Undo of Move to Trash, another app writing it anew): it is the file shown, as
            // the disk has it now.
            gone = nil
            file?.identity = ViewerFileIdentity(path: path)
            refreshChrome()
            if isDirty {
                knownModified = nil
                conflictBar.show(.changed)
                view.needsLayout = true
            } else {
                reload()
            }
            return
        }
        // Renamed to another spelling of its name (its letter case, the way its accents are stored): the path still
        // opens it on a disk that ignores those, so the disk is asked how it names the file now.
        let named = DiskPath(path).namedAsOnDisk().string
        if !samePath(named, path) {
            fileMoved(from: path, to: named)
            return
        }
        let url = DiskPath(path).url(isDirectory: false)
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        guard modified != knownModified else { return }
        if isDirty {
            knownModified = modified
            conflictBar.show(.changed)
            view.needsLayout = true
        } else {
            reload()
        }
    }

    /// The Trash folders, to tell a file moved to the Trash from one moved elsewhere.
    private static let trash = TrashFolders()

    /// Nothing is at the file's path any more: it is found where it was moved or renamed to, or it went. One that went
    /// keeps its edits on screen, if it has any; without, the viewer says so.
    private func fileLeft(_ path: String) {
        let found = file?.identity?.currentPath
        if let found, !samePath(found, path), !Self.trash.holds(found) {
            fileMoved(from: path, to: found)
            return
        }
        let how: GoneFile = found.map(Self.trash.holds) == true ? .trashed : .missing
        guard gone != how else { return }
        gone = how
        let title = Self.goneTitle(how, fileName ?? "")
        if isDirty {
            conflictBar.show(.gone(title + " Your changes haven\u{2019}t been saved."))
            view.needsLayout = true
        } else {
            showMessage(.gone(how, title))
        }
        refreshChrome()
        onGone()
    }

    /// File Trail renamed or moved items, the file shown or a folder it is in perhaps among them: the viewer goes
    /// along by what the write says, on any disk, with nothing asked of the disk. A file the watch already took for
    /// gone, on a disk that can't tell where it went, is shown again.
    func follow(_ moves: [PathMove]) {
        guard let old = filePath else { return }
        let new = ExplorerTabs.followMovedPath(old, moves)
        guard !samePath(new, old) else {
            // A link or an alias shown was renamed itself: its original stayed.
            if let shown = path, !samePath(shown, old) {
                let renamed = ExplorerTabs.followMovedPath(shown, moves)
                guard !samePath(renamed, shown) else { return }
                path = renamed
                refreshChrome()
                onMoved(shown, renamed)
            }
            return
        }
        guard file != nil else {
            // Still being read where it was: read where it is.
            if path.map({ samePath($0, old) }) == true { show(new) }
            return
        }
        let wasGone = gone != nil
        gone = nil
        fileMoved(from: old, to: new)
        // The file's identity is asked for where it is now: a disk without file ids knows it by its path alone.
        file?.identity = ViewerFileIdentity(path: new)
        guard wasGone else { return }
        if isDirty {
            conflictBar.isHidden = true
            view.needsLayout = true
        } else {
            reload()
        }
    }

    /// The file was moved or renamed: it is shown, read, watched and saved where it is now, its edits kept. A link or
    /// an alias shown keeps its own name: only its original moved.
    private func fileMoved(from old: String, to new: String) {
        let shownItself = path.map { samePath($0, old) } ?? false
        file?.path = new
        if shownItself { path = new }
        stopWatching?()
        stopWatching = nil
        // Once it runs, the watch looks at the file's date: one changed meanwhile is read again.
        watch(new)
        refreshChrome()
        if shownItself { onMoved(old, new) }
    }

    private func keepMine() {
        conflictBar.isHidden = true
        view.needsLayout = true
    }

    /// The file's text in place of the edits, as one change Undo takes back.
    private func useFileOnDisk() {
        conflictBar.isHidden = true
        view.needsLayout = true
        guard let path = filePath else { return }
        let number = loadNumber
        Task { [weak self] in
            let file = await ViewerFile.read(path)
            guard let self, number == self.loadNumber, case .text(let text, let format, _, _) = file.content else {
                return
            }
            self.format = format
            self.knownModified = file.modified
            let whole = NSRange(location: 0, length: self.textView.string.utf16.count)
            if self.textView.shouldChangeText(in: whole, replacementString: text) {
                self.textView.replaceCharacters(in: whole, with: text)
                self.textView.didChangeText()
            }
            self.savedText = NSString(string: text)
            self.isDirty = false
            self.refreshChrome()
        }
    }

    // MARK: Look

    private var appAppearance: ThemeAppearance { ChromeColors.appearance(of: view) }
    var currentTheme: TextViewerTheme { settings.theme(appAppearance: appAppearance) }

    private var typingAttributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.12
        return [
            .font: ThemeFonts.mono(settings.fontSize), .foregroundColor: NSColor(currentTheme.text),
            .paragraphStyle: paragraph,
        ]
    }

    func applyLook() {
        guard isViewLoaded else { return }
        let theme = currentTheme
        let textAppearance = NSAppearance(named: theme.appearance == .dark ? .darkAqua : .aqua)
        scrollView.appearance = textAppearance
        previewScroll.appearance = textAppearance
        message.appearance = textAppearance
        body.layer?.backgroundColor = NSColor(theme.background).cgColor
        textView.backgroundColor = NSColor(theme.background)
        scrollView.backgroundColor = NSColor(theme.background)
        textView.insertionPointColor = NSColor(theme.text)
        textView.selectedTextAttributes = [.backgroundColor: NSColor(theme.selection)]
        textView.currentLineColor = NSColor(theme.currentLine)
        textView.typingAttributes = typingAttributes
        if let storage = textView.textStorage, storage.length > 0 {
            storage.addAttributes(typingAttributes, range: NSRange(location: 0, length: storage.length))
        }
        ruler.backgroundColor = NSColor(theme.background)
        ruler.textColor = NSColor(theme.gutterText)
        ruler.font = ThemeFonts.mono(max(9, settings.fontSize - 2))
        scrollView.rulersVisible = settings.lineNumbers
        ruler.linesChanged()
        scrollView.tile()
        setWrapping(settings.wrapLines)
        previewView.backgroundColor = NSColor(theme.background)
        previewScroll.backgroundColor = NSColor(theme.background)
        message.theme = theme
        coloring.theme = theme
        if !previewScroll.isHidden { renderPreview() }
        refreshChrome()
    }

    /// Long lines wrap at the visible width, or run on with a horizontal scroller. The text view's width is the
    /// scroll view's to set (`tile`), beside the line numbers: one set by hand ran under them.
    private func setWrapping(_ wraps: Bool) {
        guard let container = textView.textContainer else { return }
        scrollView.hasHorizontalScroller = !wraps
        textView.isHorizontallyResizable = !wraps
        textView.autoresizingMask = wraps ? [.width] : []
        container.widthTracksTextView = wraps
        container.containerSize = NSSize(
            width: wraps ? textView.bounds.width : CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        scrollView.tile()
    }

    // MARK: Header and footer

    func refreshChrome() {
        guard isViewLoaded else { return }
        header.update(
            ViewerHeaderView.State(
                name: fileName ?? (mode == .following ? "Nothing selected" : ""), mode: mode, isText: isText,
                isEditing: isEditing, isDirty: isDirty, hasPreview: isText && language.hasPreview,
                showsPreview: showsPreview, languageID: language.id,
                position: position.map { ViewerHeaderView.Position(index: $0.index, count: $0.count) },
                settings: settings,
                keys: ViewerHeaderView.Keys(
                    save: keyLabel(.saveViewerFile), next: keyLabel(.nextViewerFile),
                    previous: keyLabel(.previousViewerFile))))
        refreshFooter()
        onStateChange()
        view.needsLayout = true
    }

    private func refreshFooter() {
        guard isViewLoaded else { return }
        var parts: [String] = []
        if isText {
            let text = textView.string as NSString
            let location = min(textView.selectedRange().location, text.length)
            let line = coloring.line(at: location)
            let column = location - coloring.lineStarts[line] + 1
            if isEditing || textView.selectedRange().length > 0 || location > 0 {
                parts.append("Ln \(line + 1), Col \(column)")
            }
            let lines = coloring.lineStarts.count
            parts.append(lines == 1 ? "1 line" : "\(FormatLocale.count(lines)) lines")
            parts.append(language.name)
            parts.append(format.encodingName)
            parts.append(format.lineEnding.rawValue)
            if let indentation { parts.append(indentation.label) }
            if !coloring.colorsOn, language.grammar.colors { parts.append("Colors off for a file this large") }
        } else if let file, case .other = file.content {
            parts.append(SizeText.size(file.size))
        }
        let status = parts.joined(separator: " · ")
        if status != lastStatus {
            lastStatus = status
            onStatusChange(status)
        }
    }

    private func layoutViews() {
        let bounds = view.bounds
        let headerHeight = ViewerHeaderView.height
        header.frame = NSRect(x: 0, y: 0, width: bounds.width, height: headerHeight)
        var top = headerHeight
        if !conflictBar.isHidden {
            conflictBar.frame = NSRect(x: 0, y: top, width: bounds.width, height: ViewerConflictBar.height)
            top += ViewerConflictBar.height
        }
        let bodyHeight = max(0, bounds.height - top)
        body.frame = NSRect(x: 0, y: top, width: bounds.width, height: bodyHeight)
        for child in [scrollView, previewScroll, message, quickLook] as [NSView] { child.frame = body.bounds }
        imageView.frame = body.bounds.insetBy(dx: 16, dy: 16)
        scrollView.tile()
        // What is on screen once the text has its size: a first layout may have shown none of it.
        coloring.colorVisible()
    }
}

extension SyntaxGrammar {
    /// Whether the grammar colors anything.
    var colors: Bool {
        if case .plain = self { return false }
        return true
    }
}

extension NSView {
    /// The viewer's root this view is in, or itself; nil outside a viewer.
    var enclosingViewer: ViewerRootView? {
        var view: NSView? = self
        while let each = view {
            if let root = each as? ViewerRootView { return root }
            view = each.superview
        }
        return nil
    }
}

/// The viewer's root: flipped, and laid out by its controller. It takes the viewer's own keys while the keyboard is
/// in the viewer, before the menu bar sees them.
final class ViewerRootView: NSView {
    var onLayout: () -> Void = {}
    var onKey: (NSEvent) -> Bool = { _ in false }
    /// Esc and Tab while the viewer itself has the keyboard, with no text shown, or from its preview.
    var onCancel: () -> Bool = { false }
    var onTab: () -> Void = {}
    var onFocusChange: () -> Void = {}
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocusChange() }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onFocusChange() }
        return resigned
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control])
        switch event.charactersIgnoringModifiers?.unicodeScalars.first?.value {
        case 0x09 where flags.isEmpty, 0x19 where flags.isEmpty: onTab()
        case 0x1B where flags.isEmpty: cancelOperation(nil)
        default: super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        if onCancel() { return }
        super.cancelOperation(sender)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let responder = window?.firstResponder as? NSView, responder.isDescendant(of: self), onKey(event) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func layout() {
        super.layout()
        onLayout()
    }
}
