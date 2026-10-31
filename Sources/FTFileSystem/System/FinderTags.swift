// Finder's tags, stored where Finder stores them, so each app sees the other's
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
}

/// How many of the items a color is on.
public enum FinderTagColorState: Sendable, Equatable {
    case all, some
}

public struct FinderTagFailure: Sendable, Equatable {
    public var path: String
    public var message: String
}

/// Reads and writes tags. Links are followed, as `URLResourceValues.tagNames` and Finder's own scripting do.
///
/// `tagNames` is not used to write: it looks each color up by name, and so turned a custom tag's stored color to none
/// when tried. The attribute is read and written as it is, which is what leaves other apps' tags as they were.
public enum FinderTags {
    static let attribute = "com.apple.metadata:_kMDItemUserTags"

    public static func read(_ path: String) throws -> [FinderTag] {
        let length = getxattr(path, attribute, nil, 0, 0, 0)
        if length < 0 {
            if errno == ENOATTR { return [] }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var data = Data(count: length)
        let read = data.withUnsafeMutableBytes { getxattr(path, attribute, $0.baseAddress, length, 0, 0) }
        guard read >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard let stored = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        return stored.map(FinderTag.init(stored:))
    }

    /// The colors of an item's tags in their order, each once; none for an item that can't be read.
    public static func colors(_ path: String) -> [FinderTagColor] {
        var seen = Set<FinderTagColor>()
        return ((try? read(path)) ?? []).compactMap(\.color).filter { seen.insert($0).inserted }
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
        var values = URLResourceValues()
        values.labelNumber = tags.last { $0.color != nil }?.color?.rawValue ?? 0
        var url = URL(fileURLWithPath: path)
        try url.setResourceValues(values)
    }

    /// Customizes a folder as Finder does: what it shows, and the flag in Finder's information that says to look.
    static func markCustomized(_ path: String, configuration: String) throws {
        let data = Data(configuration.utf8)
        var result = data.withUnsafeBytes {
            setxattr(path, "com.apple.icon.folder#S", $0.baseAddress, data.count, 0, 0)
        }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var finderInfo = [UInt8](repeating: 0, count: 32)
        // What is there stays: the label is in it.
        _ = getxattr(path, "com.apple.FinderInfo", &finderInfo, 32, 0, 0)
        finderInfo[8] |= 0x04
        result = setxattr(path, "com.apple.FinderInfo", finderInfo, 32, 0, 0)
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
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
    public static func toggle(_ color: FinderTagColor, name: String, on paths: [String]) -> [FinderTagFailure] {
        var failures: [FinderTagFailure] = []
        var current: [(path: String, tags: [FinderTag])] = []
        for path in paths {
            // An attribute that can't be understood isn't written over.
            do { current.append((path, try read(path))) } catch {
                failures.append(FinderTagFailure(path: path, message: error.localizedDescription))
            }
        }
        let removing = current.allSatisfy { item in item.tags.contains { $0.color == color } }
        for item in current {
            let has = item.tags.contains { $0.color == color }
            guard removing || !has else { continue }
            let tags =
                removing ? item.tags.filter { $0.color != color } : item.tags + [FinderTag(name: name, color: color)]
            do { try write(tags, to: item.path) } catch {
                failures.append(FinderTagFailure(path: item.path, message: error.localizedDescription))
            }
        }
        return failures
    }
}
