import Foundation

extension TextLanguages {
    /// Compiled languages: the C family, the JVM's, and the systems languages.
    static let compiled: [TextLanguage] = [
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
    ]
}
