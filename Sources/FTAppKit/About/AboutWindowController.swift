// Port of apps/desktop/src/renderer/AboutWindowApp.tsx, openAboutWindow in apps/desktop/src/main/main.ts and the
// .about-* rules of styles.css (ui.md section 7.2)
import AppKit
import FTFileSystem
import FTFoundation

/// What About needs of the rest of the app; tests stand in for each.
@MainActor
public struct AboutActions {
    /// Puts text on the clipboard; false when it could not.
    public var copyText: @MainActor (String) -> Bool
    public var openURL: @MainActor (URL) -> Void
    public var openAcknowledgements: @MainActor () -> Void
    public var scheduler: any FolderWatchScheduler

    public init(
        copyText: @escaping @MainActor (String) -> Bool = AboutActions.copyToPasteboard,
        openURL: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) },
        openAcknowledgements: @escaping @MainActor () -> Void = {},
        scheduler: any FolderWatchScheduler = DispatchFolderWatchScheduler()
    ) {
        self.copyText = copyText
        self.openURL = openURL
        self.openAcknowledgements = openAcknowledgements
        self.scheduler = scheduler
    }

    public static func copyToPasteboard(_ text: String) -> Bool {
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(text, forType: .string)
    }
}

/// The About window: what the app is, the versions a bug report needs, and the way to the project and to the licenses of
/// the software inside it. 460 by 356, not resizable; replaces the standard About panel.
@MainActor
public final class AboutWindowController: PageWindowController {
    public static let contentSize = NSSize(width: 460, height: 356)
    /// COPIED_NOTE_MS.
    public static let copiedNoteMilliseconds = 1500.0

    public let aboutView: AboutView

    public init(info: AboutInfo?, actions: AboutActions, model: AppearanceModel = .shared) {
        aboutView = AboutView(info: info, actions: actions, theme: model.theme)
        super.init(
            spec: PageWindowSpec(
                title: "About \(AboutText.appName)", size: Self.contentSize, resizable: false, minimizable: false),
            model: model)
        (window as? PageWindow)?.closesOnEscape = true
        window?.contentView = aboutView
        window?.initialFirstResponder = aboutView
        window?.setContentSize(Self.contentSize)
        themeChanged(model.theme)
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

/// The page: the title strip, the header, the rows, the buttons and the footer.
@MainActor
public final class AboutView: ThemedView {
    private let info: AboutInfo?
    private let actions: AboutActions
    /// The icon's 72 by 72 place; its image is drawn a little larger inside it.
    private let icon = NSView()
    private let iconImage = NSImageView()
    private let name: ThemedText
    private let tagline: ThemedText
    private var labels: [ThemedText] = []
    private var values: [ThemedText] = []
    public let copyButton: PushButton
    public let gitHubButton: PushButton
    public let issuesButton: PushButton
    public let acknowledgementsLink: LinkButton
    private let copyright: ThemedText
    private var cancelCopiedNote: (() -> Void)?
    public private(set) var copied = false

    // padding 0 28px 18px; the title strip is 40 tall; the header has 2 above and 18 below.
    private static let sidePadding: CGFloat = 28
    private static let bottomPadding: CGFloat = 18
    private static let titleStrip: CGFloat = 40
    private static let iconSize: CGFloat = 72

    private static let nameStyle = TextStyle(
        font: ThemeFonts.sans(DesignTokens.typeScale.title1, .semibold), color: { $0.palette.textPrimary },
        lineHeight: 1.25)
    private static let taglineStyle = TextStyle(
        font: ThemeFonts.sans(DesignTokens.typeScale.body), color: { $0.palette.textSecondary })
    private static let labelStyle = TextStyle(
        font: ThemeFonts.sans(DesignTokens.typeScale.callout), color: { $0.palette.textSecondary })
    private static let valueStyle = TextStyle(
        font: ThemeFonts.sans(DesignTokens.typeScale.callout), color: { $0.palette.textPrimary })
    private static let footerStyle = TextStyle(
        font: ThemeFonts.sans(DesignTokens.typeScale.small), color: { $0.palette.textSecondary })

    init(info: AboutInfo?, actions: AboutActions, theme: Theme) {
        self.info = info
        self.actions = actions
        name = ThemedText(AboutText.appName, style: Self.nameStyle)
        tagline = ThemedText(AboutText.tagline, style: Self.taglineStyle)
        copyButton = PushButton(title: "Copy Details", theme: theme)
        gitHubButton = PushButton(title: "GitHub", theme: theme)
        issuesButton = PushButton(title: "Report an Issue", theme: theme)
        acknowledgementsLink = LinkButton(
            title: "Acknowledgements", fontSize: DesignTokens.typeScale.small, theme: theme)
        copyright = ThemedText(AboutText.copyright, style: Self.footerStyle)
        super.init(frame: NSRect(origin: .zero, size: AboutWindowController.contentSize), theme: theme)
        fill = { $0.palette.bgBase }

        iconImage.image = NSApp.applicationIconImage
        iconImage.imageScaling = .scaleProportionallyUpOrDown
        iconImage.setAccessibilityElement(false)
        icon.addSubview(iconImage)
        icon.setAccessibilityElement(false)
        icon.setAccessibilityIdentifier("about.icon")
        name.setAccessibilityIdentifier("about.title")
        tagline.setAccessibilityIdentifier("about.tagline")
        copyright.setAccessibilityIdentifier("about.copyright")
        for (button, id) in [
            (copyButton, "about.button"), (gitHubButton, "about.button"), (issuesButton, "about.button"),
        ] {
            button.setAccessibilityIdentifier(id)
            addSubview(button)
        }
        acknowledgementsLink.setAccessibilityIdentifier("about.link")
        setAccessibilityIdentifier("about")
        setAccessibilityLabel("About \(AboutText.appName)")

        copyButton.target = self
        copyButton.action = #selector(copyDetails(_:))
        copyButton.isEnabled = info != nil
        gitHubButton.target = self
        gitHubButton.action = #selector(openGitHub(_:))
        issuesButton.target = self
        issuesButton.action = #selector(openIssues(_:))
        acknowledgementsLink.target = self
        acknowledgementsLink.action = #selector(openAcknowledgements(_:))

        for subview in [icon, name, tagline, acknowledgementsLink, copyright] { addSubview(subview) }
        // The details: a row each; none while the info could not be read.
        for row in info.map(AboutText.rows) ?? [] {
            let label = ThemedText(row.label, style: Self.labelStyle, selectable: true)
            let value = ThemedText(row.value, style: Self.valueStyle, selectable: true)
            label.setAccessibilityIdentifier("about.row.label")
            value.setAccessibilityIdentifier("about.row.value")
            labels.append(label)
            values.append(value)
            addSubview(label)
            addSubview(value)
        }
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The view itself takes the keyboard when the window opens, so no button shows a focus ring.
    public override var acceptsFirstResponder: Bool { true }

    public override func applyTheme(_ theme: Theme) {
        super.applyTheme(theme)
        // The edges of the details are the theme's `--border`.
        edges = [:]
    }

    // MARK: Layout

    private static var rowHeight: CGFloat {
        8 + ThemeFonts.normalLineHeight(ThemeFonts.sans(DesignTokens.typeScale.callout)) + 8 + 1
    }

    /// The y of the line above the first row.
    static var detailsTop: CGFloat { titleStrip + 2 + iconSize + 18 }

    public override func layout() {
        super.layout()
        let width = bounds.width
        let contentWidth = width - 2 * Self.sidePadding
        let iconTop = Self.titleStrip + 2
        // The app's icon file has a margin around its artwork that the original's SVG has not: drawn a little larger so
        // the artwork is as big as the original's.
        let iconDraw = Self.iconSize * 1.085
        icon.frame = NSRect(x: Self.sidePadding, y: iconTop, width: Self.iconSize, height: Self.iconSize)
        iconImage.frame = NSRect(
            x: -(iconDraw - Self.iconSize) / 2, y: -(iconDraw - Self.iconSize) / 2, width: iconDraw, height: iconDraw)

        // The name and the tagline, centered on the icon: 1.25 line height, 3 between, then the tagline's own.
        let nameHeight = ceil(CGFloat(DesignTokens.typeScale.title1) * 1.25)
        let taglineHeight = ThemeFonts.normalLineHeight(ThemeFonts.sans(DesignTokens.typeScale.body))
        let blockHeight = nameHeight + 3 + taglineHeight
        let textLeft = Self.sidePadding + Self.iconSize + 16
        let blockTop = iconTop + (Self.iconSize - blockHeight) / 2
        // The column is as wide as its wider line.
        let textWidth = min(
            width - textLeft - Self.sidePadding, max(ceil(name.naturalWidth), ceil(tagline.naturalWidth)))
        name.frame = NSRect(x: textLeft, y: blockTop, width: textWidth, height: nameHeight)
        tagline.frame = NSRect(x: textLeft, y: blockTop + nameHeight + 3, width: textWidth, height: taglineHeight)

        // The details, between hairlines.
        let rowHeight = Self.rowHeight
        let textHeight = rowHeight - 17
        for index in labels.indices {
            let top = Self.detailsTop + 1 + CGFloat(index) * rowHeight
            let valueWidth = ceil(values[index].naturalWidth)
            labels[index].frame = NSRect(
                x: Self.sidePadding, y: top + 8, width: ceil(labels[index].naturalWidth), height: textHeight)
            values[index].frame = NSRect(
                x: Self.sidePadding + contentWidth - valueWidth, y: top + 8, width: valueWidth, height: textHeight)
        }

        // The buttons, 16 under the last row, 8 apart.
        let detailsBottom = Self.detailsTop + 1 + CGFloat(labels.count) * rowHeight
        let buttonsTop = detailsBottom + 16
        var x = Self.sidePadding
        for button in [copyButton, gitHubButton, issuesButton] {
            let buttonWidth = button.preferredWidth
            button.frame = NSRect(x: x, y: buttonsTop, width: buttonWidth, height: CGFloat(PushButton.height))
            x += buttonWidth + 8
        }

        // The footer sits at the bottom.
        let footerHeight = ThemeFonts.normalLineHeight(ThemeFonts.sans(DesignTokens.typeScale.small))
        let footerTop = bounds.height - Self.bottomPadding - footerHeight
        let linkSize = acknowledgementsLink.preferredSize
        acknowledgementsLink.frame = NSRect(
            x: Self.sidePadding, y: footerTop, width: linkSize.width, height: footerHeight)
        let copyrightWidth = ceil(copyright.naturalWidth)
        copyright.frame = NSRect(
            x: width - Self.sidePadding - copyrightWidth, y: footerTop, width: copyrightWidth, height: footerHeight)
    }

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // Hairlines of the details: above the first row and under each.
        guard !labels.isEmpty else { return }
        NSColor(theme.palette.border).setFill()
        let left = Self.sidePadding
        let width = bounds.width - 2 * Self.sidePadding
        NSRect(x: left, y: Self.detailsTop, width: width, height: 1).fill()
        for index in labels.indices {
            let bottom = Self.detailsTop + 1 + CGFloat(index + 1) * Self.rowHeight - 1
            NSRect(x: left, y: bottom, width: width, height: 1).fill()
        }
    }

    // MARK: Actions

    /// The rows as shown, label and value.
    public var rows: [(label: String, value: String)] {
        zip(labels, values).map { ($0.stringValue, $1.stringValue) }
    }

    @objc private func copyDetails(_ sender: Any?) {
        guard let info, actions.copyText(AboutText.formatAboutDetails(info)) else { return }
        copied = true
        copyButton.title = "Copied"
        cancelCopiedNote?()
        cancelCopiedNote = actions.scheduler.schedule(afterMilliseconds: AboutWindowController.copiedNoteMilliseconds) {
            [weak self] in
            self?.copied = false
            self?.copyButton.title = "Copy Details"
        }
        needsLayout = true
    }

    @objc private func openGitHub(_ sender: Any?) {
        if let url = URL(string: AboutText.repositoryURL) { actions.openURL(url) }
    }

    @objc private func openIssues(_ sender: Any?) {
        if let url = URL(string: AboutText.issuesURL) { actions.openURL(url) }
    }

    @objc private func openAcknowledgements(_ sender: Any?) {
        actions.openAcknowledgements()
    }

    isolated deinit { cancelCopiedNote?() }
}
