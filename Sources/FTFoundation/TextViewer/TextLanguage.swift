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

    /// The language of a file, by its whole name, then its extension, then the program its `#!` line names. A name
    /// with no extension goes by its `#!` line first: a script called `build` is the script's, not Bazel's.
    public static func detect(fileName: String, firstLine: String? = nil) -> TextLanguage {
        let lower = fileName.lowercased()
        let ext = (lower as NSString).pathExtension
        let interpreted = firstLine.flatMap(TextLanguages.interpreter(of:))
        if ext.isEmpty, let interpreted { return interpreted }
        if let language = TextLanguages.byFileName[lower] { return language }
        if !ext.isEmpty, let language = TextLanguages.byExtension[ext] { return language }
        if lower.hasPrefix(".env") || lower.hasSuffix(".env") { return TextLanguages.byID["dotenv"] ?? plainText }
        if let interpreted { return interpreted }
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

    /// The language of the program a `#!` line runs: the program itself (`/bin/zsh`), the one `env` runs after its
    /// options (`env -S deno run`), or for a runner that names no language, the first word after it that does
    /// (`env -S npx tsx`). `python3.12` is `python`.
    static func interpreter(of line: String) -> TextLanguage? {
        guard line.hasPrefix("#!") else { return nil }
        var words = line.dropFirst(2).split(whereSeparator: { $0 == " " || $0 == "\t" }).map { word in
            String(word.split(separator: "/").last ?? word).lowercased()
        }
        if words.first == "env" {
            words.removeFirst()
            while let first = words.first, first.hasPrefix("-") || first.contains("=") { words.removeFirst() }
        }
        for word in words where !word.hasPrefix("-") {
            let name = word.trimmingCharacters(in: .decimalDigits.union(CharacterSet(charactersIn: ".")))
            if let language = byInterpreter[name] { return language }
        }
        return nil
    }

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

    static let list: [TextLanguage] = compiled + scripting + data + documents
}
