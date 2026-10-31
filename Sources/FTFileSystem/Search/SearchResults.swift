// Port of toSearchResultItem (packages/core/src/search/fdSearch.ts) and apps/desktop/src/renderer/lib/searchResults.ts
import FTFoundation
import Foundation

public enum SearchResults {
    // MARK: - Items from fd's output

    /// A result from one record of fd's output. fd ends a folder's path with a slash, which tells folders from files
    /// without a stat call.
    public static func item(rootPath: String, outputPath: String) -> SearchResultItem {
        let units = Array(outputPath.utf16)
        let isFolder = units.count > 1 && units.last == slash
        let entryPath = isFolder ? String(decoding: units.dropLast(), as: UTF16.self) : outputPath
        let name = NodePath.basename(entryPath)
        let parentPath = NodePath.dirname(entryPath)
        let relativeParentPath = relative(from: rootPath, to: parentPath)
        let kind: EntryKind
        if !isFolder {
            kind = .file
        } else {
            // Packages (.app and the like) are folders on disk but single items to the user.
            kind = ItemNames.isMacOSPackageName(name) ? .bundle : .directory
        }
        return SearchResultItem(
            path: entryPath, name: name, fileExtension: extensionOf(name), kind: kind,
            isHidden: name.hasPrefix("."), isSymlink: false, parentPath: parentPath,
            relativeParentPath: relativeParentPath.isEmpty ? "." : relativeParentPath)
    }

    private static let slash = UInt16(UInt8(ascii: "/"))

    /// `path.extname(name).replace(/^\./, "").toLowerCase()`.
    static func extensionOf(_ name: String) -> String {
        let units = Array(name.utf16)
        let dot = UInt16(UInt8(ascii: "."))
        guard let last = units.lastIndex(of: dot) else { return "" }
        // Node's rule: a name that is all dots, or whose only dot starts it, has no extension.
        let onlyDots = !units.contains { $0 != dot }
        let startsAtOnlyDot = last == 0
        if onlyDots && units.count <= 2 || startsAtOnlyDot { return "" }
        let ext = Array(units[(last + 1)...])
        return jsLowercased(String(decoding: ext, as: UTF16.self))
    }

    /// `path.relative(from, to)` for absolute, normalized paths.
    static func relative(from: String, to: String) -> String {
        if from == to { return "" }
        let fromParts = from.split(separator: "/", omittingEmptySubsequences: true)
        let toParts = to.split(separator: "/", omittingEmptySubsequences: true)
        var common = 0
        while common < fromParts.count && common < toParts.count
            && fromParts[common].utf8.elementsEqual(toParts[common].utf8)
        {
            common += 1
        }
        let up = Array(repeating: "..", count: fromParts.count - common)
        return (up + toParts[common...].map(String.init)).joined(separator: "/")
    }

    /// `toDirectoryEntryFromSearchResult` (explorerAppUtils.ts): a result as the views of the folder show an entry.
    public static func entry(_ item: SearchResultItem) -> DirectoryEntry {
        DirectoryEntry(
            path: item.path, name: item.name, fileExtension: item.fileExtension, kind: item.kind,
            isHidden: item.isHidden, isSymlink: item.isSymlink, isExecutable: nil, sizeBytes: nil)
    }

    // MARK: - Ordering

    /// Search updates arrive incrementally, so appending is the common path.
    public static func append(_ current: [SearchResultItem], _ next: [SearchResultItem]) -> [SearchResultItem] {
        next.isEmpty ? current : current + next
    }

    /// Sorting is pure and stable, so Apply Sort can reorder already-fetched results.
    public static func sort(
        _ items: [SearchResultItem], by sortBy: SearchResultsSortByPreference, direction: SortDirectionPreference
    ) -> [SearchResultItem] {
        sortedIndexes(items, by: sortBy, direction: direction).map { items[$0] }
    }

    /// The positions of `items` in sorted order; equal items keep their places.
    public static func sortedIndexes(
        _ items: [SearchResultItem], by sortBy: SearchResultsSortByPreference, direction: SortDirectionPreference
    ) -> [Int] {
        let sign = direction == .asc ? 1 : -1
        let collator = Collator()
        return items.indices.sorted { left, right in
            let order = compare(items[left], items[right], by: sortBy, collator: collator) * sign
            return order != 0 ? order < 0 : left < right
        }
    }

    public static func compare(
        _ left: SearchResultItem, _ right: SearchResultItem, by sortBy: SearchResultsSortByPreference
    )
        -> Int
    {
        compare(left, right, by: sortBy, collator: Collator())
    }

    // Path is the deterministic tie-breaker so sort output stays stable across repeated runs.
    private static func compare(
        _ left: SearchResultItem, _ right: SearchResultItem, by sortBy: SearchResultsSortByPreference,
        collator: Collator
    ) -> Int {
        switch sortBy {
        case .name:
            return firstNonZero(
                collator.base(left.name, right.name), collator.base(left.path, right.path))
        case .kind:
            // Kind is told from the extension, which every result has at once (the kind's name loads only for the rows
            // on screen): folders first, then files by extension, those without one last, each group by name.
            return firstNonZero(
                compareKindKeys(kindKey(left), kindKey(right), collator: collator),
                collator.base(left.name, right.name), collator.base(left.path, right.path))
        case .path:
            return collator.base(left.path, right.path)
        }
    }

    private static func firstNonZero(_ values: Int...) -> Int {
        values.first { $0 != 0 } ?? 0
    }

    /// Folders (and links to them) are 0, files with an extension 1, files without one 2.
    private static func kindKey(_ item: SearchResultItem) -> (Int, String) {
        if item.kind == .directory || item.kind == .symlinkDirectory { return (0, "") }
        return item.fileExtension.isEmpty ? (2, "") : (1, jsLowercased(item.fileExtension))
    }

    private static func compareKindKeys(_ left: (Int, String), _ right: (Int, String), collator: Collator) -> Int {
        left.0 != right.0 ? left.0 - right.0 : collator.variant(left.1, right.1)
    }

    /// `String.prototype.localeCompare` with the user's locale: `base` is `{ sensitivity: "base" }` (case and accents
    /// do not count), `variant` the default.
    struct Collator {
        let locale = Locale.current

        func base(_ left: String, _ right: String) -> Int {
            order(left.compare(right, options: [.caseInsensitive, .diacriticInsensitive], range: nil, locale: locale))
        }

        func variant(_ left: String, _ right: String) -> Int {
            order(left.compare(right, options: [], range: nil, locale: locale))
        }

        private func order(_ result: ComparisonResult) -> Int {
            switch result {
            case .orderedAscending: -1
            case .orderedSame: 0
            case .orderedDescending: 1
            }
        }
    }

    // MARK: - Highlighting

    /// What a name search matched, to mark it in the names. fd uses smart case (case-sensitive only when the query has
    /// an uppercase letter); glob patterns match the whole name, so they are not marked, and neither are patterns that
    /// JavaScript cannot parse. The JavaScript-compatible matcher marks what the original marks.
    public static func highlightPattern(
        query: String, patternMode: SearchPatternModePreference, matchScope: SearchMatchScopePreference
    ) -> JSLegacyRegExp? {
        let trimmed = jsTrimmed(query)
        if trimmed.isEmpty || patternMode == .glob || matchScope != .name {
            return nil
        }
        let hasUppercase = trimmed.unicodeScalars.contains { $0.properties.generalCategory == .uppercaseLetter }
        if patternMode == .text {
            return try? JSLegacyRegExp(literal: trimmed, ignoreCase: !hasUppercase)
        }
        return try? JSLegacyRegExp(source: trimmed, ignoreCase: !hasUppercase)
    }

    // MARK: - Folder column

    /// The folder a result is in, from where the search started, with › between folders ("src › renderer"); a result
    /// right in that folder shows the folder's name.
    public static func folderText(path: String, rootPath: String) -> String {
        let pathUnits = Array(path.utf16)
        let lastSlash = pathUnits.lastIndex(of: slash) ?? -1
        let parentPath = Array(pathUnits[..<max(1, lastSlash)])
        var rootUnits = Array(rootPath.utf16)
        if rootUnits.count > 1 {
            while rootUnits.last == slash { rootUnits.removeLast() }
        }
        let root = String(decoding: rootUnits, as: UTF16.self)
        if parentPath == rootUnits {
            if root == "/" { return "Macintosh HD" }
            return root.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? root
        }
        let cut = root == "/" ? 1 : rootUnits.count + 1
        let relative = cut <= parentPath.count ? Array(parentPath[cut...]) : []
        return String(decoding: relative, as: UTF16.self)
            .split(separator: "/", omittingEmptySubsequences: true).joined(separator: " › ")
    }

    // MARK: - JavaScript's trim

    static func isJSWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09...0x0D, 0x20, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF: true
        default: false
        }
    }

    static func jsTrimmed(_ text: String) -> String {
        var scalars = Substring(text).unicodeScalars[...]
        while let first = scalars.first, isJSWhitespace(first) { scalars.removeFirst() }
        while let last = scalars.last, isJSWhitespace(last) { scalars.removeLast() }
        return String(scalars)
    }

    /// `toLowerCase()`: full case mappings, and the Greek capital sigma lowered to its final form at the end of a word.
    static func jsLowercased(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        let scalars = Array(text.unicodeScalars)
        for (index, scalar) in scalars.enumerated() {
            if scalar == "\u{03A3}" {
                result.append(isFinalSigma(scalars, at: index) ? "\u{03C2}" : "\u{03C3}")
            } else {
                result.append(contentsOf: scalar.properties.lowercaseMapping.unicodeScalars)
            }
        }
        return String(result)
    }

    private static func isFinalSigma(_ scalars: [Unicode.Scalar], at index: Int) -> Bool {
        var before = index - 1
        while before >= 0, scalars[before].properties.isCaseIgnorable { before -= 1 }
        guard before >= 0, scalars[before].properties.isCased else { return false }
        var after = index + 1
        while after < scalars.count, scalars[after].properties.isCaseIgnorable { after += 1 }
        return after >= scalars.count || !scalars[after].properties.isCased
    }
}
