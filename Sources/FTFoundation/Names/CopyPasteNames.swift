// Port of packages/core/src/fs/copyPasteNames.ts (the pure naming logic; disk checks are injected)
import Foundation

/// Keep Both and duplicate naming: Finder-style "name copy.ext", "name copy 2.ext", names within the
/// 255 UTF-8 bytes of APFS and HFS+, cut at whole characters.
public enum CopyPasteNames {
    /// The longest name macOS disks take, in UTF-8 bytes.
    public static let maxNameBytes = ItemNames.maxBytes
    /// Guards against an endless search when every candidate looks taken.
    public static let maxDuplicateNameAttempts = 10_000

    private static let multiPartExtensions = [".tar.gz", ".tar.bz2", ".tar.xz", ".tar.zst"]

    /// Folders macOS shows as a single item, as far as their extension tells.
    private static let packageExtensions: Set<String> = [
        ".action", ".app", ".appex", ".band", ".bundle", ".component", ".docset", ".fcpbundle",
        ".fcpxbundle", ".framework", ".imovielibrary", ".kext", ".key", ".logicx", ".mdimporter",
        ".mlmodelc", ".mlpackage", ".mpkg", ".musiclibrary", ".numbers", ".pages", ".photoslibrary",
        ".pkg", ".playground", ".plugin", ".prefpane", ".qlgenerator", ".rtfd", ".saver", ".scriv",
        ".sparsebundle", ".textbundle", ".workflow", ".xcarchive", ".xcodeproj", ".xcworkspace", ".xpc",
    ]

    public struct Options: Sendable {
        /// Folders don't have an extension to keep at the end (packages aside).
        public var isDirectory: Bool
        /// Whether the folder is a package, as macOS says; nil lets the extension tell.
        public var isPackage: Bool?
        /// Whether the destination volume tells "a" and "A" apart.
        public var caseSensitive: Bool

        public init(isDirectory: Bool = false, isPackage: Bool? = nil, caseSensitive: Bool = false) {
            self.isDirectory = isDirectory
            self.isPackage = isPackage
            self.caseSensitive = caseSensitive
        }
    }

    public struct NoFreeName: Error, Equatable, CustomStringConvertible, Sendable {
        public let sourceName: String
        public var description: String { "Couldn't find a free name for \u{201C}\(sourceName)\u{201D}." }
    }

    /// Whether something is at a path: false only when lstat says it is missing (ENOENT). Any other
    /// failure counts as "exists", so a name is never reused by mistake. `FTOperations` supplies the
    /// real one.
    public typealias Exists = (String) -> Bool

    /// The Keep Both path for a source pasted at `destinationPath`. `isPackageFolder` is asked (with the
    /// source path) for a folder when `options.isPackage` is not given.
    public static func resolveKeepBothDestinationPath(
        sourcePath: String, destinationPath: String, options: Options = Options(),
        isPackageFolder: (String) -> Bool? = { _ in nil }, exists: Exists
    ) throws -> String {
        let sourceName = NodePath.basename(sourcePath)
        var resolved = options
        resolved.isPackage =
            options.isPackage
            ?? (options.isDirectory ? isPackage(folderAt: sourcePath, asked: isPackageFolder) : nil)
        return try resolveDuplicateName(
            sourceName: sourceName, in: NodePath.dirname(destinationPath), reserved: nil,
            options: resolved, exists: exists)
    }

    /// "name copy.ext", "name copy 2.ext", … that is free on disk and not already claimed by another item
    /// of the same paste (`reserved`, keyed by `NameKeys.destinationPathKey`).
    public static func resolveDuplicateName(
        sourceName: String, in directory: String, reserved: Set<NameKeys.Exact>? = nil,
        options: Options = Options(), exists: Exists
    ) throws -> String {
        let (fullBaseName, ext) = splitNameExtension(
            sourceName, isDirectory: options.isDirectory, isPackage: options.isPackage)
        var baseName = fullBaseName
        var firstIndex = 1.0
        if let existing = existingCopy(of: fullBaseName) {
            baseName = existing.base
            firstIndex = existing.number + 1
        }
        // Doubles, as in JavaScript: past 2^53 adding one changes nothing, so the loop ends early or
        // repeats a number; `attempts` keeps the repeat finite.
        var index = firstIndex
        var attempts = 0
        while index < firstIndex + Double(maxDuplicateNameAttempts) && attempts < maxDuplicateNameAttempts {
            attempts += 1
            let suffix = index == 1 ? " copy" : " copy \(JSText.integerText(index))"
            let candidate = NodePath.join(directory, fitName(baseName, suffix: suffix, extension: ext))
            index += 1
            if let reserved,
                reserved.contains(NameKeys.exactDestinationKey(candidate, caseSensitive: options.caseSensitive))
            {
                continue
            }
            if !exists(candidate) {
                return candidate
            }
        }
        throw NoFreeName(sourceName: sourceName)
    }

    /// `/^(.+?) copy(?: ([2-9]|[1-9]\d+))?$/u`: "x copy" continues as "x copy 2". The number is a double,
    /// as `Number(…)` makes it.
    static func existingCopy(of name: String) -> (base: String, number: Double)? {
        let scalars = Array(name.unicodeScalars)
        // `.` matches no line terminator.
        func isLineTerminator(_ scalar: Unicode.Scalar) -> Bool {
            scalar == "\n" || scalar == "\r" || scalar == "\u{2028}" || scalar == "\u{2029}"
        }
        guard !scalars.contains(where: isLineTerminator) else { return nil }
        let marker = Array(" copy".unicodeScalars)
        func matches(at start: Int) -> Bool {
            start + marker.count <= scalars.count && Array(scalars[start..<(start + marker.count)]) == marker
        }
        func text(_ range: Range<Int>) -> String {
            var view = String.UnicodeScalarView()
            view.append(contentsOf: scalars[range])
            return String(view)
        }
        // The lazy base is the shortest one (at least a character) that leaves " copy" and an optional
        // number as the whole rest.
        var baseEnd = 1
        while baseEnd + marker.count <= scalars.count {
            if matches(at: baseEnd) {
                let rest = baseEnd + marker.count
                if rest == scalars.count {
                    return (text(0..<baseEnd), 1)
                }
                if scalars[rest] == " ", let number = copyNumber(scalars[(rest + 1)...]) {
                    return (text(0..<baseEnd), number)
                }
            }
            baseEnd += 1
        }
        return nil
    }

    /// `[2-9]|[1-9]\d+` over the whole slice (digits are ASCII), as a number.
    private static func copyNumber(_ digits: ArraySlice<Unicode.Scalar>) -> Double? {
        guard let first = digits.first, first.value >= 0x31, first.value <= 0x39 else { return nil }
        guard digits.allSatisfy({ $0.value >= 0x30 && $0.value <= 0x39 }) else { return nil }
        // A single digit must be 2-9: "x copy 1" is not a copy number.
        if digits.count == 1 && first.value == 0x31 { return nil }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: digits)
        return Double(String(view))
    }

    /// Whether a name has the extension of a package (see `packageExtensions`).
    public static func isPackageName(_ name: String) -> Bool {
        let ext = NodePath.extname(name)
        return ext.utf16.count > 1 && packageExtensions.contains(JSText.lowercased(ext))
    }

    /// Whether a folder is a package: what macOS says when it can be asked, otherwise the extension.
    public static func isPackage(folderAt path: String, asked: (String) -> Bool?) -> Bool {
        asked(path) ?? isPackageName(NodePath.basename(path))
    }

    /// "._name" beside "name": AppleDouble metadata kept for "name" on disks without extended
    /// attributes. `hasSibling` says whether a name is in the same folder (compared as the caller does).
    public static func isAppleDoubleCompanionName(_ name: String, hasSibling: (String) -> Bool) -> Bool {
        let scalars = Array(name.unicodeScalars)
        guard scalars.count > 2, scalars[0] == ".", scalars[1] == "_" else { return false }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars[2...])
        return hasSibling(String(view))
    }

    /// Finder writes ".DS_Store" into a folder just by showing it; it is nobody's item.
    public static func isFolderViewFile(_ name: String) -> Bool {
        name.utf8.elementsEqual(".DS_Store".utf8)
    }

    /// Splits "name.ext" into ("name", ".ext"), keeping multi-part extensions together and leaving
    /// folder names (other than packages) whole.
    public static func splitNameExtension(_ name: String, isDirectory: Bool, isPackage: Bool? = nil) -> (
        String, String
    ) {
        let units = Array(name.utf16)
        if !isDirectory {
            let lower = Array(JSText.lowercased(name).utf16)
            for ext in multiPartExtensions {
                let extUnits = Array(ext.utf16)
                if lower.count >= extUnits.count, lower.suffix(extUnits.count).elementsEqual(extUnits),
                    units.count > extUnits.count
                {
                    return (text(units.dropLast(extUnits.count)), text(units.suffix(extUnits.count)))
                }
            }
        }
        let ext = NodePath.extname(name)
        let extLength = ext.utf16.count
        if extLength <= 1 {
            return (name, "")
        }
        if isDirectory && !(isPackage ?? packageExtensions.contains(JSText.lowercased(ext))) {
            return (name, "")
        }
        return (text(units.dropLast(extLength)), ext)
    }

    private static func text(_ units: some Collection<UInt16>) -> String {
        String(decoding: Array(units), as: UTF16.self)
    }

    /// Adds `suffix` before the extension, shortening the name to fit the volume's limit. Shortening
    /// drops whole characters as people see them (an accented letter or an emoji is never cut in half).
    public static func fitName(_ baseName: String, suffix: String, extension ext: String) -> String {
        var base = baseName
        var extra = ext
        if (suffix + extra).utf8.count >= maxNameBytes {
            // An absurdly long extension: treat the whole name as the base instead.
            base = baseName + ext
            extra = ""
        }
        if (base + suffix + extra).utf8.count <= maxNameBytes {
            return base + suffix + extra
        }
        let budget = maxNameBytes - (suffix + extra).utf8.count
        var kept = ""
        var keptBytes = 0
        for character in base {
            let bytes = character.utf8.count
            if keptBytes + bytes > budget {
                break
            }
            kept.unicodeScalars.append(contentsOf: character.unicodeScalars)
            keptBytes += bytes
        }
        return JSText.trimmingEnd(kept) + suffix + extra
    }

    // MARK: Case sensitivity

    /// What a volume's case sensitivity probe sees of a path.
    public enum Lookup: Equatable, Sendable {
        case missing
        /// Found, with its device and inode.
        case found(dev: UInt64, ino: UInt64)
        /// Any other failure.
        case failed
    }

    /// What `detectCaseSensitivity` asks of the file system.
    public protocol CaseProbingFileSystem {
        /// The volume's own answer for a folder, or nil when it can't say.
        func isCaseSensitive(_ directory: String) -> Bool?
        /// The names in a folder; empty when it can't be read.
        func entries(_ directory: String) -> [String]
        func lookup(_ path: String) -> Lookup
    }

    /// Whether the volume holding `directory` tells names apart by letter case. Asks the volume when the
    /// file system can; otherwise looks up an existing name with its letter case swapped: finding the same
    /// item means case is ignored. Without anything to try, assumes the macOS default (case-insensitive).
    public static func detectCaseSensitivity(_ fileSystem: some CaseProbingFileSystem, in directory: String)
        -> Bool
    {
        if let answer = fileSystem.isCaseSensitive(directory) {
            return answer
        }
        var candidates = fileSystem.entries(directory).map { NodePath.join(directory, $0) }
        if NodePath.dirname(directory) != directory {
            candidates.append(directory)
        }
        for candidate in candidates {
            let name = NodePath.basename(candidate)
            let swapped = swapLetterCase(name)
            if swapped.unicodeScalars.elementsEqual(name.unicodeScalars) {
                continue
            }
            if let answer = probeCaseSensitivity(
                fileSystem, path: candidate, swappedPath: NodePath.join(NodePath.dirname(candidate), swapped))
            {
                return answer
            }
        }
        return false
    }

    /// An inode a JavaScript number holds exactly; FAT and exFAT empty files get ids near 2^64.
    private static func hasFileId(_ ino: UInt64) -> Bool {
        ino <= 9_007_199_254_740_991
    }

    private static func probeCaseSensitivity(
        _ fileSystem: some CaseProbingFileSystem, path: String, swappedPath: String
    ) -> Bool? {
        guard case .found(let dev, let ino) = fileSystem.lookup(path) else { return nil }
        switch fileSystem.lookup(swappedPath) {
        case .found(let swappedDev, let swappedIno):
            if !hasFileId(ino) || !hasFileId(swappedIno) {
                return nil
            }
            // Two different items whose names differ only by case can exist only when case counts.
            return !(swappedIno == ino && swappedDev == dev)
        case .missing:
            return true
        case .failed:
            return nil
        }
    }

    /// Only ASCII letters: their case mapping is one-to-one on every volume ("ß" isn't).
    static func swapLetterCase(_ name: String) -> String {
        var view = String.UnicodeScalarView()
        for scalar in name.unicodeScalars {
            switch scalar.value {
            case 0x41...0x5A: view.append(Unicode.Scalar(scalar.value + 32) ?? scalar)
            case 0x61...0x7A: view.append(Unicode.Scalar(scalar.value - 32) ?? scalar)
            default: view.append(scalar)
            }
        }
        return String(view)
    }
}
