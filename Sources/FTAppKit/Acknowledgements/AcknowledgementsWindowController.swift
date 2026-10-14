// Port of apps/desktop/src/renderer/AcknowledgementsWindowApp.tsx, openAcknowledgementsWindow in main.ts and the
// .acknowledgement* rules of styles.css (ui.md section 7.3)
import AppKit
import FTFileSystem
import FTFoundation

/// The Acknowledgements window: the open-source software shipped inside the app, each with its license as shipped.
/// 620 by 640, at least 460 by 360.
@MainActor
public final class AcknowledgementsWindowController: PageWindowController {
    public static let size = NSSize(width: 620, height: 640)
    public static let minSize = NSSize(width: 460, height: 360)

    public let listView: AcknowledgementsView

    /// `load` reads the list; a failure says so in the window instead.
    public init(
        load: () throws -> [Acknowledgement] = { try Acknowledgements.read() },
        openURL: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) },
        model: AppearanceModel = .shared
    ) {
        var components: [Acknowledgement] = []
        var failed = false
        do { components = try load() } catch { failed = true }
        listView = AcknowledgementsView(
            components: components, failed: failed, openURL: openURL, theme: model.theme)
        super.init(
            spec: PageWindowSpec(title: "Acknowledgements", size: Self.size, minSize: Self.minSize), model: model)
        (window as? PageWindow)?.closesOnEscape = true
        window?.contentView = listView
        window?.initialFirstResponder = listView
        window?.setContentSize(Self.size)
        themeChanged(model.theme)
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

/// The page: a title strip, and under it the intro and one disclosure entry for each component.
@MainActor
public final class AcknowledgementsView: ThemedView {
    private let titleStrip: AcknowledgementsTitle
    private let scroll = NSScrollView()
    private let list: AcknowledgementList

    static let titleHeight: CGFloat = 40

    init(components: [Acknowledgement], failed: Bool, openURL: @escaping @MainActor (URL) -> Void, theme: Theme) {
        titleStrip = AcknowledgementsTitle(theme: theme)
        list = AcknowledgementList(components: components, failed: failed, openURL: openURL, theme: theme)
        super.init(frame: NSRect(origin: .zero, size: AcknowledgementsWindowController.size), theme: theme)
        fill = { $0.palette.bgBase }
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsetsZero
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.documentView = list
        scroll.setAccessibilityIdentifier("acknowledgements.scroll")
        addSubview(scroll)
        addSubview(titleStrip)
        setAccessibilityIdentifier("acknowledgements")
        setAccessibilityLabel("Acknowledgements")
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The view itself takes the keyboard when the window opens.
    public override var acceptsFirstResponder: Bool { true }

    /// The entries, top to bottom.
    public var entries: [AcknowledgementEntryView] { list.entries }

    public var introTexts: [String] { list.introTexts }

    public override func layout() {
        super.layout()
        titleStrip.frame = NSRect(x: 0, y: 0, width: bounds.width, height: Self.titleHeight)
        scroll.frame = NSRect(
            x: 0, y: Self.titleHeight, width: bounds.width, height: max(0, bounds.height - Self.titleHeight))
        list.frame.size.width = scroll.contentSize.width
        list.layoutForWidth(scroll.contentSize.width)
    }
}

/// The strip across the top: the window's title centered, on the toolbar's color over a hairline.
@MainActor
final class AcknowledgementsTitle: TextControl {
    init(theme: Theme) {
        super.init(text: "Acknowledgements", theme: theme)
        font = ThemeFonts.sans(DesignTokens.typeScale.body, .semibold)
        alignment = .center
        textColor = NSColor(theme.palette.textPrimary)
        setAccessibilityIdentifier("acknowledgements.title")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func applyTheme(_ theme: Theme) {
        super.applyTheme(theme)
        textColor = NSColor(theme.palette.textPrimary)
    }

    override func drawChrome() {
        NSColor(theme.palette.toolbarBg).setFill()
        bounds.fill()
        NSColor(theme.palette.border).setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

/// The scrolling content: padding 16 24 24.
@MainActor
final class AcknowledgementList: NSView, ThemeApplying {
    private(set) var entries: [AcknowledgementEntryView] = []
    private let intro: ThemedText
    private let failure: ThemedText?
    private static let introStyle = TextStyle(
        font: ThemeFonts.sans(DesignTokens.typeScale.callout), color: { $0.palette.textSecondary }, lineHeight: 1.5)

    override var isFlipped: Bool { true }

    var introTexts: [String] { [intro.stringValue] + (failure.map { [$0.stringValue] } ?? []) }

    init(components: [Acknowledgement], failed: Bool, openURL: @escaping @MainActor (URL) -> Void, theme: Theme) {
        intro = ThemedText(
            "\(AboutText.appName) is built with the open-source software below. Each one is used under its own license.",
            style: Self.introStyle, wrapping: true)
        failure = failed ? ThemedText("Couldn’t load the licenses.", style: Self.introStyle, wrapping: true) : nil
        super.init(frame: .zero)
        intro.setAccessibilityIdentifier("acknowledgements.intro")
        addSubview(intro)
        if let failure {
            failure.setAccessibilityIdentifier("acknowledgements.intro")
            addSubview(failure)
        }
        for component in components {
            let entry = AcknowledgementEntryView(component: component, openURL: openURL, theme: theme)
            entry.onToggle = { [weak self] in
                self?.needsLayout = true
                self?.layoutForWidth(self?.frame.width ?? 0)
            }
            entries.append(entry)
            addSubview(entry)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func applyTheme(_ theme: Theme) {}

    func layoutForWidth(_ width: CGFloat) {
        let left: CGFloat = 24
        let contentWidth = max(0, width - 2 * left)
        var y: CGFloat = 16
        let introHeight = intro.height(forWidth: contentWidth)
        intro.frame = NSRect(x: left, y: y, width: contentWidth, height: introHeight)
        y += introHeight + 10
        if let failure {
            let height = failure.height(forWidth: contentWidth)
            failure.frame = NSRect(x: left, y: y, width: contentWidth, height: height)
            y += height + 10
        }
        for entry in entries {
            let height = entry.height(forWidth: contentWidth)
            entry.frame = NSRect(x: left, y: y, width: contentWidth, height: height)
            entry.needsLayout = true
            y += height
        }
        frame.size = NSSize(width: width, height: y + 24)
    }
}

/// The line of an entry that opens and closes it (`<summary>`).
@MainActor
final class AcknowledgementSummary: NSView {
    var onClick: () -> Void = {}

    override var isFlipped: Bool { true }

    override func mouseDown(with event: NSEvent) { onClick() }
}

/// One component: a summary line (disclosure triangle, name and version, license on the right), and when open its
/// site and its license text.
@MainActor
public final class AcknowledgementEntryView: NSView, ThemeApplying {
    public let component: Acknowledgement
    public private(set) var isOpen = false
    public private(set) var theme: Theme
    var onToggle: () -> Void = {}
    private let openURL: @MainActor (URL) -> Void

    private let summary = AcknowledgementSummary()
    private let nameText: ThemedText
    private let licenseText: ThemedText
    public let link: LinkButton
    private let box: ThemedView
    private let boxScroll = NSScrollView()
    private let licenseBody: ThemedText
    /// What the box scrolls: the text with its padding.
    private let licenseDocument = FlippedView()

    private static let nameFont = ThemeFonts.sans(DesignTokens.typeScale.body, .semibold)
    private static let bodyFont = ThemeFonts.sans(DesignTokens.typeScale.body)
    private static let licenseFont = ThemeFonts.sans(DesignTokens.typeScale.callout)
    private static let textFont = ThemeFonts.mono(DesignTokens.typeScale.small)
    /// Where the name starts: the disclosure marker's width.
    private static let nameIndent: CGFloat = 11.17
    /// `.acknowledgement-body`: padding-left.
    private static let bodyIndent: CGFloat = 16
    private static let boxMaxHeight: CGFloat = 300

    init(component: Acknowledgement, openURL: @escaping @MainActor (URL) -> Void, theme: Theme) {
        self.component = component
        self.openURL = openURL
        self.theme = theme
        nameText = ThemedText(wrapping: false) { theme in
            let name = NSMutableAttributedString(
                string: component.name,
                attributes: [
                    .font: Self.nameFont, .foregroundColor: NSColor(theme.palette.textPrimary),
                ])
            if let version = component.version {
                name.append(
                    NSAttributedString(
                        string: " " + version,
                        attributes: [
                            .font: Self.bodyFont, .foregroundColor: NSColor(theme.palette.textSecondary),
                        ]))
            }
            return name
        }
        licenseText = ThemedText(
            component.license,
            style: TextStyle(font: Self.licenseFont, color: { $0.palette.textSecondary }, alignment: .right))
        link = LinkButton(
            title: component.url.replacingOccurrences(of: "^https://(www\\.)?", with: "", options: .regularExpression),
            fontSize: DesignTokens.typeScale.callout, theme: theme)
        box = ThemedView(theme: theme)
        var licenseStyle = TextStyle(font: Self.textFont, color: { $0.palette.textSecondary }, lineHeight: 1.5)
        licenseStyle.background = { $0.palette.bgInput.flattened(over: $0.palette.bgBase) }
        licenseBody = ThemedText(component.text, style: licenseStyle, wrapping: true, selectable: true)
        super.init(frame: .zero)
        nameText.setAccessibilityIdentifier("acknowledgements.name")
        licenseText.setAccessibilityIdentifier("acknowledgements.license")
        link.setAccessibilityIdentifier("acknowledgements.link")
        link.target = self
        link.action = #selector(openSite(_:))
        box.fill = { $0.palette.bgInput }
        box.borderColor = { $0.palette.border }
        box.cornerRadius = CGFloat(DesignTokens.radii.control)
        box.setAccessibilityIdentifier("acknowledgements.text")
        licenseBody.setAccessibilityIdentifier("acknowledgements.licenseText")
        licenseDocument.addSubview(licenseBody)
        boxScroll.documentView = licenseDocument
        boxScroll.drawsBackground = false
        boxScroll.automaticallyAdjustsContentInsets = false
        boxScroll.contentInsets = NSEdgeInsetsZero
        boxScroll.hasVerticalScroller = true
        boxScroll.scrollerStyle = .overlay
        box.addSubview(boxScroll)
        summary.onClick = { [weak self] in
            self?.window?.makeFirstResponder(self)
            self?.toggle()
        }
        summary.setAccessibilityIdentifier("acknowledgements.row")
        summary.setAccessibilityLabel(component.name)
        summary.setAccessibilityRole(.disclosureTriangle)
        addSubview(summary)
        for view in [nameText, licenseText] { addSubview(view) }
        applyTheme(theme)
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }

    public func applyTheme(_ theme: Theme) {
        self.theme = theme
        needsDisplay = true
    }

    // MARK: Opening

    public func toggle() { setOpen(!isOpen) }

    public func setOpen(_ open: Bool) {
        guard open != isOpen else { return }
        isOpen = open
        if open {
            addSubview(link)
            addSubview(box)
        } else {
            link.removeFromSuperview()
            box.removeFromSuperview()
        }
        needsDisplay = true
        onToggle()
    }

    @objc private func openSite(_ sender: Any?) {
        if let url = URL(string: component.url) { openURL(url) }
    }

    public override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " || event.keyCode == 36 {
            toggle()
        } else {
            super.keyDown(with: event)
        }
    }

    // MARK: Layout

    /// The summary line: padding 8 above and below the text.
    private var summaryHeight: CGFloat { 8 + ThemeFonts.normalLineHeight(Self.nameFont) + 8 }

    /// The license box at this width: its text, 10 and 12 in, and a 1 pt border; at most 300 tall.
    private func boxHeight(forWidth width: CGFloat) -> CGFloat {
        min(Self.boxMaxHeight, licenseBody.height(forWidth: width - 2 - 24) + 20 + 2)
    }

    /// The entry's height at this width, with its bottom hairline.
    func height(forWidth width: CGFloat) -> CGFloat {
        var height = summaryHeight
        if isOpen {
            let linkHeight = ThemeFonts.normalLineHeight(Self.licenseFont)
            height += linkHeight + 10 + boxHeight(forWidth: width - Self.bodyIndent) + 14
        }
        return height + 1
    }

    public override func layout() {
        super.layout()
        let width = bounds.width
        summary.frame = NSRect(x: 0, y: 0, width: width, height: summaryHeight)
        let nameHeight = ThemeFonts.normalLineHeight(Self.nameFont)
        let licenseHeight = ThemeFonts.normalLineHeight(Self.licenseFont)
        // The license at the right of a line 20 shorter than the entry, the name beside the marker; baselines line up.
        let licenseWidth = licenseText.naturalWidth
        let right = width - 20 + Self.nameIndent
        let nameWidth = min(nameText.naturalWidth, max(0, right - licenseWidth - 16 - Self.nameIndent))
        nameText.frame = NSRect(x: Self.nameIndent, y: 8, width: nameWidth, height: nameHeight)
        licenseText.frame = NSRect(
            x: right - licenseWidth, y: 8 + nameHeight - licenseHeight, width: licenseWidth, height: licenseHeight)
        guard isOpen else { return }
        let bodyWidth = width - Self.bodyIndent
        var y = summaryHeight
        let linkHeight = ThemeFonts.normalLineHeight(Self.licenseFont)
        link.frame = NSRect(x: Self.bodyIndent, y: y, width: link.preferredSize.width, height: linkHeight)
        y += linkHeight + 10
        let height = boxHeight(forWidth: bodyWidth)
        box.frame = NSRect(x: Self.bodyIndent, y: y, width: bodyWidth, height: height)
        boxScroll.frame = box.bounds.insetBy(dx: 1, dy: 1)
        let textWidth = bodyWidth - 2 - 24
        let textHeight = licenseBody.height(forWidth: textWidth)
        licenseBody.frame = NSRect(x: 12, y: 10, width: textWidth, height: textHeight)
        licenseDocument.frame = NSRect(x: 0, y: 0, width: boxScroll.contentSize.width, height: textHeight + 20)
    }

    public override func draw(_ dirtyRect: NSRect) {
        // The disclosure triangle, and the hairline under the entry.
        NSColor(theme.palette.textSecondary).setFill()
        let nameHeight = ThemeFonts.normalLineHeight(Self.nameFont)
        let midY = 8 + nameHeight / 2
        let triangle = NSBezierPath()
        if isOpen {
            triangle.move(to: NSPoint(x: 0, y: midY - 3.5))
            triangle.line(to: NSPoint(x: 9, y: midY - 3.5))
            triangle.line(to: NSPoint(x: 4.5, y: midY + 4))
        } else {
            triangle.move(to: NSPoint(x: 1, y: midY - 4.5))
            triangle.line(to: NSPoint(x: 1, y: midY + 4.5))
            triangle.line(to: NSPoint(x: 8, y: midY))
        }
        triangle.close()
        triangle.fill()
        NSColor(theme.palette.border).setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }
}
