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
        window?.setContentSize(Self.size)
        themeChanged(model.theme)
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

/// The page: a title strip, and under it the intro and one disclosure entry for each component.
@MainActor
public final class AcknowledgementsView: ThemedView {
    private let titleStrip: ThemedView
    private let titleText: ThemedText
    private let scroll = NSScrollView()
    private let list: AcknowledgementList

    static let titleHeight: CGFloat = 40

    init(components: [Acknowledgement], failed: Bool, openURL: @escaping @MainActor (URL) -> Void, theme: Theme) {
        titleStrip = ThemedView(theme: theme)
        titleText = ThemedText(
            "Acknowledgements",
            style: TextStyle(
                font: ThemeFonts.sans(DesignTokens.typeScale.body, .semibold), color: { $0.palette.textPrimary },
                alignment: .center))
        list = AcknowledgementList(components: components, failed: failed, openURL: openURL, theme: theme)
        super.init(frame: NSRect(origin: .zero, size: AcknowledgementsWindowController.size), theme: theme)
        fill = { $0.palette.bgBase }
        titleStrip.fill = { $0.palette.toolbarBg }
        titleStrip.edges = [.bottom: { $0.palette.border }]
        titleText.setAccessibilityIdentifier("acknowledgements.title")
        titleStrip.addSubview(titleText)
        scroll.drawsBackground = false
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

    /// The entries, top to bottom.
    public var entries: [AcknowledgementEntryView] { list.entries }

    public var introTexts: [String] { list.introTexts }

    public override func layout() {
        super.layout()
        titleStrip.frame = NSRect(x: 0, y: 0, width: bounds.width, height: Self.titleHeight)
        let titleHeight = ThemeFonts.normalLineHeight(ThemeFonts.sans(DesignTokens.typeScale.body, .semibold))
        titleText.frame = NSRect(
            x: 0, y: ((Self.titleHeight - 1 - titleHeight) / 2).rounded(), width: bounds.width, height: titleHeight)
        scroll.frame = NSRect(
            x: 0, y: Self.titleHeight, width: bounds.width, height: max(0, bounds.height - Self.titleHeight))
        list.frame.size.width = scroll.contentSize.width
        list.layoutForWidth(scroll.contentSize.width)
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
            entry.onToggle = { [weak self] in self?.needsLayout = true; self?.layoutForWidth(self?.frame.width ?? 0) }
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

/// One component: a summary line (disclosure triangle, name and version, license on the right), and when open its
/// site and its license text.
@MainActor
public final class AcknowledgementEntryView: NSView, ThemeApplying {
    public let component: Acknowledgement
    public private(set) var isOpen = false
    public private(set) var theme: Theme
    var onToggle: () -> Void = {}
    private let openURL: @MainActor (URL) -> Void

    private let nameText: ThemedText
    private let licenseText: ThemedText
    public let link: LinkButton
    private let box: ThemedView
    private let boxScroll = NSScrollView()
    private let textView = NSTextView()

    private static let nameFont = ThemeFonts.sans(DesignTokens.typeScale.body, .semibold)
    private static let bodyFont = ThemeFonts.sans(DesignTokens.typeScale.body)
    private static let licenseFont = ThemeFonts.sans(DesignTokens.typeScale.callout)
    private static let textFont = ThemeFonts.mono(DesignTokens.typeScale.small)
    private static let summaryIndent: CGFloat = 16
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
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 12, height: 10)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        boxScroll.documentView = textView
        boxScroll.drawsBackground = false
        boxScroll.hasVerticalScroller = true
        boxScroll.scrollerStyle = .overlay
        box.addSubview(boxScroll)
        for view in [nameText, licenseText] { addSubview(view) }
        setAccessibilityRole(.disclosureTriangle)
        setAccessibilityIdentifier("acknowledgements.row")
        setAccessibilityLabel(component.name)
        applyTheme(theme)
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }

    public func applyTheme(_ theme: Theme) {
        self.theme = theme
        textView.textStorage?.setAttributedString(
            NSAttributedString(
                string: component.text,
                attributes: [
                    .font: Self.textFont, .foregroundColor: NSColor(theme.palette.textSecondary),
                    .paragraphStyle: {
                        let paragraph = NSMutableParagraphStyle()
                        let height = CGFloat(DesignTokens.typeScale.small * 1.5)
                        paragraph.minimumLineHeight = height
                        paragraph.maximumLineHeight = height
                        return paragraph
                    }(),
                ]))
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

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        if point.y < summaryHeight { toggle() }
    }

    public override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " || event.keyCode == 36 { toggle() } else { super.keyDown(with: event) }
    }

    // MARK: Layout

    /// The summary line: padding 8 above and below the text.
    private var summaryHeight: CGFloat { 8 + ThemeFonts.normalLineHeight(Self.nameFont) + 8 }

    private func boxTextHeight(forWidth width: CGFloat) -> CGFloat {
        let storage = textView.textStorage ?? NSTextStorage()
        let rect = storage.boundingRect(
            with: NSSize(width: max(1, width - 2 - 24), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading])
        return ceil(rect.height)
    }

    /// The entry's height at this width, with its bottom hairline.
    func height(forWidth width: CGFloat) -> CGFloat {
        var height = summaryHeight
        if isOpen {
            let bodyWidth = width - Self.summaryIndent
            let linkHeight = ThemeFonts.normalLineHeight(Self.licenseFont)
            let boxHeight = min(Self.boxMaxHeight, boxTextHeight(forWidth: bodyWidth) + 20 + 2)
            height += linkHeight + 10 + boxHeight + 14
        }
        return height + 1
    }

    public override func layout() {
        super.layout()
        let width = bounds.width
        let nameHeight = ThemeFonts.normalLineHeight(Self.nameFont)
        let licenseHeight = ThemeFonts.normalLineHeight(Self.licenseFont)
        let licenseWidth = ceil(licenseText.naturalWidth)
        // The license on the right; the name beside the triangle; their baselines line up.
        nameText.frame = NSRect(
            x: Self.summaryIndent, y: 8, width: max(0, width - Self.summaryIndent - licenseWidth - 16 - 20),
            height: nameHeight)
        licenseText.frame = NSRect(
            x: width - 20 - licenseWidth, y: 8 + nameHeight - licenseHeight - 1, width: licenseWidth,
            height: licenseHeight)
        guard isOpen else { return }
        let bodyX = Self.summaryIndent
        let bodyWidth = width - bodyX
        var y = summaryHeight
        let linkSize = link.preferredSize
        link.frame = NSRect(x: bodyX, y: y, width: linkSize.width, height: ThemeFonts.normalLineHeight(Self.licenseFont))
        y += ThemeFonts.normalLineHeight(Self.licenseFont) + 10
        let boxHeight = min(Self.boxMaxHeight, boxTextHeight(forWidth: bodyWidth) + 20 + 2)
        box.frame = NSRect(x: bodyX, y: y, width: bodyWidth, height: boxHeight)
        boxScroll.frame = box.bounds.insetBy(dx: 1, dy: 1)
        textView.frame.size.width = boxScroll.contentSize.width
    }

    public override func draw(_ dirtyRect: NSRect) {
        // The disclosure triangle, and the hairline under the entry.
        let color = NSColor(theme.palette.textSecondary)
        color.setFill()
        let nameHeight = ThemeFonts.normalLineHeight(Self.nameFont)
        let midY = 8 + nameHeight / 2
        let triangle = NSBezierPath()
        if isOpen {
            triangle.move(to: NSPoint(x: 1, y: midY - 2.5))
            triangle.line(to: NSPoint(x: 9, y: midY - 2.5))
            triangle.line(to: NSPoint(x: 5, y: midY + 4))
        } else {
            triangle.move(to: NSPoint(x: 2, y: midY - 4.5))
            triangle.line(to: NSPoint(x: 2, y: midY + 4.5))
            triangle.line(to: NSPoint(x: 8.5, y: midY))
        }
        triangle.close()
        triangle.fill()
        NSColor(theme.palette.border).setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }
}
