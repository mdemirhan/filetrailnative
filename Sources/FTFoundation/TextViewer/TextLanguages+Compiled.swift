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
        TextLanguage(
            "metal", "Metal",
            cLike(
                keywords: cppKeywords + """
                     kernel vertex fragment device constant threadgroup threadgroup_imageblock thread ray_data \
                    object mesh visible stitchable
                    """,
                types: [
                    cTypes, shaderVectors("float half int uint short ushort char uchar bool"),
                    """
                    half uint ushort uchar float2x2 float3x3 float4x4 half2x2 half3x3 half4x4 packed_float2 \
                    packed_float3 packed_float4 texture1d texture2d texture3d texturecube texture2d_array depth2d \
                    sampler atomic_int atomic_uint atomic_bool
                    """,
                ].joined(separator: " "),
                literals: "true false nullptr NULL"
            ) {
                $0.preprocessor = true
                $0.doubleBracketAttributes = true
            }, extensions: ["metal"]),
        TextLanguage(
            "glsl", "GLSL",
            cLike(
                keywords: """
                    attribute const uniform varying buffer shared coherent volatile restrict readonly writeonly layout \
                    centroid flat smooth noperspective patch sample break continue do for while switch case default if \
                    else subroutine in out inout invariant precise discard return struct precision lowp mediump highp
                    """,
                types: [
                    "void bool int uint float double", shaderVectors("vec dvec bvec ivec uvec", matrices: "mat dmat"),
                    """
                    sampler1D sampler2D sampler3D samplerCube sampler2DShadow sampler2DArray isampler2D usampler2D \
                    image2D image3D atomic_uint
                    """,
                ].joined(separator: " ")
            ) { $0.preprocessor = true },
            extensions: ["glsl", "vert", "frag", "geom", "tesc", "tese", "comp", "vsh", "fsh"]),
        TextLanguage(
            "hlsl", "HLSL",
            cLike(
                keywords: """
                    cbuffer tbuffer struct register packoffset static const uniform extern in out inout groupshared \
                    nointerpolation linear centroid noperspective sample precise if else for while do switch case \
                    default break continue return discard typedef namespace technique technique11 pass compile \
                    row_major column_major
                    """,
                types: [
                    "void",
                    shaderVectors("float half int uint bool double min16float min16int", matrices: "float half"),
                    """
                    Texture1D Texture2D Texture3D TextureCube Texture2DArray RWTexture2D RWTexture3D SamplerState \
                    SamplerComparisonState Buffer RWBuffer StructuredBuffer RWStructuredBuffer ByteAddressBuffer \
                    RWByteAddressBuffer ConstantBuffer
                    """,
                ].joined(separator: " ")
            ) { $0.preprocessor = true }, extensions: ["hlsl", "hlsli", "fx", "fxh"]),
        TextLanguage(
            "solidity", "Solidity",
            cLike(
                keywords: """
                    pragma solidity import as from contract interface library abstract is function modifier event emit \
                    struct enum mapping public private internal external pure view payable constant immutable override \
                    virtual returns return if else for while do break continue new delete try catch revert require \
                    assert memory storage calldata using constructor fallback receive error type unchecked assembly \
                    anonymous indexed
                    """,
                types: """
                    address bool string bytes int uint int8 int16 int32 int64 int128 int256 uint8 uint16 uint32 uint64 \
                    uint128 uint256 bytes1 bytes2 bytes4 bytes8 bytes16 bytes20 bytes32
                    """,
                literals: "true false wei gwei ether seconds minutes hours days weeks",
                definers: "function modifier event contract interface library"
            ) { $0.capitalizedTypes = true }, extensions: ["sol"]),
        TextLanguage(
            "vb", "Visual Basic",
            code {
                $0.lineComments = [Array("'".utf16), Array("rem ".utf16), Array("Rem ".utf16), Array("REM ".utf16)]
                $0.strings = [StringRule("\"", escape: false, doubled: true)]
                $0.keywords = words(
                    """
                    addhandler addressof alias and andalso as byref byval call case catch class const continue declare \
                    default delegate dim do each else elseif end enum erase error event exit finally for friend function \
                    get global gosub goto handles if implements imports in inherits interface is isnot let lib like loop \
                    me mod module mustinherit mustoverride mybase myclass namespace narrowing new next not of on option \
                    optional or orelse overloads overridable overrides paramarray partial private property protected \
                    public raiseevent readonly redim removehandler resume return select set shadows shared static step \
                    stop structure sub synclock then throw to try typeof until using wend when while widening with \
                    withevents writeonly xor async await iterator yield explicit strict compare
                    """)
                $0.types = words(
                    "Boolean Byte Char Date Decimal Double Integer Long Object SByte Short Single String UInteger ULong UShort Variant"
                )
                $0.literals = words("true false nothing")
                $0.definers = words("sub function property")
                $0.caseInsensitive = true
                $0.preprocessor = true
                $0.capitalizedTypes = false
            }, extensions: ["vb", "vbs", "bas", "vba"]),
    ]

    /// The vector types of a shading language, `float2` to `float4` and `vec2` to `vec4` (`2…4` after each prefix), and
    /// the square and rectangular matrices `mat2` to `mat4x4` after each matrix prefix.
    static func shaderVectors(_ prefixes: String, matrices: String = "") -> String {
        let sizes = 2...4
        let vectors = prefixes.split(separator: " ").flatMap { prefix in sizes.map { "\(prefix)\($0)" } }
        let grids = matrices.split(separator: " ").flatMap { prefix in
            sizes.map { "\(prefix)\($0)" } + sizes.flatMap { rows in sizes.map { "\(prefix)\(rows)x\($0)" } }
        }
        return (vectors + grids).joined(separator: " ")
    }
}
