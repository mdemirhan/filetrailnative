import Foundation

public enum LineEnding: String, Sendable, CaseIterable {
    case lf = "LF"
    case crlf = "CRLF"
    case cr = "CR"

    public var characters: String {
        switch self {
        case .lf: "\n"
        case .crlf: "\r\n"
        case .cr: "\r"
        }
    }
}

public enum Indentation: Equatable, Sendable {
    case tabs
    case spaces(Int)

    public var label: String {
        switch self {
        case .tabs: "Tabs"
        case .spaces(let width): "Spaces: \(width)"
        }
    }
}

/// How a text file is written: what its bytes are read as, and what is written back on Save.
public struct TextFormat: Equatable, Sendable {
    public var encoding: String.Encoding
    public var hasBOM: Bool
    public var lineEnding: LineEnding

    public init(encoding: String.Encoding = .utf8, hasBOM: Bool = false, lineEnding: LineEnding = .lf) {
        self.encoding = encoding
        self.hasBOM = hasBOM
        self.lineEnding = lineEnding
    }

    /// As the status bar names it.
    public var encodingName: String {
        let base: String =
            switch encoding {
            case .utf8: "UTF-8"
            case .utf16LittleEndian: "UTF-16 LE"
            case .utf16BigEndian: "UTF-16 BE"
            case .utf32LittleEndian: "UTF-32 LE"
            case .utf32BigEndian: "UTF-32 BE"
            case .windowsCP1252: "Windows Latin 1"
            case .macOSRoman: "Mac Roman"
            case .isoLatin1: "ISO Latin 1"
            default: String.localizedName(of: encoding)
            }
        return hasBOM && encoding == .utf8 ? base + " with BOM" : base
    }
}

/// Reads a file's bytes as text, and writes text back as the file had it.
public enum TextDecoding {
    /// How much of a file is looked at to tell text from other files.
    public static let sniffLength = 8192

    /// The text and its format, or nil for a file that isn't text in any encoding read here. Line breaks come back as
    /// `\n`; `format.lineEnding` says what Save writes.
    public static func decode(_ data: Data) -> (text: String, format: TextFormat)? {
        guard let (encoding, bomLength) = encoding(of: data) else { return nil }
        let body = bomLength > 0 ? data.dropFirst(bomLength) : data[...]
        guard let raw = String(data: Data(body), encoding: encoding) else { return nil }
        let ending = lineEnding(of: raw)
        let text: String =
            switch ending {
            case .lf: raw
            case .crlf: raw.replacingOccurrences(of: "\r\n", with: "\n")
            case .cr: raw.replacingOccurrences(of: "\r", with: "\n")
            }
        return (text, TextFormat(encoding: encoding, hasBOM: bomLength > 0, lineEnding: ending))
    }

    /// The bytes Save writes, or nil when a character can't be written in the file's encoding.
    public static func encode(_ text: String, as format: TextFormat) -> Data? {
        let lines =
            format.lineEnding == .lf ? text : text.replacingOccurrences(of: "\n", with: format.lineEnding.characters)
        guard var data = lines.data(using: format.encoding, allowLossyConversion: false) else { return nil }
        if format.hasBOM {
            let bom: [UInt8] =
                switch format.encoding {
                case .utf8: [0xEF, 0xBB, 0xBF]
                case .utf16LittleEndian: [0xFF, 0xFE]
                case .utf16BigEndian: [0xFE, 0xFF]
                case .utf32LittleEndian: [0xFF, 0xFE, 0, 0]
                case .utf32BigEndian: [0, 0, 0xFE, 0xFF]
                default: []
                }
            data.insert(contentsOf: bom, at: 0)
        }
        return data
    }

    /// Whether the start of a file reads as text, without decoding all of it.
    public static func looksLikeText(_ prefix: Data) -> Bool {
        guard let (encoding, bomLength) = encoding(of: prefix) else { return false }
        if bomLength > 0 || encoding != .utf8 { return true }
        // A multi-byte character cut at the end of the prefix is still text.
        for cut in 0...3 where prefix.count > cut {
            if String(data: prefix.dropLast(cut), encoding: .utf8) != nil { return true }
        }
        return false
    }

    /// The encoding and the length of the byte order mark, by the mark, else UTF-8, else Windows Latin 1 for bytes
    /// with few control characters. Nil for a file with a zero byte and no mark, which no text file has.
    static func encoding(of data: Data) -> (String.Encoding, Int)? {
        let head = [UInt8](data.prefix(4))
        if head.starts(with: [0xEF, 0xBB, 0xBF]) { return (.utf8, 3) }
        if head.starts(with: [0xFF, 0xFE, 0, 0]) { return (.utf32LittleEndian, 4) }
        if head.starts(with: [0, 0, 0xFE, 0xFF]) { return (.utf32BigEndian, 4) }
        if head.starts(with: [0xFF, 0xFE]) { return (.utf16LittleEndian, 2) }
        if head.starts(with: [0xFE, 0xFF]) { return (.utf16BigEndian, 2) }
        let sample = data.prefix(sniffLength)
        if sample.contains(0) { return nil }
        if isUTF8(sample, whole: sample.count == data.count) { return (.utf8, 0) }
        var controls = 0
        for byte in sample where byte < 0x20 && ![9, 10, 12, 13, 27].contains(byte) { controls += 1 }
        return controls * 100 <= sample.count ? (.windowsCP1252, 0) : nil
    }

    private static func isUTF8(_ sample: Data, whole: Bool) -> Bool {
        if String(data: sample, encoding: .utf8) != nil { return true }
        guard !whole else { return false }
        for cut in 1...3 where sample.count > cut {
            if String(data: sample.dropLast(cut), encoding: .utf8) != nil { return true }
        }
        return false
    }

    /// The line ending most lines have, among the first 64 KB.
    public static func lineEnding(of text: String) -> LineEnding {
        var crlf = 0
        var lf = 0
        var cr = 0
        var previous: UInt8 = 0
        var seen = 0
        for byte in text.utf8 {
            if byte == 10 {
                if previous == 13 {
                    crlf += 1
                    cr -= 1
                } else {
                    lf += 1
                }
            } else if byte == 13 {
                cr += 1
            }
            previous = byte
            seen += 1
            if seen > 65536 { break }
        }
        if crlf > lf && crlf >= cr { return .crlf }
        if cr > lf && cr > crlf { return .cr }
        return .lf
    }

    /// Tabs, or the indent width most indented lines are a multiple of, among the first 2,000 lines.
    public static func indentation(of text: String) -> Indentation? {
        var tabs = 0
        var widths: [Int: Int] = [:]
        var lines = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            lines += 1
            if lines > 2000 { break }
            guard let first = line.first else { continue }
            if first == "\t" {
                tabs += 1
            } else if first == " " {
                let width = line.prefix { $0 == " " }.count
                if width < line.count { widths[width, default: 0] += 1 }
            }
        }
        let spaced = widths.values.reduce(0, +)
        if tabs == 0 && spaced == 0 { return nil }
        if tabs > spaced { return .tabs }
        for candidate in [8, 4, 3, 2] {
            let fits = widths.filter { $0.key % candidate == 0 }.values.reduce(0, +)
            if fits * 10 >= spaced * 9 && widths.keys.contains(where: { $0 == candidate }) { return .spaces(candidate) }
        }
        return .spaces(widths.keys.min() ?? 4)
    }
}
