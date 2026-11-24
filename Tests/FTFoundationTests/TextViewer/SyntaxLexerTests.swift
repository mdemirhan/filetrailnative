import Foundation
import Testing

@testable import FTFoundation

/// The lexer, by the runs it colors in short texts of each kind of grammar: each expectation names the text of a run
/// and its kind, worked out by hand from the language's rules.
@Suite struct SyntaxLexerTests {
    /// The runs of `text` as (their text, their kind), in order.
    private func runs(_ text: String, _ id: String) throws -> [(String, SyntaxKind)] {
        let language = try #require(TextLanguage.with(id: id))
        let units = Array(text.utf16)
        return SyntaxLexer(language: language).tokens(of: text).map { token in
            let slice = Array(units[token.location..<(token.location + token.length)])
            return (String(decoding: slice, as: UTF16.self), token.kind)
        }
    }

    private func kinds(_ text: String, _ id: String) throws -> [String: SyntaxKind] {
        Dictionary(try runs(text, id).map { ($0.0, $0.1) }, uniquingKeysWith: { first, _ in first })
    }

    @Test func swiftHasKeywordsTypesStringsCommentsNumbersAndAttributes() throws {
        let found = try kinds(
            """
            @State private var count: Int = 42 // the count
            func reload() { print("hi \\" there") }
            """, "swift")
        #expect(found["@State"] == .attribute)
        #expect(found["private var"] == nil)
        #expect(found["private"] == .keyword)
        #expect(found["var"] == .keyword)
        #expect(found["Int"] == .type)
        #expect(found["42"] == .number)
        #expect(found["// the count"] == .comment)
        #expect(found["func"] == .keyword)
        #expect(found["reload"] == .function)
        #expect(found["print"] == .function)
        #expect(found["\"hi \\\" there\""] == .string)
    }

    @Test func aMemberAfterADotIsNotAKeyword() throws {
        let found = try kinds("let x = value.default", "swift")
        #expect(found["let"] == .keyword)
        #expect(found["default"] == nil)
    }

    @Test func aRangeIsTwoNumbersAndAnExponentIsOne() throws {
        #expect(try runs("0..<5", "swift").map(\.0) == ["0", "5"])
        #expect(try runs("x = 1.5e-3", "python").map(\.0) == ["1.5e-3"])
        #expect(try runs("0x1F", "c").map(\.1) == [.number])
    }

    @Test func aBlockCommentAndATripleQuotedStringRunOnToTheLinesAfter() throws {
        let c = try runs("int a; /* one\ntwo */ int b;", "c")
        #expect(c.contains { $0 == ("/* one", .comment) })
        #expect(c.contains { $0 == ("two */", .comment) })
        #expect(c.contains { $0 == ("int", .type) })
        let python = try runs("x = \"\"\"first\nsecond\"\"\"\ny = 1", "python")
        #expect(python.map(\.1) == [.string, .string, .number])
    }

    @Test func swiftCommentsNest() throws {
        let found = try runs("/* a /* b */ c */ let", "swift")
        #expect(found.map(\.0) == ["/* a /* b */ c */", "let"])
    }

    @Test func aShellHashStartsACommentOnlyAfterASpace() throws {
        let found = try runs("echo a#b # note\nexport NAME=$HOME", "shell")
        #expect(found.contains { $0 == ("# note", .comment) })
        #expect(!found.contains { $0.0.contains("#b") })
        #expect(found.contains { $0 == ("$HOME", .variable) })
        #expect(found.contains { $0 == ("export", .keyword) })
    }

    @Test func aPreprocessorLineHasItsDirectiveAndItsHeader() throws {
        let found = try kinds("#include <stdio.h>", "c")
        #expect(found["#include"] == .attribute)
        #expect(found["<stdio.h>"] == .string)
    }

    @Test func jsonKeysAreToldFromValues() throws {
        let found = try kinds("{\"name\": \"lighthouse\", \"ok\": true, \"n\": 12}", "json")
        #expect(found["\"name\""] == .property)
        #expect(found["\"lighthouse\""] == .string)
        #expect(found["true"] == .literal)
        #expect(found["12"] == .number)
    }

    @Test func yamlHasKeysCommentsLiteralsAndBlockScalars() throws {
        let found = try runs("server:\n  port: 8080 # the port\n  on: yes\ntext: |\n  any: thing\nnext: 1", "yaml")
        #expect(found.contains { $0 == ("server", .property) })
        #expect(found.contains { $0 == ("8080", .number) })
        #expect(found.contains { $0 == ("# the port", .comment) })
        #expect(found.contains { $0 == ("yes", .literal) })
        // The block scalar's line is text, not a key.
        #expect(found.contains { $0 == ("any: thing", .string) })
        #expect(found.contains { $0 == ("next", .property) })
    }

    @Test func markdownHasHeadingsFencesEmphasisAndLinks() throws {
        let found = try runs(
            "# Title\nSome *em* and **strong** and `code`.\n```\nlet x = 1\n```\n- [link](http://a.b)", "markdown")
        #expect(found.contains { $0 == ("# Title", .heading) })
        #expect(found.contains { $0 == ("*em*", .emphasis) })
        #expect(found.contains { $0 == ("**strong**", .strong) })
        #expect(found.contains { $0 == ("`code`", .code) })
        #expect(found.contains { $0 == ("let x = 1", .code) })
        #expect(found.contains { $0 == ("-", .keyword) })
        #expect(found.contains { $0 == ("[link]", .link) })
        #expect(found.contains { $0 == ("(http://a.b)", .meta) })
    }

    @Test func markupHasTagsAttributesValuesCommentsAndEntities() throws {
        let found = try runs("<a href=\"x\">&amp; <!-- note\nend --></a>", "html")
        #expect(found.contains { $0 == ("<a", .tag) })
        #expect(found.contains { $0 == ("href", .property) })
        #expect(found.contains { $0 == ("\"x\"", .string) })
        #expect(found.contains { $0 == ("&amp;", .literal) })
        #expect(found.contains { $0 == ("<!-- note", .comment) })
        #expect(found.contains { $0 == ("end -->", .comment) })
        // The closing tag and its bracket touch, so they are one run.
        #expect(found.contains { $0 == ("</a>", .tag) })
    }

    @Test func cssHasSelectorsPropertiesColorsAndAtRules() throws {
        let found = try kinds("@media screen {\n.card a:hover { color: #fff; margin: 4px !important; }\n}", "css")
        #expect(found["@media"] == .keyword)
        #expect(found[".card"] == .attribute)
        #expect(found["color"] == .property)
        #expect(found["#fff"] == .number)
        #expect(found["4px"] == .number)
        #expect(found["!important"] == .keyword)
    }

    @Test func iniAndTomlHaveSectionsKeysAndValues() throws {
        let ini = try kinds("; note\n[core]\neditor = vim", "ini")
        #expect(ini["; note"] == .comment)
        #expect(ini["[core]"] == .heading)
        #expect(ini["editor"] == .property)
        let toml = try kinds("[package]\nname = \"ft\"\nversion = 2\nok = true", "toml")
        #expect(toml["\"ft\""] == .string)
        #expect(toml["2"] == .number)
        #expect(toml["true"] == .literal)
    }

    @Test func aDiffHasItsAddedAndRemovedLines() throws {
        let found = try runs("--- a\n+++ b\n@@ -1 +1 @@\n-old\n+new\n same", "diff")
        #expect(found.map(\.1) == [.meta, .meta, .meta, .deleted, .inserted])
    }

    @Test func sqlKeywordsIgnoreCase() throws {
        let found = try kinds("SELECT name FROM people WHERE id = 'it''s'", "sql")
        #expect(found["SELECT"] == .keyword)
        #expect(found["FROM"] == .keyword)
        #expect(found["'it''s'"] == .string)
    }

    @Test func aStringsFileAndAnXcodeProjectHaveKeysBeforeTheirEquals() throws {
        let strings = try kinds("/* Greeting */\n\"hello\" = \"Hello\";", "strings")
        #expect(strings["/* Greeting */"] == .comment)
        #expect(strings["\"hello\""] == .property)
        #expect(strings["\"Hello\""] == .string)
        let project = try kinds("isa = PBXBuildFile; fileRef = 8A1B2C /* App.swift */;", "pbxproj")
        #expect(project["isa"] == .property)
        #expect(project["fileRef"] == .property)
        #expect(project["PBXBuildFile"] == nil)
        #expect(project["8A1B2C"] == .number)
    }

    @Test func anXcodeConfigHasItsSettingsIncludesAndVariables() throws {
        let found = try kinds(
            "#include \"Base.xcconfig\"\n// Release\nOTHER_LDFLAGS[sdk=macosx*] = $(inherited) -ObjC\nENABLE_BITCODE = NO",
            "xcconfig")
        #expect(found["#include"] == .attribute)
        #expect(found["\"Base.xcconfig\""] == .string)
        #expect(found["// Release"] == .comment)
        #expect(found["OTHER_LDFLAGS"] == .property)
        #expect(found["$(inherited)"] == .variable)
        #expect(found["ENABLE_BITCODE"] == .property)
        #expect(found["NO"] == .literal)
    }

    @Test func metalHasItsQualifiersVectorsAndAttributes() throws {
        let found = try kinds("vertex float4 main0(uint id [[vertex_id]], constant half3 *c [[buffer(0)]])", "metal")
        #expect(found["vertex"] == .keyword)
        #expect(found["float4"] == .type)
        #expect(found["half3"] == .type)
        #expect(found["constant"] == .keyword)
        #expect(found["[[vertex_id]]"] == .attribute)
        #expect(found["[[buffer(0)]]"] == .attribute)
    }

    @Test func shadingLanguagesHaveTheirVectorAndMatrixTypes() throws {
        let glsl = try kinds("uniform mat4x3 m; layout(location = 0) in vec3 p;", "glsl")
        #expect(glsl["uniform"] == .keyword)
        #expect(glsl["mat4x3"] == .type)
        #expect(glsl["vec3"] == .type)
        let hlsl = try kinds("cbuffer C : register(b0) { float4x4 world; Texture2D tex; };", "hlsl")
        #expect(hlsl["cbuffer"] == .keyword)
        #expect(hlsl["float4x4"] == .type)
        #expect(hlsl["Texture2D"] == .type)
    }

    @Test func visualBasicAndAppleScriptIgnoreCase() throws {
        let vb = try kinds("Public Sub Main() ' starts\n  Dim s As String = \"a\"\"b\"\nEnd Sub", "vb")
        #expect(vb["Public"] == .keyword)
        #expect(vb["Main"] == .function)
        #expect(vb["' starts"] == .comment)
        #expect(vb["String"] == .type)
        #expect(vb["\"a\"\"b\""] == .string)
        let script = try kinds(
            "on greet(name) -- say it\n  tell application \"Finder\" to activate\nend greet", "applescript")
        #expect(script["on"] == .keyword)
        #expect(script["greet"] == .function)
        #expect(script["-- say it"] == .comment)
        #expect(script["tell"] == .keyword)
        #expect(script["\"Finder\""] == .string)
    }

    @Test func aGoModuleHasItsDirectives() throws {
        let found = try kinds(
            "module example.com/app\n\ngo 1.22\n\nrequire golang.org/x/text v0.14.0 // indirect", "gomod")
        #expect(found["module"] == .keyword)
        #expect(found["go"] == .keyword)
        #expect(found["1.22"] == .number)
        #expect(found["require"] == .keyword)
        #expect(found["// indirect"] == .comment)
    }

    @Test func aScriptAndAStyleAreColoredAsTheirLanguage() throws {
        let found = try runs(
            """
            <style>
            .card { color: red; }
            </style>
            <script type="module">
            const n = 1 // count
            </script><p class="x">
            """, "html")
        #expect(found.contains { $0 == (".card", .attribute) })
        #expect(found.contains { $0 == ("color", .property) })
        #expect(found.contains { $0 == ("const", .keyword) })
        #expect(found.contains { $0 == ("// count", .comment) })
        // The closing tag touches the next, so they are one run.
        #expect(found.contains { $0 == ("</script><p", .tag) })
        #expect(found.contains { $0 == ("class", .property) })
    }

    @Test func aVueOrSvelteBlockGoesByItsLang() throws {
        let found = try runs(
            """
            <script setup
              lang="ts">
            let n: number = 1
            </script>
            <style lang="scss">$gap: 4px;</style>
            <template><div>{{ n }}</div></template>
            """, "html")
        #expect(found.contains { $0 == ("number", .type) })
        #expect(found.contains { $0 == ("$gap", .variable) })
        #expect(found.contains { $0 == ("<template><div>", .tag) })
    }

    @Test func aScriptOfAnotherTypeIsJSONOrPlainText() throws {
        let json = try runs("<script type=\"application/ld+json\">{\"a\": 1}</script>", "html")
        #expect(json.contains { $0 == ("\"a\"", .property) })
        let shader = try runs("<script type=\"x-shader/x-vertex\">if (a < b) {}</script>", "html")
        #expect(!shader.contains { $0.0 == "if" || $0.0 == "b" })
        // A script that closes as it opens has no text.
        let empty = try runs("<script src=\"a.js\"/><b>x</b>", "html")
        #expect(empty.contains { $0 == ("/><b>", .tag) })
    }

    @Test func aFencedBlockIsColoredAsTheLanguageItNames() throws {
        let found = try runs(
            """
            ```swift
            let x = 1 // one
            ```
            ```{r}
            x <- TRUE
            ```
            ```unknown
            let y = 2
            ```
            """, "markdown")
        #expect(found.contains { $0 == ("```swift", .code) })
        #expect(found.contains { $0 == ("let", .keyword) })
        #expect(found.contains { $0 == ("// one", .comment) })
        #expect(found.contains { $0 == ("TRUE", .literal) })
        #expect(found.contains { $0 == ("let y = 2", .code) })
    }

    @Test func codeInsideCodeIsNotLookedInto() throws {
        let found = try runs("```html\n<script>let a = 1</script>\n```", "markdown")
        #expect(found.contains { $0 == ("<script>", .tag) })
        #expect(!found.contains { $0.0 == "let" })
    }

    @Test func plainTextHasNoRuns() throws {
        #expect(try runs("let x = 1 // nothing", "plain").isEmpty)
    }

    /// Lexing a line at a time from the state the line before ended in gives the runs of the whole text: what lets an
    /// edit re-lex from its line only.
    @Test(arguments: [
        ("a = '''x\ny''' # c\n/* not a comment */ b = 2", "python"),
        ("<script\n type=\"module\">\nconst s = `a\nb` /* c\nd */\n</script>\n<p>", "html"),
        ("```js\nconst s = `a\nb`\n```\n*em*", "markdown"),
    ])
    func lineByLineFromCarriedStatesGivesTheSameRuns(_ text: String, _ id: String) throws {
        let language = try #require(TextLanguage.with(id: id))
        let lexer = SyntaxLexer(language: language)
        let whole = lexer.tokens(of: text)
        var state = LexState.normal
        var offset = 0
        var pieces: [SyntaxToken] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let units = Array(line.utf16)
            var tokens: [SyntaxToken] = []
            state = units.withUnsafeBufferPointer { lexer.lex($0, from: state, into: &tokens) }
            pieces += tokens.map { SyntaxToken($0.location + offset, $0.length, $0.kind) }
            offset += units.count + 1
        }
        #expect(pieces == whole)
    }
}
