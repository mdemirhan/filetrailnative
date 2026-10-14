// Port of packages/core/src/fs/explorerService.ts
import FTFoundation
import Foundation

/// Names kinds as the system does ("Markdown Document"), asking once per extension; a file without one is
/// asked each time. Without a describer, files are called "MD File" and the like.
public final class KindLabeler: @unchecked Sendable {
    public typealias Describer = @Sendable (String) -> String?

    private let describer: Describer?
    private let lock = NSLock()
    private var byExtension: [String: String?] = [:]

    public init(describer: Describer?) {
        self.describer = describer
    }

    /// The system's own kind strings (`FileKind`).
    public static var system: KindLabeler { KindLabeler(describer: { FileKind.kind(forPath: $0) }) }

    /// What the system calls a file's kind, or nil.
    func describe(path: @autoclosure () -> String, fileExtension: String) -> String? {
        guard let describer else { return nil }
        if fileExtension.isEmpty { return describer(path()) }
        lock.lock()
        if let known = byExtension[fileExtension] {
            lock.unlock()
            return known
        }
        lock.unlock()
        let described = describer(path())
        lock.lock()
        byExtension[fileExtension] = .some(described)
        lock.unlock()
        return described
    }

    func label(for kind: EntryKind, path: String) -> String {
        label(for: kind, fileExtension: ExplorerListing.extensionName(path), path: path)
    }

    /// The label of an entry, given the facts the caller already has.
    func label(for kind: EntryKind, fileExtension: String, path: @autoclosure () -> String) -> String {
        // Human-readable labels are used directly in details/info UI and intentionally stay simple.
        switch kind {
        case .directory: return "Folder"
        case .symlinkDirectory: return "Alias Folder"
        case .symlinkFile: return "Alias File"
        case .bundle:
            switch fileExtension {
            case "app": return "Application"
            case "framework": return "Framework"
            case "xcodeproj": return "Xcode Project"
            case "playground": return "Playground"
            default: return "Bundle"
            }
        case .file:
            if let described = describe(path: path(), fileExtension: fileExtension) { return described }
            return fileExtension.isEmpty ? "File" : "\(fileExtension.uppercased()) File"
        case .other: return "Item"
        }
    }
}

/// The listing functions of explorerService.ts, over a file system.
enum ExplorerListing {
    // MARK: Paths

    /// `path.resolve(path)`: absolute, normalized, without a trailing slash.
    static func resolve(_ path: String) -> String {
        if path.hasPrefix("/") { return NodePath.resolve(path) }
        return NodePath.resolve(FileManager.default.currentDirectoryPath + "/" + path)
    }

    static func join(_ directory: String, _ name: String) -> String {
        directory == "/" ? "/" + name : directory + "/" + name
    }

    /// `extname(path)` without its dot, lowercased.
    static func extensionName(_ path: String) -> String {
        extensionName(ofName: NodePath.basename(path))
    }

    /// The same for a name without folders: from the last dot, unless the name starts with it (".bashrc")
    /// or is "..". (FTFoundation's `NodePath.extname` answers "" for any name starting "..".)
    static func extensionName(ofName name: String) -> String {
        var name = name
        return name.withUTF8 { bytes in
            guard let dot = bytes.lastIndex(of: UInt8(ascii: ".")), dot > 0 else { return "" }
            if dot == 1 && bytes.count == 2 { return "" }
            let tail = UnsafeBufferPointer(rebasing: bytes[(dot + 1)...])
            if tail.isEmpty { return "" }
            if tail.allSatisfy({ $0 < 0x80 }) {
                var lowered = [UInt8](tail)
                for index in lowered.indices where lowered[index] >= 65 && lowered[index] <= 90 {
                    lowered[index] += 32
                }
                return String(decoding: lowered, as: UTF8.self)
            }
            return String(decoding: tail, as: UTF8.self).lowercased()
        }
    }

    static func isHidden(_ name: String) -> Bool { name.utf8.first == UInt8(ascii: ".") }

    // MARK: Reading

    /// The folder's real path; it must be a folder.
    static func resolveDirectoryPath(_ path: String, _ fileSystem: any ExplorerFileSystem) throws -> String {
        // Normalize through realpath when possible so aliased directories do not fork history/tree state.
        let resolved = resolve(path)
        let stats = try fileSystem.stat(resolved)
        guard stats.isDirectory else { throw ExplorerError.notADirectory(resolved) }
        return (try? fileSystem.realpath(resolved)) ?? resolved
    }

    static func tryResolveDirectoryPath(_ path: String, _ fileSystem: any ExplorerFileSystem) -> String? {
        try? resolveDirectoryPath(path, fileSystem)
    }

    static func safeStat(_ path: String, _ fileSystem: any ExplorerFileSystem) -> FileStats? {
        try? fileSystem.stat(path)
    }

    static func safeLstat(_ path: String, _ fileSystem: any ExplorerFileSystem) -> FileStats? {
        try? fileSystem.lstat(path)
    }

    /// What an entry is: a symlink is followed to see whether its target is a file or a folder, and a
    /// folder named like a package (.app, .framework…) is a bundle.
    static func classify(_ record: DirectoryRecord, path: String, _ fileSystem: any ExplorerFileSystem) -> EntryKind {
        switch record.type {
        case .directory:
            return ItemNames.isMacOSPackageName(record.name) ? .bundle : .directory
        case .file:
            return .file
        case .symlink:
            guard let stats = try? fileSystem.stat(path) else { return .other }
            return kind(from: stats, isSymlink: true, path: path)
        case .other:
            return .other
        }
    }

    static func kind(from stats: FileStats, isSymlink: Bool, path: String?) -> EntryKind {
        if stats.isDirectory {
            if let path, ItemNames.isMacOSPackageName(NodePath.basename(path)) { return .bundle }
            return isSymlink ? .symlinkDirectory : .directory
        }
        if stats.isFile {
            return isSymlink ? .symlinkFile : .file
        }
        return .other
    }

    /// `stat`, or `lstat` when the target can't be reached (a dangling link). A read that already carries
    /// what `lstat` says serves any entry that isn't a link.
    private static func bestEffortStats(
        _ record: DirectoryRecord, path: String, _ fileSystem: any ExplorerFileSystem
    ) -> FileStats? {
        if record.type != .symlink, let known = record.lstat { return known }
        return safeStat(path, fileSystem) ?? record.lstat ?? safeLstat(path, fileSystem)
    }

    // MARK: Tree

    /// Tree loading only returns navigable folders, not every entry in the directory.
    static func treeChildren(
        path: String, includeHidden: Bool, _ fileSystem: any ExplorerFileSystem
    ) throws -> TreeChildren {
        let directoryPath = try resolveDirectoryPath(path, fileSystem)
        let records = try fileSystem.readDirectory(directoryPath)
        var children: [TreeChild] = []
        var keys = NameKeys()
        for record in records {
            let hidden = isHidden(record.name)
            if !includeHidden && hidden { continue }
            let entryPath = join(directoryPath, record.name)
            let kind = classify(record, path: entryPath, fileSystem)
            guard kind == .directory || kind == .symlinkDirectory else { continue }
            children.append(
                TreeChild(
                    path: entryPath, name: record.name, kind: kind, isHidden: hidden,
                    isSymlink: kind == .symlinkDirectory))
            keys.append(record.name)
        }
        return TreeChildren(path: directoryPath, children: keys.sortedPositions().map { children[$0] })
    }

    // MARK: Snapshot

    /// Snapshot listing fetches extra stat data only for sort modes that require it so the common
    /// name-sorted path stays as cheap as possible.
    static func snapshot(
        path: String, includeHidden: Bool, sortBy: DirectorySortKey, sortDirection: SortDirection,
        foldersFirst: Bool, _ fileSystem: any ExplorerFileSystem, kinds: KindLabeler
    ) throws -> DirectorySnapshot {
        let directoryPath = try resolveDirectoryPath(path, fileSystem)
        let records = try fileSystem.readDirectory(directoryPath)

        // What each kept entry is, one column per fact, so sorting touches only what it compares.
        var entries: [DirectoryEntry] = []
        entries.reserveCapacity(records.count)
        var keys = NameKeys(capacity: records.count)
        var modified: [Int64?] = []
        var sizes: [Int64?] = []
        var labels: [String] = []
        for record in records {
            let hidden = isHidden(record.name)
            if !includeHidden && hidden { continue }
            let entryPath = join(directoryPath, record.name)
            let kind = classify(record, path: entryPath, fileSystem)
            let fileExtension = extensionName(ofName: record.name)
            // A file without an extension is drawn as a document or as an executable, which only its
            // permissions tell apart. Other entries are not looked at unless the sort needs it.
            let needsExecutableFlag = kind == .file && fileExtension.isEmpty
            let stats =
                sortBy == .modified || sortBy == .size || needsExecutableFlag
                ? bestEffortStats(record, path: entryPath, fileSystem) : nil
            var entry = DirectoryEntry(
                path: entryPath, name: record.name, fileExtension: fileExtension, kind: kind, isHidden: hidden,
                isSymlink: kind == .symlinkDirectory || kind == .symlinkFile)
            if needsExecutableFlag, let stats {
                entry.isExecutable = stats.mode & 0o111 != 0
            }
            switch sortBy {
            case .modified:
                modified.append(stats?.mtimeMs)
            case .size:
                // A link to a folder is sized as the link itself (see readEntrySize).
                if kind == .symlinkDirectory {
                    sizes.append((record.lstat ?? safeLstat(entryPath, fileSystem))?.size)
                } else if let stats, kind == .file || kind == .symlinkFile {
                    sizes.append(stats.size)
                } else {
                    sizes.append(nil)
                }
            case .kind:
                labels.append(kinds.label(for: kind, fileExtension: fileExtension, path: entryPath))
            case .name:
                break
            }
            entries.append(entry)
            keys.append(record.name)
        }

        let order = sortedPositions(
            entries: entries, keys: keys, modified: modified, sizes: sizes, labels: labels, sortBy: sortBy,
            sortDirection: sortDirection, foldersFirst: foldersFirst)
        let parent = NodePath.dirname(directoryPath)
        var sorted: [DirectoryEntry] = []
        sorted.reserveCapacity(order.count)
        for position in order {
            var entry = entries[position]
            if sortBy == .size { entry.sizeBytes = sizes[position] }
            sorted.append(entry)
        }
        return DirectorySnapshot(
            path: directoryPath, parentPath: directoryPath == parent ? nil : parent, entries: sorted)
    }

    /// `compareEntries`: the order of the entries.
    private static func sortedPositions(
        entries: [DirectoryEntry], keys: NameKeys, modified: [Int64?], sizes: [Int64?], labels: [String],
        sortBy: DirectorySortKey, sortDirection: SortDirection, foldersFirst: Bool
    ) -> [Int] {
        let isFolder = entries.map { $0.kind.isDirectoryKind }
        // Kinds compare as labels; each distinct label is ranked once.
        var labelRanks: [Int] = []
        if sortBy == .kind {
            let sortedLabels = stableSorted(Array(Set(labels)).sorted()) {
                Collation.compareVariant(CollationKey($0), CollationKey($1))
            }
            var rankOf: [String: Int] = [:]
            var rank = 0
            for (index, label) in sortedLabels.enumerated() {
                if index > 0
                    && Collation.compareVariant(CollationKey(sortedLabels[index - 1]), CollationKey(label)) != 0
                {
                    rank += 1
                }
                rankOf[label] = rank
            }
            labelRanks = labels.map { rankOf[$0] ?? 0 }
        }
        let descending = sortDirection == .descending
        return keys.withComparator { compareNames in
            var order = Array(0..<entries.count)
            order.sort { left, right in
                // `foldersFirst` is applied before the requested sort mode, matching Finder-style behavior.
                if foldersFirst && isFolder[left] != isFolder[right] {
                    return isFolder[left]
                }
                var compared = 0
                switch sortBy {
                case .modified:
                    // Items without a value stay at the end in both directions.
                    let missing = compareMissing(modified[left], modified[right])
                    if missing != 0 { return missing < 0 }
                    compared = compareValues(modified[left], modified[right])
                case .size:
                    let missing = compareMissing(sizes[left], sizes[right])
                    if missing != 0 { return missing < 0 }
                    compared = compareValues(sizes[left], sizes[right])
                case .kind:
                    compared = labelRanks[left] == labelRanks[right] ? 0 : (labelRanks[left] < labelRanks[right] ? -1 : 1)
                case .name:
                    break
                }
                if compared == 0 {
                    compared = compareNames(left, right)
                }
                if descending { compared = -compared }
                return compared != 0 ? compared < 0 : left < right
            }
            return order
        }
    }

    /// Nulls sort last so missing metadata does not float directories/unknown values to the top: negative
    /// when only `right` lacks a value, positive when only `left` does, else 0.
    private static func compareMissing(_ left: Int64?, _ right: Int64?) -> Int {
        if left != nil && right != nil { return 0 }
        if left == nil && right == nil { return 0 }
        return left == nil ? 1 : -1
    }

    private static func compareValues(_ left: Int64?, _ right: Int64?) -> Int {
        guard let left, let right else { return 0 }
        return left == right ? 0 : (left < right ? -1 : 1)
    }

    // MARK: Metadata

    /// Metadata batches are constrained to a single parent directory so the renderer cannot use this as a
    /// generic arbitrary-path stat API.
    static func metadataBatch(
        directoryPath: String, paths: [String], _ fileSystem: any ExplorerFileSystem, kinds: KindLabeler
    ) throws -> MetadataBatch {
        let resolvedDirectoryPath = try resolveDirectoryPath(directoryPath, fileSystem)
        var items: [EntryMetadata] = []
        items.reserveCapacity(paths.count)
        for path in paths {
            let resolvedPath = resolve(path)
            if NodePath.dirname(resolvedPath) != resolvedDirectoryPath {
                throw ExplorerError.outsideDirectory(path: resolvedPath, directory: resolvedDirectoryPath)
            }
            items.append(entryMetadata(path: resolvedPath, fileSystem, kinds: kinds))
        }
        return MetadataBatch(directoryPath: resolvedDirectoryPath, items: items)
    }

    private static func entryMetadata(
        path: String, _ fileSystem: any ExplorerFileSystem, kinds: KindLabeler
    ) -> EntryMetadata {
        // Directory sizes are intentionally deferred; everything else is cheap enough for bulk reads.
        let details = readDetails(path: path, fileSystem, kinds: kinds)
        return EntryMetadata(
            path: path, kindLabel: details.kindLabel, createdAt: details.createdAt, modifiedAt: details.modifiedAt,
            sizeBytes: details.sizeBytes, sizeStatus: details.sizeStatus, permissionMode: details.permissionMode)
    }

    private struct Details {
        var kind: EntryKind
        var kindLabel: String
        var isSymlink: Bool
        var createdAt: String?
        var modifiedAt: String?
        var sizeBytes: Int64?
        var sizeStatus: SizeStatus
        var permissionMode: Int?
    }

    private static func readDetails(path: String, _ fileSystem: any ExplorerFileSystem, kinds: KindLabeler) -> Details {
        let symlinkStats = safeLstat(path, fileSystem)
        let stats = safeStat(path, fileSystem)
        let metadataStats = stats ?? symlinkStats
        let isSymlink = symlinkStats?.isSymbolicLink ?? false
        let kind = stats.map { self.kind(from: $0, isSymlink: isSymlink, path: path) } ?? .other
        let size = readEntrySize(kind: kind, stats: stats, symlinkStats: symlinkStats)
        return Details(
            kind: kind, kindLabel: kinds.label(for: kind, path: path), isSymlink: isSymlink,
            createdAt: metadataStats?.birthtimeMs.flatMap(IsoDate.string(milliseconds:)),
            modifiedAt: metadataStats?.mtimeMs.flatMap(IsoDate.string(milliseconds:)),
            sizeBytes: size.bytes, sizeStatus: size.status,
            permissionMode: metadataStats.map { Int($0.mode & 0o777) })
    }

    /// Folder sizes are calculated separately, so a folder's is deferred. A link to a folder has the size
    /// of the link itself, as measuring the folder it is in counts it: the folder it points to may be
    /// counted elsewhere already.
    private static func readEntrySize(
        kind: EntryKind, stats: FileStats?, symlinkStats: FileStats?
    ) -> (bytes: Int64?, status: SizeStatus) {
        if kind == .symlinkDirectory, let symlinkStats { return (symlinkStats.size, .ready) }
        guard let stats else { return (nil, .unavailable) }
        return stats.isDirectory ? (nil, .deferred) : (stats.size, .ready)
    }

    /// The info panel uses this richer single-item shape rather than stitching fields together from
    /// snapshot + metadata batch responses.
    static func itemProperties(
        path: String, _ fileSystem: any ExplorerFileSystem, kinds: KindLabeler
    ) -> ItemProperties {
        let resolvedPath = resolve(path)
        let details = readDetails(path: resolvedPath, fileSystem, kinds: kinds)
        let name = NodePath.basename(resolvedPath)
        return ItemProperties(
            path: resolvedPath,
            // `/` has no base name, and the response needs one: it is named as the app names it.
            name: resolvedPath == "/" ? "Macintosh HD" : name,
            fileExtension: extensionName(resolvedPath), kind: details.kind, kindLabel: details.kindLabel,
            isHidden: isHidden(name), isSymlink: details.isSymlink, createdAt: details.createdAt,
            modifiedAt: details.modifiedAt, sizeBytes: details.sizeBytes, sizeStatus: details.sizeStatus,
            permissionMode: details.permissionMode)
    }

    // MARK: Suggestions

    /// Suggestions resolve the deepest existing directory prefix, then match only directory-like children
    /// under that base path.
    static func pathSuggestions(
        inputPath: String, includeHidden: Bool, limit: Int, _ fileSystem: any ExplorerFileSystem
    ) throws -> PathSuggestions {
        guard let query = suggestionQuery(inputPath, fileSystem) else {
            return PathSuggestions(inputPath: inputPath, basePath: nil, suggestions: [])
        }
        let records = try fileSystem.readDirectory(query.basePath)
        let typed = Array(query.typedName.lowercased().utf16)
        var matches: [PathSuggestion] = []
        var keys = NameKeys()
        for record in records {
            if !includeHidden && isHidden(record.name) { continue }
            if !typed.isEmpty && !Array(record.name.lowercased().utf16).starts(with: typed) { continue }
            let entryPath = join(query.basePath, record.name)
            let kind = classify(record, path: entryPath, fileSystem)
            guard kind == .directory || kind == .symlinkDirectory else { continue }
            matches.append(PathSuggestion(path: entryPath, name: record.name, isDirectory: true))
            keys.append(record.name)
        }
        return PathSuggestions(
            inputPath: inputPath, basePath: query.basePath,
            suggestions: keys.sortedPositions().prefix(limit).map { matches[$0] })
    }

    private static func suggestionQuery(
        _ inputPath: String, _ fileSystem: any ExplorerFileSystem
    ) -> (basePath: String, typedName: String)? {
        // Example:
        // `/Users/al/Doc` => basePath `/Users/al`, typedName `Doc`
        // `/Users/al/Documents/` => basePath `/Users/al/Documents`, typedName ``
        let trimmed = jsTrimmed(inputPath)
        let normalizedPath = resolve(trimmed.isEmpty ? "/" : trimmed)
        let parts = normalizedPath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)

        if trimmed.hasSuffix("/"), let exact = tryResolveDirectoryPath(normalizedPath, fileSystem) {
            return (exact, "")
        }

        var index = parts.count
        while index >= 0 {
            let candidate = index == 0 ? "/" : "/" + parts[..<index].joined(separator: "/")
            if let resolved = tryResolveDirectoryPath(candidate, fileSystem) {
                if index == parts.count {
                    return (NodePath.dirname(resolve(resolved)), parts.last ?? "")
                }
                return (resolved, parts[index])
            }
            index -= 1
        }
        return nil
    }

    /// `String.prototype.trim`: white space, line terminators and the byte order mark.
    private static func jsTrimmed(_ text: String) -> String {
        func isSpace(_ scalar: Unicode.Scalar) -> Bool {
            switch scalar.value {
            case 0x09...0x0D, 0x20, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF:
                return true
            default:
                return false
            }
        }
        var scalars = Substring(text).unicodeScalars
        while let first = scalars.first, isSpace(first) { scalars.removeFirst() }
        while let last = scalars.last, isSpace(last) { scalars.removeLast() }
        return String(scalars)
    }

    // MARK: Resolve

    static func resolvePathTarget(_ path: String, _ fileSystem: any ExplorerFileSystem) -> ResolvedPath {
        // Failure is represented as `resolvedPath: nil` so callers can fall back gracefully.
        let input = resolve(path)
        return ResolvedPath(inputPath: input, resolvedPath: try? fileSystem.realpath(input))
    }
}

/// `Date.prototype.toISOString`.
enum IsoDate {
    static func string(milliseconds: Int64) -> String? {
        // The years a JavaScript date can hold (-271821 to 275760) are far more than a disk keeps.
        guard abs(milliseconds) <= 8_640_000_000_000_000 else { return nil }
        let days = Int64((Double(milliseconds) / 86_400_000).rounded(.down))
        let millisecondsOfDay = Int(milliseconds - days * 86_400_000)
        // Civil date from days since 1970-01-01 (Howard Hinnant's algorithm).
        let shifted = days + 719_468
        let era = (shifted >= 0 ? shifted : shifted - 146_096) / 146_097
        let dayOfEra = shifted - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let monthIndex = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * monthIndex + 2) / 5 + 1
        let month = monthIndex < 10 ? monthIndex + 3 : monthIndex - 9
        let year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0)
        let hours = millisecondsOfDay / 3_600_000
        let minutes = millisecondsOfDay / 60_000 % 60
        let seconds = millisecondsOfDay / 1000 % 60
        let millis = millisecondsOfDay % 1000
        let yearText: String
        if (0...9999).contains(year) {
            yearText = pad(Int(year), 4)
        } else {
            yearText = (year < 0 ? "-" : "+") + pad(Int(abs(year)), 6)
        }
        return "\(yearText)-\(pad(Int(month), 2))-\(pad(Int(day), 2))T\(pad(hours, 2)):\(pad(minutes, 2)):\(pad(seconds, 2)).\(pad(millis, 3))Z"
    }

    private static func pad(_ value: Int, _ width: Int) -> String {
        let text = String(value)
        return String(repeating: "0", count: max(0, width - text.count)) + text
    }
}
