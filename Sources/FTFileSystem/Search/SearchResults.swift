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

    /// The extension of `name`, from its last dot, lowercased; "" when the name has no dot or only one at its start.
    static func extensionOf(_ name: String) -> String {
        let units = Array(name.utf16)
        let dot = UInt16(UInt8(ascii: "."))
        guard let last = units.lastIndex(of: dot) else { return "" }
        // A name that is all dots, or whose only dot starts it, has no extension.
        let onlyDots = !units.contains { $0 != dot }
        let startsAtOnlyDot = last == 0
        if onlyDots && units.count <= 2 || startsAtOnlyDot { return "" }
        let ext = Array(units[(last + 1)...])
        return jsLowercased(String(decoding: ext, as: UTF16.self))
    }

    /// `to` as seen from `from`, both absolute and normalized: ".." for each folder to go up, then the rest of `to`.
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

    /// A result as the views of the folder show an entry.
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
        _ items: [SearchResultItem], by sortBy: SearchResultsSortByPreference, direction: SortDirectionPreference,
        order: NameOrder = .current
    ) -> [SearchResultItem] {
        sortedIndexes(items, by: sortBy, direction: direction, order: order).map { items[$0] }
    }

    /// The positions of `items` in sorted order; items of the very same path keep their places.
    public static func sortedIndexes(
        _ items: [SearchResultItem], by sortBy: SearchResultsSortByPreference, direction: SortDirectionPreference,
        order: NameOrder = .current
    ) -> [Int] {
        let sign = direction == .asc ? 1 : -1
        return items.indices.sorted { left, right in
            let compared = compare(items[left], items[right], by: sortBy, order: order) * sign
            return compared != 0 ? compared < 0 : left < right
        }
    }

    /// `later` merged into `earlier`, each already in the order asked for: the order a sort of them all would give, with
    /// a tie going to the earlier result.
    public static func merge(
        _ earlier: [SearchResultItem], _ later: [SearchResultItem], by sortBy: SearchResultsSortByPreference,
        direction: SortDirectionPreference, order: NameOrder = .current
    ) -> [SearchResultItem] {
        let sign = direction == .asc ? 1 : -1
        var merged: [SearchResultItem] = []
        merged.reserveCapacity(earlier.count + later.count)
        var left = 0
        var right = 0
        while left < earlier.count, right < later.count {
            if compare(later[right], earlier[left], by: sortBy, order: order) * sign < 0 {
                merged.append(later[right])
                right += 1
            } else {
                merged.append(earlier[left])
                left += 1
            }
        }
        merged += earlier[left...]
        merged += later[right...]
        return merged
    }

    // The path is the tie-breaker, as the language orders it and then by its text, so the order is the same every time.
    private static func compare(
        _ left: SearchResultItem, _ right: SearchResultItem, by sortBy: SearchResultsSortByPreference,
        order: NameOrder
    ) -> Int {
        // Names and paths the order holds equal are told apart by their text, so equal ones come in a fixed order. Each
        // step is worked out only when the one before it holds the two equal: most pairs differ at the first.
        func byName() -> Int {
            let names = order.compare(left.name, right.name)
            return names != 0 ? names : order.compare(left.path, right.path)
        }
        let first: Int
        switch sortBy {
        case .name:
            first = byName()
        case .kind:
            // Kind is told from the extension, which every result has at once (the kind's name loads only for the rows
            // on screen): folders first, then files by extension, those without one last, each group by name.
            let kinds = compareKindKeys(kindKey(left), kindKey(right), order: order)
            first = kinds != 0 ? kinds : byName()
        case .path:
            first = order.compare(left.path, right.path)
        }
        return first != 0 ? first : NameOrder.compareText(left.path, right.path)
    }

    /// Folders (and links to them) are 0, files with an extension 1, files without one 2.
    private static func kindKey(_ item: SearchResultItem) -> (Int, String) {
        if item.kind == .directory || item.kind == .symlinkDirectory { return (0, "") }
        return item.fileExtension.isEmpty ? (2, "") : (1, jsLowercased(item.fileExtension))
    }

    private static func compareKindKeys(_ left: (Int, String), _ right: (Int, String), order: NameOrder) -> Int {
        left.0 != right.0 ? left.0 - right.0 : order.compareWords(left.1, right.1)
    }

    // MARK: - Highlighting

    /// What a name search matched, to mark it in the names. fd uses smart case (case-sensitive only when the query has
    /// an uppercase letter); glob patterns match the whole name, so they are not marked, and neither are patterns that
    /// the system's regular expressions don't take.
    public static func highlightPattern(
        query: String, patternMode: SearchPatternModePreference, matchScope: SearchMatchScopePreference
    ) -> HighlightPattern? {
        let trimmed = jsTrimmed(query)
        if trimmed.isEmpty || patternMode == .glob || matchScope != .name {
            return nil
        }
        let hasUppercase = trimmed.unicodeScalars.contains { $0.properties.generalCategory == .uppercaseLetter }
        if patternMode == .text {
            return HighlightPattern(text: trimmed, ignoreCase: !hasUppercase)
        }
        return HighlightPattern(regex: trimmed, ignoreCase: !hasUppercase)
    }

    // MARK: - Folder column

    /// The folder a result is in, from where the search started, with › between folders ("Taxes › 2025"); a result
    /// right in that folder shows the folder's name (the startup disk's for `/`).
    public static func folderText(
        path: String, rootPath: String, startupDiskName: String = VolumePaths.defaultStartupDiskName
    ) -> String {
        let pathUnits = Array(path.utf16)
        let lastSlash = pathUnits.lastIndex(of: slash) ?? -1
        let parentPath = Array(pathUnits[..<max(1, lastSlash)])
        var rootUnits = Array(rootPath.utf16)
        if rootUnits.count > 1 {
            while rootUnits.last == slash { rootUnits.removeLast() }
        }
        let root = String(decoding: rootUnits, as: UTF16.self)
        if parentPath == rootUnits {
            if root == "/" { return startupDiskName }
            return root.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? root
        }
        let cut = root == "/" ? 1 : rootUnits.count + 1
        let relative = cut <= parentPath.count ? Array(parentPath[cut...]) : []
        return String(decoding: relative, as: UTF16.self)
            .split(separator: "/", omittingEmptySubsequences: true).joined(separator: " › ")
    }

    // MARK: - Trimming

    /// White space, line terminators and the byte order mark.
    static func isJSWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09...0x0D, 0x20, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF: true
        default: false
        }
    }

    /// The text without white space at either end: a typed query, a path typed in the path bar or Go To, an `fd`
    /// error.
    static func jsTrimmed(_ text: String) -> String {
        var scalars = Substring(text).unicodeScalars[...]
        while let first = scalars.first, isJSWhitespace(first) { scalars.removeFirst() }
        while let last = scalars.last, isJSWhitespace(last) { scalars.removeLast() }
        return String(scalars)
    }

    /// Lowercased: full case mappings, and the Greek capital sigma lowered to its final form at the end of a word.
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
