// Port of the pages of apps/desktop/src/renderer/components/HelpView.tsx (TopicPage, ShortcutsPage, SearchResultsPage) and
// the .help-page rules of styles.css
import AppKit
import FTFoundation

/// What the content column shows.
enum HelpPageKind: Equatable {
    case topic(HelpTopicID)
    case results(String)
}

/// Styles of the page, from the stylesheet. `.help-page` has `line-height: 1.5`.
@MainActor
private enum PageStyle {
    static let lineHeight = 1.5
    static let title = TextStyle(
        font: ThemeFonts.sans(DesignTokens.typeScale.title1, .bold), color: { $0.palette.textPrimary },
        lineHeight: lineHeight, kern: -0.2)
    static let heading = TextStyle(
        font: ThemeFonts.sans(DesignTokens.typeScale.body, .semibold), color: { $0.palette.textPrimary },
        lineHeight: lineHeight)
    static let intro = TextStyle(
        font: ThemeFonts.sans(DesignTokens.typeScale.body), color: { $0.palette.textSecondary }, lineHeight: lineHeight)
    static let label = TextStyle(
        font: ThemeFonts.sans(DesignTokens.typeScale.body), color: { $0.palette.textPrimary }, lineHeight: lineHeight)
    static let note = TextStyle(
        font: ThemeFonts.sans(DesignTokens.typeScale.callout), color: { $0.palette.textSecondary },
        lineHeight: lineHeight)
    static let code = ThemeFonts.mono(DesignTokens.typeScale.callout)

    /// `renderInline`: plain text, and `code` in the code style. `{command}` is already the key it names.
    @MainActor
    static func inline(_ text: String, style: TextStyle, display: ShortcutDisplay, theme: Theme) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for part in HelpContent.inlineParts(text, display) {
            result.append(
                part.isCode ? code(part.text, style: style, theme: theme) : style.string(part.text, theme))
        }
        return result
    }

    /// `.help-code`: the mono font on the input fill.
    @MainActor
    static func code(_ text: String, style: TextStyle, theme: Theme) -> NSAttributedString {
        var attributes = style.attributes(theme)
        attributes[.font] = Self.code
        attributes[.foregroundColor] = NSColor(theme.palette.textPrimary)
        attributes[.backgroundColor] = NSColor(theme.palette.bgInput)
        return NSAttributedString(string: text, attributes: attributes)
    }
}

/// A row of a topic: the label at the left and what it does (`.help-row`).
@MainActor
final class HelpRowView: ThemedView {
    private let label: ThemedText
    private let detail: ThemedText
    let isFirst: Bool

    static let labelColumn: CGFloat = 180
    static let columnGap: CGFloat = 14

    init(row: HelpRow, display: ShortcutDisplay, isFirst: Bool, theme: Theme) {
        self.isFirst = isFirst
        label = ThemedText(wrapping: true, selectable: true) { theme in
            row.code
                ? PageStyle.code(row.label, style: PageStyle.label, theme: theme)
                : PageStyle.label.string(row.label, theme)
        }
        detail = ThemedText(wrapping: true, selectable: true) { theme in
            PageStyle.inline(row.description, style: PageStyle.intro, display: display, theme: theme)
        }
        super.init(theme: theme)
        if !isFirst { edges = [.top: { $0.palette.borderLight }] }
        label.setAccessibilityIdentifier("help.row.label")
        detail.setAccessibilityIdentifier("help.row.description")
        setAccessibilityIdentifier("help.row")
        addSubview(label)
        addSubview(detail)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var labelText: String { label.stringValue }
    var descriptionText: String { detail.stringValue }

    private var border: CGFloat { isFirst ? 0 : 1 }

    func height(forWidth width: CGFloat, compact: Bool) -> CGFloat {
        if compact {
            return border + 16 + label.height(forWidth: width) + 2 + detail.height(forWidth: width)
        }
        let detailWidth = width - Self.labelColumn - Self.columnGap
        return border + 16 + max(label.height(forWidth: Self.labelColumn), detail.height(forWidth: detailWidth))
    }

    func arrange(width: CGFloat, compact: Bool) {
        let top = border + 8
        if compact {
            let labelHeight = label.height(forWidth: width)
            label.frame = NSRect(x: 0, y: top, width: width, height: labelHeight)
            detail.frame = NSRect(
                x: 0, y: top + labelHeight + 2, width: width, height: detail.height(forWidth: width))
        } else {
            let detailWidth = width - Self.labelColumn - Self.columnGap
            label.frame = NSRect(x: 0, y: top, width: Self.labelColumn, height: label.height(forWidth: Self.labelColumn))
            detail.frame = NSRect(
                x: Self.labelColumn + Self.columnGap, y: top, width: detailWidth, height: detail.height(forWidth: detailWidth))
        }
    }
}

/// A shortcut and the keys that do it (`.help-shortcut-row`).
@MainActor
final class HelpShortcutRowView: ThemedView {
    private let detail: ThemedText
    private(set) var keycaps: [KeycapView]
    let isFirst: Bool

    init(item: HelpShownShortcut, isFirst: Bool, theme: Theme) {
        self.isFirst = isFirst
        detail = ThemedText(item.description, style: PageStyle.label, wrapping: true, selectable: true)
        keycaps = ShortcutLabels.parts(item.shortcut).map { KeycapView(key: $0, theme: theme) }
        super.init(theme: theme)
        if !isFirst { edges = [.top: { $0.palette.borderLight }] }
        detail.setAccessibilityIdentifier("help.shortcutRow.description")
        setAccessibilityIdentifier("help.shortcutRow")
        addSubview(detail)
        for keycap in keycaps {
            keycap.setAccessibilityIdentifier("help.keycap")
            addSubview(keycap)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var descriptionText: String { detail.stringValue }
    var keys: [String] { keycaps.map(\.key) }

    private var border: CGFloat { isFirst ? 0 : 1 }
    private var keysWidth: CGFloat {
        keycaps.reduce(0) { $0 + $1.preferredWidth } + CGFloat(max(0, keycaps.count - 1)) * 3
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        let detailWidth = width - keysWidth - 14
        return border + 16 + max(detail.height(forWidth: detailWidth), CGFloat(KeycapView.height))
    }

    func arrange(width: CGFloat) {
        let detailWidth = width - keysWidth - 14
        let inner = height(forWidth: width) - border - 16
        let detailHeight = detail.height(forWidth: detailWidth)
        detail.frame = NSRect(x: 0, y: border + 8 + (inner - detailHeight) / 2, width: detailWidth, height: detailHeight)
        var x = width - keysWidth
        for keycap in keycaps {
            let keyWidth = keycap.preferredWidth
            keycap.frame = NSRect(
                x: x, y: border + 8 + (inner - CGFloat(KeycapView.height)) / 2, width: keyWidth,
                height: CGFloat(KeycapView.height))
            x += keyWidth + 3
        }
    }
}

/// The remark under a section's rows, in an accent-soft box (`.help-note`).
@MainActor
final class HelpNoteView: ThemedView {
    private let text: ThemedText

    init(note: String, display: ShortcutDisplay, theme: Theme) {
        text = ThemedText(wrapping: true, selectable: true) { theme in
            PageStyle.inline(note, style: PageStyle.note, display: display, theme: theme)
        }
        super.init(theme: theme)
        fill = { $0.accent.softBg }
        cornerRadius = CGFloat(DesignTokens.radii.menu)
        text.setAccessibilityIdentifier("help.note")
        setAccessibilityIdentifier("help.noteBox")
        addSubview(text)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func height(forWidth width: CGFloat) -> CGFloat { 16 + text.height(forWidth: width - 24) }

    func arrange(width: CGFloat) {
        text.frame = NSRect(x: 12, y: 8, width: width - 24, height: text.height(forWidth: width - 24))
    }
}

/// A section's heading and its rows or shortcuts, laid out down the column.
@MainActor
final class HelpSectionView: NSView {
    let heading: ThemedText
    var rows: [HelpRowView] = []
    var shortcutRows: [HelpShortcutRowView] = []
    var note: HelpNoteView?
    /// The space above the heading: 22 in a page, 0 for the first of a column.
    var topMargin: CGFloat
    var bottomPadding: CGFloat = 0

    override var isFlipped: Bool { true }

    init(title: String, topMargin: CGFloat = 22) {
        heading = ThemedText(title, style: PageStyle.heading, wrapping: true)
        self.topMargin = topMargin
        super.init(frame: .zero)
        heading.setAccessibilityIdentifier("help.sectionTitle")
        setAccessibilityIdentifier("help.section")
        addSubview(heading)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func add(rows newRows: [HelpRowView]) {
        rows += newRows
        newRows.forEach(addSubview)
    }

    func add(shortcuts newRows: [HelpShortcutRowView]) {
        shortcutRows += newRows
        newRows.forEach(addSubview)
    }

    func set(note view: HelpNoteView) {
        note = view
        addSubview(view)
    }

    /// Positions the parts and answers the section's height (from the heading's top margin, not counting it).
    @discardableResult
    func arrange(width: CGFloat, compact: Bool) -> CGFloat {
        var y: CGFloat = 0
        let headingHeight = heading.height(forWidth: width)
        heading.frame = NSRect(x: 0, y: y, width: width, height: headingHeight)
        y += headingHeight + 4
        for row in rows {
            let height = row.height(forWidth: width, compact: compact)
            row.frame = NSRect(x: 0, y: y, width: width, height: height)
            row.arrange(width: width, compact: compact)
            y += height
        }
        for row in shortcutRows {
            let height = row.height(forWidth: width)
            row.frame = NSRect(x: 0, y: y, width: width, height: height)
            row.arrange(width: width)
            y += height
        }
        if let note {
            y += 8
            let height = note.height(forWidth: width)
            note.frame = NSRect(x: 0, y: y, width: width, height: height)
            note.arrange(width: width)
            y += height
        }
        return y + bottomPadding
    }
}

/// The page itself: the title, the introduction and the sections, in a column at most 720 wide.
@MainActor
final class HelpPageView: NSView, ThemeApplying {
    let kind: HelpPageKind
    private(set) var theme: Theme
    private let title: ThemedText
    private var intro: ThemedText?
    private(set) var action: PushButton?
    private(set) var sections: [HelpSectionView] = []
    /// The shortcuts page puts its groups in columns.
    private var columnSections = false
    private var customizeTarget: ClosureTarget?

    static let maxWidth: CGFloat = 720

    override var isFlipped: Bool { true }

    init(
        kind: HelpPageKind, display: ShortcutDisplay, theme: Theme, onCustomize: (() -> Void)?
    ) {
        self.kind = kind
        self.theme = theme
        let titleText: String
        switch kind {
        case .topic(let id): titleText = HelpContent.topic(id).title
        case .results(let query): titleText = "Results for “\(query)”"
        }
        title = ThemedText(titleText, style: PageStyle.title, wrapping: true, selectable: true)
        super.init(frame: .zero)
        title.setAccessibilityIdentifier("help.pageTitle")
        addSubview(title)
        switch kind {
        case .topic(.shortcuts): buildShortcuts(display: display, theme: theme, onCustomize: onCustomize)
        case .topic(let id): buildTopic(HelpContent.topic(id), display: display, theme: theme)
        case .results(let query): buildResults(query, display: display, theme: theme)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func applyTheme(_ theme: Theme) { self.theme = theme }

    private func addIntro(_ text: String, display: ShortcutDisplay, filled: Bool) {
        let view = ThemedText(wrapping: true, selectable: true) { theme in
            filled
                ? PageStyle.inline(text, style: PageStyle.intro, display: display, theme: theme)
                : PageStyle.intro.string(text, theme)
        }
        view.setAccessibilityIdentifier("help.intro")
        intro = view
        addSubview(view)
    }

    private func rows(_ rows: [HelpRow], display: ShortcutDisplay, theme: Theme) -> [HelpRowView] {
        rows.enumerated().map {
            HelpRowView(row: $0.element, display: display, isFirst: $0.offset == 0, theme: theme)
        }
    }

    private func shortcutRows(_ items: [HelpShownShortcut], theme: Theme) -> [HelpShortcutRowView] {
        items.enumerated().map { HelpShortcutRowView(item: $0.element, isFirst: $0.offset == 0, theme: theme) }
    }

    private func buildTopic(_ topic: HelpTopic, display: ShortcutDisplay, theme: Theme) {
        addIntro(topic.intro, display: display, filled: true)
        for section in topic.sections {
            let view = HelpSectionView(title: section.title)
            view.add(rows: rows(section.rows, display: display, theme: theme))
            if let note = section.note { view.set(note: HelpNoteView(note: note, display: display, theme: theme)) }
            sections.append(view)
            addSubview(view)
        }
        let shortcuts = HelpContent.listShortcuts(display).filter { $0.group.topicID == topic.id }
        if !shortcuts.isEmpty {
            let view = HelpSectionView(title: "Shortcuts")
            view.add(shortcuts: shortcutRows(shortcuts, theme: theme))
            sections.append(view)
            addSubview(view)
        }
    }

    private func buildShortcuts(display: ShortcutDisplay, theme: Theme, onCustomize: (() -> Void)?) {
        let topic = HelpContent.topic(.shortcuts)
        addIntro(topic.intro, display: display, filled: false)
        if let onCustomize {
            let button = PushButton(title: "Customize…", theme: theme)
            button.setAccessibilityIdentifier("help.action")
            let target = ClosureTarget(onCustomize)
            customizeTarget = target
            button.target = target
            button.action = ClosureTarget.selector
            action = button
            addSubview(button)
        }
        let shown = HelpContent.listShortcuts(display)
        columnSections = true
        for group in HelpContent.shortcutGroups {
            let view = HelpSectionView(title: HelpContent.topic(group.topicID).title, topMargin: 0)
            view.add(shortcuts: shortcutRows(shown.filter { $0.group == group }, theme: theme))
            view.bottomPadding = 22
            sections.append(view)
            addSubview(view)
        }
    }

    private func buildResults(_ query: String, display: ShortcutDisplay, theme: Theme) {
        let results = HelpContent.search(query, display)
        if results.isEmpty {
            addIntro("Nothing in Help matches. Try a shorter or different word.", display: display, filled: false)
        }
        for result in results {
            let view = HelpSectionView(title: result.topic.title)
            if !result.rows.isEmpty {
                view.add(rows: rows(result.rows.map(\.row), display: display, theme: theme))
            }
            if !result.shortcuts.isEmpty { view.add(shortcuts: shortcutRows(result.shortcuts, theme: theme)) }
            sections.append(view)
            addSubview(view)
        }
    }

    // MARK: Layout

    /// Puts the parts in a column `width` wide (the column's own, padding aside); answers the height.
    @discardableResult
    func arrange(width: CGFloat, compact: Bool) -> CGFloat {
        var y: CGFloat = 0
        let titleHeight = title.height(forWidth: width)
        title.frame = NSRect(x: 0, y: y, width: width, height: titleHeight)
        y += titleHeight
        if let intro {
            y += 4
            let height = intro.height(forWidth: width)
            intro.frame = NSRect(x: 0, y: y, width: width, height: height)
            y += height
        }
        if let action {
            y += 10
            action.frame = NSRect(x: 0, y: y, width: action.preferredWidth, height: CGFloat(PushButton.height))
            y += CGFloat(PushButton.height) + 12
        }
        if columnSections {
            return y + 22 + arrangeColumns(top: y + 22, width: width, compact: compact)
        }
        for section in sections {
            y += section.topMargin
            let height = section.arrange(width: width, compact: compact)
            section.frame = NSRect(x: 0, y: y, width: width, height: height)
            y += height
        }
        return y
    }

    /// `columns: 2 300px; column-gap: 36px`: groups that do not break, in as many columns of at least 300 as fit, filled
    /// evenly. Answers the height of the columns.
    private func arrangeColumns(top: CGFloat, width: CGFloat, compact: Bool) -> CGFloat {
        let gap: CGFloat = 36
        let count = width >= 2 * 300 + gap ? 2 : 1
        let columnWidth = (width - CGFloat(count - 1) * gap) / CGFloat(count)
        let heights = sections.map { $0.arrange(width: columnWidth, compact: compact) }
        // The split that makes the columns most even, groups kept whole and in order.
        var split = sections.count
        if count == 2 {
            var best = CGFloat.greatestFiniteMagnitude
            for candidate in 1...max(1, sections.count) {
                let first = heights.prefix(candidate).reduce(0, +)
                let second = heights.dropFirst(candidate).reduce(0, +)
                if max(first, second) < best {
                    best = max(first, second)
                    split = candidate
                }
            }
        }
        var tallest: CGFloat = 0
        var x: CGFloat = 0
        var y = top
        for (index, section) in sections.enumerated() {
            if index == split {
                tallest = max(tallest, y - top)
                x = columnWidth + gap
                y = top
            }
            section.frame = NSRect(x: x, y: y, width: columnWidth, height: heights[index])
            y += heights[index]
        }
        return max(tallest, y - top)
    }

    // MARK: Introspection

    /// Every shortcut row on the page.
    var allShortcutRows: [HelpShortcutRowView] { sections.flatMap(\.shortcutRows) }
    var allRows: [HelpRowView] { sections.flatMap(\.rows) }
    var introText: String? { intro?.stringValue }
    var titleText: String { title.stringValue }
}

/// Lets a plain closure be the target of a control (a control keeps its target unretained).
@MainActor
final class ClosureTarget: NSObject {
    static let selector = #selector(ClosureTarget.fire(_:))
    private let handler: () -> Void

    init(_ handler: @escaping () -> Void) { self.handler = handler }

    @objc func fire(_ sender: Any?) { handler() }
}
