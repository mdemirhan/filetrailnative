import AppKit
import FTFoundation

/// Colors a text view's text as its language says, only the lines on screen, as layout-manager temporary attributes:
/// the text storage keeps no colors, so a large file costs only what is shown. It keeps where each line starts and the
/// lexer's state at each line's start, so an edit re-lexes from its line only until the states agree again.
@MainActor
final class SyntaxColoring: NSObject, NSTextStorageDelegate {
    private weak var textView: NSTextView?
    private(set) var language: TextLanguage
    private var lexer: SyntaxLexer
    var theme: TextViewerTheme {
        didSet { recolorAll() }
    }
    /// Over this many UTF-16 units the text is shown without colors.
    var colorLimit = 10 * 1024 * 1024

    /// Where each line starts, by UTF-16 offset: the first is 0.
    private(set) var lineStarts: [Int] = [0]
    /// The lexer's state at each line's start; empty while not worked out, or for text without colors.
    private var states: [LexState] = []
    private var colored = IndexSet()
    private var buffer: [UInt16] = []
    private var generation = 0
    /// While the whole text is set: `textReplaced()` follows.
    var ignoresEdits = false
    /// Called when the lines or their count changed: the line numbers are drawn again.
    var onLinesChanged: () -> Void = {}

    init(textView: NSTextView, language: TextLanguage, theme: TextViewerTheme) {
        self.textView = textView
        self.language = language
        self.lexer = SyntaxLexer(language: language)
        self.theme = theme
        super.init()
        textView.textStorage?.delegate = self
        NotificationCenter.default.addObserver(
            self, selector: #selector(boundsChanged), name: NSView.boundsDidChangeNotification,
            object: textView.enclosingScrollView?.contentView)
        textView.enclosingScrollView?.contentView.postsBoundsChangedNotifications = true
    }

    var colorsOn: Bool {
        if case .plain = language.grammar { return false }
        return (textView?.textStorage?.length ?? 0) <= colorLimit
    }

    func setLanguage(_ language: TextLanguage) {
        self.language = language
        lexer = SyntaxLexer(language: language)
        textReplaced()
    }

    /// The whole text was set: lines and states are worked out again, the states off the main thread.
    func textReplaced() {
        generation += 1
        clearColors()
        guard let storage = textView?.textStorage else { return }
        let text = storage.string as NSString
        let length = text.length
        var units = [UInt16](repeating: 0, count: length)
        if length > 0 { text.getCharacters(&units, range: NSRange(location: 0, length: length)) }
        lineStarts = Self.lineStarts(of: units)
        states = []
        onLinesChanged()
        guard colorsOn else { return }
        let lexer = self.lexer
        let starts = lineStarts
        let generation = self.generation
        if length < 256 * 1024 {
            states = Self.states(units, starts: starts, lexer: lexer)
            colorVisible()
            return
        }
        Task.detached(priority: .userInitiated) {
            let states = Self.states(units, starts: starts, lexer: lexer)
            await MainActor.run { [weak self] in
                guard let self, self.generation == generation else { return }
                self.states = states
                self.colorVisible()
            }
        }
    }

    nonisolated static func lineStarts(of units: [UInt16]) -> [Int] {
        var starts = [0]
        starts.reserveCapacity(units.count / 40 + 1)
        for (index, unit) in units.enumerated() where unit == 10 { starts.append(index + 1) }
        return starts
    }

    nonisolated static func states(_ units: [UInt16], starts: [Int], lexer: SyntaxLexer) -> [LexState] {
        var states = [LexState]()
        states.reserveCapacity(starts.count)
        var state = LexState.normal
        units.withUnsafeBufferPointer { all in
            for (index, start) in starts.enumerated() {
                states.append(state)
                var end = index + 1 < starts.count ? starts[index + 1] - 1 : units.count
                if end > start && all[end - 1] == 13 { end -= 1 }
                state = lexer.endState(UnsafeBufferPointer(rebasing: all[start..<max(start, end)]), from: state)
            }
        }
        return states
    }

    /// The line `location` is on.
    func line(at location: Int) -> Int {
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= location { low = mid } else { high = mid - 1 }
        }
        return low
    }

    func lineRange(_ line: Int, length: Int) -> NSRange {
        let start = lineStarts[line]
        let end = line + 1 < lineStarts.count ? lineStarts[line + 1] - 1 : length
        return NSRange(location: start, length: max(0, end - start))
    }

    // MARK: Edits

    nonisolated func textStorage(
        _ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        guard editedMask.contains(.editedCharacters) else { return }
        MainActor.assumeIsolated { edited(editedRange, delta: delta) }
    }

    private func edited(_ range: NSRange, delta: Int) {
        guard let storage = textView?.textStorage else { return }
        let text = storage.string as NSString
        let length = text.length
        guard !ignoresEdits else { return }
        if colorsOn != !states.isEmpty {
            // Crossed the limit, or the states are still being worked out: worked out whole.
            textReplaced()
            return
        }
        let first = line(at: range.location)
        let oldEnd = range.location + range.length - delta
        var starts = Array(lineStarts[0...first])
        let scanStart = range.location
        let scanEnd = min(range.location + range.length, length)
        if scanEnd > scanStart {
            var units = [UInt16](repeating: 0, count: scanEnd - scanStart)
            text.getCharacters(&units, range: NSRange(location: scanStart, length: scanEnd - scanStart))
            for (offset, unit) in units.enumerated() where unit == 10 { starts.append(scanStart + offset + 1) }
        }
        let insertedLines = starts.count - (first + 1)
        let tailIndex = lineStarts.firstIndex { $0 > oldEnd } ?? lineStarts.count
        let removedLines = tailIndex - (first + 1)
        for old in lineStarts[tailIndex...] { starts.append(old + delta) }
        lineStarts = starts
        if !states.isEmpty {
            var newStates = Array(states[0...first])
            newStates.append(contentsOf: Array(repeating: LexState.normal, count: insertedLines))
            if tailIndex < states.count { newStates.append(contentsOf: states[tailIndex...]) }
            states = newStates
            relex(from: first, through: first + insertedLines, text: text)
        }
        // Lines after the edit moved: what was colored is colored again where it now is.
        let lineDelta = insertedLines - removedLines
        var shifted = IndexSet(colored.filter { $0 < first })
        if lineDelta == 0 {
            shifted.formUnion(IndexSet(colored.filter { $0 > first + insertedLines }))
        } else {
            for index in colored where index > first + removedLines { shifted.insert(index + lineDelta) }
        }
        colored = shifted
        onLinesChanged()
        colorVisible()
    }

    /// Lexes from `first`, past `last`, until a line starts in the state it had.
    private func relex(from first: Int, through last: Int, text: NSString) {
        var index = first
        let length = text.length
        while index < lineStarts.count {
            let range = lineRange(index, length: length)
            let end = endState(range, text: text, from: states[index])
            colored.remove(index)
            if index + 1 >= lineStarts.count { break }
            if index >= last && states[index + 1] == end { break }
            states[index + 1] = end
            index += 1
        }
    }

    private func endState(_ range: NSRange, text: NSString, from state: LexState) -> LexState {
        withLine(range, text: text) { lexer.endState($0, from: state) }
    }

    private func withLine<T>(_ range: NSRange, text: NSString, _ body: (UnsafeBufferPointer<UInt16>) -> T) -> T {
        if buffer.count < range.length { buffer = [UInt16](repeating: 0, count: max(range.length, 256)) }
        var length = range.length
        if length > 0 {
            buffer.withUnsafeMutableBufferPointer { pointer in
                text.getCharacters(pointer.baseAddress!, range: range)
            }
            if buffer[length - 1] == 13 { length -= 1 }
        }
        return buffer.withUnsafeBufferPointer { body(UnsafeBufferPointer(rebasing: $0[0..<length])) }
    }

    // MARK: Coloring what is on screen

    @objc private func boundsChanged() { colorVisible() }

    func recolorAll() {
        clearColors()
        colorVisible()
    }

    private func clearColors() {
        colored = []
        guard let manager = textView?.layoutManager, let length = textView?.textStorage?.length else { return }
        manager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: NSRange(location: 0, length: length))
    }

    func colorVisible() {
        guard let textView, let manager = textView.layoutManager, let container = textView.textContainer,
            !states.isEmpty, states.count == lineStarts.count
        else { return }
        let text = textView.textStorage?.string as NSString? ?? ""
        let visible = textView.visibleRect.insetBy(dx: 0, dy: -textView.visibleRect.height / 2)
        let glyphs = manager.glyphRange(forBoundingRectWithoutAdditionalLayout: visible, in: container)
        let characters = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let first = line(at: characters.location)
        let last = line(at: NSMaxRange(characters))
        guard first <= last else { return }
        var tokens: [SyntaxToken] = []
        for index in first...last where !colored.contains(index) {
            let range = lineRange(index, length: text.length)
            tokens.removeAll(keepingCapacity: true)
            _ = withLine(range, text: text) { lexer.lex($0, from: states[index], into: &tokens) }
            manager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range)
            for token in tokens {
                manager.addTemporaryAttribute(
                    .foregroundColor, value: NSColor(theme.color(for: token.kind)),
                    forCharacterRange: NSRange(location: range.location + token.location, length: token.length))
            }
            colored.insert(index)
        }
    }
}
