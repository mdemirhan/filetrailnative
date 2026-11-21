// The names a folder and its files are stored under for the accent parity suite, the disk read byte for byte, and the
// facts a run of the scenario gives, told in names that are the same whatever the spelling
import AppKit
import FTFileSystem
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTAppKit

/// How the names with an accent are stored in the folder the scenario works in.
enum AccentFileSpelling: String, Sendable {
    /// No accents at all: "resume.txt".
    case plain
    /// Every other name composed ("é" as one scalar), starting with the first, and the rest decomposed.
    case composedFirst
    /// The same the other way round, so that between the two every name is stored both ways.
    case decomposedFirst
}

/// One folder the scenario runs in: its name as the disk is to keep it, whether it is inside a folder of the same
/// name, and how the files in it are spelled.
struct AccentKind: Sendable, Hashable, CustomTestStringConvertible {
    var label: String
    /// The folder's name, scalar for scalar as `mkdir(2)` is given it.
    var folder: String
    var nested: Bool
    var files: AccentFileSpelling

    var testDescription: String { "\(label), \(nested ? "nested" : "top"), files \(files.rawValue)" }

    /// The folder every other is compared with: no accent anywhere.
    static func plain(nested: Bool) -> AccentKind {
        AccentKind(label: "plain", folder: "cafe", nested: nested, files: .plain)
    }

    /// "café", "한글" and "şüö" (a cedilla and two umlauts, as Turkish and German have them), each as one scalar a
    /// letter and with its accents, or its jamo, apart.
    private static let accented: [(label: String, folder: String)] = [
        ("cafe composed", "caf\u{E9}"),
        ("cafe decomposed", "cafe\u{301}"),
        ("hangul composed", "\u{D55C}\u{AE00}"),
        ("hangul decomposed", "\u{D55C}\u{AE00}".decomposedStringWithCanonicalMapping),
        ("turkish composed", "\u{15F}\u{FC}\u{F6}"),
        ("turkish decomposed", "\u{15F}\u{FC}\u{F6}".decomposedStringWithCanonicalMapping),
    ]

    /// Every folder name, at the top and nested, the files' spelling turning with each so that both spellings of the
    /// files meet both spellings of the folder; then the plain folder with files spelled each way.
    static let compared: [AccentKind] = {
        var kinds: [AccentKind] = []
        for (index, name) in accented.enumerated() {
            for nested in [false, true] {
                let files: AccentFileSpelling = (index + (nested ? 1 : 0)) % 2 == 0 ? .composedFirst : .decomposedFirst
                kinds.append(AccentKind(label: name.label, folder: name.folder, nested: nested, files: files))
            }
        }
        for files in [AccentFileSpelling.composedFirst, .decomposedFirst] {
            kinds.append(AccentKind(label: "plain folder", folder: "cafe", nested: false, files: files))
        }
        return kinds
    }()

    /// The folders stored composed, which a launch that knew its folders by a URL's spelling saved with their accents
    /// apart: all but "café" at the top, which the suites of each kept thing look at.
    static let savedByAnEarlierVersion: [AccentKind] = compared.filter {
        $0.label.hasSuffix(" composed") && ($0.nested || $0.label != "cafe composed")
    }
}

/// What each item of the scenario's folder is there for. A step works on its own items, so one that goes wrong
/// leaves the others' as they were.
enum AccentRole: String, CaseIterable, Sendable {
    case tagged, vanishes, appears, renamed, copied, cut, duplicated, trashed, sheetOne, sheetTwo, zippedOne,
        zippedTwo, dragged, paned, picture, archiveOne, archiveTwo, movedOne, movedTwo, sub, plain

    /// The name without its extension, accents composed.
    private var stem: String {
        switch self {
        case .tagged: "r\u{E9}sum\u{E9}"
        case .vanishes: "na\u{EF}ve"
        case .appears: "cr\u{E8}me"
        case .renamed: "fa\u{E7}ade"
        case .copied: "jalape\u{F1}o"
        case .cut: "\u{FC}ber"
        case .duplicated: "se\u{F1}or"
        case .trashed: "gar\u{E7}on"
        case .sheetOne: "pi\u{F1}ata"
        case .sheetTwo: "fianc\u{E9}e"
        case .zippedOne: "sm\u{F6}rg\u{E5}s"
        case .zippedTwo: "\u{C5}ngstr\u{F6}m"
        case .dragged: "d\u{E9}j\u{E0}"
        case .paned: "entr\u{E9}e"
        case .picture: "clich\u{E9}"
        case .archiveOne: "expos\u{E9}"
        case .archiveTwo: "prot\u{E9}g\u{E9}"
        case .movedOne: "\u{E9}clair"
        case .movedTwo: "p\u{E2}t\u{E9}"
        case .sub: "d\u{E9}p\u{F4}t"
        case .plain: "plain"
        }
    }

    var fileExtension: String {
        switch self {
        case .sub: ""
        case .picture: ".png"
        case .archiveOne, .archiveTwo: ".zip"
        default: ".txt"
        }
    }

    /// Where the item starts: in the scenario's folder, or in the folder inside it.
    var startsInSub: Bool { self == .movedOne || self == .movedTwo }

    /// The stem as it is stored for a spelling of the files.
    func stem(_ files: AccentFileSpelling) -> String {
        let index = Self.allCases.firstIndex(of: self) ?? 0
        switch files {
        case .plain:
            // The accents taken off: decomposed, and the marks dropped.
            return String(
                String.UnicodeScalarView(
                    stem.decomposedStringWithCanonicalMapping.unicodeScalars.filter { $0.isASCII }))
        case .composedFirst:
            return index % 2 == 0 ? stem : stem.decomposedStringWithCanonicalMapping
        case .decomposedFirst:
            return index % 2 == 0 ? stem.decomposedStringWithCanonicalMapping : stem
        }
    }

    func name(_ files: AccentFileSpelling) -> String { stem(files) + fileExtension }

    /// How many bytes the file holds: each its own, so a detail read for one row can't pass for another's.
    var size: Int { 10 + (Self.allCases.firstIndex(of: self) ?? 0) }
}

/// The disk asked directly, byte for byte, beside what the app says of it.
enum AccentDisk {
    /// The names in `folder` as the disk holds them, without "." and "..": what `readdir(3)` gives, each then asked
    /// of the disk by itself, since FAT and exFAT list a name with its accents decomposed whatever it was made by
    /// (`AccentSpellingSourcesTests`).
    static func names(in folder: String) -> [[UInt8]] {
        listedNames(in: folder).map { listed in
            let name = String(decoding: listed, as: UTF8.self)
            return DiskPath.nameOnDisk(folder + "/" + name).map { Array($0.utf8) } ?? listed
        }
    }

    /// The names in `folder` as `readdir(3)` gives them, without "." and "..".
    static func listedNames(in folder: String) -> [[UInt8]] {
        guard let directory = opendir(folder) else { return [] }
        defer { closedir(directory) }
        var names: [[UInt8]] = []
        while let entry = readdir(directory) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                Array(raw.prefix(Int(entry.pointee.d_namlen)))
            }
            if name != Array(".".utf8), name != Array("..".utf8) { names.append(name) }
        }
        return names
    }

    /// Whether `folder` holds an item whose name is `name` byte for byte.
    static func holds(_ name: String, in folder: String) -> Bool {
        names(in: folder).contains(Array(name.utf8))
    }

    /// Whether an item is there under `name`, however the disk spells it.
    static func has(_ name: String, in folder: String) -> Bool {
        var info = stat()
        return lstat(folder + "/" + name, &info) == 0
    }

    /// Whether every part of `path` below `root` is spelled as the folder above it holds it.
    static func spells(_ path: String, below root: String) -> Bool {
        guard path.utf8.starts(with: (root + "/").utf8) else { return path.utf8.elementsEqual(root.utf8) }
        var folder = root
        for part in path.utf8.dropFirst(root.utf8.count + 1).split(separator: UInt8(ascii: "/")) {
            guard names(in: folder).contains(Array(part)) else { return false }
            folder += "/" + String(decoding: part, as: UTF8.self)
        }
        return true
    }

    static func makeFolder(_ path: String) {
        // mkdir(2) keeps the name as given; Foundation would decompose it.
        #expect(mkdir(path, 0o755) == 0, "mkdir \(path)")
    }

    static func write(_ data: Data, to path: String) {
        let file = Darwin.open(path, O_CREAT | O_WRONLY | O_TRUNC, 0o644)
        #expect(file >= 0, "open \(path)")
        guard file >= 0 else { return }
        let written = data.withUnsafeBytes { Darwin.write(file, $0.baseAddress, data.count) }
        #expect(written == data.count)
        close(file)
    }

    /// A zip at `path` holding one file, `inside`. It is made under a plain name and written where it goes, so the
    /// path keeps its bytes whatever `zip` would do with them.
    static func makeZip(at path: String, holding inside: String) throws {
        let scratch = try TemporaryDirectory(prefix: "filetrail-parity-zips")
        defer { scratch.remove() }
        let file = scratch.path + "/" + inside
        try Data(inside.utf8).write(to: URL(fileURLWithPath: file))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-q", "-j", scratch.path + "/made.zip", file]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        write(try Data(contentsOf: URL(fileURLWithPath: scratch.path + "/made.zip")), to: path)
    }

    /// A small picture, as PNG data.
    static func picture() -> Data {
        let side = 64
        guard
            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return Data() }
        for x in 0..<side {
            for y in 0..<side {
                bitmap.setColor(
                    NSColor(deviceRed: CGFloat(x) / 64, green: 0.4, blue: CGFloat(y) / 64, alpha: 1), atX: x, y: y)
            }
        }
        return bitmap.representation(using: .png, properties: [:]) ?? Data()
    }
}

/// The names of one run, and what stands for each in a fact: a path or a text of the app is told with every stored
/// name replaced by what the item is there for, byte for byte, so two runs say the same only when each spelled its
/// names as its own disk has them. A name left in another spelling stays as it is, its scalars written out.
///
/// On a disk whose calls don't agree on how a name is spelled there is no one spelling to hold a path to. There
/// (`anySpelling`) a name is told by what it is there for in whichever spelling it comes, and which spelling it came
/// in is told beside it (`spelled`), so what a step saw can be held against the plain folder's and the spellings read
/// on their own.
struct AccentNames {
    let kind: AccentKind
    /// The folder the run is under, by its real path: the harness's, or a folder of a disk image.
    let root: String
    /// The folder the scenario's folder is in.
    let parent: String
    /// The scenario's folder, as it was made.
    let folder: String
    let anySpelling: Bool
    /// The name a step types into a row: with its accents composed, as a keyboard types them. In the plain folder of
    /// a disk whose calls don't agree on a spelling it has none, so that folder's run meets no accent at all.
    let typed: String
    private let replacements: [(bytes: [UInt8], label: String, spelling: AccentSpelling)]

    /// The names of `kind` under `top`, by the path a listing gives that folder.
    init(kind: AccentKind, under top: String, anySpelling: Bool = false) {
        self.kind = kind
        self.anySpelling = anySpelling
        let root: String = {
            guard let resolved = realpath(top, nil) else { return top }
            defer { free(resolved) }
            return String(cString: resolved)
        }()
        self.root = root
        parent = kind.nested ? root + "/" + kind.folder : root
        folder = parent + "/" + kind.folder
        var replacements: [(bytes: [UInt8], label: String, spelling: AccentSpelling)] = [
            (Array(root.utf8), "<root>", .plain)
        ]
        func add(_ name: String, _ label: String) {
            replacements.append((Array(name.utf8), label, AccentSpelling(of: name)))
            guard anySpelling else { return }
            for other in [name.precomposedStringWithCanonicalMapping, name.decomposedStringWithCanonicalMapping]
            where !other.utf8.elementsEqual(name.utf8) {
                replacements.append((Array(other.utf8), label, AccentSpelling(of: other)))
            }
        }
        add(kind.folder, "<folder>")
        for role in AccentRole.allCases { add(role.stem(kind.files), "<\(role.rawValue)>") }
        // On the harness's own disk the name typed is told as it is, scalar for scalar, in every folder.
        typed = anySpelling && kind.files == .plain ? "ete.txt" : "\u{E9}t\u{E9}.txt"
        if anySpelling { add(String(typed.dropLast(4)), "<typed>") }
        // The longest first, so a name isn't taken for a part of another.
        self.replacements = replacements.sorted { $0.bytes.count > $1.bytes.count }
    }

    var sub: String { folder + "/" + AccentRole.sub.name(kind.files) }

    /// Where the item is when the scenario starts.
    func path(_ role: AccentRole) -> String {
        role == .sub ? sub : (role.startsInSub ? sub : folder) + "/" + role.name(kind.files)
    }

    func name(_ role: AccentRole) -> String { role.name(kind.files) }

    /// `text` with each stored name replaced by its role and any other scalar outside ASCII written out; and, for
    /// each name with an accent found in it, how it was spelled there ("<folder> composed").
    func tell(_ text: String) -> (told: String, spelled: [String]) {
        let bytes = Array(text.utf8)
        var replaced: [UInt8] = []
        replaced.reserveCapacity(bytes.count)
        var spelled: [String] = []
        var index = 0
        while index < bytes.count {
            let rest = bytes[index...]
            if let found = replacements.first(where: { rest.starts(with: $0.bytes) }) {
                replaced += Array(found.label.utf8)
                if found.spelling != .plain { spelled.append(found.label + " " + found.spelling.rawValue) }
                index += found.bytes.count
            } else {
                replaced.append(bytes[index])
                index += 1
            }
        }
        var result = ""
        for scalar in String(decoding: replaced, as: UTF8.self).unicodeScalars {
            if scalar.isASCII {
                result.unicodeScalars.append(scalar)
            } else {
                result += "\\u{" + String(scalar.value, radix: 16, uppercase: true) + "}"
            }
        }
        return (result, spelled)
    }

    func told(_ text: String) -> String { tell(text).told }

    func told(_ text: String?) -> String { text.map { told($0) } ?? "nil" }

    /// Several paths or texts, in the order given.
    func told(_ texts: [String]) -> String { "[" + texts.map { told($0) }.joined(separator: ", ") + "]" }

    /// Several paths whose order isn't the point (a listing's rows, sorted by names that differ from run to run).
    func toldSorted(_ texts: [String]) -> String { "[" + texts.map { told($0) }.sorted().joined(separator: ", ") + "]" }

    /// How the names with an accent in `texts` are spelled there, each once ("<folder> composed, <sub> decomposed").
    func spelled(_ texts: [String]) -> String {
        var seen: [String] = []
        for text in texts {
            for spelling in tell(text).spelled where !seen.contains(spelling) { seen.append(spelling) }
        }
        return seen.sorted().joined(separator: ", ")
    }
}

/// One thing a step of the scenario saw.
struct AccentFact: Equatable, Sendable {
    var step: String
    var name: String
    var value: String
    /// How the names with an accent in what was seen were spelled, where a run tells it; never held against another
    /// run's, as the plain folder has none.
    var spelled = ""

    var key: String { step + ": " + name }
}

/// The plain folder's facts, read once for the top and once nested, and what a kind's facts are held against.
@MainActor
enum AccentParity {
    private static var plain: [Bool: [AccentFact]] = [:]

    static func plainFacts(nested: Bool) async throws -> [AccentFact] {
        if let kept = plain[nested] { return kept }
        let facts = try await AccentScenario.run(.plain(nested: nested))
        plain[nested] = facts
        return facts
    }

    private static var plainOnDisk: [DiskImage.Kind: [AccentFact]] = [:]

    /// The scenario run in a folder of `kind` on a disk image of `disk`: in a folder of its own on the volume the
    /// tests of this process share.
    static func facts(of kind: AccentKind, on disk: DiskImage.Kind) async throws -> [AccentFact] {
        try await DiskImage.withSharedVolume(disk) { volume in
            try await AccentScenario.run(kind, under: volume.path)
        }
    }

    /// The plain folder's facts on a disk image of `disk`, read once.
    static func plainFacts(on disk: DiskImage.Kind) async throws -> [AccentFact] {
        if let kept = plainOnDisk[disk] { return kept }
        let facts = try await facts(of: .plain(nested: false), on: disk)
        plainOnDisk[disk] = facts
        return facts
    }

    /// The plain folder's run did what each step is there to show: no step missed what it waited for.
    static func checkPlain(nested: Bool) async throws {
        let facts = try await plainFacts(nested: nested)
        #expect(facts.count > 100)
        for fact in facts where fact.value == "false" || fact.value == "nil" {
            Issue.record("\(fact.key) is \(fact.value) in the plain folder")
        }
        #expect(Set(facts.map(\.key)).count == facts.count, "each fact has a name of its own")
    }

    /// The scenario run in a folder of `kind`, and each of its facts held against the plain folder's.
    static func check(_ kind: AccentKind) async throws {
        let plain = try await plainFacts(nested: kind.nested)
        let facts = try await AccentScenario.run(kind)
        compare(facts, of: kind, with: plain)
    }

    /// Each fact of `kind` against the plain folder's, by its step and name, so a difference names its step.
    static func compare(_ facts: [AccentFact], of kind: AccentKind, with plain: [AccentFact]) {
        let own = Dictionary(facts.map { ($0.key, $0.value) }) { first, _ in first }
        for fact in plain {
            #expect(own[fact.key] == fact.value, "\(kind.testDescription): \(fact.key)")
        }
        #expect(facts.map(\.key) == plain.map(\.key), "\(kind.testDescription): the same steps ran")
    }
}
