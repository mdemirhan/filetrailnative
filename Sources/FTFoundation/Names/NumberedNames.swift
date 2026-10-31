// Port of addNumberToName and splitItemName (apps/desktop/src/shared/batchRename.ts) and nextFreeFolderPath (apps/desktop/src/main/bootstrap/writeOperations.ts)
import Foundation

/// "name 2.ext" numbering: Undo of Keep Both and batch rename ("Lisbon 2.jpg"), and New Folder ("untitled folder 2").
public enum NumberedNames {
    public struct Split: Equatable, Sendable {
        public let stem: String
        /// The part after the last dot, or nil.
        public let `extension`: String?
    }

    public struct Numbered: Equatable, Sendable {
        public let name: String
        /// Lengths in UTF-16 units, as the original counts them: the stem kept, and the stem before cutting.
        public let keptStemLength: Int
        public let stemLength: Int
    }

    /// A name split into what Rename treats as the name and as the extension: the part after the last
    /// dot. A folder has none, and neither has a name whose only dot starts it (".env").
    public static func splitItemName(_ name: String, isFolder: Bool) -> Split {
        let units = Array(name.utf16)
        guard let dot = units.lastIndex(of: 0x2E), !isFolder, dot > 0, dot != units.count - 1 else {
            return Split(stem: name, extension: nil)
        }
        return Split(
            stem: String(decoding: units[..<dot], as: UTF16.self),
            extension: String(decoding: units[(dot + 1)...], as: UTF16.self))
    }

    /// The name with a number added before its extension: "Lisbon 2.jpg", or "Lisbon 2" for a folder.
    /// When that would make the name too long for the disk, the name before the extension gives up
    /// characters at its end, as Finder's numbered names do.
    public static func addNumberToName(_ name: String, isFolder: Bool, separator: String, number: Int)
        -> Numbered
    {
        let split = splitItemName(name, isFolder: isFolder)
        let tail = "\(separator)\(number)" + (split.extension.map { ".\($0)" } ?? "")
        let room = ItemNames.maxBytes - tail.utf8.count
        var kept = split.stem
        if split.stem.utf8.count > room {
            // Whole characters only: an accent is never cut from its letter.
            kept = ""
            for character in split.stem {
                if kept.utf8.count + character.utf8.count > room {
                    break
                }
                kept.unicodeScalars.append(contentsOf: character.unicodeScalars)
            }
            kept = JSText.trimmingEnd(kept)
            // Nothing would be left: the name stays too long, and is reported as such.
            if kept.isEmpty {
                kept = split.stem
            }
        }
        return Numbered(
            name: kept + tail, keptStemLength: kept.utf16.count, stemLength: split.stem.utf16.count)
    }

    public struct NameTaken: Error, Equatable, CustomStringConvertible, Sendable {
        public let name: String
        public var description: String { "An item named \u{201C}\(name)\u{201D} already exists." }
    }

    /// New Folder with the name taken: "untitled folder" becomes "untitled folder 2", "untitled folder 3"…
    /// (from "untitled folder 3", the next), up to 10,000 tries. `exists` says whether lstat finds
    /// anything at a path; unlike the Keep Both check, any failure counts as "not there".
    public static func nextFreeFolderPath(
        in parentDirectory: String, name: String, exists: (String) -> Bool
    ) throws -> String {
        var base = name
        var first = 2.0
        if let (stem, digits) = trailingNumber(of: name) {
            base = stem
            first = (Double(digits) ?? 0) + 1
        }
        var number = first
        while number < first + 10_000 {
            let candidate = NodePath.join(parentDirectory, "\(base) \(JSText.integerText(number))")
            if !exists(candidate) {
                return candidate
            }
            number += 1
        }
        throw NameTaken(name: name)
    }

    /// `/^(.*?) (\d+)$/u`: the shortest base that leaves a space and ASCII digits as the rest.
    static func trailingNumber(of name: String) -> (base: String, digits: String)? {
        let scalars = Array(name.unicodeScalars)
        let terminators: Set<Unicode.Scalar> = ["\n", "\r", "\u{2028}", "\u{2029}"]
        guard !scalars.contains(where: { terminators.contains($0) }) else { return nil }
        func isDigit(_ scalar: Unicode.Scalar) -> Bool { scalar.value >= 0x30 && scalar.value <= 0x39 }
        var baseEnd = 0
        while baseEnd < scalars.count {
            if scalars[baseEnd] == " " {
                let rest = scalars[(baseEnd + 1)...]
                if !rest.isEmpty && rest.allSatisfy(isDigit) {
                    var base = String.UnicodeScalarView()
                    base.append(contentsOf: scalars[..<baseEnd])
                    var digits = String.UnicodeScalarView()
                    digits.append(contentsOf: rest)
                    return (String(base), String(digits))
                }
            }
            baseEnd += 1
        }
        return nil
    }
}
