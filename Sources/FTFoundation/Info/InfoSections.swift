import Foundation
import UniformTypeIdentifiers

/// A section of the Info panel. The sections every item has come first and keep their rows from item to item, so
/// what is read moving from one item to the next stays in its place; the sections only some items have come after.
public struct InfoSection: Equatable, Sendable {
    public enum ID: String, Sendable, CaseIterable {
        case general, dates, permissions
        case image, movie, sound, document, text, application, volume, diskImage
        case downloaded, more

        public var title: String {
            switch self {
            case .general: "General"
            case .dates: "Dates"
            case .permissions: "Sharing & Permissions"
            case .image: "Image"
            case .movie: "Movie"
            case .sound: "Sound"
            case .document: "Document"
            case .text: "Text"
            case .application: "Application"
            case .volume: "Volume"
            case .diskImage: "Disk Image"
            case .downloaded: "Downloaded"
            case .more: "More"
            }
        }

        /// Folded until it is opened: what few look for.
        public var foldedAtFirst: Bool { self == .more }
    }

    public var id: ID
    public var rows: [InfoRow]
    /// Whether its title has Edit…: Sharing & Permissions, but not a disk's.
    public var editable: Bool

    public init(id: ID, rows: [InfoRow], editable: Bool = false) {
        self.id = id
        self.rows = rows
        self.editable = editable
    }

    public var title: String { id.title }
}

/// The disk images macOS mounts when one is opened: the extensions DiskImageMounter opens.
public enum DiskImageTypes {
    public static let extensions: Set<String> = [
        "dmg", "udif", "img", "toast", "dvdr", "cdr", "dmgpart", "iso", "sparseimage", "asif", "sparsebundle",
        "backupbundle",
    ]
}

/// What kind of content a file is, which says the section of its own it has. The reader and the panel ask the same
/// question, the panel from the name before anything is read, so the section is there, with dashes, from the start.
public enum InfoContentKind: Equatable, Sendable {
    case image, movie, sound, pdf, document, text, diskImage, other

    public static func of(_ type: UTType?) -> InfoContentKind {
        guard let type else { return .other }
        if type.conforms(to: .diskImage) { return .diskImage }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .movie }
        if type.conforms(to: .audio) { return .sound }
        if type.conforms(to: .pdf) { return .pdf }
        if [UTType.presentation, .spreadsheet, .rtf, .rtfd, .epub].contains(where: { type.conforms(to: $0) })
            || type.identifier.hasPrefix("org.openxmlformats.") || type.identifier.hasPrefix("com.apple.iwork.")
            || type.identifier == "com.microsoft.word.doc"
        {
            return .document
        }
        if type.conforms(to: .text) || type.conforms(to: .sourceCode) { return .text }
        return .other
    }

    public static func of(extension fileExtension: String) -> InfoContentKind {
        if DiskImageTypes.extensions.contains(fileExtension.lowercased()) { return .diskImage }
        return fileExtension.isEmpty ? .other : of(UTType(filenameExtension: fileExtension))
    }

    var section: InfoSection.ID? {
        switch self {
        case .image: .image
        case .movie: .movie
        case .sound: .sound
        case .pdf, .document: .document
        case .text: .text
        case .diskImage: .diskImage
        case .other: nil
        }
    }
}

/// The words of the panel's values.
public enum InfoText {
    public static let pending = InfoPanelModel.pending

    /// "3,104,512 bytes".
    public static func bytes(_ value: Int64) -> String {
        "\(FormatLocale.count(Int(clamping: value))) \(value == 1 ? "byte" : "bytes")"
    }

    /// "3.1 MB (3,104,512 bytes)"; a size under 1 KB is its bytes already.
    public static func sizeWithBytes(_ value: Int64) -> String {
        value < 1000 ? SizeText.size(value) : "\(SizeText.size(value)) (\(bytes(value)))"
    }

    /// "2:31", "1:02:03".
    public static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let (hours, minutes, rest) = (total / 3600, total / 60 % 60, total % 60)
        let tail = String(format: "%02d", rest)
        return hours > 0 ? "\(hours):\(String(format: "%02d", minutes)):\(tail)" : "\(minutes):\(tail)"
    }

    /// "18 KB (18,469 bytes), 20 KB on disk": what a Size's tooltip and Copy say.
    public static func sizeWithDisk(_ bytes: Int64, _ disk: Int64) -> String {
        "\(sizeWithBytes(bytes)), \(SizeText.size(disk)) on disk"
    }

    /// "4032 × 3024".
    public static func dimensions(_ width: Int, _ height: Int) -> String { "\(width) × \(height)" }

    /// "1/120 s", "2.5 s".
    public static func exposure(_ seconds: Double) -> String {
        guard seconds > 0 else { return pending }
        if seconds < 1 { return "1/\(Int((1 / seconds).rounded())) s" }
        return "\(JSString.toFixed(seconds, seconds.rounded() == seconds ? 0 : 1)) s"
    }

    /// "38.7223° N, 9.1393° W".
    public static func location(latitude: Double, longitude: Double) -> String {
        func part(_ value: Double, _ positive: String, _ negative: String) -> String {
            "\(JSString.toFixed(abs(value), 4))° \(value < 0 ? negative : positive)"
        }
        return "\(part(latitude, "N", "S")), \(part(longitude, "E", "W"))"
    }

    /// "8.4 Mbit/s".
    public static func bitRate(_ bitsPerSecond: Double) -> String {
        if bitsPerSecond >= 1_000_000 { return "\(JSString.toFixed(bitsPerSecond / 1_000_000, 1)) Mbit/s" }
        return "\(Int((bitsPerSecond / 1000).rounded())) kbit/s"
    }

    /// "48 kHz, stereo".
    public static func audio(sampleRate: Double?, channels: Int?) -> String? {
        var parts: [String] = []
        if let sampleRate, sampleRate > 0 {
            let khz = sampleRate / 1000
            parts.append("\(JSString.toFixed(khz, khz.rounded() == khz ? 0 : 1)) kHz")
        }
        if let channels {
            parts.append(channels == 1 ? "mono" : channels == 2 ? "stereo" : "\(channels) channels")
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// "A4 · 210 × 297 mm", "Letter · 8.5 × 11 in": the page's paper where it is one, in the units of the region.
    public static func pageSize(width: Double, height: Double, locale: Locale = FormatLocale.current) -> String {
        let papers: [(String, Double, Double)] = [
            ("A3", 842, 1191), ("A4", 595, 842), ("A5", 420, 595), ("Letter", 612, 792), ("Legal", 612, 1008),
            ("Tabloid", 792, 1224),
        ]
        let short = min(width, height)
        let long = max(width, height)
        let paper = papers.first { abs($0.1 - short) <= 2 && abs($0.2 - long) <= 2 }?.0
        let size: String
        if locale.measurementSystem == .us {
            func inches(_ points: Double) -> String {
                let value = points / 72
                return JSString.toFixed(value, (value * 10).rounded() == value * 10 && value.rounded() == value ? 0 : 1)
            }
            size = "\(inches(width)) × \(inches(height)) in"
        } else {
            size = "\(Int((width / 72 * 25.4).rounded())) × \(Int((height / 72 * 25.4).rounded())) mm"
        }
        return paper.map { "\($0) · \(size)" } ?? size
    }

    /// What one of the three groups of the mode lets do: "Read & Write", "Read only", "Write only", "No Access".
    public static func privilege(_ mode: Int, shift: Int) -> String {
        let read = mode >> (shift + 2) & 1 == 1
        let write = mode >> (shift + 1) & 1 == 1
        return read && write ? "Read & Write" : read ? "Read only" : write ? "Write only" : "No Access"
    }

    /// The same in letters: "rw", "r", "w", "none".
    public static func privilegeLetters(_ mode: Int, shift: Int) -> String {
        let read = mode >> (shift + 2) & 1 == 1
        let write = mode >> (shift + 1) & 1 == 1
        return read && write ? "rw" : read ? "r" : write ? "w" : "none"
    }

    /// Who the owner or the group is and what it may do, in full: "demo (you) · Read & Write"; what it may do alone
    /// until the name is read.
    public static func access(_ name: String?, isYou: Bool, _ access: String) -> String {
        guard let name else { return access }
        return "\(name)\(isYou ? " (you)" : "") · \(access)"
    }

    /// The same on one line of the room `fits` says there is: in words, else in letters, else in letters with the
    /// name cut short at its end ("dem… (you) · rw"), to its first letter at the least.
    public static func access(
        _ name: String?, isYou: Bool, words: String, letters: String, fits: (String) -> Bool
    ) -> String {
        let full = access(name, isYou: isYou, words)
        if fits(full) { return full }
        let short = access(name, isYou: isYou, letters)
        guard let name, name.count > 1, !fits(short) else { return short }
        let tail = "\u{2026}\(isYou ? " (you)" : "") · \(letters)"
        let characters = Array(name)
        var low = 1
        var high = max(1, characters.count - 1)
        while low < high {
            let middle = (low + high + 1) / 2
            if fits(String(characters[..<middle]) + tail) { low = middle } else { high = middle - 1 }
        }
        return String(characters[..<low]) + tail
    }

    /// The kinds of several items, the most first: "HEIF Image (9), QuickTime movie (2), Folder", and what stands for
    /// it where it doesn't fit on one line: "3 kinds".
    public static func kinds(_ labels: [String]) -> (full: String, short: String) {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for label in labels {
            if counts[label] == nil { order.append(label) }
            counts[label, default: 0] += 1
        }
        let sorted = order.enumerated().sorted { a, b in
            let (ca, cb) = (counts[a.element] ?? 0, counts[b.element] ?? 0)
            return ca != cb ? ca > cb : a.offset < b.offset
        }.map(\.element)
        let full = sorted.map { counts[$0] == 1 ? $0 : "\($0) (\(FormatLocale.count(counts[$0] ?? 0)))" }
            .joined(separator: ", ")
        let short = order.count == 1 ? full : "\(FormatLocale.count(order.count)) kinds"
        return (full, short)
    }
}
