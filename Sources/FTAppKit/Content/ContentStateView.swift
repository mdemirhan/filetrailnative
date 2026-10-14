// Port of ContentState, EmptyState and the filter state (apps/desktop/src/renderer/components/ContentPane.tsx:546-561,
// 2355-2466) and the `.content-state` rules of styles.css:2972-3050
import AppKit
import FTFoundation

/// What the pane says in place of items.
enum ContentStateKind: Equatable {
    case none
    /// "Loading…", after the delay.
    case loading
    case error(message: String)
    /// The Trash, which macOS lists only for an app with Full Disk Access.
    case fullDiskAccess
    /// "Empty folder" and its variants; the text is complete.
    case empty(text: String)
    /// A filter nothing matches.
    case noMatches(query: String)
}

/// The cards and the quiet line of the states, laid out by hand over the area below the list's header.
final class ContentStateView: NSView {
    private(set) var kind: ContentStateKind = .none
    var onOpenPrivacySettings: () -> Void = {}
    var onSearchSubfolders: (() -> Void)?

    private let stateLayout = ContentStateLayout.standard
    private var theme = AppearanceModel.shared.theme
    private let card = ThemedView()
    private var title: ThemedText?
    private var message: ThemedText?
    private var line: ThemedText?
    private var button: PushButton?
    private var searchButton: PushButton?

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        isHidden = true
        card.setAccessibilityIdentifier("content.state")
        card.cornerRadius = CGFloat(DesignTokens.radii.menu)
        addSubview(card)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The pointer goes through the empty parts to the list below.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    func show(_ next: ContentStateKind, theme: Theme) {
        self.theme = theme
        kind = next
        for view in [title, message, line, button, searchButton] as [NSView?] { view?.removeFromSuperview() }
        title = nil
        message = nil
        line = nil
        button = nil
        searchButton = nil
        isHidden = next == .none
        card.isHidden = true
        if next == .none { return }
        let type = DesignTokens.typeScale
        let strong = TextStyle(
            font: ThemeFonts.sans(type.body, .bold), color: { $0.palette.textPrimary })
        let plain = TextStyle(font: ThemeFonts.sans(type.body), color: { $0.palette.textSecondary })
        let quiet = TextStyle(font: ThemeFonts.sans(type.callout), color: { $0.palette.textSecondary })
        func text(_ string: String, _ style: TextStyle, id: String, wrapping: Bool = false) -> ThemedText {
            let made = ThemedText(string, style: style, wrapping: wrapping)
            made.setAccessibilityIdentifier(id)
            addSubview(made)
            return made
        }
        switch next {
        case .none:
            break
        case .loading:
            card.isHidden = false
            card.borderColor = { $0.palette.border }
            title = text(ContentStateText.loading, strong, id: "content.state.title")
        case .error(let messageText):
            card.isHidden = false
            card.borderColor = { $0.palette.danger.withAlpha(0.18) }
            title = text(ContentStateText.errorTitle, strong, id: "content.state.title")
            message = text(messageText, plain, id: "content.state.message", wrapping: true)
        case .fullDiskAccess:
            card.isHidden = false
            card.borderColor = { $0.palette.danger.withAlpha(0.18) }
            title = text(ContentStateText.fullDiskAccessTitle, strong, id: "content.state.title")
            message = text(ContentStateText.fullDiskAccessMessage, plain, id: "content.state.message", wrapping: true)
            let push = PushButton(title: ContentStateText.openPrivacySettings, theme: theme)
            push.isDefault = true
            push.target = self
            push.action = #selector(openPrivacySettings(_:))
            push.setAccessibilityIdentifier("content.state.button")
            addSubview(push)
            button = push
        case .empty(let string):
            card.isHidden = false
            card.borderColor = nil
            line = text(string, quiet, id: "content.state.empty")
        case .noMatches(let query):
            card.isHidden = false
            card.borderColor = nil
            line = text(ContentStateText.noMatches(query: query), quiet, id: "content.state.empty")
            message = text(ContentStateText.noMatchesMessage, plain, id: "content.state.message", wrapping: true)
            if onSearchSubfolders != nil {
                let push = PushButton(title: ContentStateText.searchSubfolders, theme: theme)
                push.target = self
                push.action = #selector(searchSubfolders(_:))
                push.setAccessibilityIdentifier("content.state.button")
                addSubview(push)
                searchButton = push
            }
        }
        card.applyTheme(theme)
        needsLayout = true
    }

    @objc private func openPrivacySettings(_ sender: Any?) { onOpenPrivacySettings() }
    @objc private func searchSubfolders(_ sender: Any?) { onSearchSubfolders?() }

    override func layout() {
        super.layout()
        let width = bounds.width
        switch kind {
        case .none:
            return
        case .loading, .error, .fullDiskAccess:
            layoutCard(width: width)
        case .empty, .noMatches:
            layoutQuiet(width: width)
        }
    }

    /// A bordered card: 6 in from the pane's sides, padded 16 by 18, its parts a gap of 8 apart.
    private func layoutCard(width: CGFloat) {
        let margin = CGFloat(stateLayout.cardMarginHorizontal)
        let border = CGFloat(1)
        let inner = max(0, width - 2 * margin - 2 * border - 2 * CGFloat(stateLayout.paddingHorizontal))
        var y = border + CGFloat(stateLayout.paddingVertical)
        let x = margin + border + CGFloat(stateLayout.paddingHorizontal)
        var parts: [(NSView, CGFloat)] = []
        if let title { parts.append((title, title.height(forWidth: inner))) }
        if let message { parts.append((message, message.height(forWidth: inner))) }
        for (index, part) in parts.enumerated() {
            part.0.frame = NSRect(x: x, y: y, width: inner, height: part.1)
            y += part.1 + (index < parts.count - 1 ? CGFloat(stateLayout.gap) : 0)
        }
        if let button {
            y += CGFloat(stateLayout.gap) + CGFloat(stateLayout.actionsTopMargin)
            let buttonWidth = button.preferredWidth
            button.frame = NSRect(x: x, y: y, width: buttonWidth, height: PushButton.height)
            y += PushButton.height
        }
        y += CGFloat(stateLayout.paddingVertical) + border
        card.frame = NSRect(x: margin, y: 0, width: max(0, width - 2 * margin), height: y)
    }

    /// One quiet line, centered in the area less 24 (`min-height: calc(100% - 24px)`).
    private func layoutQuiet(width: CGFloat) {
        let areaHeight = max(0, bounds.height - CGFloat(stateLayout.emptyHeightReduction))
        card.frame = NSRect(x: 0, y: 0, width: width, height: areaHeight)
        var parts: [(NSView, CGFloat, CGFloat)] = []
        let inner = max(0, width - 2 * CGFloat(stateLayout.emptyPaddingHorizontal))
        for part in [line, message] {
            if let part { parts.append((part, min(part.naturalWidth, inner), part.height(forWidth: inner))) }
        }
        let gap = CGFloat(stateLayout.gap)
        var total = parts.reduce(0) { $0 + $1.2 } + CGFloat(max(0, parts.count - 1)) * gap
        if let searchButton { total += gap + PushButton.height; _ = searchButton }
        var y = max(CGFloat(stateLayout.emptyPaddingVertical), (areaHeight - total) / 2)
        for part in parts {
            part.0.frame = NSRect(x: ((width - part.1) / 2), y: y, width: part.1, height: part.2)
            y += part.2 + gap
        }
        if let searchButton {
            let buttonWidth = searchButton.preferredWidth
            searchButton.frame = NSRect(
                x: (width - buttonWidth) / 2, y: y, width: buttonWidth, height: PushButton.height)
        }
    }
}
