// Port of apps/desktop/src/renderer/components/CopyPasteRuntimeConflictDialog.tsx (the alert, FingerprintCard) and of
// where AppDialogs.tsx (:497-511) shows it, with the .copy-paste-conflict-* rules of styles.css
import AppKit
import FTFoundation
import FTOperations

/// What sits under the runtime conflict alert's message: the two cards comparing the item that is there with the one
/// on its way, and "Do the same for similar changes".
@MainActor
final class RuntimeConflictAccessory: NSView, AlertAccessory, ThemeApplying {
    let cards: [ConflictCardView]
    let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    let checkboxLabel: ThemedText
    private var theme = AppearanceModel.shared.theme

    init(text: RuntimeConflictText) {
        cards = text.cards.map(ConflictCardView.init)
        var style = TextStyle(font: ThemeFonts.sans(DesignTokens.typeScale.callout), color: { $0.palette.textPrimary })
        style.background = { $0.palette.bgElevated }
        checkboxLabel = ThemedText(text.checkboxLabel, style: style, wrapping: true)
        super.init(frame: .zero)
        setAccessibilityIdentifier("conflictAlert.accessory")
        for card in cards { addSubview(card) }
        checkbox.setAccessibilityLabel(text.checkboxLabel)
        checkbox.setAccessibilityIdentifier("conflictAlert.applyToRemaining")
        checkboxLabel.setAccessibilityIdentifier("conflictAlert.applyToRemaining.label")
        addSubview(checkbox)
        addSubview(checkboxLabel)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    var applyToRemaining: Bool { checkbox.state == .on }

    func applyTheme(_ theme: Theme) {
        self.theme = theme
        needsDisplay = true
    }

    private var boxSize: NSSize { checkbox.fittingSize }

    private func cardWidth(_ width: CGFloat) -> CGFloat {
        max(0, (width - CGFloat(CopyPasteSheetLayout.cardGap)) / 2)
    }

    private func checkboxRowHeight(_ width: CGFloat) -> CGFloat {
        let labelWidth = max(1, width - boxSize.width - CGFloat(CopyPasteSheetLayout.checkboxGap))
        return max(boxSize.height, ceil(checkboxLabel.height(forWidth: labelWidth)))
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        let cardsHeight = cards.map { $0.height(forWidth: cardWidth(width)) }.max() ?? 0
        return cardsHeight + CGFloat(DialogLayout.Alert.wideAccessorySpacing) + checkboxRowHeight(width)
    }

    override func layout() {
        super.layout()
        let width = cardWidth(bounds.width)
        let cardsHeight = cards.map { $0.height(forWidth: width) }.max() ?? 0
        for (index, card) in cards.enumerated() {
            card.frame = NSRect(
                x: CGFloat(index) * (width + CGFloat(CopyPasteSheetLayout.cardGap)), y: 0, width: width,
                height: cardsHeight)
        }
        let top = cardsHeight + CGFloat(DialogLayout.Alert.wideAccessorySpacing)
        let row = checkboxRowHeight(bounds.width)
        let box = boxSize
        checkbox.frame = NSRect(x: 0, y: top + (row - box.height) / 2, width: box.width, height: box.height)
        let labelX = box.width + CGFloat(CopyPasteSheetLayout.checkboxGap)
        let labelWidth = max(0, bounds.width - labelX)
        let labelHeight = ceil(checkboxLabel.height(forWidth: labelWidth))
        checkboxLabel.frame = NSRect(
            x: labelX, y: top + (row - labelHeight) / 2, width: labelWidth, height: labelHeight)
    }

    /// A click on the label toggles the box, as a `<label>` does.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard checkboxLabel.frame.contains(point), checkbox.isEnabled else { return }
        checkbox.state = checkbox.state == .on ? .off : .on
    }
}

/// One card of the comparison (`FingerprintCard`): what it is, its name, and "Folder" or its size and date.
@MainActor
final class ConflictCardView: NSView, ThemeApplying {
    let label: ThemedText
    let name: ThemedText
    let facts: ThemedText
    private var theme = AppearanceModel.shared.theme
    private static let font = ThemeFonts.sans(DesignTokens.typeScale.body)

    init(_ card: RuntimeConflictCard) {
        label = ThemedText { theme in
            singleLineText(
                [(card.label, ThemeFonts.sans(DesignTokens.typeScale.small, .semibold), theme.palette.textSecondary)],
                background: theme.palette.bgElevated)
        }
        name = ThemedText { theme in
            singleLineText(
                [(card.name, ThemeFonts.sans(DesignTokens.typeScale.body, .medium), theme.palette.textPrimary)],
                background: theme.palette.bgElevated)
        }
        var factsStyle = TextStyle(font: Self.font, color: { $0.palette.textSecondary })
        factsStyle.background = { $0.palette.bgElevated }
        facts = ThemedText(card.facts, style: factsStyle, wrapping: true)
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(card.label)
        setAccessibilityIdentifier("conflictAlert.card")
        label.toolTip = card.label
        name.toolTip = card.name
        label.lineBreakMode = .byTruncatingTail
        name.lineBreakMode = .byTruncatingTail
        label.setAccessibilityIdentifier("conflictAlert.card.label")
        name.setAccessibilityIdentifier("conflictAlert.card.name")
        facts.setAccessibilityIdentifier("conflictAlert.card.facts")
        addSubview(label)
        addSubview(name)
        addSubview(facts)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    func applyTheme(_ theme: Theme) {
        self.theme = theme
        needsDisplay = true
    }

    private var inset: CGFloat { CGFloat(CopyPasteSheetLayout.border + CopyPasteSheetLayout.cardPadding) }

    func height(forWidth width: CGFloat) -> CGFloat {
        let inner = max(1, width - 2 * inset)
        let gap = CGFloat(CopyPasteSheetLayout.cardInnerGap)
        return 2 * inset + ceil(label.height(forWidth: 10_000)) + gap + ceil(name.height(forWidth: 10_000)) + gap
            + ceil(facts.height(forWidth: inner))
    }

    override func layout() {
        super.layout()
        let inner = max(0, bounds.width - 2 * inset)
        let gap = CGFloat(CopyPasteSheetLayout.cardInnerGap)
        var y = inset
        for (view, wraps) in [(label, false), (name, false), (facts, true)] {
            let height = ceil(view.height(forWidth: wraps ? inner : 10_000))
            view.frame = NSRect(x: inset, y: y, width: inner, height: height)
            y += height + gap
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = CGFloat(DesignTokens.radii.menu)
        let half = CGFloat(CopyPasteSheetLayout.border) / 2
        let edge = NSBezierPath(roundedRect: bounds.insetBy(dx: half, dy: half), xRadius: radius, yRadius: radius)
        edge.lineWidth = CGFloat(CopyPasteSheetLayout.border)
        NSColor(theme.palette.borderLight).setStroke()
        edge.stroke()
    }
}

/// The question a paused operation asks (`CopyPasteRuntimeConflictDialog`): a wide alert over the window, one per
/// conflict. One answer per alert: everything is disabled after the first click; a new conflict gets a fresh alert.
/// If the answer can't be sent, the question stays.
@MainActor
final class RuntimeConflictAlertController {
    private(set) var conflictId: String?
    private(set) var operationId: String?
    private(set) var card: AlertCard?
    private(set) var accessory: RuntimeConflictAccessory?
    private var scrim: DialogScrim?
    private var answered = false
    /// The time the cards' dates are written against.
    var now: () -> Double = { AppClock.now.epochMilliseconds }

    /// Follows the operation's progress: its question is shown while it waits on one, and taken away once it goes on.
    func update(_ event: WriteOperationEvent, in tab: MainWindowController?) {
        if event.status == .awaitingResolution, let conflict = event.runtimeConflict {
            guard conflict.conflictId != conflictId || scrim?.isDismissed != false else { return }
            dismiss()
            if let tab { present(conflict, event: event, in: tab) }
        } else if event.operationId == operationId {
            dismiss()
        }
    }

    /// The operation ended: its question, if still up, goes.
    func ended(_ operationId: String) {
        if operationId == self.operationId { dismiss() }
    }

    func dismiss() {
        scrim?.dismiss()
        scrim = nil
        card = nil
        accessory = nil
        conflictId = nil
        operationId = nil
    }

    private func present(_ conflict: CopyPasteRuntimeConflict, event: WriteOperationEvent, in tab: MainWindowController)
    {
        guard let window = tab.window, window.contentView != nil else { return }
        let text = RuntimeConflictText(RuntimeConflictInput(conflict), verb: CopyLikeVerb(event.action), now: now())
        let accessory = RuntimeConflictAccessory(text: text)
        let conflictId = conflict.conflictId
        answered = false
        let resolve: (CopyPasteChoice) -> AlertButton = { [weak self, weak tab] choice in
            let answer = choice == text.primary.choice ? text.primary : text.secondary.first { $0.choice == choice }
            let variant: PushButtonVariant =
                choice == text.primary.choice ? .default : (answer?.destructive == true ? .destructive : .plain)
            return AlertButton(title: answer?.title ?? CopyPasteReview.label(choice), variant: variant) {
                self?.answer {
                    _ = tab?.writeActions?.resolveConflict(
                        conflictId, resolution: choice, applyToRemaining: accessory.applyToRemaining)
                }
            }
        }
        let stop = AlertButton(title: text.stopLabel) { [weak self, weak tab] in
            self?.answer { _ = tab?.writeActions?.cancel() }
        }
        let content = AlertContent(
            title: text.title, message: text.message,
            buttons: text.secondary.map { resolve($0.choice) } + [resolve(text.primary.choice)], stacked: false,
            wide: true, aside: stop, accessory: accessory,
            // Escape stops the operation, as Stop does (B-CLIP-116).
            onEscape: { [weak tab] in _ = tab?.writeActions?.cancel() },
            // Return on anything but a button does nothing.
            onReturn: {})
        let scrim = InWindowAlerts.present(content, in: window)
        CopyPasteDialogs.track(scrim, on: tab)
        self.scrim = scrim
        self.card = scrim.panel as? AlertCard
        self.accessory = accessory
        self.conflictId = conflictId
        operationId = event.operationId
    }

    /// One answer per alert: a double click must not send a second one for the next conflict.
    private func answer(_ send: () -> Void) {
        guard !answered else { return }
        answered = true
        for button in (card?.buttons ?? []) + [card?.asideButton].compactMap({ $0 }) { button.isEnabled = false }
        accessory?.checkbox.isEnabled = false
        send()
    }
}
