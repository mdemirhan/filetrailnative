import CFileTrail
import Darwin
import FTFoundation
import Foundation

/// An archive's own trouble, as a sentence naming it.
public struct ArchiveError: CodedError, Equatable, Sendable {
    public enum Reason: Equatable, Sendable {
        case unreadable, needsPassword, empty, notQuarantined
    }

    public var reason: Reason
    public var message: String
    public var code: ErrorCode? { nil }

    init(_ reason: Reason, archivePath: String) {
        self.reason = reason
        let name = NodePath.basename(archivePath)
        message =
            switch reason {
            case .unreadable:
                "\u{201C}\(name)\u{201D} can\u{2019}t be read. It may be damaged, or of a kind File Trail doesn\u{2019}t take apart."
            case .needsPassword:
                "\u{201C}\(name)\u{201D} is protected with a password. File Trail can\u{2019}t open protected archives yet; Archive Utility can."
            case .empty:
                "\u{201C}\(name)\u{201D} holds nothing to extract."
            // Mostly a folder or a disk that refuses the mark on what is put in it: another folder may take it.
            case .notQuarantined:
                "\u{201C}\(name)\u{201D} wasn\u{2019}t extracted. Its items couldn\u{2019}t be marked as downloaded from the internet, as the archive is, so macOS couldn\u{2019}t check them before they open. Try extracting it into another folder, such as one on your Mac\u{2019}s own disk."
            }
    }
}

/// libarchive's work, as `archive.c` does it, on the calling thread (never the main thread).
enum NativeArchive {
    /// One archive's stop flag and progress, read from any thread while the work runs on another.
    final class Control: @unchecked Sendable {
        // Only read and set through the C functions, which are atomic.
        private let pointer: OpaquePointer

        init() {
            guard let made = ft_archive_control_create() else { fatalError("out of memory") }
            pointer = made
            ft_archive_control_detect_names_with(pointer) { names, length, charset, room in
                guard let names, let charset, length > 0 else { return 0 }
                let name = ArchiveNameEncoding.charset(forNames: Data(bytes: names, count: length))
                return strlcpy(charset, name, room) < room ? 1 : 0
            }
        }

        deinit { ft_archive_control_free(pointer) }

        func stop() { ft_archive_control_stop(pointer) }
        /// For tests: the destination is taken for a disk that keeps no extended attributes.
        func takeDiskAsKeepingNoAttributes() { ft_archive_control_take_disk_as_keeping_no_attributes(pointer) }
        /// Bytes done: of the archive read, when extracting; of the items' data read, when compressing.
        var done: Int64 { ft_archive_control_done(pointer) }
        var total: Int64 { ft_archive_control_total(pointer) }
        var skipped: Int64 { ft_archive_control_skipped(pointer) }
        /// How many times the encoding of a zip's names was asked for: once for a zip with names that aren't UTF-8,
        /// never for any other archive.
        var nameEncodingsAsked: Int64 { ft_archive_control_names_asked(pointer) }

        fileprivate var raw: OpaquePointer { pointer }
    }

    /// Takes `archivePath` apart into `folder`, empty and existing. `rawName`: the name a single compressed file is
    /// written as. Throws `StopError` when stopped, `ArchiveError` for the archive's own trouble, and the disk's
    /// errors as `NativeError`.
    static func extract(
        _ archivePath: String, into folder: String, rawName: String?, quarantine: Bool, control: Control
    ) throws {
        let code = ft_archive_extract(archivePath, folder, rawName, quarantine ? 1 : 0, control.raw)
        try throwIfFailed(code, path: archivePath, syscall: "extract")
    }

    /// Makes the zip `zipPath` (which must not exist) of the items `names` of `folder`, as Finder's Compress does.
    /// A zip left partly written by a failure or a stop is the caller's to remove.
    static func compressZip(_ names: [String], in folder: String, to zipPath: String, control: Control) throws {
        let pointers = names.map { strdup($0) }
        defer {
            for pointer in pointers { free(pointer) }
        }
        let code = pointers.map { UnsafePointer($0) }.withUnsafeBufferPointer { buffer in
            ft_archive_compress_zip(folder, buffer.baseAddress, buffer.count, zipPath, control.raw)
        }
        // The item it failed on is the one to name, not the zip that was being made.
        let failed = ft_archive_control_failed_path(control.raw).map { String(cString: $0) }
        try throwIfFailed(code, path: failed ?? zipPath, syscall: "compress")
    }

    private static func throwIfFailed(_ code: Int32, path: String, syscall: String) throws {
        switch code {
        case 0: return
        case ECANCELED: throw StopError()
        case Int32(FT_ARCHIVE_UNREADABLE): throw ArchiveError(.unreadable, archivePath: path)
        case Int32(FT_ARCHIVE_NEEDS_PASSWORD): throw ArchiveError(.needsPassword, archivePath: path)
        case Int32(FT_ARCHIVE_EMPTY): throw ArchiveError(.empty, archivePath: path)
        case Int32(FT_ARCHIVE_NOT_QUARANTINED): throw ArchiveError(.notQuarantined, archivePath: path)
        default: throw NativeError.errno(code, syscall: syscall, path: path)
        }
    }
}

/// The encoding a zip's names are in when they aren't UTF-8 and the zip doesn't say: zips made on Windows and by
/// older tools write names in the system's own encoding of the place they were made.
enum ArchiveNameEncoding {
    /// An encoding names are tried in, and the name iconv (and so libarchive's `hdrcharset`) knows it by.
    struct Candidate: Equatable {
        let charset: String
        let encoding: UInt
        /// The start of the languages (`Locale.preferredLanguages`) whose zips are most likely in it.
        let languages: [String]

        init(_ charset: String, _ encoding: CFStringEncodings, languages: [String]) {
            self.charset = charset
            self.encoding = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(encoding.rawValue))
            self.languages = languages
        }

        init(_ charset: String, _ encoding: String.Encoding) {
            self.charset = charset
            self.encoding = encoding.rawValue
            languages = []
        }
    }

    /// Japanese, Simplified Chinese, Traditional Chinese, Korean, in the order tried when no language says otherwise.
    static let eastAsian = [
        Candidate("CP932", .dosJapanese, languages: ["ja"]),
        Candidate("GB18030", .GB_18030_2000, languages: ["zh-Hans", "zh-CN", "zh-SG"]),
        Candidate("BIG5", .big5, languages: ["zh-Hant", "zh-TW", "zh-HK", "zh-MO"]),
        Candidate("CP949", .dosKorean, languages: ["ko"]),
    ]
    static let western = Candidate("CP1252", .windowsCP1252)
    /// What the zip format itself says names are in when nothing marks them: the encoding of MS-DOS. Every byte is a
    /// character in it, so it always fits.
    static let fallback = "CP437"

    /// The encodings tried, those of the user's languages first, in the languages' order; Windows-1252 last.
    static func candidates(preferredLanguages: [String]) -> [Candidate] {
        var first: [Candidate] = []
        for language in preferredLanguages {
            for candidate in eastAsian where !first.contains(candidate) {
                if candidate.languages.contains(where: { language == $0 || language.hasPrefix($0 + "-") }) {
                    first.append(candidate)
                }
            }
        }
        return first + eastAsian.filter { !first.contains($0) } + [western]
    }

    /// The encoding `names` (the names that aren't UTF-8, a line each) are most likely in, as iconv names it:
    /// Foundation's guess among the candidates, and CP437 when none of them reads the names whole.
    static func charset(forNames names: Data, preferredLanguages: [String] = Locale.preferredLanguages) -> String {
        let candidates = candidates(preferredLanguages: preferredLanguages)
        var converted: NSString?
        var lossy: ObjCBool = false
        let found = NSString.stringEncoding(
            for: names,
            encodingOptions: [
                .suggestedEncodingsKey: candidates.map { NSNumber(value: $0.encoding) },
                .useOnlySuggestedEncodingsKey: true, .allowLossyKey: false,
            ], convertedString: &converted, usedLossyConversion: &lossy)
        guard converted != nil, !lossy.boolValue, let candidate = candidates.first(where: { $0.encoding == found })
        else { return fallback }
        return candidate.charset
    }
}
