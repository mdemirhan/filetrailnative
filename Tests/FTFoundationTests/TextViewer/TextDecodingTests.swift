import Foundation
import Testing

@testable import FTFoundation

@Suite struct TextDecodingTests {
    @Test func utf8IsReadAndWrittenBackByteForByte() throws {
        let data = Data("héllo\nwörld\n".utf8)
        let (text, format) = try #require(TextDecoding.decode(data))
        #expect(text == "héllo\nwörld\n")
        #expect(format == TextFormat(encoding: .utf8, hasBOM: false, lineEnding: .lf))
        #expect(TextDecoding.encode(text, as: format) == data)
    }

    @Test func aByteOrderMarkIsKeptAndNotShown() throws {
        let data = Data([0xEF, 0xBB, 0xBF] + Array("a\r\nb".utf8))
        let (text, format) = try #require(TextDecoding.decode(data))
        #expect(text == "a\nb")
        #expect(format.hasBOM && format.lineEnding == .crlf && format.encoding == .utf8)
        #expect(format.encodingName == "UTF-8 with BOM")
        #expect(TextDecoding.encode(text, as: format) == data)
    }

    @Test func utf16WithItsMarkIsText() throws {
        let data = Data([0xFF, 0xFE]) + "hi\n".data(using: .utf16LittleEndian)!
        let (text, format) = try #require(TextDecoding.decode(data))
        #expect(text == "hi\n")
        #expect(format.encoding == .utf16LittleEndian)
        #expect(TextDecoding.encode(text, as: format) == data)
    }

    @Test func aZeroByteWithoutAMarkIsNotText() {
        #expect(TextDecoding.decode(Data([0x89, 0x50, 0x4E, 0x47, 0, 0, 0, 0x0D])) == nil)
        #expect(!TextDecoding.looksLikeText(Data([0x41, 0, 0x42])))
    }

    @Test func bytesThatArentUTF8AreReadAsWindowsLatin1() throws {
        let data = Data([0x63, 0x61, 0x66, 0xE9, 0x0A])
        let (text, format) = try #require(TextDecoding.decode(data))
        #expect(text == "café\n")
        #expect(format.encoding == .windowsCP1252)
        #expect(TextDecoding.encode(text, as: format) == data)
    }

    @Test func aCharacterTheEncodingCantHoldCantBeWritten() {
        #expect(TextDecoding.encode("日本", as: TextFormat(encoding: .windowsCP1252)) == nil)
    }

    @Test func aMultiByteCharacterCutAtTheEndOfTheSampleIsStillText() {
        let data = Data("é".utf8).prefix(1)
        #expect(TextDecoding.looksLikeText(Data("ab".utf8) + data))
    }

    @Test func classicMacLineEndingsAreReadAndWrittenBack() throws {
        let data = Data("a\rb\rc".utf8)
        let (text, format) = try #require(TextDecoding.decode(data))
        #expect(text == "a\nb\nc")
        #expect(format.lineEnding == .cr)
        #expect(TextDecoding.encode(text, as: format) == data)
    }

    @Test func theIndentMostLinesHaveIsFound() {
        #expect(TextDecoding.indentation(of: "a\n\tb\n\tc\n") == .tabs)
        #expect(TextDecoding.indentation(of: "a\n    b\n        c\n    d\n") == .spaces(4))
        #expect(TextDecoding.indentation(of: "a:\n  b: 1\n  c:\n    d: 2\n") == .spaces(2))
        #expect(TextDecoding.indentation(of: "no indent\nat all") == nil)
    }
}
