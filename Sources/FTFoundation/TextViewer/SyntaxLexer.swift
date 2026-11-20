import Foundation

/// What a run of text is, for its color in the viewer.
public enum SyntaxKind: UInt8, CaseIterable, Sendable {
    case plain
    case keyword
    case type
    case string
    case comment
    case number
    /// `true`, `nil`, `None`: values named by a word.
    case literal
    /// `@State`, `#include`, `#[derive]`, a decorator, a YAML tag.
    case attribute
    /// `$HOME`, `${name}`, a YAML anchor.
    case variable
    case function
    /// An HTML or XML tag's name and brackets.
    case tag
    /// An attribute's name in a tag, a key in JSON, YAML, TOML or an INI file, a CSS property.
    case property
    case heading
    case emphasis
    case strong
    /// Code inside Markdown.
    case code
    case link
    /// A diff's added line.
    case inserted
    /// A diff's removed line.
    case deleted
    /// A diff's hunk header, a document marker, a link's address.
    case meta
}

/// A run of one kind in a line, by UTF-16 offset from the line's start.
public struct SyntaxToken: Equatable, Sendable {
    public var location: Int
    public var length: Int
    public var kind: SyntaxKind

    public init(_ location: Int, _ length: Int, _ kind: SyntaxKind) {
        self.location = location
        self.length = length
        self.kind = kind
    }
}

/// Where a line's lexing starts: inside a comment or a string that an earlier line opened, or not. Two lines that
/// start in the same state lex the same, which is what lets an edit stop re-lexing once the states agree again.
public struct LexState: Hashable, Sendable {
    public enum Mode: UInt8, Sendable {
        case normal
        case blockComment
        case string
        case markupComment
        case markupTag
        case markupCData
        case fence
        case blockScalar
    }

    public var mode: Mode
    /// Which rule opened it: the block comment's or the string's index, a fence's character.
    public var rule: UInt16
    /// A nested comment's depth, a fence's length, a block scalar's indent, CSS's brace depth.
    public var depth: UInt16

    public init(_ mode: Mode = .normal, rule: UInt16 = 0, depth: UInt16 = 0) {
        self.mode = mode
        self.rule = rule
        self.depth = depth
    }

    public static let normal = LexState()
}

/// Lexes a language a line at a time. The lines are given without their line break.
public struct SyntaxLexer: Sendable {
    public let language: TextLanguage

    public init(language: TextLanguage) {
        self.language = language
    }

    /// Lexes one line, appending its tokens to `tokens` when it is given, and returns the state the next line starts
    /// in. Offsets are from the line's start.
    public func lex(
        _ chars: UnsafeBufferPointer<UInt16>, from state: LexState, into tokens: inout [SyntaxToken]
    ) -> LexState {
        var line = Line(chars: chars, tokens: tokens)
        let next: LexState
        switch language.grammar {
        case .plain: next = .normal
        case .code(let rules): next = line.lexCode(rules, state)
        case .markup: next = line.lexMarkup(state)
        case .markdown: next = line.lexMarkdown(state)
        case .yaml: next = line.lexYAML(state)
        case .ini(let rules): next = line.lexINI(rules, state)
        case .css(let rules): next = line.lexCSS(rules, state)
        case .diff: next = line.lexDiff()
        }
        tokens = line.tokens
        return next
    }

    /// The state the line after this one starts in, without keeping its tokens.
    public func endState(_ chars: UnsafeBufferPointer<UInt16>, from state: LexState) -> LexState {
        if case .plain = language.grammar { return .normal }
        var unused: [SyntaxToken] = []
        unused.reserveCapacity(8)
        return lex(chars, from: state, into: &unused)
    }

    /// Every token of `text`, by UTF-16 offset from its start. Lines end at `\n`; a `\r` before it is left out.
    public func tokens(of text: String) -> [SyntaxToken] {
        let units = Array(text.utf16)
        var result: [SyntaxToken] = []
        var state = LexState.normal
        units.withUnsafeBufferPointer { all in
            var start = 0
            while start <= units.count {
                var end = start
                while end < units.count && units[end] != 10 { end += 1 }
                var lineEnd = end
                if lineEnd > start && units[lineEnd - 1] == 13 { lineEnd -= 1 }
                var lineTokens: [SyntaxToken] = []
                let slice = UnsafeBufferPointer(rebasing: all[start..<lineEnd])
                state = lex(slice, from: state, into: &lineTokens)
                for token in lineTokens {
                    result.append(SyntaxToken(token.location + start, token.length, token.kind))
                }
                if end >= units.count { break }
                start = end + 1
            }
        }
        return result
    }
}

// MARK: - Characters

enum Char {
    static let tab: UInt16 = 9
    static let space: UInt16 = 32
    static let bang: UInt16 = 33
    static let quote: UInt16 = 34
    static let hash: UInt16 = 35
    static let dollar: UInt16 = 36
    static let percent: UInt16 = 37
    static let amp: UInt16 = 38
    static let apostrophe: UInt16 = 39
    static let openParen: UInt16 = 40
    static let closeParen: UInt16 = 41
    static let star: UInt16 = 42
    static let plus: UInt16 = 43
    static let comma: UInt16 = 44
    static let minus: UInt16 = 45
    static let dot: UInt16 = 46
    static let slash: UInt16 = 47
    static let zero: UInt16 = 48
    static let colon: UInt16 = 58
    static let semicolon: UInt16 = 59
    static let less: UInt16 = 60
    static let equals: UInt16 = 61
    static let greater: UInt16 = 62
    static let question: UInt16 = 63
    static let at: UInt16 = 64
    static let openBracket: UInt16 = 91
    static let backslash: UInt16 = 92
    static let closeBracket: UInt16 = 93
    static let underscore: UInt16 = 95
    static let backtick: UInt16 = 96
    static let openBrace: UInt16 = 123
    static let pipe: UInt16 = 124
    static let closeBrace: UInt16 = 125
    static let tilde: UInt16 = 126

    @inline(__always) static func isSpace(_ c: UInt16) -> Bool { c == space || c == tab || c == 12 }
    @inline(__always) static func isDigit(_ c: UInt16) -> Bool { c >= 48 && c <= 57 }
    @inline(__always) static func isLetter(_ c: UInt16) -> Bool { (c >= 65 && c <= 90) || (c >= 97 && c <= 122) }
    @inline(__always) static func isUpper(_ c: UInt16) -> Bool { c >= 65 && c <= 90 }
    @inline(__always) static func isIdentStart(_ c: UInt16) -> Bool { isLetter(c) || c == underscore || c >= 0x80 }
    @inline(__always) static func isIdentPart(_ c: UInt16) -> Bool { isIdentStart(c) || isDigit(c) }
}

// MARK: - The line being lexed

struct Line {
    let chars: UnsafeBufferPointer<UInt16>
    var tokens: [SyntaxToken]
    var count: Int { chars.count }

    init(chars: UnsafeBufferPointer<UInt16>, tokens: [SyntaxToken]) {
        self.chars = chars
        self.tokens = tokens
    }

    @inline(__always) func at(_ i: Int) -> UInt16 { i < chars.count ? chars[i] : 0 }

    func matches(_ pattern: [UInt16], at i: Int) -> Bool {
        guard !pattern.isEmpty, i + pattern.count <= chars.count else { return false }
        for k in 0..<pattern.count where chars[i + k] != pattern[k] { return false }
        return true
    }

    mutating func emit(_ start: Int, _ end: Int, _ kind: SyntaxKind) {
        guard end > start, kind != .plain else { return }
        if let last = tokens.last, last.kind == kind, last.location + last.length == start {
            tokens[tokens.count - 1].length += end - start
        } else {
            tokens.append(SyntaxToken(start, end - start, kind))
        }
    }

    func word(_ start: Int, _ end: Int) -> String {
        String(utf16CodeUnits: chars.baseAddress! + start, count: end - start)
    }

    func firstNonSpace(from i: Int = 0) -> Int {
        var j = i
        while j < count && Char.isSpace(chars[j]) { j += 1 }
        return j
    }

    func identifierEnd(from i: Int, extra: Set<UInt16> = []) -> Int {
        var j = i
        while j < count && (Char.isIdentPart(chars[j]) || extra.contains(chars[j])) { j += 1 }
        return j
    }

    /// The end of a number starting at `i`: digits, a radix prefix, one decimal point, an exponent, a suffix.
    func numberEnd(from i: Int) -> Int {
        var j = i
        var sawDot = false
        let radix = at(i) == Char.zero && [120, 88, 98, 66, 111, 79].contains(at(i + 1))
        while j < count {
            let c = chars[j]
            if Char.isIdentPart(c) {
                j += 1
            } else if c == Char.dot && !sawDot && !radix && Char.isDigit(at(j + 1)) {
                sawDot = true
                j += 1
            } else if (c == Char.plus || c == Char.minus) && !radix && j > i && (at(j - 1) == 101 || at(j - 1) == 69) {
                j += 1
            } else if c == Char.apostrophe && Char.isDigit(at(j + 1)) && j > i && Char.isDigit(at(j - 1)) {
                j += 1
            } else {
                break
            }
        }
        return j
    }

    /// The end of a string whose opening is before `i`, and whether it closed on this line.
    func stringEnd(_ rule: StringRule, from i: Int) -> (end: Int, closed: Bool) {
        var j = i
        while j < count {
            if let escape = rule.escape, chars[j] == escape {
                j += 2
                continue
            }
            if matches(rule.close, at: j) {
                if rule.doubledCloseEscapes && matches(rule.close, at: j + rule.close.count) {
                    j += rule.close.count * 2
                    continue
                }
                return (j + rule.close.count, true)
            }
            j += 1
        }
        return (count, false)
    }
}
