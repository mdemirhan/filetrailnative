// Port of apps/desktop/src/renderer/lib/places.ts (with getFavoriteLabel and getTrashPath from lib/favorites.ts)
import Foundation

public struct Place: Codable, Equatable, Sendable {
    public var path: String
    public var name: String
    /// The path as shown, with the home folder as "~"; also what a typed word is looked for in.
    public var displayPath: String
    public var isFavorite: Bool
    /// Whether the folder has been opened; favorites that never were can not be forgotten.
    public var isVisited: Bool
    /// How much the folder is in use (see `VisitedFolders.score`); 0 for a favorite never opened.
    public var score: Double

    public init(path: String, name: String, displayPath: String, isFavorite: Bool, isVisited: Bool, score: Double) {
        self.path = path
        self.name = name
        self.displayPath = displayPath
        self.isFavorite = isFavorite
        self.isVisited = isVisited
        self.score = score
    }
}

public struct PlaceMatch: Equatable, Sendable {
    public var place: Place
    /// UTF-16 ranges of the name to highlight, as [start, end) pairs (what `NSRange` counts in).
    public var nameRanges: [Range<Int>]
}

/// The names the sidebar gives places (lib/favorites.ts).
public enum FavoriteLabel {
    public static func trashPath(homePath: String) -> String {
        homePath.isEmpty ? "" : "\(homePath)/.Trash"
    }

    /// Home, Applications, Trash, Macintosh HD, or the folder's own name.
    public static func label(for path: String, homePath: String) -> String {
        if JSString.equals(path, homePath) { return "Home" }
        if JSString.equals(path, "/Applications") { return "Applications" }
        if JSString.equals(path, trashPath(homePath: homePath)) { return "Trash" }
        if JSString.equals(path, "/") { return "Macintosh HD" }
        return PathText.leafName(path)
    }
}

/// The Go To box (⌘K) finds a folder from a few letters of its name. Candidates are the folders that
/// have been opened plus the favorites; they are ranked by how well the text matches first, and by
/// how much the folder is used second.
public enum Places {
    // How a piece of the typed text was found, best first.
    private static let matchPrefix = 5
    private static let matchWordStart = 4
    private static let matchSubstring = 3
    private static let matchScattered = 2
    private static let matchPathOnly = 1

    public static let maxResults = 50

    /// Every opened folder and every favorite, once each, without the folder on screen.
    public static func build(
        visitedFolders: [VisitedFolder], favoritePaths: [String], currentPath: String, homePath: String, now: Double
    ) -> [Place] {
        let favorites = Set(favoritePaths.map(ExactKey.init))
        // Insertion order is kept, as a Map keeps it; setting a path again replaces its value in place.
        var order: [ExactKey] = []
        var places: [ExactKey: Place] = [:]
        func set(_ key: ExactKey, _ place: Place) {
            if places.updateValue(place, forKey: key) == nil {
                order.append(key)
            }
        }
        for folder in visitedFolders {
            set(
                ExactKey(folder.path),
                Place(
                    path: folder.path,
                    // Named as the sidebar names them: Home, Trash, Macintosh HD.
                    name: FavoriteLabel.label(for: folder.path, homePath: homePath),
                    displayPath: abbreviate(folder.path, homePath: homePath),
                    isFavorite: favorites.contains(ExactKey(folder.path)),
                    isVisited: true,
                    score: VisitedFolders.score(folder, now: now)))
        }
        for path in favoritePaths where places[ExactKey(path)] == nil {
            set(
                ExactKey(path),
                Place(
                    path: path,
                    name: FavoriteLabel.label(for: path, homePath: homePath),
                    displayPath: abbreviate(path, homePath: homePath),
                    isFavorite: true,
                    isVisited: false,
                    score: 0))
        }
        let current = ExactKey(currentPath)
        return order.filter { $0 != current }.compactMap { places[$0] }
    }

    /// Text that is a path rather than a name: the box completes it folder by folder instead.
    public static func isPathQuery(_ query: String) -> Bool {
        let trimmed = JSString.trimmedStart(query)
        return JSString.hasPrefix(trimmed, "/") || JSString.hasPrefix(trimmed, "~")
    }

    /// The places matching `query`, best first. Each word typed must be found, in the name or failing
    /// that in the path. With nothing typed, the most used places are listed.
    public static func rank(_ places: [Place], query: String) -> [PlaceMatch] {
        let words = JSString.words(JSString.lowercased(query))
        var ranked: [(place: Place, nameRanges: [Range<Int>], quality: Int)] = []
        for place in places {
            if words.isEmpty {
                ranked.append((place, [], 0))
                continue
            }
            let name = Array(JSString.lowercased(place.name).utf16)
            // The shortened path, so the name of the home folder does not match every folder in it.
            let path = Array(JSString.lowercased(place.displayPath).utf16)
            var quality = Int.max
            var nameRanges: [Range<Int>] = []
            for word in words {
                let wordUnits = Array(word.utf16)
                if let inName = matchWord(name, word: wordUnits, scalars: word) {
                    quality = min(quality, inName.quality)
                    nameRanges.append(contentsOf: inName.ranges)
                    continue
                }
                if JSString.index(of: wordUnits, in: path) != nil {
                    quality = min(quality, matchPathOnly)
                    continue
                }
                quality = 0
                break
            }
            if quality > 0 {
                ranked.append((place, mergeRanges(nameRanges), quality))
            }
        }
        // A stable sort, so equals keep their order: most recently opened first, then the favorites
        // as the sidebar lists them.
        let sorted = ranked.enumerated().sorted { left, right in
            let (a, b) = (left.element, right.element)
            if a.quality != b.quality { return a.quality > b.quality }
            if a.place.score != b.place.score { return a.place.score > b.place.score }
            if a.place.isFavorite != b.place.isFavorite { return a.place.isFavorite }
            return left.offset < right.offset
        }
        return sorted.prefix(maxResults).map { PlaceMatch(place: $0.element.place, nameRanges: $0.element.nameRanges) }
    }

    // Finds `word` in `name`: at the start, at the start of a later word, anywhere, or as letters in
    // order with other letters between them ("dwn" finds "Downloads").
    private static func matchWord(_ name: [UInt16], word: [UInt16], scalars: String) -> (
        quality: Int, ranges: [Range<Int>]
    )? {
        if let index = JSString.index(of: word, in: name) {
            if index == 0 {
                return (matchPrefix, [0..<word.count])
            }
            if let wordStart = findWordStart(name, word: word) {
                return (matchWordStart, [wordStart..<wordStart + word.count])
            }
            return (matchSubstring, [index..<index + word.count])
        }
        var ranges: [Range<Int>] = []
        var position = 0
        for character in scalars.unicodeScalars {
            let units = Array(String(character).utf16)
            guard let found = JSString.index(of: units, in: name, from: position) else { return nil }
            ranges.append(found..<found + units.count)
            position = found + units.count
        }
        // Scattered letters only count when the first one starts the name; otherwise almost anything
        // would match a short query.
        return ranges.first?.lowerBound == 0 ? (matchScattered, ranges) : nil
    }

    private static func findWordStart(_ name: [UInt16], word: [UInt16]) -> Int? {
        var index = JSString.index(of: word, in: name)
        while let current = index {
            if current == 0 || isWordBoundary(name[current - 1]) {
                return current
            }
            index = JSString.index(of: word, in: name, from: current + 1)
        }
        return nil
    }

    // /[\s\-_.()[\]]/u
    private static func isWordBoundary(_ unit: UInt16) -> Bool {
        JSString.isWhitespace(unit) || [0x2D, 0x5F, 0x2E, 0x28, 0x29, 0x5B, 0x5D].contains(unit)
    }

    private static func mergeRanges(_ ranges: [Range<Int>]) -> [Range<Int>] {
        // A stable sort by start.
        let sorted = ranges.enumerated()
            .sorted {
                $0.element.lowerBound != $1.element.lowerBound
                    ? $0.element.lowerBound < $1.element.lowerBound : $0.offset < $1.offset
            }
            .map(\.element)
        var merged: [Range<Int>] = []
        for range in sorted {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    /// Where a place is, as its row says it beside the name: the folder it is in, since the name
    /// already says the rest ("~/Projects" for Lighthouse). A place named otherwise than its folder
    /// (Home, Macintosh HD) shows its own path.
    public static func describeLocation(name: String, displayPath: String) -> String {
        let units = Array(displayPath.utf16)
        guard let lastSlash = units.lastIndex(of: 0x2F),
            JSString.equals(JSString.string(units[(lastSlash + 1)...]), name)
        else {
            return displayPath
        }
        return lastSlash == 0 ? "/" : JSString.string(units[..<lastSlash])
    }

    /// The path as shown next to a name: the home folder as "~", like Terminal.
    public static func abbreviate(_ path: String, homePath: String) -> String {
        if homePath.utf16.count > 1, JSString.equals(path, homePath) || JSString.hasPrefix(path, "\(homePath)/") {
            return "~" + JSString.string(Array(path.utf16)[homePath.utf16.count...])
        }
        return path
    }
}
