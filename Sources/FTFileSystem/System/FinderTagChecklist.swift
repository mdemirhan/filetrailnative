// The tags the Tags popover offers: every tag in use on this Mac, the items' own, and the seven colors
import CoreServices
import FTFoundation
import Foundation

/// The tags in use on this Mac, as Spotlight knows them.
///
/// Finder keeps its own list of tags where no other app can read it dependably, so the tags offered are those on some
/// item. Spotlight keeps each item's tags with their colors (`_kMDItemUserTags`, stored as the attribute stores them),
/// and gives each value once for all its items: about 180 ms for ten thousand tagged items the first time, under 10
/// after, on an M-series Mac. A tag that is on no item, or only on a disk Spotlight doesn't index, isn't in it.
public enum FinderTagCatalog {
    private static let attributeName = "_kMDItemUserTags"

    /// Each tag in use once, in no order; a name stored in several colors takes the one most items have.
    public static func inUse() -> [FinderTag] {
        let attribute = attributeName as CFString
        guard
            let query = MDQueryCreate(
                kCFAllocatorDefault, "kMDItemUserTags == \"*\"" as CFString, [attribute] as CFArray, nil)
        else { return [] }
        MDQuerySetSearchScope(query, [kMDQueryScopeComputerIndexed] as CFArray, 0)
        guard MDQueryExecute(query, CFOptionFlags(kMDQuerySynchronous.rawValue)) else { return [] }
        defer { MDQueryStop(query) }
        let values = (MDQueryCopyValuesOfAttribute(query, attribute) as? [CFTypeRef]) ?? []
        var counted: [(tag: FinderTag, count: Int)] = []
        for value in values {
            guard let stored = value as? String else { continue }
            let count = MDQueryGetCountOfResultsWithAttributeValue(query, attribute, value)
            counted.append((FinderTag(stored: stored), count))
        }
        return merged(counted)
    }

    /// Each name once, case aside, in the color most of its items have it in.
    static func merged(_ counted: [(tag: FinderTag, count: Int)]) -> [FinderTag] {
        var best: [String: (tag: FinderTag, count: Int)] = [:]
        var order: [String] = []
        for entry in counted where !entry.tag.name.isEmpty {
            let key = entry.tag.key
            if let held = best[key] {
                if entry.count > held.count { best[key] = entry }
            } else {
                best[key] = entry
                order.append(key)
            }
        }
        return order.compactMap { best[$0]?.tag }
    }
}

/// One row of the Tags popover: a tag, and how many of the items have it.
public struct FinderTagChecklistRow: Sendable, Equatable {
    public var tag: FinderTag
    public var count: Int
    /// One of the seven colors' own tags, listed after the others.
    public var isColor: Bool

    public init(tag: FinderTag, count: Int, isColor: Bool) {
        self.tag = tag
        self.count = count
        self.isColor = isColor
    }
}

public enum FinderTagChecklist {
    /// The rows: the tags of one's own (on the items, or in use anywhere) by name, then the seven colors in the order
    /// of the color row. A color's tag is the tag of its name in this language (`colorNames`, as macOS names them,
    /// renamed in Finder's settings or not); a tag of that name keeps the color's place whatever color it is stored in.
    public static func rows(
        on items: FinderTagsOnItems, inUse: [FinderTag], colorNames: [FinderTagColor: String],
        order: NameOrder = .current
    ) -> [FinderTagChecklistRow] {
        let colorKeys = Dictionary(
            FinderTagColor.menuOrder.compactMap { color in colorNames[color].map { ($0.lowercased(), color) } },
            uniquingKeysWith: { first, _ in first })
        var own: [String: FinderTag] = [:]
        // The items' own color first, so a tag shows as it is on them.
        for tag in items.tags + inUse where colorKeys[tag.key] == nil && own[tag.key] == nil {
            own[tag.key] = tag
        }
        let named = own.values.sorted { left, right in
            let compared = order.compare(left.name, right.name)
            return compared != 0 ? compared < 0 : NameOrder.compareText(left.name, right.name) < 0
        }
        let colors = FinderTagColor.menuOrder.compactMap { color -> FinderTag? in
            colorNames[color].map { FinderTag(name: $0, color: color) }
        }
        return named.map { FinderTagChecklistRow(tag: $0, count: items.count(of: $0), isColor: false) }
            + colors.map { FinderTagChecklistRow(tag: $0, count: items.count(of: $0), isColor: true) }
    }

    /// The rows whose name holds the text, as the file filter matches a name (case aside, a plain letter finding its
    /// accented forms); all of them for no text.
    public static func filter(_ rows: [FinderTagChecklistRow], by text: String) -> [FinderTagChecklistRow] {
        guard let matcher = NameMatcher(text, mode: .contains) else { return rows }
        return rows.filter { matcher.matches($0.tag.name) }
    }
}
