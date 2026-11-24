import AppKit

/// The bar over a PDF or a document that finds text in it, as the text's own find bar does: what is typed is looked
/// for as it is typed, every match is marked, Return goes to the next and Shift-Return to the one before, and Esc or
/// Done closes it.
final class ViewerFindBar: NSView, NSSearchFieldDelegate {
    static let height: CGFloat = 36

    /// The text to look for, as it is typed.
    var onChange: (String) -> Void = { _ in }
    /// The next match (true) or the one before.
    var onStep: (Bool) -> Void = { _ in }
    var onClose: () -> Void = {}

    let field = NSSearchField()
    private let count = NSTextField(labelWithString: "")
    private let steps = NSSegmentedControl()
    private let done = NSButton(title: "Done", target: nil, action: nil)
    private let line = NSBox()

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityIdentifier("textViewer.findBar")
        wantsLayer = true
        field.placeholderString = "Find in PDF"
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.delegate = self
        field.target = self
        field.action = #selector(changed)
        field.setAccessibilityIdentifier("textViewer.findField")
        count.textColor = .secondaryLabelColor
        count.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        count.alignment = .right
        count.setAccessibilityIdentifier("textViewer.findCount")
        steps.segmentCount = 2
        steps.trackingMode = .momentary
        steps.segmentStyle = .rounded
        steps.setImage(NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Previous"), forSegment: 0)
        steps.setImage(NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Next"), forSegment: 1)
        steps.setToolTip("Previous match (⇧↩)", forSegment: 0)
        steps.setToolTip("Next match (↩)", forSegment: 1)
        steps.target = self
        steps.action = #selector(stepped)
        done.bezelStyle = .push
        done.controlSize = .small
        done.target = self
        done.action = #selector(closed)
        line.boxType = .separator
        for view in [field, count, steps, done, line] as [NSView] { addSubview(view) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    /// What was found: "3 of 12", "Not found", or nothing while there is nothing to look for.
    func show(match index: Int?, of total: Int, searching: Bool) {
        if field.stringValue.isEmpty {
            count.stringValue = ""
        } else if total == 0 {
            count.stringValue = searching ? "" : "Not found"
        } else {
            count.stringValue = "\(index.map { "\($0 + 1)" } ?? "–") of \(total)"
        }
        steps.isEnabled = total > 0
    }

    override func layout() {
        super.layout()
        let height = bounds.height
        let doneSize = done.fittingSize
        done.frame = NSRect(
            x: bounds.width - 10 - doneSize.width, y: (height - doneSize.height) / 2, width: doneSize.width,
            height: doneSize.height)
        let stepsSize = steps.fittingSize
        steps.frame = NSRect(
            x: done.frame.minX - 8 - stepsSize.width, y: (height - stepsSize.height) / 2, width: stepsSize.width,
            height: stepsSize.height)
        count.frame = NSRect(x: steps.frame.minX - 8 - 90, y: (height - 16) / 2, width: 90, height: 16)
        let fieldHeight = field.fittingSize.height
        field.frame = NSRect(
            x: 10, y: (height - fieldHeight) / 2, width: max(80, min(320, count.frame.minX - 18)), height: fieldHeight)
        line.frame = NSRect(x: 0, y: height - 1, width: bounds.width, height: 1)
    }

    @objc private func changed() { onChange(field.stringValue) }

    @objc private func stepped() { onStep(steps.selectedSegment == 1) }

    @objc private func closed() { onClose() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            onStep(!(NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false))
            return true
        case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            onStep(true)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onClose()
            return true
        default:
            return false
        }
    }
}
