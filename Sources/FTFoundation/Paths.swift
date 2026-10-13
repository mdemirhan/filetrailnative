// Port of packages/contracts/src/paths.ts and packages/contracts/src/trash.ts
import Foundation

/// Path rules shared by every operation. Paths are compared by their exact Unicode scalars, as the
/// original compares JavaScript strings; Swift's `==` on `String` would treat NFC and NFD as equal.
public enum Paths {
    /// The paths picked, without any that sit inside another one picked (or repeat one): a folder and
    /// an item inside it picked together (Select All in search results) are acted on as the folder,
    /// which takes the item with it.
    public static func withoutNestedPaths(_ paths: [String]) -> [String] {
        let picked = Set(paths.map { Array($0.utf8) })
        var seen = Set<[UInt8]>()
        var kept: [String] = []
        for path in paths {
            let bytes = Array(path.utf8)
            if seen.contains(bytes) || hasPickedAncestor(bytes, picked) {
                continue
            }
            seen.insert(bytes)
            kept.append(path)
        }
        return kept
    }

    private static let slash = UInt8(ascii: "/")

    private static func hasPickedAncestor(_ path: [UInt8], _ picked: Set<[UInt8]>) -> Bool {
        var end = path.lastIndex(of: slash)
        while let current = end, current > 0 {
            if picked.contains(Array(path[..<current])) {
                return true
            }
            end = path[..<current].lastIndex(of: slash)
        }
        return path != [slash] && path.first == slash && picked.contains([slash])
    }

    /// Where the Trash is: the home folder's ".Trash", and on every other disk its ".Trashes" folder
    /// (which holds one Trash per user). Nothing is pasted, dropped or made there, and only what is in
    /// it may be deleted for good. The disks ignore letter case by default, so case is ignored here too.
    public static func isInsideTrash(_ path: String, homePath: String) -> Bool {
        let key = comparable(path)
        let home = trimmingAllTrailingSlashes(comparable(homePath))
        if !home.isEmpty {
            let trash = home + scalars("/.trash")
            if key == trash || key.starts(with: trash + scalars("/")) {
                return true
            }
        }
        // /^\/volumes\/[^/]+\/\.trashes(?:\/|$)/u
        guard let rest = afterVolumeTrashes(key) else { return false }
        return rest.isEmpty || rest.first == "/"
    }

    /// A Trash folder itself, not something in it: the home folder's ".Trash", and on another disk its
    /// ".Trashes" and each user's Trash in that. It is never deleted, renamed, moved or put in the
    /// Trash; only what is in it may be deleted for good.
    public static func isTrashFolder(_ path: String, homePath: String) -> Bool {
        let key = trimmingTrailingSlashesAfterCharacter(comparable(path))
        let home = trimmingAllTrailingSlashes(comparable(homePath))
        if !home.isEmpty && key == home + scalars("/.trash") {
            return true
        }
        // /^\/volumes\/[^/]+\/\.trashes(?:\/[^/]+)?$/u
        guard let rest = afterVolumeTrashes(key) else { return false }
        if rest.isEmpty {
            return true
        }
        return rest.first == "/" && rest.count > 1 && !rest.dropFirst().contains("/")
    }

    private typealias Scalars = [Unicode.Scalar]

    private static func scalars(_ text: String) -> Scalars {
        Array(text.unicodeScalars)
    }

    /// NFD, then lowercased as JavaScript's `toLowerCase` does (with the final-sigma rule, which
    /// Swift's own `lowercased()` leaves out).
    private static func comparable(_ path: String) -> Scalars {
        scalars(path.decomposedStringWithCanonicalMapping.lowercased(with: nil))
    }

    /// `.replace(/\/+$/u, "")`
    private static func trimmingAllTrailingSlashes(_ text: Scalars) -> Scalars {
        var end = text.count
        while end > 0 && text[end - 1] == "/" {
            end -= 1
        }
        return Array(text[..<end])
    }

    /// `.replace(/(.)\/+$/u, "$1")`: the leftmost match wins, and `.` matches no line terminator, so
    /// a run of slashes after one keeps a slash, and a path of slashes alone becomes "/".
    private static func trimmingTrailingSlashesAfterCharacter(_ text: Scalars) -> Scalars {
        let trimmed = trimmingAllTrailingSlashes(text)
        guard trimmed.count < text.count else { return text }
        guard let last = trimmed.last else { return ["/"] }
        let isLineTerminator = ["\n", "\r", "\u{2028}", "\u{2029}"].contains(last)
        return isLineTerminator ? Array(text[...trimmed.count]) : trimmed
    }

    /// What follows `/volumes/<name>/.trashes` at the start of `key`, or nil when it doesn't start so.
    private static func afterVolumeTrashes(_ key: Scalars) -> ArraySlice<Unicode.Scalar>? {
        let volumes = scalars("/volumes/")
        guard key.starts(with: volumes) else { return nil }
        let afterVolumes = key[volumes.count...]
        guard let nameEnd = afterVolumes.firstIndex(of: "/"), nameEnd > afterVolumes.startIndex else {
            return nil
        }
        let trashes = scalars("/.trashes")
        let afterName = key[nameEnd...]
        guard afterName.starts(with: trashes) else { return nil }
        return afterName.dropFirst(trashes.count)
    }
}
