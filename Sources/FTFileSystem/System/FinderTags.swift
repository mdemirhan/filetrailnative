// Finder's tags, stored where Finder stores them, so each app sees the other's
import FTFoundation
import Foundation

/// The seven colors of Finder's tags. The raw values are the numbers Finder stores, and index
/// `NSWorkspace.fileLabels` and `fileLabelColors`.
public enum FinderTagColor: Int, Sendable, Hashable, Codable, CaseIterable {
    case gray = 1
    case green, purple, blue, yellow, red, orange

    /// The order of Finder's row of colors.
    public static let menuOrder: [FinderTagColor] = [.red, .orange, .yellow, .green, .blue, .purple, .gray]
}

/// One tag of an item: its name and its color, if it has one.
public struct FinderTag: Sendable, Hashable {
    public var name: String
    public var color: FinderTagColor?

    public init(name: String, color: FinderTagColor?) {
        self.name = name
        self.color = color
    }

    /// As Finder stores it: "Red\n6", or "Project\n0" with no color. Older tags may have no number.
    init(stored: String) {
        let parts = stored.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        name = String(parts[0])
        color = parts.count > 1 ? Int(parts[1]).flatMap(FinderTagColor.init(rawValue:)) : nil
    }

    var stored: String { "\(name)\n\(color?.rawValue ?? 0)" }

    /// The name tags are told apart by: case aside, as Finder keeps one tag of a name and the search's `tag:` finds it.
    public var key: String { name.lowercased() }
}

/// How many of the items a color is on.
public enum FinderTagColorState: Sendable, Equatable {
    case all, some
}

/// An item whose tags a change wrote: what they were, and what they are now.
public struct FinderTagsChanged: Sendable, Equatable {
    public var path: String
    public var before: [FinderTag]
    public var after: [FinderTag]

    public init(path: String, before: [FinderTag], after: [FinderTag]) {
        self.path = path
        self.before = before
        self.after = after
    }
}

/// What a change of tags did: the items it wrote, and those it couldn't.
public struct FinderTagsWritten: Sendable, Equatable {
    public var changed: [FinderTagsChanged] = []
    public var failures: [FinderTagFailure] = []

    public init(changed: [FinderTagsChanged] = [], failures: [FinderTagFailure] = []) {
        self.changed = changed
        self.failures = failures
    }
}

public struct FinderTagFailure: Sendable, Equatable {
    public var path: String
    public var message: String

    public init(path: String, message: String) {
        self.path = path
        self.message = message
    }
}

/// Reads and writes tags. Links are followed, as `URLResourceValues.tagNames` and Finder's own scripting do.
///
/// `tagNames` is not used to write: it looks each color up by name, and so turned a custom tag's stored color to none
/// when tried. The attribute is read and written as it is, which is what leaves other apps' tags as they were.
public enum FinderTags {
    static let attribute = "com.apple.metadata:_kMDItemUserTags"

    public static func read(_ path: String) throws -> [FinderTag] {
        // Asking for one attribute costs over ten times what listing an item's attributes does (getxattr 15 µs,
        // listxattr 1.7 µs, an lstat 1.3 µs on an M-series Mac), and most items have no tags: the list is looked at
        // first, and the tags read only when it names them.
        guard mayHaveTags(path) else { return [] }
        return try readListed(path)
    }

    /// The tags of an item whose list of attributes names them, or wasn't read (`mayHaveTags`).
    static func readListed(_ path: String) throws -> [FinderTag] {
        // The tags in one call, as the usual few fit `firstRead`; a longer list is sized first.
        let data: Data? = try withUnsafeTemporaryAllocation(byteCount: firstRead, alignment: 1) { buffer in
            let length = getxattr(path, attribute, buffer.baseAddress, firstRead, 0, 0)
            if length >= 0 { return Data(bytes: buffer.baseAddress!, count: length) }
            if errno == ENOATTR { return Data() }
            if errno == ERANGE { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let stored = try data ?? readLong(path)
        if stored.isEmpty { return [] }
        guard let names = try PropertyListSerialization.propertyList(from: stored, format: nil) as? [String] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        return names.map(FinderTag.init(stored:))
    }

    /// Bytes read at once: a list of a dozen tags of ordinary names fits.
    static let firstRead = 512

    /// Whether the item's attributes include its tags: false only when its list of attributes was read and doesn't name
    /// them; a list too long to read at once, or one that can't be read, leaves the tags to be asked for.
    static func mayHaveTags(_ path: String) -> Bool {
        ExtendedAttributes.names(path)?.contains(attribute) ?? true
    }

    /// A list longer than `firstRead`: its size, then the list.
    private static func readLong(_ path: String) throws -> Data {
        let length = getxattr(path, attribute, nil, 0, 0, 0)
        if length < 0 {
            if errno == ENOATTR { return Data() }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var data = Data(count: length)
        let read = data.withUnsafeMutableBytes { getxattr(path, attribute, $0.baseAddress, length, 0, 0) }
        guard read >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return data.prefix(read)
    }

    /// The colors of an item's tags in their order, each once; none for an item that can't be read. The home folder's
    /// Desktop, Documents and Downloads aren't read (`asksPermission`): their colors show as none.
    public static func colors(_ path: String) -> [FinderTagColor] {
        colors(of: shown(path))
    }

    /// The colors of tags in their order, each once.
    public static func colors(of tags: [FinderTag]) -> [FinderTagColor] {
        var seen = Set<FinderTagColor>()
        return tags.compactMap(\.color).filter { seen.insert($0).inserted }
    }

    /// An item's tags as the views show them: none for an item that can't be read, nor for the home folder's Desktop,
    /// Documents and Downloads (`asksPermission`).
    public static func shown(_ path: String) -> [FinderTag] {
        guard !asksPermission(path) else { return [] }
        return ((try? read(path)) ?? []).filter { !$0.name.isEmpty }
    }

    /// The folders macOS asks the person about before an app reads them: the home folder's Desktop, Documents and
    /// Downloads. Reading even a folder's own tags counts, so drawing their tag colors in the home folder asked for
    /// permission at every start of an app not yet allowed, though nothing was opened.
    static func asksPermission(_ path: String, homePath: String = DiskPath.home.string) -> Bool {
        var path = path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        var home = homePath
        while home.count > 1, home.hasSuffix("/") { home.removeLast() }
        guard path.utf8.count > home.utf8.count + 1, path.utf8.starts(with: (home + "/").utf8) else { return false }
        let name = String(decoding: path.utf8.dropFirst(home.utf8.count + 1), as: UTF8.self)
        return ["Desktop", "Documents", "Downloads"].contains { name.utf8.elementsEqual($0.utf8) }
    }

    /// Writes an item's tags. The item's label, which `labelNumber` and older apps read, goes with them: the last
    /// color, as macOS makes it.
    public static func write(_ tags: [FinderTag], to path: String) throws {
        if tags.isEmpty {
            if removexattr(path, attribute, 0) != 0, errno != ENOATTR {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } else {
            let data = try PropertyListSerialization.data(
                fromPropertyList: tags.map(\.stored), format: .binary, options: 0)
            let result = data.withUnsafeBytes { setxattr(path, attribute, $0.baseAddress, data.count, 0, 0) }
            guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        // Best effort: the tags are what Finder and this app read, and are written already; a label refused (a disk
        // that keeps no Finder information) doesn't make them unwritten.
        var values = URLResourceValues()
        values.labelNumber = tags.last { $0.color != nil }?.color?.rawValue ?? 0
        var url = DiskPath(path).fileURL()
        try? url.setResourceValues(values)
    }

    /// Which colors are on the items, for the menu's row.
    public static func states(of paths: [String]) -> [FinderTagColor: FinderTagColorState] {
        var counts: [FinderTagColor: Int] = [:]
        for path in paths {
            for color in colors(path) { counts[color, default: 0] += 1 }
        }
        return counts.mapValues { $0 == paths.count ? .all : .some }
    }

    /// Choosing a color: on every item already, it comes off them; otherwise it goes on those without it, named
    /// `name`. A color is one choice whatever its tags are called, so a tag named in another language or a custom one
    /// of that color counts as it, and comes off with it. Other tags stay as they are.
    @discardableResult
    public static func toggle(_ color: FinderTagColor, name: String, on paths: [String]) -> FinderTagsWritten {
        toggle(on: paths, has: { $0.color == color }, adding: FinderTag(name: name, color: color))
    }

    /// Choosing a tag in the Tags popover: on every item already, it comes off them; otherwise it goes on those
    /// without it, with its color. A tag is its name, case aside (`key`), whatever its color on each item: "Work" in
    /// blue on one and in none on another is one tag. Other tags stay as they are.
    @discardableResult
    public static func toggle(_ tag: FinderTag, on paths: [String]) -> FinderTagsWritten {
        let key = tag.key
        return toggle(on: paths, has: { $0.key == key }, adding: tag)
    }

    /// Takes every tag off the items. One whose attribute can't be understood keeps it, and is reported.
    @discardableResult
    public static func removeAll(from paths: [String]) -> FinderTagsWritten {
        change(paths) { current in current.map { item in item.tags.isEmpty ? nil : [] } }
    }

    /// The tags of the items: each once, in the order first met (an item's own order, then the next item's), with
    /// how many of the items have it. An item whose tags can't be read is in `failures` and counted in none.
    /// `sparingAsked`: the home folder's Desktop, Documents and Downloads count as having none (`asksPermission`), for
    /// what is only shown.
    public static func onItems(_ paths: [String], sparingAsked: Bool = false) -> FinderTagsOnItems {
        var result = FinderTagsOnItems(itemCount: paths.count, tags: [], counts: [:], failures: [])
        for path in paths {
            if sparingAsked, asksPermission(path) { continue }
            do {
                var seen = Set<String>()
                for tag in try read(path) where !tag.name.isEmpty && seen.insert(tag.key).inserted {
                    if result.counts[tag.key] == nil { result.tags.append(tag) }
                    result.counts[tag.key, default: 0] += 1
                }
            } catch {
                result.failures.append(FinderTagFailure(path: path, message: error.localizedDescription))
            }
        }
        return result
    }

    /// The rule of the color row and the popover: when every item readable `has` the tag, it comes off them all;
    /// otherwise `adding` goes on those without it.
    private static func toggle(on paths: [String], has: @escaping (FinderTag) -> Bool, adding: FinderTag)
        -> FinderTagsWritten
    {
        change(paths) { current in
            let removing = current.allSatisfy { $0.tags.contains(where: has) }
            return current.map { item in
                let present = item.tags.contains(where: has)
                if removing { return item.tags.filter { !has($0) } }
                return present ? nil : item.tags + [adding]
            }
        }
    }

    /// Reads each item's tags, asks `newTags` what each should now be (nil to leave it), and writes those. An
    /// attribute that can't be understood isn't written over, and an item whose tags would stay as they are isn't
    /// written.
    private static func change(
        _ paths: [String], newTags: ([(path: String, tags: [FinderTag])]) -> [[FinderTag]?]
    ) -> FinderTagsWritten {
        var written = FinderTagsWritten()
        var current: [(path: String, tags: [FinderTag])] = []
        for path in paths {
            do { current.append((path, try read(path))) } catch {
                written.failures.append(FinderTagFailure(path: path, message: error.localizedDescription))
            }
        }
        for (item, tags) in zip(current, newTags(current)) {
            guard let tags, tags != item.tags else { continue }
            do {
                try write(tags, to: item.path)
                written.changed.append(FinderTagsChanged(path: item.path, before: item.tags, after: tags))
            } catch {
                written.failures.append(FinderTagFailure(path: item.path, message: error.localizedDescription))
            }
        }
        return written
    }
}

/// The tags of some items, for the Tags popover and the Info panel.
public struct FinderTagsOnItems: Sendable, Equatable {
    public var itemCount: Int
    /// Each tag once, in the order first met; its color the first item's that has it.
    public var tags: [FinderTag]
    /// How many of the items have each tag, by `FinderTag.key`.
    public var counts: [String: Int]
    /// The items whose tags couldn't be read.
    public var failures: [FinderTagFailure]

    public init(itemCount: Int, tags: [FinderTag], counts: [String: Int], failures: [FinderTagFailure]) {
        self.itemCount = itemCount
        self.tags = tags
        self.counts = counts
        self.failures = failures
    }

    /// How many of the items have the tag.
    public func count(of tag: FinderTag) -> Int { counts[tag.key] ?? 0 }

    /// How many of the items had their tags read: a tag on all of these is on every item it can be taken off, which
    /// is what a choice of it does (`FinderTags.toggle`).
    public var readCount: Int { itemCount - failures.count }
}
