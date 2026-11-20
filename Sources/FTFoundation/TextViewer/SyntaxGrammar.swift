import Foundation

/// How a language is lexed.
public enum SyntaxGrammar: Sendable {
    /// No colors.
    case plain
    /// Keywords, strings, comments and numbers: most programming languages, shells, SQL.
    case code(CodeRules)
    /// HTML, XML, SVG, property lists.
    case markup
    case markdown
    case yaml
    /// INI, TOML, .env, Java properties, Git config.
    case ini(INIRules)
    /// CSS, SCSS, Less.
    case css(CSSRules)
    case diff
}

/// A string's delimiters.
public struct StringRule: Sendable {
    public let open: [UInt16]
    public let close: [UInt16]
    public let escape: UInt16?
    /// Whether it may run past the end of its line (`"""`, a backtick template).
    public let multiline: Bool
    /// Whether the closing delimiter doubled stands for itself (`'it''s'` in SQL).
    public let doubledCloseEscapes: Bool

    public init(
        _ open: String, _ close: String? = nil, escape: Bool = true, multiline: Bool = false, doubled: Bool = false
    ) {
        self.open = Array(open.utf16)
        self.close = Array((close ?? open).utf16)
        self.escape = escape ? Char.backslash : nil
        self.multiline = multiline
        self.doubledCloseEscapes = doubled
    }
}

public struct CommentRule: Sendable {
    public let open: [UInt16]
    public let close: [UInt16]
    public let nested: Bool

    public init(_ open: String, _ close: String, nested: Bool = false) {
        self.open = Array(open.utf16)
        self.close = Array(close.utf16)
        self.nested = nested
    }
}

public struct CodeRules: Sendable {
    public var lineComments: [[UInt16]] = []
    /// Line comments that start only at the line's start or after a space (`#` in a shell: `a#b` is a word).
    public var lineCommentsNeedSpace = false
    public var blockComments: [CommentRule] = []
    /// Longest opening first: `"""` before `"`.
    public var strings: [StringRule] = []
    /// Words just before a string that are part of it: `r"…"`, `f"…"`, `b'…'`.
    public var stringPrefixes: Set<String> = []
    public var keywords: Set<String> = []
    public var types: Set<String> = []
    public var literals: Set<String> = []
    /// Words that name the function after them: `func`, `def`, `fn`.
    public var definers: Set<String> = []
    public var caseInsensitive = false
    /// A word starting with a capital is a type: Swift, Java, Kotlin, Rust, Go's exported names are not, so off there.
    public var capitalizedTypes = false
    /// A word before `(` is a function.
    public var functionCalls = true
    /// `@name` or `#name` is an attribute.
    public var attributePrefixes: Set<UInt16> = []
    /// `#[…]` and `#![…]` are attributes (Rust).
    public var bracketAttributes = false
    /// A line starting with `#` is a preprocessor line (C): its directive is an attribute, and `<…>` after it a string.
    public var preprocessor = false
    /// `$name`, `${…}`, `$(…)`: shells, PHP, Perl, Make.
    public var variablePrefix: UInt16?
    /// A word at the line's start before `:` is a function: a Make target.
    public var lineStartLabels = false
    /// A string before `:` is a key (JSON).
    public var keysBeforeColon = false
    /// Characters a word may hold besides letters, digits and `_`: `-` in Lisp, `?` and `!` in Ruby.
    public var identifierExtras: Set<UInt16> = []

    public init() {}

    @inline(__always) func lookup(_ word: String) -> String { caseInsensitive ? word.lowercased() : word }
}

public struct INIRules: Sendable {
    /// `;` as well as `#` starts a comment.
    public var semicolonComments = true
    /// `:` as well as `=` ends a key (Java properties).
    public var colonSeparates = false
    /// Values are lexed as TOML: strings, numbers, booleans, dates, arrays.
    public var typedValues = false
    /// `export` before a key is a keyword (.env).
    public var exportKeyword = false

    public init() {}
}

public struct CSSRules: Sendable {
    /// `//` starts a comment (SCSS, Less).
    public var lineComments = false
    /// The prefix of a variable: `$` in SCSS, `@` in Less. CSS's `--name` is always one.
    public var variablePrefix: UInt16?

    public init() {}
}
