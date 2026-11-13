// What a batch rename says of a pattern it can't take: JavaScript's words for each mistake (with the u flag)
import Testing

@testable import FTFoundation

struct JSRegExpErrorTests {
    @Test(arguments: [
        ("(", "Unterminated group"), ("a(b", "Unterminated group"), ("a)", "Unmatched ')'"),
        ("*", "Nothing to repeat"), ("a**", "Nothing to repeat"), ("{1}", "Nothing to repeat"),
        ("{", "Lone quantifier brackets"), ("x|{a", "Lone quantifier brackets"), ("a*{", "Lone quantifier brackets"),
        ("}", "Lone quantifier brackets"), ("a{1", "Incomplete quantifier"), ("a{,1}", "Incomplete quantifier"),
        ("a{2,1}", "numbers out of order in {} quantifier"), ("{2,1}", "Nothing to repeat"),
        ("[a", "Unterminated character class"), ("[z-a]", "Range out of order in character class"),
        ("[\\d-z]", "Invalid character class"), ("(?<a", "Invalid capture group name"),
        ("(?<1a>x)", "Invalid capture group name"), ("(?<a>x)(?<a>y)", "Duplicate capture group name"),
        ("(?<a>x)\\k<b>", "Invalid named capture referenced"), ("(?x)", "Invalid group"),
        ("a\\", "\\ at end of pattern"), ("\\u{110000}", "Invalid Unicode escape"), ("\\u12", "Invalid Unicode escape"),
        ("\\p{Nope!}", "Invalid property name"), ("\\p{Nope}", "Invalid property name"),
        ("\\p", "Invalid property name"), ("\\q", "Invalid escape"),
        ("\\x4", "Invalid escape"),
    ])
    func saysWhatIsWrongWithAPattern(pattern: String, message: String) {
        let error = #expect(throws: JSRegExpError.self) { try JSRegExp(source: pattern, ignoreCase: false) }
        #expect(error?.message == message)
    }

    // A property ICU knows by JavaScript's name is taken, and matches.
    @Test(arguments: [("\\p{L}", "é"), ("\\p{Lu}", "A"), ("\\P{Lu}", "a"), ("\\p{Script=Greek}", "λ")])
    func takesAKnownProperty(pattern: String, text: String) throws {
        #expect(try JSRegExp(source: pattern, ignoreCase: false).matches(in: text).count == 1)
    }
}
