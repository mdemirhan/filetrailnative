// Port of apps/desktop/src/shared/visitedFolders.ts
import Foundation

/// How a folder was come to, which says how much the visit counts:
/// - `goTo`: picked in the Go To box, the plainest sign it was wanted.
/// - `stay`: opened some other way and stayed in, or something was done there.
/// - `passThrough`: opened and left again at once, on the way somewhere else. It is not kept as a
///   visit; it only makes the folder known, so its name can be found.
public enum FolderVisitKind: String, Codable, Sendable {
    case goTo
    case stay
    case passThrough
}

public struct FolderVisit: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case goTo
        case stay
    }

    /// Milliseconds since the epoch.
    public var at: Double
    public var kind: Kind

    public init(at: Double, kind: Kind) {
        self.at = at
        self.kind = kind
    }
}

public struct VisitedFolder: Codable, Equatable, Sendable {
    public var path: String
    /// Newest first, at most `maxVisitsPerFolder`; empty for a folder only passed through.
    public var visits: [FolderVisit]

    public init(path: String, visits: [FolderVisit]) {
        self.path = path
        self.visits = visits
    }
}

/// The folders that have been opened, each with its latest visits. The Go To box (⌘K) ranks them so
/// the folders in use now come first. Only folders are remembered, never files.
public enum VisitedFolders {
    /// Enough for years of ordinary use; past it the least used folders are forgotten.
    public static let maxFolders = 500
    /// As Firefox does for its history: the latest visits say how much a folder is used now, and
    /// older ones fall away instead of adding up forever.
    public static let maxVisitsPerFolder = 10

    private static let day = 24.0 * 60 * 60 * 1000

    private static func weight(of kind: FolderVisit.Kind) -> Double {
        switch kind {
        case .goTo: 3
        case .stay: 1
        }
    }

    // How much a visit still counts by its age, in Firefox's steps: in full for four days, a tenth
    // after three months.
    private static func recencyWeight(age: Double) -> Double {
        if age <= 4 * day { return 1 }
        if age <= 14 * day { return 0.7 }
        if age <= 31 * day { return 0.5 }
        return age <= 90 * day ? 0.3 : 0.1
    }

    /// How much a folder is in use right now: each of its latest visits, by how it was made and how
    /// long ago. A folder opened daily this week outranks one opened often last spring.
    public static func score(_ folder: VisitedFolder, now: Double) -> Double {
        var score = 0.0
        for visit in folder.visits {
            score += weight(of: visit.kind) * recencyWeight(age: max(0, now - visit.at))
        }
        return score
    }

    /// Adds a visit to `path`, which moves to the front. A pass through only adds a folder not known
    /// yet, and returns `folders` as it is when there is nothing to add. Over the limit, the folders
    /// with the lowest score are dropped (never the one just visited).
    public static func record(_ folders: [VisitedFolder], path: String, kind: FolderVisitKind, now: Double)
        -> [VisitedFolder]
    {
        if path.isEmpty {
            return folders
        }
        let existing = folders.first { JSString.equals($0.path, path) }
        if kind == .passThrough, existing != nil {
            return folders
        }
        var visits: [FolderVisit] = []
        if let visitKind = FolderVisit.Kind(rawValue: kind.rawValue) {
            visits = Array(
                ([FolderVisit(at: now, kind: visitKind)] + (existing?.visits ?? [])).prefix(maxVisitsPerFolder))
        }
        let visited = VisitedFolder(path: path, visits: visits)
        let others = folders.filter { !JSString.equals($0.path, path) }
        if others.count + 1 <= maxFolders {
            return [visited] + others
        }
        // A stable sort, highest score first: equals keep their order.
        var scored: [(index: Int, folder: VisitedFolder, score: Double)] = []
        for (index, folder) in others.enumerated() {
            scored.append((index, folder, score(folder, now: now)))
        }
        scored.sort { left, right in
            left.score != right.score ? left.score > right.score : left.index < right.index
        }
        return [visited] + scored.prefix(maxFolders - 1).map(\.folder)
    }

    public static func forget(_ folders: [VisitedFolder], path: String) -> [VisitedFolder] {
        folders.filter { !JSString.equals($0.path, path) }
    }

    /// On disk each visit is a pair, [time, kind], and each folder takes one line: a full list is a
    /// few hundred kilobytes at most, and still easy to read.
    public static func serialize(_ folders: [VisitedFolder]) -> String {
        let lines = folders.map { folder in
            let visits = folder.visits.map { "[\(jsonNumber($0.at)),\"\($0.kind.rawValue)\"]" }.joined(separator: ",")
            return "{\"path\":\(JSString.jsonQuoted(folder.path)),\"visits\":[\(visits)]}"
        }
        return lines.isEmpty ? "{\"folders\":[]}\n" : "{\"folders\":[\n\(lines.joined(separator: ",\n"))\n]}\n"
    }

    // A JSON number as JavaScript writes it: whole numbers without a fraction.
    private static func jsonNumber(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 {
            return String(Int64(value))
        }
        return "\(value)"
    }

    /// Saved visits are read leniently: anything that is not a visit record is skipped. `value` is
    /// the parsed `folders` array (from `JSONSerialization`).
    public static func sanitize(_ value: Any?) -> [VisitedFolder] {
        guard let items = value as? [Any] else { return [] }
        var seen = Set<ExactKey>()
        var folders: [VisitedFolder] = []
        for item in items {
            guard let record = item as? [String: Any],
                let path = record["path"] as? String,
                JSString.hasPrefix(path, "/"),
                !seen.contains(ExactKey(path)),
                let rawVisits = record["visits"] as? [Any]
            else { continue }
            seen.insert(ExactKey(path))
            folders.append(VisitedFolder(path: path, visits: sanitizeVisits(rawVisits)))
            if folders.count == maxFolders {
                break
            }
        }
        return folders
    }

    /// Reads the text `serialize` writes (a file with anything else in it gives no folders).
    public static func parse(_ text: String) -> [VisitedFolder] {
        guard let data = text.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }
        return sanitize(object["folders"])
    }

    private static func sanitizeVisits(_ items: [Any]) -> [FolderVisit] {
        var visits: [FolderVisit] = []
        for item in items {
            guard let pair = item as? [Any], pair.count >= 2,
                let at = validTime(pair[0]),
                let text = pair[1] as? String,
                let kind = FolderVisit.Kind(rawValue: text)
            else { continue }
            visits.append(FolderVisit(at: at, kind: kind))
        }
        // Newest first; a stable sort, so equal times keep their order.
        return visits.enumerated()
            .sorted { $0.element.at != $1.element.at ? $0.element.at > $1.element.at : $0.offset < $1.offset }
            .prefix(maxVisitsPerFolder)
            .map(\.element)
    }

    // A JSON number (not a boolean), finite and not negative.
    private static func validTime(_ value: Any) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let time = number.doubleValue
        return time.isFinite && time >= 0 ? time : nil
    }
}
