// Text that can be selected (Help's rows, its intro) stays where it is and as it is when a click selects it: the
// field editor that takes it lays it out where the cell drew it, with its runs.
import AppKit
import Testing

@testable import FTAppKit

@MainActor @Suite struct ThemedTextSelectionTests {
    private func selected(_ string: NSAttributedString) throws -> (ThemedText, NSTextView, NSWindow) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 300), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        window.contentView = host
        let text = ThemedText(wrapping: true, selectable: true) { _ in string }
        text.frame = NSRect(x: 100, y: 50, width: 300, height: text.height(forWidth: 300))
        host.addSubview(text)
        #expect(window.makeFirstResponder(text))
        text.selectText(nil)
        let editor = try #require(text.currentEditor() as? NSTextView)
        return (text, editor, window)
    }

    /// Where the editor puts the first letter, in the text field's own coordinates.
    private func firstLetter(_ editor: NSTextView, in text: NSView) throws -> NSPoint {
        let layout = try #require(editor.layoutManager)
        let container = try #require(editor.textContainer)
        let glyph = layout.boundingRect(forGlyphRange: NSRange(location: 0, length: 1), in: container)
        let origin = editor.textContainerOrigin
        return editor.convert(NSPoint(x: glyph.minX + origin.x, y: glyph.minY + origin.y), to: text)
    }

    @Test func selectingTextLeavesItWhereItWasDrawn() throws {
        let string = NSAttributedString(
            string: "Names containing both words, in any order", attributes: [.font: NSFont.systemFont(ofSize: 13)])
        let (text, editor, window) = try selected(string)
        defer { window.close() }
        let drawn = try #require(text.cell as? ThemedTextCell).textFrame(forBounds: text.bounds)
        let letter = try firstLetter(editor, in: text)
        #expect(abs(letter.x - drawn.minX) < 0.5, "drawn at \(drawn.minX), selected at \(letter.x)")
        #expect(abs(letter.y - drawn.minY) < 0.5, "drawn at \(drawn.minY), selected at \(letter.y)")
    }

    @Test func selectingTextKeepsItsRuns() throws {
        let string = NSMutableAttributedString(
            string: "Names without draft: ", attributes: [.font: NSFont.systemFont(ofSize: 13)])
        let code = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        string.append(
            NSAttributedString(
                string: "report !draft", attributes: [.font: code, .backgroundColor: NSColor.quaternaryLabelColor]))
        let (_, editor, window) = try selected(string)
        defer { window.close() }
        let storage = try #require(editor.textStorage)
        let at = (storage.string as NSString).range(of: "report !draft").location
        #expect((storage.attribute(.font, at: at, effectiveRange: nil) as? NSFont)?.isFixedPitch == true)
        #expect(storage.attribute(.backgroundColor, at: at, effectiveRange: nil) != nil)
        // Still read-only.
        #expect(!editor.isEditable)
    }
    /// A label of each of the app's kinds, read-only and selectable, showing `string` in a window.
    private func label(_ kind: String, _ string: NSAttributedString) -> (NSTextField, NSWindow) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 300), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        window.contentView = host
        let field: NSTextField
        switch kind {
        case "TextBoxField": field = TextBoxField(wrappingLabelWithString: "")
        case "PlainLabel": field = PlainLabel(wrappingLabelWithString: "")
        case "FlushTextField": field = FlushTextField(wrappingLabelWithString: "")
        default: field = ThemedText(wrapping: true, selectable: true) { _ in string }
        }
        field.isSelectable = true
        field.attributedStringValue = string
        field.frame = NSRect(x: 100, y: 50, width: 300, height: 40)
        host.addSubview(field)
        return (field, window)
    }

    // Every kind of label the app draws itself stays where it was drawn when a click selects it, and keeps its runs.
    @Test(arguments: ["TextBoxField", "PlainLabel", "FlushTextField", "ThemedText"])
    func everyKindOfLabelStaysAsItWas(_ kind: String) throws {
        let string = NSMutableAttributedString(
            string: "Info for ", attributes: [.font: NSFont.systemFont(ofSize: 13)])
        string.append(
            NSAttributedString(
                string: "report.pdf", attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)]))
        let (field, window) = label(kind, string)
        defer { window.close() }
        #expect(window.makeFirstResponder(field), "\(kind)")
        field.selectText(nil)
        let editor = try #require(field.currentEditor() as? NSTextView, "\(kind)")
        let cell = try #require(field.cell as? TextBoxCell, "\(kind)")
        let drawn = cell.textFrame(forBounds: field.bounds)
        let letter = try firstLetter(editor, in: field)
        #expect(abs(letter.x - drawn.minX) < 0.5, "\(kind): drawn at \(drawn.minX), selected at \(letter.x)")
        let storage = try #require(editor.textStorage)
        let at = (storage.string as NSString).range(of: "report.pdf").location
        #expect((storage.attribute(.font, at: at, effectiveRange: nil) as? NSFont)?.isFixedPitch == true, "\(kind)")
        #expect(!editor.isEditable, "\(kind)")
    }

    // A field that is typed in keeps the system's placing of its editor: only read-only text is moved.
    @Test func aFieldTypedInIsLeftAsTheSystemPlacesIt() throws {
        let (field, window) = label("TextBoxField", NSAttributedString(string: "typed"))
        defer { window.close() }
        field.isEditable = true
        #expect(window.makeFirstResponder(field))
        let editor = try #require(field.currentEditor() as? NSTextView)
        #expect(editor.isEditable)
        #expect(abs(editor.convert(editor.bounds, to: field).minX - field.bounds.minX) < 0.5)
    }
}
