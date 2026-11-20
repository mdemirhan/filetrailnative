import Foundation

/// A language or format the viewer colors, and how a file is matched to it.
public struct TextLanguage: Sendable, Identifiable, Hashable {
    public let id: String
    /// As the language pop-up and the status bar name it.
    public let name: String
    public let grammar: SyntaxGrammar
    /// Lowercased, without the dot.
    public let extensions: [String]
    /// Whole names, lowercased: `makefile`, `dockerfile`, `.zshrc`.
    public let fileNames: [String]
    /// The interpreter a `#!` line names: `python3` matches `python`.
    public let interpreters: [String]
    /// Whether it has a rendered preview beside its source (Markdown).
    public let hasPreview: Bool

    init(
        _ id: String, _ name: String, _ grammar: SyntaxGrammar, extensions: [String] = [], fileNames: [String] = [],
        interpreters: [String] = [], hasPreview: Bool = false
    ) {
        self.id = id
        self.name = name
        self.grammar = grammar
        self.extensions = extensions
        self.fileNames = fileNames
        self.interpreters = interpreters
        self.hasPreview = hasPreview
    }

    public static func == (a: TextLanguage, b: TextLanguage) -> Bool { a.id == b.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

extension TextLanguage {
    public static let plainText = TextLanguage("plain", "Plain Text", .plain, extensions: ["txt", "text"])

    /// Every language, by name, Plain Text first.
    public static let all: [TextLanguage] =
        [plainText]
        + TextLanguages.list.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }

    public static func with(id: String) -> TextLanguage? {
        TextLanguages.byID[id]
    }

    /// The language a file is in: by its whole name, its extension, then a `#!` line among its first characters.
    public static func detect(fileName: String, firstLine: String? = nil) -> TextLanguage {
        let lower = fileName.lowercased()
        if let language = TextLanguages.byFileName[lower] { return language }
        let ext = (lower as NSString).pathExtension
        if !ext.isEmpty, let language = TextLanguages.byExtension[ext] { return language }
        if lower.hasPrefix(".env") || lower.hasSuffix(".env") { return TextLanguages.byID["dotenv"] ?? plainText }
        if let line = firstLine, line.hasPrefix("#!") {
            let words = line.dropFirst(2).split(whereSeparator: { $0 == " " || $0 == "/" }).map(String.init)
            let program = words.last(where: { !$0.hasPrefix("-") && $0 != "env" }) ?? ""
            let name = program.trimmingCharacters(in: .decimalDigits.union(CharacterSet(charactersIn: ".")))
            if let language = TextLanguages.byInterpreter[name] { return language }
        }
        if lower.hasPrefix("dockerfile") || lower.hasSuffix(".dockerfile") {
            return TextLanguages.byID["dockerfile"] ?? plainText
        }
        return plainText
    }
}

enum TextLanguages {
    static let byID: [String: TextLanguage] = Dictionary(
        uniqueKeysWithValues: TextLanguage.all.map { ($0.id, $0) })
    static let byExtension: [String: TextLanguage] = index(\.extensions)
    static let byFileName: [String: TextLanguage] = index(\.fileNames)
    static let byInterpreter: [String: TextLanguage] = index(\.interpreters)

    private static func index(_ keys: KeyPath<TextLanguage, [String]>) -> [String: TextLanguage] {
        var result: [String: TextLanguage] = [:]
        for language in TextLanguage.all {
            for key in language[keyPath: keys] where result[key] == nil { result[key] = language }
        }
        return result
    }

    static func words(_ text: String) -> Set<String> {
        Set(text.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init))
    }

    static func code(_ build: (inout CodeRules) -> Void) -> SyntaxGrammar {
        var rules = CodeRules()
        build(&rules)
        return .code(rules)
    }

    static let cStrings = [StringRule("\""), StringRule("'")]
    static let cComments = (line: [Array("//".utf16)], block: [CommentRule("/*", "*/")])

    /// The C family: braces, `//` and `/* */`, `"` and `'`.
    static func cLike(
        keywords: String, types: String = "", literals: String = "true false", definers: String = "",
        _ more: (inout CodeRules) -> Void = { _ in }
    ) -> SyntaxGrammar {
        code {
            $0.lineComments = cComments.line
            $0.blockComments = cComments.block
            $0.strings = cStrings
            $0.keywords = words(keywords)
            $0.types = words(types)
            $0.literals = words(literals)
            $0.definers = words(definers)
            more(&$0)
        }
    }

    static let cKeywords = """
        auto break case const continue default do else enum extern for goto if inline register restrict return \
        sizeof static struct switch typedef union volatile while _Alignas _Alignof _Atomic _Bool _Generic \
        _Noreturn _Static_assert _Thread_local
        """
    static let cTypes = """
        char double float int long short signed unsigned void bool size_t ssize_t int8_t int16_t int32_t int64_t \
        uint8_t uint16_t uint32_t uint64_t uintptr_t intptr_t ptrdiff_t FILE
        """
    static let cppKeywords =
        cKeywords + """
             alignas alignof and asm catch class concept consteval constexpr constinit co_await co_return co_yield \
            decltype delete explicit export friend mutable namespace new noexcept not operator or private protected \
            public requires static_assert static_cast dynamic_cast reinterpret_cast const_cast template this \
            thread_local throw try typeid typename using virtual xor override final
            """
    static let jsKeywords = """
        async await break case catch class const continue debugger default delete do else export extends finally \
        for from function get if import in instanceof let new of return set static super switch this throw try \
        typeof var void while with yield as
        """

    static let list: [TextLanguage] = [
        TextLanguage(
            "swift", "Swift",
            cLike(
                keywords: """
                    associatedtype actor async await break case catch class continue default defer deinit do else \
                    enum extension fallthrough fileprivate for func guard if import in indirect init inout internal \
                    is let mutating nonmutating open operator private protocol public repeat rethrows return \
                    some any static struct subscript super switch throw throws try typealias var where while \
                    convenience dynamic final lazy optional override required unowned weak nonisolated isolated \
                    consuming borrowing sending macro package get set willSet didSet as Self self
                    """,
                literals: "true false nil", definers: "func"
            ) {
                $0.strings = [StringRule("\"\"\"", multiline: true), StringRule("\"")]
                $0.blockComments = [CommentRule("/*", "*/", nested: true)]
                $0.attributePrefixes = [Char.at, Char.hash]
                $0.capitalizedTypes = true
            },
            extensions: ["swift", "swiftinterface"], interpreters: ["swift"]),
        TextLanguage(
            "c", "C",
            cLike(keywords: cKeywords, types: cTypes, literals: "true false NULL") {
                $0.preprocessor = true
            }, extensions: ["c", "h"]),
        TextLanguage(
            "cpp", "C++",
            cLike(keywords: cppKeywords, types: cTypes + " string vector map std", literals: "true false nullptr NULL")
            {
                $0.preprocessor = true
                $0.stringPrefixes = ["L", "u", "U", "u8", "R"]
            }, extensions: ["cpp", "cc", "cxx", "c++", "hpp", "hh", "hxx", "h++", "ipp", "tpp", "inl", "cu", "ino"]),
        TextLanguage(
            "objc", "Objective-C",
            cLike(
                keywords: cKeywords + """
                     @interface @implementation @end @protocol @property @synthesize @dynamic @class @selector \
                    @encode @autoreleasepool @try @catch @finally @throw @optional @required @import self super \
                    nonatomic atomic strong weak copy assign readonly readwrite nullable nonnull instancetype id
                    """,
                types: cTypes + " BOOL NSInteger NSUInteger CGFloat SEL IMP Class",
                literals: "YES NO nil Nil NULL true false"
            ) {
                $0.preprocessor = true
                $0.attributePrefixes = [Char.at]
                $0.capitalizedTypes = true
            }, extensions: ["m", "mm"]),
        TextLanguage(
            "csharp", "C#",
            cLike(
                keywords: """
                    abstract as base break case catch checked class const continue default delegate do else enum \
                    event explicit extern finally fixed for foreach goto if implicit in interface internal is lock \
                    namespace new operator out override params private protected public readonly ref return sealed \
                    sizeof stackalloc static struct switch this throw try typeof unchecked unsafe using virtual \
                    volatile while async await var dynamic get set init record when where yield nameof
                    """,
                types: "bool byte char decimal double float int long object sbyte short string uint ulong ushort void",
                literals: "true false null"
            ) {
                $0.strings = [StringRule("\"\"\"", multiline: true), StringRule("\""), StringRule("'")]
                $0.stringPrefixes = ["@", "$"]
                $0.preprocessor = true
                $0.capitalizedTypes = true
            }, extensions: ["cs", "csx"]),
        TextLanguage(
            "java", "Java",
            cLike(
                keywords: """
                    abstract assert break case catch class const continue default do else enum extends final \
                    finally for goto if implements import instanceof interface native new package private protected \
                    public return static strictfp super switch synchronized this throw throws transient try volatile \
                    while var record sealed permits yield non-sealed
                    """,
                types: "boolean byte char double float int long short void String",
                literals: "true false null"
            ) {
                $0.strings = [StringRule("\"\"\"", multiline: true), StringRule("\""), StringRule("'")]
                $0.attributePrefixes = [Char.at]
                $0.capitalizedTypes = true
            }, extensions: ["java"]),
        TextLanguage(
            "kotlin", "Kotlin",
            cLike(
                keywords: """
                    as break class continue do else for fun if in interface is object package return super this \
                    throw try typealias typeof val var when while by catch constructor delegate dynamic field file \
                    finally get import init param property receiver set setparam where actual abstract annotation \
                    companion const crossinline data enum expect external final infix inline inner internal lateinit \
                    noinline open operator out override private protected public reified sealed suspend tailrec vararg
                    """,
                literals: "true false null", definers: "fun"
            ) {
                $0.strings = [StringRule("\"\"\"", multiline: true), StringRule("\""), StringRule("'")]
                $0.blockComments = [CommentRule("/*", "*/", nested: true)]
                $0.attributePrefixes = [Char.at]
                $0.capitalizedTypes = true
            }, extensions: ["kt", "kts"]),
        TextLanguage(
            "scala", "Scala",
            cLike(
                keywords: """
                    abstract case catch class def do else extends final finally for forSome if implicit import lazy \
                    match new object override package private protected return sealed super this throw trait try type \
                    val var while with yield given using enum export then end extension inline opaque transparent
                    """,
                literals: "true false null", definers: "def"
            ) {
                $0.strings = [StringRule("\"\"\"", multiline: true), StringRule("\""), StringRule("'")]
                $0.stringPrefixes = ["s", "f", "raw"]
                $0.attributePrefixes = [Char.at]
                $0.capitalizedTypes = true
            }, extensions: ["scala", "sc", "sbt"]),
        TextLanguage(
            "groovy", "Groovy",
            cLike(
                keywords: """
                    abstract as assert break case catch class const continue def default do else enum extends final \
                    finally for goto if implements import in instanceof interface new package private protected public \
                    return static super switch this throw throws trait try var while
                    """,
                literals: "true false null", definers: "def"
            ) {
                $0.strings = [
                    StringRule("\"\"\"", multiline: true), StringRule("'''", multiline: true), StringRule("\""),
                    StringRule("'"),
                ]
                $0.attributePrefixes = [Char.at]
                $0.capitalizedTypes = true
            }, extensions: ["groovy", "gradle", "gvy"], fileNames: ["jenkinsfile"]),
        TextLanguage(
            "go", "Go",
            cLike(
                keywords: """
                    break case chan const continue default defer else fallthrough for func go goto if import \
                    interface map package range return select struct switch type var
                    """,
                types: """
                    bool byte complex64 complex128 error float32 float64 int int8 int16 int32 int64 rune string uint \
                    uint8 uint16 uint32 uint64 uintptr any comparable
                    """,
                literals: "true false nil iota", definers: "func"
            ) {
                $0.strings = [StringRule("`", escape: false, multiline: true), StringRule("\""), StringRule("'")]
            }, extensions: ["go"]),
        TextLanguage(
            "rust", "Rust",
            cLike(
                keywords: """
                    as async await break const continue crate dyn else enum extern fn for if impl in let loop match mod \
                    move mut pub ref return self Self static struct super trait type union unsafe use where while macro_rules
                    """,
                types:
                    "bool char f32 f64 i8 i16 i32 i64 i128 isize str u8 u16 u32 u64 u128 usize String Vec Option Result Box",
                literals: "true false None Some Ok Err", definers: "fn"
            ) {
                $0.strings = [StringRule("\"", multiline: true)]
                $0.stringPrefixes = ["b", "r", "br", "c"]
                $0.blockComments = [CommentRule("/*", "*/", nested: true)]
                $0.attributePrefixes = [Char.hash]
                $0.bracketAttributes = true
                $0.capitalizedTypes = true
            }, extensions: ["rs"]),
        TextLanguage(
            "zig", "Zig",
            cLike(
                keywords: """
                    addrspace align allowzero and anyframe anytype asm async await break callconv catch comptime const \
                    continue defer else enum errdefer error export extern fn for if inline linksection noalias noinline \
                    nosuspend opaque or orelse packed pub resume return struct suspend switch test threadlocal try union \
                    unreachable usingnamespace var volatile while
                    """,
                literals: "true false null undefined", definers: "fn"
            ) {
                $0.blockComments = []
                $0.attributePrefixes = [Char.at]
            }, extensions: ["zig"]),
        TextLanguage(
            "dart", "Dart",
            cLike(
                keywords: """
                    abstract as assert async await break case catch class const continue covariant default deferred do \
                    dynamic else enum export extends extension external factory final finally for get hide if implements \
                    import in interface is late library mixin new on operator part required rethrow return set show \
                    static super switch sync this throw try typedef var void while with yield
                    """,
                literals: "true false null"
            ) {
                $0.strings = [
                    StringRule("\"\"\"", multiline: true), StringRule("'''", multiline: true), StringRule("\""),
                    StringRule("'"),
                ]
                $0.stringPrefixes = ["r"]
                $0.attributePrefixes = [Char.at]
                $0.capitalizedTypes = true
            }, extensions: ["dart"]),
        TextLanguage(
            "javascript", "JavaScript",
            cLike(
                keywords: jsKeywords, literals: "true false null undefined NaN Infinity", definers: "function"
            ) {
                $0.strings = [StringRule("`", multiline: true), StringRule("\""), StringRule("'")]
                $0.attributePrefixes = [Char.at]
            }, extensions: ["js", "mjs", "cjs", "jsx"], interpreters: ["node", "bun", "deno"]),
        TextLanguage(
            "typescript", "TypeScript",
            cLike(
                keywords: jsKeywords + """
                     abstract declare enum implements interface keyof module namespace private protected public readonly \
                    type infer is satisfies asserts override accessor
                    """,
                types: "any boolean never number object string symbol unknown bigint void",
                literals: "true false null undefined NaN Infinity", definers: "function"
            ) {
                $0.strings = [StringRule("`", multiline: true), StringRule("\""), StringRule("'")]
                $0.attributePrefixes = [Char.at]
                $0.capitalizedTypes = true
            }, extensions: ["ts", "tsx", "mts", "cts"]),
        TextLanguage(
            "json", "JSON",
            code {
                $0.lineComments = cComments.line
                $0.blockComments = cComments.block
                $0.strings = [StringRule("\"")]
                $0.literals = words("true false null")
                $0.keysBeforeColon = true
                $0.functionCalls = false
            }, extensions: ["json", "jsonc", "json5", "geojson", "webmanifest", "har", "ipynb"],
            fileNames: [".babelrc", ".eslintrc", ".prettierrc", "package.lock"]),
        TextLanguage(
            "python", "Python",
            code {
                $0.lineComments = [Array("#".utf16)]
                $0.strings = [
                    StringRule("\"\"\"", multiline: true), StringRule("'''", multiline: true), StringRule("\""),
                    StringRule("'"),
                ]
                $0.stringPrefixes = words("r u b f rb br fr rf R U B F Rb bR Br BR Fr fR FR rF RF")
                $0.keywords = words(
                    """
                    and as assert async await break class continue def del elif else except finally for from global \
                    if import in is lambda nonlocal not or pass raise return try while with yield match case type self cls
                    """)
                $0.literals = words("True False None NotImplemented Ellipsis")
                $0.types = words("int float str bytes bool list dict set tuple object complex frozenset bytearray")
                $0.definers = words("def class")
                $0.attributePrefixes = [Char.at]
            }, extensions: ["py", "pyw", "pyi", "pyx", "gyp"], fileNames: ["sconstruct", "sconscript"],
            interpreters: ["python", "python2", "python3", "pypy"]),
        TextLanguage(
            "ruby", "Ruby",
            code {
                $0.lineComments = [Array("#".utf16)]
                $0.blockComments = [CommentRule("=begin", "=end")]
                $0.strings = [StringRule("\""), StringRule("'"), StringRule("`")]
                $0.keywords = words(
                    """
                    BEGIN END alias and begin break case class def defined? do else elsif end ensure for if in module \
                    next not or redo rescue retry return self super then undef unless until when while yield \
                    require require_relative include extend attr_reader attr_writer attr_accessor private protected public
                    """)
                $0.literals = words("true false nil")
                $0.definers = words("def")
                $0.attributePrefixes = [Char.at, Char.colon]
                $0.variablePrefix = Char.dollar
                $0.identifierExtras = [Char.question, Char.bang]
                $0.capitalizedTypes = true
            }, extensions: ["rb", "rake", "gemspec", "ru", "erb"],
            fileNames: ["gemfile", "rakefile", "podfile", "fastfile", "vagrantfile", "brewfile"], interpreters: ["ruby"]
        ),
        TextLanguage(
            "php", "PHP",
            cLike(
                keywords: """
                    abstract and array as break callable case catch class clone const continue declare default do echo \
                    else elseif empty enddeclare endfor endforeach endif endswitch endwhile enum extends final finally fn \
                    for foreach function global goto if implements include include_once instanceof insteadof interface \
                    isset list match namespace new or print private protected public readonly require require_once \
                    return static switch throw trait try unset use var while xor yield
                    """,
                literals: "true false null TRUE FALSE NULL", definers: "function"
            ) {
                $0.lineComments = [Array("//".utf16), Array("#".utf16)]
                $0.variablePrefix = Char.dollar
                $0.caseInsensitive = false
            }, extensions: ["php", "phtml", "php3", "php4", "php5", "phps"], interpreters: ["php"]),
        TextLanguage(
            "perl", "Perl",
            code {
                $0.lineComments = [Array("#".utf16)]
                $0.strings = [StringRule("\""), StringRule("'"), StringRule("`")]
                $0.keywords = words(
                    """
                    my our local sub if elsif else unless while until for foreach do last next redo return use no \
                    require package BEGIN END and or not eq ne lt gt le ge cmp print say die warn
                    """)
                $0.definers = words("sub")
                $0.variablePrefix = Char.dollar
                $0.attributePrefixes = [Char.at, Char.percent]
            }, extensions: ["pl", "pm", "t", "pod"], interpreters: ["perl"]),
        TextLanguage(
            "lua", "Lua",
            code {
                $0.blockComments = [CommentRule("--[[", "]]")]
                $0.lineComments = [Array("--".utf16)]
                $0.strings = [
                    StringRule("[[", "]]", escape: false, multiline: true), StringRule("\""), StringRule("'"),
                ]
                $0.keywords = words(
                    "and break do else elseif end for function goto if in local not or repeat return then until while")
                $0.literals = words("true false nil")
                $0.definers = words("function")
            }, extensions: ["lua"], interpreters: ["lua"]),
        TextLanguage(
            "r", "R",
            code {
                $0.lineComments = [Array("#".utf16)]
                $0.strings = [StringRule("\""), StringRule("'")]
                $0.keywords = words("if else repeat while function for in next break library require return")
                $0.literals = words("TRUE FALSE NULL NA NaN Inf NA_integer_ NA_real_ NA_character_ T F")
            }, extensions: ["r", "rmd"], interpreters: ["rscript"]),
        TextLanguage(
            "julia", "Julia",
            code {
                $0.lineComments = [Array("#".utf16)]
                $0.blockComments = [CommentRule("#=", "=#", nested: true)]
                $0.strings = [StringRule("\"\"\"", multiline: true), StringRule("\""), StringRule("'")]
                $0.keywords = words(
                    """
                    baremodule begin break catch const continue do else elseif end export finally for function global \
                    if import let local macro module quote return struct try using while mutable abstract primitive type where
                    """)
                $0.literals = words("true false nothing missing Inf NaN")
                $0.definers = words("function macro")
                $0.attributePrefixes = [Char.at]
                $0.capitalizedTypes = true
            }, extensions: ["jl"], interpreters: ["julia"]),
        TextLanguage(
            "haskell", "Haskell",
            code {
                $0.blockComments = [CommentRule("{-", "-}", nested: true)]
                $0.lineComments = [Array("--".utf16)]
                $0.strings = [StringRule("\""), StringRule("'")]
                $0.keywords = words(
                    """
                    case class data default deriving do else foreign if import in infix infixl infixr instance let module \
                    newtype of then type where qualified as hiding forall mdo family
                    """)
                $0.literals = words("True False Nothing Just")
                $0.capitalizedTypes = true
                $0.functionCalls = false
                $0.identifierExtras = [Char.apostrophe]
            }, extensions: ["hs", "lhs"], interpreters: ["runhaskell"]),
        TextLanguage(
            "ocaml", "OCaml",
            code {
                $0.blockComments = [CommentRule("(*", "*)", nested: true)]
                $0.strings = [StringRule("\"")]
                $0.keywords = words(
                    """
                    and as assert begin class constraint do done downto else end exception external for fun function \
                    functor if in include inherit initializer lazy let match method module mutable new nonrec object of \
                    open or private rec sig struct then to try type val virtual when while with
                    """)
                $0.literals = words("true false None Some")
                $0.capitalizedTypes = true
                $0.functionCalls = false
            }, extensions: ["ml", "mli"]),
        TextLanguage(
            "fsharp", "F#",
            code {
                $0.blockComments = [CommentRule("(*", "*)", nested: true)]
                $0.lineComments = [Array("//".utf16)]
                $0.strings = [StringRule("\"\"\"", multiline: true), StringRule("\"")]
                $0.keywords = words(
                    """
                    abstract and as assert base begin class default delegate do done downcast downto elif else end \
                    exception extern for fun function global if in inherit inline interface internal lazy let match \
                    member module mutable namespace new not of open or override private public rec return static struct \
                    then to try type upcast use val void when while with yield
                    """)
                $0.literals = words("true false null None Some")
                $0.capitalizedTypes = true
                $0.attributePrefixes = [Char.hash]
            }, extensions: ["fs", "fsi", "fsx"]),
        TextLanguage(
            "elixir", "Elixir",
            code {
                $0.lineComments = [Array("#".utf16)]
                $0.strings = [StringRule("\"\"\"", multiline: true), StringRule("\""), StringRule("'")]
                $0.keywords = words(
                    """
                    after alias and catch cond def defmacro defmodule defp defprotocol defimpl defstruct do else end fn \
                    for if import in not or quote raise receive require rescue try unless unquote use when with
                    """)
                $0.literals = words("true false nil")
                $0.definers = words("def defp defmacro")
                $0.attributePrefixes = [Char.at, Char.colon]
                $0.identifierExtras = [Char.question, Char.bang]
                $0.capitalizedTypes = true
            }, extensions: ["ex", "exs", "heex"], interpreters: ["elixir"]),
        TextLanguage(
            "erlang", "Erlang",
            code {
                $0.lineComments = [Array("%".utf16)]
                $0.strings = [StringRule("\"")]
                $0.keywords = words(
                    """
                    after and andalso band begin bnot bor bsl bsr bxor case catch cond div end fun if let not of or \
                    orelse receive rem try when xor
                    """)
                $0.literals = words("true false undefined")
                $0.attributePrefixes = [Char.minus]
                $0.capitalizedTypes = false
            }, extensions: ["erl", "hrl"], interpreters: ["escript"]),
        TextLanguage(
            "clojure", "Clojure",
            code {
                $0.lineComments = [Array(";".utf16)]
                $0.strings = [StringRule("\"")]
                $0.keywords = words(
                    "def defn defn- defmacro defmulti defmethod defprotocol defrecord deftype fn if do let loop recur when when-not cond case ns require import quote try catch finally throw"
                )
                $0.literals = words("true false nil")
                $0.attributePrefixes = [Char.colon]
                $0.identifierExtras = [
                    Char.minus, Char.question, Char.bang, Char.star, Char.greater, Char.less, Char.equals,
                ]
                $0.functionCalls = false
            }, extensions: ["clj", "cljs", "cljc", "edn"]),
        TextLanguage(
            "lisp", "Lisp",
            code {
                $0.lineComments = [Array(";".utf16)]
                $0.blockComments = [CommentRule("#|", "|#", nested: true)]
                $0.strings = [StringRule("\"")]
                $0.keywords = words(
                    "defun defmacro defvar defparameter defconstant lambda let let* if cond when unless progn setq setf loop do dolist dotimes define define-syntax"
                )
                $0.literals = words("t nil #t #f")
                $0.attributePrefixes = [Char.colon]
                $0.identifierExtras = [Char.minus, Char.question, Char.bang, Char.star]
                $0.functionCalls = false
            }, extensions: ["lisp", "lsp", "cl", "el", "scm", "ss", "rkt"], fileNames: [".emacs"]),
        TextLanguage(
            "shell", "Shell",
            code {
                $0.lineComments = [Array("#".utf16)]
                $0.lineCommentsNeedSpace = true
                $0.strings = [StringRule("\"", multiline: true), StringRule("'", escape: false, multiline: true)]
                $0.keywords = words(
                    """
                    if then else elif fi case esac for select while until do done in function time coproc return exit \
                    export local readonly declare typeset unset shift source alias break continue eval exec trap set
                    """)
                $0.literals = words("true false")
                $0.variablePrefix = Char.dollar
                $0.definers = words("function")
                $0.functionCalls = false
                $0.identifierExtras = [Char.minus]
            }, extensions: ["sh", "bash", "zsh", "ksh", "command", "bats", "fish"],
            fileNames: [
                ".bashrc", ".bash_profile", ".bash_logout", ".zshrc", ".zprofile", ".zshenv", ".zlogin", ".profile",
                "pkgbuild",
            ],
            interpreters: ["sh", "bash", "zsh", "ksh", "dash", "fish"]),
        TextLanguage(
            "powershell", "PowerShell",
            code {
                $0.lineComments = [Array("#".utf16)]
                $0.blockComments = [CommentRule("<#", "#>")]
                $0.strings = [StringRule("\""), StringRule("'", escape: false, doubled: true)]
                $0.keywords = words(
                    """
                    begin break catch class continue data define do dynamicparam else elseif end exit filter finally \
                    for foreach from function if in param process return switch throw trap try until using var while
                    """)
                $0.literals = words("$true $false $null")
                $0.variablePrefix = Char.dollar
                $0.caseInsensitive = true
                $0.identifierExtras = [Char.minus]
            }, extensions: ["ps1", "psm1", "psd1"], interpreters: ["pwsh"]),
        TextLanguage(
            "batch", "Batch File",
            code {
                $0.lineComments = [Array("::".utf16), Array("rem ".utf16), Array("REM ".utf16), Array("@rem".utf16)]
                $0.strings = [StringRule("\"", escape: false)]
                $0.keywords = words(
                    "echo set if else goto call exit for in do not exist defined errorlevel setlocal endlocal pause shift cd pushd popd"
                )
                $0.caseInsensitive = true
                $0.variablePrefix = Char.percent
            }, extensions: ["bat", "cmd"]),
        TextLanguage(
            "sql", "SQL",
            code {
                $0.lineComments = [Array("--".utf16)]
                $0.blockComments = cComments.block
                $0.strings = [
                    StringRule("'", escape: false, doubled: true), StringRule("\"", escape: false),
                    StringRule("`", escape: false),
                ]
                $0.keywords = words(
                    """
                    select from where and or not insert into values update set delete create table view index drop \
                    alter add column primary key foreign references unique default check constraint join inner left \
                    right outer full cross on as group by order having limit offset union all distinct case when then \
                    else end in is like between exists asc desc begin commit rollback transaction with recursive \
                    returning if replace trigger procedure function returns declare cast database schema grant revoke \
                    truncate merge using over partition window
                    """)
                $0.types = words(
                    "int integer bigint smallint tinyint decimal numeric float real double varchar char text blob date time timestamp boolean serial uuid json jsonb"
                )
                $0.literals = words("null true false")
                $0.caseInsensitive = true
                $0.attributePrefixes = [Char.at, Char.colon]
            }, extensions: ["sql", "ddl", "dml", "psql", "mysql", "sqlite"]),
        TextLanguage(
            "graphql", "GraphQL",
            code {
                $0.lineComments = [Array("#".utf16)]
                $0.strings = [StringRule("\"\"\"", multiline: true), StringRule("\"")]
                $0.keywords = words(
                    "query mutation subscription fragment on type interface union enum input scalar schema extend implements directive repeatable"
                )
                $0.literals = words("true false null")
                $0.attributePrefixes = [Char.at]
                $0.variablePrefix = Char.dollar
                $0.capitalizedTypes = true
            }, extensions: ["graphql", "gql", "graphqls"]),
        TextLanguage(
            "protobuf", "Protocol Buffers",
            cLike(
                keywords:
                    "syntax edition import weak public package option message enum service rpc returns stream oneof map reserved extensions extend optional required repeated to max",
                types:
                    "double float int32 int64 uint32 uint64 sint32 sint64 fixed32 fixed64 sfixed32 sfixed64 bool string bytes"
            ) { $0.capitalizedTypes = true }, extensions: ["proto"]),
        TextLanguage(
            "thrift", "Thrift",
            cLike(
                keywords:
                    "namespace include typedef struct union exception enum const service extends throws oneway required optional void",
                types: "bool byte i8 i16 i32 i64 double string binary list set map"
            ) { $0.lineComments = [Array("//".utf16), Array("#".utf16)] }, extensions: ["thrift"]),
        TextLanguage(
            "hcl", "Terraform",
            code {
                $0.lineComments = [Array("#".utf16), Array("//".utf16)]
                $0.blockComments = cComments.block
                $0.strings = [StringRule("\"")]
                $0.keywords = words(
                    "resource data variable output module provider locals terraform for in if each count depends_on lifecycle dynamic content"
                )
                $0.literals = words("true false null")
            }, extensions: ["tf", "tfvars", "hcl", "nomad"]),
        TextLanguage(
            "nix", "Nix",
            code {
                $0.lineComments = [Array("#".utf16)]
                $0.blockComments = cComments.block
                $0.strings = [StringRule("''", escape: false, multiline: true), StringRule("\"")]
                $0.keywords = words("let in with rec inherit if then else assert import or")
                $0.literals = words("true false null")
                $0.identifierExtras = [Char.minus, Char.apostrophe]
            }, extensions: ["nix"]),
        TextLanguage(
            "cmake", "CMake",
            code {
                $0.lineComments = [Array("#".utf16)]
                $0.strings = [StringRule("\"", multiline: true)]
                $0.keywords = words(
                    "if elseif else endif foreach endforeach while endwhile function endfunction macro endmacro return set unset option project include add_executable add_library target_link_libraries target_include_directories find_package cmake_minimum_required install message"
                )
                $0.literals = words("ON OFF TRUE FALSE YES NO")
                $0.variablePrefix = Char.dollar
                $0.caseInsensitive = true
            }, extensions: ["cmake"], fileNames: ["cmakelists.txt"]),
        TextLanguage(
            "makefile", "Makefile",
            code {
                $0.lineComments = [Array("#".utf16)]
                $0.strings = [StringRule("\""), StringRule("'")]
                $0.keywords = words(
                    "ifeq ifneq ifdef ifndef else endif include -include sinclude define endef export unexport override vpath .PHONY"
                )
                $0.variablePrefix = Char.dollar
                $0.lineStartLabels = true
                $0.functionCalls = false
                $0.identifierExtras = [Char.minus, Char.dot, Char.slash]
            }, extensions: ["mk", "mak", "make"], fileNames: ["makefile", "gnumakefile", "bsdmakefile"]),
        TextLanguage(
            "dockerfile", "Dockerfile",
            code {
                $0.lineComments = [Array("#".utf16)]
                $0.strings = [StringRule("\""), StringRule("'")]
                $0.keywords = words(
                    "from as run cmd label maintainer expose env add copy entrypoint volume user workdir arg onbuild stopsignal healthcheck shell"
                )
                $0.caseInsensitive = true
                $0.variablePrefix = Char.dollar
                $0.functionCalls = false
            }, extensions: ["dockerfile", "containerfile"], fileNames: ["dockerfile", "containerfile"]),
        TextLanguage(
            "asm", "Assembly",
            code {
                $0.lineComments = [Array(";".utf16), Array("#".utf16), Array("//".utf16)]
                $0.blockComments = cComments.block
                $0.strings = [StringRule("\""), StringRule("'")]
                $0.keywords = words(
                    "mov movl movq add sub mul div inc dec push pop call ret jmp je jne jz jnz cmp test and or xor not shl shr lea nop int syscall ldr str bl b bx cbz cbnz adr adrp stp ldp"
                )
                $0.attributePrefixes = [Char.dot, Char.percent]
                $0.lineStartLabels = true
                $0.caseInsensitive = true
                $0.functionCalls = false
            }, extensions: ["s", "asm", "nasm"]),
        TextLanguage(
            "vim", "Vim Script",
            code {
                $0.lineComments = [Array("\"".utf16)]
                $0.strings = [StringRule("'", escape: false)]
                $0.keywords = words(
                    "let set if else elseif endif for endfor while endwhile function endfunction call return autocmd augroup map nmap vmap imap noremap nnoremap vnoremap inoremap command syntax highlight execute"
                )
            }, extensions: ["vim"], fileNames: [".vimrc", ".gvimrc", "_vimrc"]),
        TextLanguage(
            "tex", "LaTeX",
            code {
                $0.lineComments = [Array("%".utf16)]
                $0.attributePrefixes = [Char.backslash]
                $0.functionCalls = false
            }, extensions: ["tex", "sty", "cls", "bib", "ltx"]),
        TextLanguage(
            "log", "Log",
            code {
                $0.strings = [StringRule("\"")]
                $0.keywords = words("ERROR FATAL CRITICAL WARN WARNING error fatal warning Error Warning Fatal")
                $0.literals = words("INFO DEBUG TRACE NOTICE info debug trace notice true false null")
                $0.functionCalls = false
            }, extensions: ["log"]),
        TextLanguage(
            "html", "HTML", .markup,
            extensions: [
                "html", "htm", "xhtml", "shtml", "vue", "svelte", "hbs", "handlebars", "mustache", "jinja", "j2",
                "twig", "liquid",
            ]),
        TextLanguage(
            "xml", "XML", .markup,
            extensions: [
                "xml", "plist", "svg", "xsd", "xsl", "xslt", "rss", "atom", "xib", "storyboard", "entitlements",
                "csproj",
                "vbproj", "fsproj", "props", "targets", "resx", "xaml", "wsdl", "kml", "gpx", "dae", "opml",
            ]),
        TextLanguage(
            "markdown", "Markdown", .markdown, extensions: ["md", "markdown", "mdown", "mkd", "mkdn", "mdx"],
            hasPreview: true),
        TextLanguage("yaml", "YAML", .yaml, extensions: ["yaml", "yml"], fileNames: [".clang-format", ".clang-tidy"]),
        TextLanguage(
            "toml", "TOML",
            .ini(
                {
                    var rules = INIRules()
                    rules.semicolonComments = false
                    rules.typedValues = true
                    return rules
                }()), extensions: ["toml"], fileNames: ["cargo.lock", "pipfile", "poetry.lock"]),
        TextLanguage(
            "ini", "INI", .ini(INIRules()),
            extensions: ["ini", "cfg", "conf", "config", "inf", "reg", "desktop", "service", "editorconfig"],
            fileNames: [
                ".gitconfig", ".editorconfig", ".npmrc", ".gitmodules", ".flake8", ".pylintrc", "setup.cfg", "tox.ini",
            ]),
        TextLanguage(
            "properties", "Properties",
            .ini(
                {
                    var rules = INIRules()
                    rules.semicolonComments = false
                    rules.colonSeparates = true
                    return rules
                }()), extensions: ["properties"]),
        TextLanguage(
            "dotenv", "Environment File",
            .ini(
                {
                    var rules = INIRules()
                    rules.semicolonComments = false
                    rules.exportKeyword = true
                    return rules
                }()), extensions: ["env"], fileNames: [".env", ".envrc", ".flaskenv"]),
        TextLanguage(
            "ignore", "Ignore List",
            code {
                $0.lineComments = [Array("#".utf16)]
                $0.functionCalls = false
            },
            fileNames: [
                ".gitignore", ".dockerignore", ".npmignore", ".gitattributes", ".hgignore", ".eslintignore",
                ".prettierignore", "codeowners",
            ]),
        TextLanguage("css", "CSS", .css(CSSRules()), extensions: ["css"]),
        TextLanguage(
            "scss", "SCSS",
            .css(
                {
                    var rules = CSSRules()
                    rules.lineComments = true
                    rules.variablePrefix = Char.dollar
                    return rules
                }()), extensions: ["scss", "sass"]),
        TextLanguage(
            "less", "Less",
            .css(
                {
                    var rules = CSSRules()
                    rules.lineComments = true
                    rules.variablePrefix = Char.at
                    return rules
                }()), extensions: ["less"]),
        TextLanguage("diff", "Diff", .diff, extensions: ["diff", "patch", "rej"]),
        TextLanguage("csv", "CSV", .plain, extensions: ["csv", "tsv", "tab", "psv"]),
    ]
}
