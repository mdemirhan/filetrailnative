import Foundation

extension TextLanguages {
    /// Scripting and functional languages, and the shells.
    static let scripting: [TextLanguage] = [
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
    ]
}
