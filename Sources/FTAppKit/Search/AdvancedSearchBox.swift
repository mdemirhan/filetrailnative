// Advanced Search (⌥⌘F, and the button at the search field's end): the search's text in a box with room for all of it,
// over the window as Go To is. A text view that wraps, the condition words tinted and the list of what the word at the
// caret can be under it; a line saying how the search reads; the words to click; Cancel and Search.
import AppKit
import FTFoundation

@MainActor
final class AdvancedSearchBox: DialogPanelView, NSTextViewDelegate {
    /// Search, or Return: the text to search for.
    var onSubmit: (String) -> Void = { _ in }
    /// Cancel, Escape, or a press on the scrim: the search stays as it was.
    var onClose: () -> Void = {}
    /// The list's Syntax Help: Help opens at Search, the box staying open.
    var onHelp: () -> Void = {}

    let textView: AdvancedSearchTextView
    private let scroll = NSScrollView()
    let shell = AdvancedSearchShell()
    /// Over what is under the text, as a menu would be: the box keeps its size as the list comes and goes.
    let suggestions = SearchSuggestionsView(floating: true, identifier: "advancedSearch.suggestions")
    let titleLabel = PlainLabel(labelWithString: "Advanced Search")
    let scopeLabel = PlainLabel(labelWithString: "")
    let readsLabel = PlainLabel(wrappingLabelWithString: "")
    let wordsLabel = PlainLabel(labelWithString: "Add a condition")
    /// How words combine: each must match, and a comma gives a choice.
    let combineLabel = PlainLabel(wrappingLabelWithString: "")
    private(set) var wordButtons: [AdvancedSearchWordButton] = []
    let footer = DialogFooterLine(thickness: DialogLayout.GoTo.footerBorder)
    let cancelButton = SystemButton(title: "Cancel")
    let submitButton = SystemButton(title: "Search")
    /// What `tag:` and `skip:` offer.
    private let tags: [String]
    private let folders: () -> [String]
    /// How a name is matched, for the line saying how the search reads: "contains" or "matches".
    private let nameVerb: String
    /// The name is a glob or a regular expression, matched whole, not words each looked for.
    private var isPattern: Bool { nameVerb == "matches" }
    /// Escape closed the list for this text: it stays closed until the text changes.
    private var listClosedFor: String?

    /// Wider than Go To's 560, for a long search; everything else in Go To's measures (`DialogLayout.GoTo`).
    static let width = 640.0
    /// The text in a text field's font, as Go To's field has it.
    static let font = GoToFieldShell.font
    static let minLines = 3
    static let maxLines = 8
    private static let titleFont = ThemeFonts.sans(DesignTokens.typeScale.body, .bold)
    private static let smallFont = ThemeFonts.sans(DesignTokens.typeScale.small)
    private static let headingFont = ThemeFonts.sans(DesignTokens.typeScale.small, .semibold)
    /// The labels' cells draw their text 2 in: their frames start 2 early.
    private static let cellInset = GoToRowView.cellInset

    init(text: String, folderName: String, nameVerb: String, tags: [String], folders: @escaping () -> [String]) {
        self.tags = tags
        self.folders = folders
        self.nameVerb = nameVerb
        textView = AdvancedSearchTextView(usingTextLayoutManager: true)
        super.init(cornerRadius: GlassSurface.sheetRadius)
        setAccessibilityElement(true)
        setAccessibilityRole(.sheet)
        setAccessibilityLabel("Advanced Search")
        setAccessibilityIdentifier("advancedSearch")

        titleLabel.font = Self.titleFont
        titleLabel.setAccessibilityIdentifier("advancedSearch.title")
        scopeLabel.font = Self.smallFont
        scopeLabel.stringValue = "in “\(folderName)”"
        scopeLabel.lineBreakMode = .byTruncatingMiddle
        addSubview(titleLabel)
        addSubview(scopeLabel)

        textView.font = Self.font
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        // A search's words aren't prose: no word guessed after them, and no rewriting.
        textView.inlinePredictionType = .no
        textView.writingToolsBehavior = .none
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.delegate = self
        textView.string = text
        textView.setAccessibilityLabel("Search")
        textView.setAccessibilityIdentifier("advancedSearch.text")
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.documentView = textView
        shell.addSubview(scroll)
        shell.holdsKeyboard = { [weak self] in self?.window?.firstResponder === self?.textView }
        addSubview(shell)

        suggestions.onChoose = { [weak self] index in self?.choose(index) }
        suggestions.onHelp = { [weak self] in self?.onHelp() }
        suggestions.isHidden = true
        addSubview(suggestions)

        // Notes to read: a click would put the label in the field editor, which draws it in its own font.
        readsLabel.isSelectable = false
        readsLabel.font = Self.smallFont
        readsLabel.setAccessibilityIdentifier("advancedSearch.reads")
        addSubview(readsLabel)
        wordsLabel.font = Self.headingFont
        addSubview(wordsLabel)
        wordButtons = SearchQueryKey.menuOrder.map { key in
            let button = AdvancedSearchWordButton(title: key.title, word: key.word)
            button.onPress = { [weak self] in self?.insertWord(key.word) }
            addSubview(button)
            return button
        }
        combineLabel.isSelectable = false
        combineLabel.setAccessibilityIdentifier("advancedSearch.combine")
        addSubview(combineLabel)

        footer.setAccessibilityIdentifier("advancedSearch.footer")
        addSubview(footer)
        cancelButton.target = self
        cancelButton.action = #selector(cancelPressed(_:))
        cancelButton.setAccessibilityIdentifier("advancedSearch.cancel")
        submitButton.isDefault = true
        submitButton.target = self
        submitButton.action = #selector(submitPressed(_:))
        submitButton.setAccessibilityIdentifier("advancedSearch.submit")
        footer.addSubview(cancelButton)
        footer.addSubview(submitButton)
        // Over everything else in the box.
        addSubview(suggestions)
        applyTheme(theme)
        render()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The box is up: the keyboard in the text, the caret at its end. The list waits for the text to change.
    func opened() {
        listClosedFor = textView.string
        window?.makeFirstResponder(textView)
        let length = (textView.string as NSString).length
        textView.setSelectedRange(NSRange(location: length, length: 0))
        textView.scrollRangeToVisible(NSRange(location: length, length: 0))
        render()
    }

    var text: String { textView.string }

    // MARK: Typing

    func textDidChange(_ notification: Notification) { render() }

    func textViewDidChangeSelection(_ notification: Notification) { render() }

    /// A search is one line of words: a line break typed or pasted is a space.
    func textView(
        _ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?
    ) -> Bool {
        guard let replacementString, replacementString.contains(where: \.isNewline) else { return true }
        let flat = replacementString.replacingOccurrences(of: "\r\n", with: " ")
            .map { $0.isNewline ? " " : String($0) }.joined()
        textView.insertText(flat, replacementRange: affectedCharRange)
        return false
    }

    /// The list's row at `index` replaces the word at the caret, as typing it would.
    func choose(_ index: Int) {
        guard let list = suggestions.suggestions, list.rows.indices.contains(index) else { return }
        guard let replacement = list.rows[index].replacement else {
            closeList()
            return
        }
        window?.makeFirstResponder(textView)
        textView.insertText(
            replacement, replacementRange: TabSearch.range(list.range, taking: replacement, in: textView.string))
    }

    /// A condition's word at the caret, after the word the caret is in, with a space before it where it needs one.
    func insertWord(_ word: String) {
        window?.makeFirstResponder(textView)
        let string = textView.string as NSString
        var location = textView.selectedRange().location
        while location < string.length, let scalar = Unicode.Scalar(string.character(at: location)),
            !CharacterSet.whitespaces.contains(scalar)
        {
            location += 1
        }
        let before = location > 0 ? Unicode.Scalar(string.character(at: location - 1)) : nil
        let space = before.map { !CharacterSet.whitespaces.contains($0) } ?? false
        textView.insertText((space ? " " : "") + word, replacementRange: NSRange(location: location, length: 0))
    }

    func closeList() {
        listClosedFor = textView.string
        render()
    }

    // MARK: Keys

    override var initialResponder: NSView? { textView }

    override func handleKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        // The list is the text's: with the keyboard on Cancel or Search it takes no key, Esc least of all.
        let listShows = !suggestions.isHidden && window?.firstResponder === textView
        if KeyCode.isCancel(event) {
            if listShows { closeList() } else { onClose() }
            return true
        }
        guard window?.firstResponder === textView else {
            guard KeyCode.isReturn(event) || event.charactersIgnoringModifiers == " " else { return false }
            if let button = window?.firstResponder as? SystemButton, button.isDescendant(of: self) {
                button.perform()
                return true
            }
            return false
        }
        switch event.keyCode {
        // While no row is highlighted the list is only an offer: ↓ and ↑ move the caret to the line below or above
        // where the text has one, as in any text, and go into the list where it hasn't.
        case KeyCode.down where modifiers.isEmpty && listShows:
            if suggestions.highlighted < 0, caretHasLine(below: true) { return false }
            suggestions.move(1)
            return true
        case KeyCode.up where modifiers.isEmpty && listShows:
            if suggestions.highlighted < 0, caretHasLine(below: false) { return false }
            suggestions.move(-1)
            return true
        case KeyCode.tab where modifiers.isEmpty && listShows:
            // A word that reads as it is, with nothing chosen, stays as typed and Tab moves on.
            guard suggestions.highlighted >= 0 || suggestions.suggestions?.typedIsComplete == false else {
                closeList()
                return false
            }
            choose(max(0, suggestions.highlighted))
            return true
        case KeyCode.returnKey, KeyCode.keypadEnter:
            if listShows, modifiers.isEmpty, suggestions.highlightedRow?.replacement != nil {
                choose(suggestions.highlighted)
            } else {
                submit()
            }
            return true
        default:
            return false
        }
    }

    /// Whether the wrapped text has a line under the caret's, or over it.
    private func caretHasLine(below: Bool) -> Bool {
        let length = (textView.string as NSString).length
        func line(_ location: Int) -> NSRect {
            textView.firstRect(forCharacterRange: NSRange(location: location, length: 0), actualRange: nil)
        }
        let caret = line(min(textView.selectedRange().location, length))
        // On screen a lower line has the smaller y.
        return below ? caret.minY > line(length).minY + 1 : caret.minY < line(0).minY - 1
    }

    /// Tab goes from the text to Cancel and Search, and round.
    override func focusOrder() -> [NSView] { [textView, cancelButton, submitButton] }

    @objc private func cancelPressed(_ sender: Any?) { onClose() }
    @objc private func submitPressed(_ sender: Any?) { submit() }

    /// Return or Search: searched, unless a word can't be read, when every such word is marked and said instead.
    private func submit() {
        let text = textView.string
        guard SearchQuery.problems(text).isEmpty else {
            showsAllProblems = true
            problemsShownFor = text
            render()
            return
        }
        // Nothing to search for: Search is dimmed, and Return does no more than a press on it would. The search on
        // screen is ended from the field or the results, not by an emptied box.
        guard submitButton.isEnabled else { return }
        onSubmit(SearchTiming.trimmed(text))
    }

    /// Return found words that can't be read: each is marked and said, the one at the caret too, until the text
    /// changes.
    private var showsAllProblems = false
    private var problemsShownFor: String?

    // MARK: Showing

    override func applyTheme(_ theme: Theme) {
        super.applyTheme(theme)
        let palette = theme.palette
        titleLabel.textColor = NSColor(palette.textPrimary)
        scopeLabel.textColor = NSColor(palette.textSecondary)
        wordsLabel.textColor = NSColor(palette.textSecondary)
        combineLabel.attributedStringValue = Self.combining(theme)
        textView.textColor = NSColor(palette.textPrimary)
        textView.insertionPointColor = NSColor(palette.textPrimary)
        shell.applyTheme(theme)
        suggestions.applyTheme(theme)
        footer.applyTheme(theme)
        for button in [cancelButton, submitButton] { button.applyTheme(theme) }
        for button in wordButtons { button.applyTheme(theme) }
        render()
    }

    /// The tint, the list, the line saying how it reads, and what Search allows, for the text as it is.
    func render() {
        let text = textView.string
        if showsAllProblems, problemsShownFor != text { showsAllProblems = false }
        SearchQueryTint.apply(to: textView, theme: theme, marksAll: showsAllProblems)
        if listClosedFor != nil, listClosedFor != text { listClosedFor = nil }
        let selection = textView.selectedRange()
        let list =
            listClosedFor == nil && selection.length == 0 && window?.firstResponder === textView
            // Only a condition's values: the words are the buttons below.
            ? SearchQuerySuggestions.make(
                query: text, caret: selection.location, tags: tags, folders: folders(), offersConditionWords: false)
            : nil
        suggestions.show(list)
        suggestions.isHidden = list == nil
        readsLabel.attributedStringValue = reads(text, caret: selection.length == 0 ? selection.location : nil)
        let query = SearchQuery(text)
        // Nothing is searched without a word that can't be read: Search waits until each can.
        let hasName =
            isPattern
            ? !query.text.trimmingCharacters(in: .whitespaces).isEmpty
            : !query.names.isEmpty || !query.leftOutNames.isEmpty
        submitButton.isEnabled =
            (hasName || !query.conditions.isEmpty)
            && SearchQuery.problems(text).isEmpty
        shell.needsDisplay = true
        needsLayout = true
        superview?.needsLayout = true
    }

    /// How the search reads: "Finds: name contains “annual” and “report” · Kind is PDF", and a word that can't be read
    /// yet, once the caret (`caret`) has left it, as the tint marks it.
    private func reads(_ text: String, caret: Int?) -> NSAttributedString {
        let palette = theme.palette
        let plain: [NSAttributedString.Key: Any] = [
            .font: Self.smallFont, .foregroundColor: NSColor(palette.textSecondary),
        ]
        let query = SearchQuery(text)
        var parts: [String] = []
        func listed(_ words: [String], _ join: String) -> String {
            let quoted = words.map { "“\($0)”" }
            return quoted.count > 1
                ? quoted.dropLast().joined(separator: ", ") + " \(join) " + quoted[quoted.count - 1] : quoted[0]
        }
        if isPattern {
            // A glob or a regular expression is one pattern, spaces and `!` and all.
            let pattern = query.text.trimmingCharacters(in: .whitespaces)
            if !pattern.isEmpty { parts.append("Name \(nameVerb) “\(pattern)”") }
        } else {
            if !query.names.isEmpty { parts.append("Name \(nameVerb) \(listed(query.names, "and"))") }
            if !query.leftOutNames.isEmpty {
                parts.append("Name doesn’t contain \(listed(query.leftOutNames, "or"))")
            }
        }
        parts += query.conditions.map { SearchConditionText.chip($0) }
        let result = NSMutableAttributedString(
            string: parts.isEmpty
                ? "Type a name, a condition, or both: a condition alone is a search of its own."
                : "Finds: " + parts.joined(separator: "  ·  "),
            attributes: plain)
        // A word that can't be read, each with what would do: the one being typed only once more typing can't save it.
        for problem in SearchQuery.problems(text, caret: caret, whileTyping: !showsAllProblems) {
            result.append(
                NSAttributedString(
                    string: "\n" + problem.message + ".",
                    attributes: [.font: Self.smallFont, .foregroundColor: NSColor(palette.dangerText)]))
        }
        return result
    }

    /// How words combine, with examples: every word must match, quotes keep words together, a comma gives a choice.
    /// The examples are in the text's own colour, their condition words tinted as the text tints them.
    static func combining(_ theme: Theme) -> NSAttributedString {
        let plain: [NSAttributedString.Key: Any] = [
            .font: smallFont, .foregroundColor: NSColor(theme.palette.textSecondary),
        ]
        let result = NSMutableAttributedString()
        func say(_ text: String) { result.append(NSAttributedString(string: text, attributes: plain)) }
        func example(_ text: String) {
            let start = result.length
            say(text)
            result.addAttribute(
                .foregroundColor, value: NSColor(theme.palette.textPrimary),
                range: NSRange(location: start, length: result.length - start))
            for (range, attributes) in SearchQueryTint.spans(text, caret: nil, theme: theme) {
                result.addAttributes(attributes, range: NSRange(location: start + range.location, length: range.length))
            }
        }
        say("Every word must match, in any order: ")
        example("annual report")
        say(" finds names with both words, and ")
        example("tag:red tag:blue")
        say(" items with both tags. Quotes keep words together: ")
        example("\"annual report\"")
        say(" finds only that run, spaces and all. A comma gives a choice: ")
        example("tag:red,blue")
        say(" finds items with either tag, and ")
        example("kind:pdf,picture")
        say(" PDFs and pictures.")
        return result
    }

    // MARK: Layout

    private typealias Metrics = DialogLayout.GoTo

    /// One line of the text, as a text view lays it out.
    private var lineHeight: CGFloat { GoToRowView.lineHeight(Self.font) }

    /// The text's inset in its box: Go To's field's at the sides, and from the top as Go To's field centres its one
    /// line, so a one-line search sits where it would in a field.
    private var textInset: NSSize {
        NSSize(
            width: CGFloat(Metrics.fieldPaddingHorizontal),
            height: ((CGFloat(DesignTokens.controlHeights.large) - lineHeight) / 2).rounded())
    }

    /// How tall the text is at `width`, in lines kept between the least and the most; past the most it scrolls.
    private func textHeight(width: CGFloat) -> CGFloat {
        var lines = Self.minLines
        if let layout = textView.textLayoutManager {
            textView.frame.size.width = max(1, width)
            layout.ensureLayout(for: layout.documentRange)
            let used = layout.usageBoundsForTextContainer.height
            lines = max(Self.minLines, min(Self.maxLines, Int((used / lineHeight).rounded(.up))))
        }
        return CGFloat(lines) * lineHeight
    }

    private func labelHeight(_ label: NSTextField, width: CGFloat) -> CGFloat {
        ceil(label.sizeThatFits(NSSize(width: max(1, width), height: .greatestFiniteMagnitude)).height)
    }

    /// The words' buttons in lines that wrap: their frames from `y`, and the height they take.
    private func wordFrames(x: CGFloat, y: CGFloat, width: CGFloat) -> ([NSRect], CGFloat) {
        let gap = CGFloat(Metrics.footerGap) - 2
        var frames: [NSRect] = []
        var cursorX = x
        var cursorY = y
        let height = AdvancedSearchWordButton.height
        for button in wordButtons {
            let w = button.preferredWidth
            if cursorX > x, cursorX + w > x + width {
                cursorX = x
                cursorY += height + gap
            }
            frames.append(NSRect(x: cursorX, y: cursorY, width: w, height: height))
            cursorX += w + gap
        }
        return (frames, cursorY + height - y)
    }

    private var footerHeight: CGFloat {
        CGFloat(Metrics.footerBorder + Metrics.footerTop + Metrics.footerBottom)
            + CGFloat(DesignTokens.controlHeights.regular)
    }

    /// The field's section's inset, and the text's under it: the labels line up with the title.
    private var sectionInset: CGFloat { CGFloat(Metrics.inputSectionHorizontal) }
    private var labelInset: CGFloat { CGFloat(Metrics.titleHorizontal) }

    /// Everything from the top, at `width`.
    private func contentHeight(width: CGFloat) -> CGFloat {
        let field = width - 2 * sectionInset
        let labels = width - 2 * labelInset
        var height = CGFloat(Metrics.paddingTop + Metrics.titleTop) + ThemeFonts.normalLineHeight(Self.titleFont)
        height += CGFloat(Metrics.titleBottom)
        height += textHeight(width: field - 2 * textInset.width) + 2 * textInset.height
        height += CGFloat(Metrics.sectionTop) + labelHeight(readsLabel, width: labels)
        height += CGFloat(Metrics.sectionTop + Metrics.sectionTop / 2) + ThemeFonts.normalLineHeight(Self.headingFont)
        height += CGFloat(Metrics.labelBottom) + 2 + wordFrames(x: 0, y: 0, width: labels).1
        height += CGFloat(Metrics.sectionTop) + labelHeight(combineLabel, width: labels)
        height += CGFloat(Metrics.footerBottom) + footerHeight
        return height
    }

    override func panelSize(in size: NSSize) -> NSSize {
        let width = min(Self.width, max(0, size.width - CGFloat(Metrics.viewportInset)))
        let maxHeight = max(0, size.height - CGFloat(Metrics.heightInset))
        return NSSize(width: width, height: min(contentHeight(width: width), maxHeight))
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        let field = width - 2 * sectionInset
        let labels = width - 2 * labelInset
        let inset = Self.cellInset
        var y = CGFloat(Metrics.paddingTop + Metrics.titleTop)
        let titleHeight = ThemeFonts.normalLineHeight(Self.titleFont)
        let titleWidth = ceil(titleLabel.intrinsicContentSize.width)
        titleLabel.frame = NSRect(x: labelInset - inset, y: y, width: titleWidth + 2 * inset, height: titleHeight)
        // The folder in the small size, on the title's baseline.
        let scopeHeight = ThemeFonts.normalLineHeight(Self.smallFont)
        let baseline = (Self.titleFont.ascender - Self.smallFont.ascender).rounded()
        scopeLabel.frame = NSRect(
            x: titleLabel.frame.maxX + 4, y: y + baseline,
            width: max(0, width - labelInset - titleLabel.frame.maxX - 4), height: scopeHeight)
        y += titleHeight + CGFloat(Metrics.titleBottom)
        let textWidth = field - 2 * textInset.width
        let height = textHeight(width: textWidth)
        shell.frame = NSRect(x: sectionInset, y: y, width: field, height: height + 2 * textInset.height)
        scroll.frame = NSRect(x: textInset.width, y: textInset.height, width: textWidth, height: height)
        textView.frame.size.width = scroll.contentSize.width
        textView.textContainer?.size = NSSize(width: scroll.contentSize.width, height: .greatestFiniteMagnitude)
        y = shell.frame.maxY
        if !suggestions.isHidden {
            // Under the text, down to the footer at most; past that its rows scroll.
            let top = y + CGFloat(Metrics.errorTop)
            let room = bounds.height - footerHeight - CGFloat(Metrics.footerBottom) - top
            suggestions.frame = NSRect(
                x: sectionInset, y: top, width: field, height: suggestions.height(fitting: max(0, room)))
        }
        y += CGFloat(Metrics.sectionTop)
        let readsHeight = labelHeight(readsLabel, width: labels)
        readsLabel.frame = NSRect(x: labelInset - inset, y: y, width: labels + 2 * inset, height: readsHeight)
        y += readsHeight + CGFloat(Metrics.sectionTop + Metrics.sectionTop / 2)
        let headingHeight = ThemeFonts.normalLineHeight(Self.headingFont)
        wordsLabel.frame = NSRect(x: labelInset - inset, y: y, width: labels + 2 * inset, height: headingHeight)
        y += headingHeight + CGFloat(Metrics.labelBottom) + 2
        let (frames, wordsHeight) = wordFrames(x: labelInset, y: y, width: labels)
        for (button, frame) in zip(wordButtons, frames) { button.frame = frame }
        y += wordsHeight + CGFloat(Metrics.sectionTop)
        combineLabel.frame = NSRect(
            x: labelInset - inset, y: y, width: labels + 2 * inset, height: labelHeight(combineLabel, width: labels))
        footer.frame = NSRect(x: 0, y: bounds.height - footerHeight, width: width, height: footerHeight)
        layoutButtonRow(
            [cancelButton, submitButton], right: footer.bounds.width - CGFloat(Metrics.footerHorizontal),
            y: CGFloat(Metrics.footerBorder + Metrics.footerTop), height: CGFloat(DesignTokens.controlHeights.regular),
            gap: CGFloat(Metrics.footerGap))
    }
}

/// The box's text view: Return and Tab are the box's (`AdvancedSearchBox.handleKey`), never a line break.
final class AdvancedSearchTextView: NSTextView {
    override func insertNewline(_ sender: Any?) {}
    override func insertLineBreak(_ sender: Any?) {}
    override func insertParagraphSeparator(_ sender: Any?) {}
}

/// The box around the text: the field's fill and edge, and the focus ring while the text has the keyboard.
final class AdvancedSearchShell: NSView, ThemeApplying {
    var holdsKeyboard: () -> Bool = { false }
    private var theme = AppearanceModel.shared.theme

    override var isFlipped: Bool { true }

    func applyTheme(_ theme: Theme) {
        self.theme = theme
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = CGFloat(DesignTokens.radii.control)
        let palette = theme.palette
        NSColor(palette.fieldBg).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        for layer in palette.fieldEdge where layer.blur == 0 && layer.spread > 0 {
            let inset = CGFloat(layer.spread) / 2
            let edge = NSBezierPath(roundedRect: bounds.insetBy(dx: inset, dy: inset), xRadius: radius, yRadius: radius)
            edge.lineWidth = CGFloat(layer.spread)
            NSColor(layer.color).setStroke()
            edge.stroke()
        }
        if holdsKeyboard() {
            let ring = NSBezierPath(
                roundedRect: bounds.insetBy(dx: -1.5, dy: -1.5), xRadius: radius + 1.5, yRadius: radius + 1.5)
            ring.lineWidth = CGFloat(DesignTokens.focusRingWidth)
            NSColor(theme.accent.solid.withAlpha(0.5)).setStroke()
            ring.stroke()
        }
    }
}

/// A condition's name, which types its word into the box: "Kind" types `kind:`. The mouse's way in; the keyboard types
/// the word.
final class AdvancedSearchWordButton: NSView, ThemeApplying {
    var onPress: () -> Void = {}
    private let title: String
    private let word: String
    private var theme = AppearanceModel.shared.theme
    private var hovered = false {
        didSet { if hovered != oldValue { needsDisplay = true } }
    }
    private var trackingArea: NSTrackingArea?
    static let height = DesignTokens.controlHeights.small
    private static let font = ThemeFonts.sans(DesignTokens.typeScale.callout)
    private static let wordFont = ThemeFonts.mono(DesignTokens.typeScale.mono)

    init(title: String, word: String) {
        self.title = title
        self.word = word
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Add \(title)")
        setAccessibilityIdentifier("advancedSearch.word")
        toolTip = "Types \(word)"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    func applyTheme(_ theme: Theme) {
        self.theme = theme
        needsDisplay = true
    }

    private var label: NSAttributedString {
        let result = NSMutableAttributedString(
            string: title, attributes: [.font: Self.font, .foregroundColor: NSColor(theme.palette.textPrimary)])
        result.append(
            NSAttributedString(
                string: "  " + word,
                attributes: [.font: Self.wordFont, .foregroundColor: NSColor(theme.accent.batchRenameMarkText)]))
        return result
    }

    var preferredWidth: CGFloat { ceil(label.size().width) + 20 }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self,
            userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onPress() }
    }

    override func draw(_ dirtyRect: NSRect) {
        let palette = theme.palette
        let radius = CGFloat(DesignTokens.radii.control)
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        NSColor(hovered ? palette.bgHover : palette.fieldBg).setFill()
        shape.fill()
        NSColor(palette.border).setStroke()
        shape.lineWidth = 1
        shape.stroke()
        let text = label
        let size = text.size()
        text.draw(at: NSPoint(x: 10, y: (bounds.height - size.height) / 2))
    }

    override func accessibilityPerformPress() -> Bool {
        onPress()
        return true
    }
}
