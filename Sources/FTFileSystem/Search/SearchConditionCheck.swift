// What a search's conditions ask of each item the walk passes, checked cheapest first: what its folder's entry tells
// (kind, extension, a link) as its name is matched, then, of what is still kept, one `lstat` (size, the modified and
// created dates, locked, read-only, can be run, empty), and last the reads that cost more (the date added and last
// opened, an alias, tags, the date taken and a picture's size), each only for a search that asks for it, as "Nothing
// is read before it is needed" allows: the search asks for it.
import Darwin
import FTFoundation
import Foundation

struct SearchConditionCheck: Sendable {
    /// Any of these extensions, or a folder that isn't a package, or an application; nil asks for no kind.
    private let extensions: Set<String>?
    private let plainFolders: Bool
    private let applications: Bool
    private let named: Set<String>?
    private let link: Bool?
    private let hidden: Bool?
    private let size: (above: Int64?, below: Int64?)?
    /// Sizes a file is none of (`size:!1mb`), each over `above` and under `below`.
    private let excludedSizes: [(above: Int64?, below: Int64?)]
    private let pixels: [SearchPixelRule]
    /// Pictures' sizes a picture is none of (`picture:!1920`).
    private let excludedPixels: [SearchPixelRule]
    /// Each date asked about, and whether it is asked for not (`modified:!today`).
    private let dates: [(SearchDateField, SearchDateRule, SearchDateSpan, not: Bool)]
    private let attributes: [(SearchAttribute, Bool)]
    /// Lowercased: an item has a tag of each group. A tag word's tags, given with commas, are one group, any of which
    /// will do; each tag of a condition that asks for all of them is a group of its own.
    private let tagGroups: [[String]]
    /// Lowercased: an item has no tag of any of these (`tag:!red,blue`).
    private let excludedTags: Set<String>
    /// Kinds an item is none of (`kind:!pdf`), and extensions it has none of (`ext:!tmp`).
    private let excludedKinds: Set<SearchKind>
    private let excludedExtensions: Set<String>
    /// An item's mode is one of each group (`perm:755,750`), and none of `excludedModes` (`perm:!777`).
    private let modeGroups: [[SearchPermission]]
    private let excludedModes: [SearchPermission]
    private let lastOpened: @Sendable (String) -> Int64?

    /// Folders not gone into, by name.
    let skippedFolders: [String]
    /// Whether the search must list hidden items for its conditions.
    let wantsHidden: Bool
    /// Whether it must list symbolic links.
    let wantsLinks: Bool
    /// Whether an item kept by its name is read further.
    let readsEachItem: Bool
    /// Whether a condition needs what reading the item's details gives (`lstat`): its size, the dates modified and
    /// created, or the flag that locks it (locked, read-only), or a file's size (empty). The walk reads it then.
    let needsStat: Bool

    init(_ conditions: [SearchCondition], now: Date = Date(), calendar: Calendar = .current) {
        var kinds: Set<SearchKind>?
        var fileExtensions: Set<String>?
        var link: Bool?
        var hidden: Bool?
        var above: Int64?
        var below: Int64?
        var sized = false
        var pixels: [SearchPixelRule] = []
        var excludedPixels: [SearchPixelRule] = []
        var dates: [(SearchDateField, SearchDateRule, SearchDateSpan, not: Bool)] = []
        var excludedSizes: [(above: Int64?, below: Int64?)] = []
        var attributes: [(SearchAttribute, Bool)] = []
        var tagGroups: [[String]] = []
        var excludedTags = Set<String>()
        var excludedKinds = Set<SearchKind>()
        var excludedExtensions = Set<String>()
        var modeGroups: [[SearchPermission]] = []
        var excludedModes: [SearchPermission] = []
        var skipped: [String] = []
        // `is:!hidden` is `not:hidden`: an attribute's not is its other value.
        let conditions = conditions.map { condition -> SearchCondition in
            if case .not(.attribute(let attribute, let value)) = condition { return .attribute(attribute, is: !value) }
            return condition
        }
        for condition in conditions where condition.asksForSomething {
            switch condition {
            case .not(.kind(let chosen)):
                excludedKinds.formUnion(chosen)
            case .not(.fileExtension(let chosen)):
                excludedExtensions.formUnion(chosen.map { $0.lowercased() })
            case .not(.tags(let chosen, _)):
                excludedTags.formUnion(chosen.map { $0.lowercased() })
            case .not(.permissions(let modes)):
                excludedModes += modes
            case .not(.pictureSize(let rule)):
                excludedPixels.append(rule)
            case .not(.size(let rule)):
                excludedSizes.append(rule.bounds)
            case .not(.date(let field, let rule)):
                dates.append((field, rule, rule.span(now: now, calendar: calendar), not: true))
            case .not:
                // The parser makes no other.
                continue
            case .permissions(let modes):
                modeGroups.append(modes)
            case .kind(let chosen):
                // Two Kind chips: an item of a kind both have.
                kinds = kinds.map { $0.intersection(chosen) } ?? chosen
            case .fileExtension(let chosen):
                let lowered = Set(chosen.map { $0.lowercased() })
                fileExtensions = fileExtensions.map { $0.intersection(lowered) } ?? lowered
            case .size(let rule):
                sized = true
                let bounds = rule.bounds
                if let low = bounds.above { above = max(above ?? low, low) }
                if let high = bounds.below { below = min(below ?? high, high) }
            case .pictureSize(let rule):
                pixels.append(rule)
            case .date(let field, let rule):
                dates.append((field, rule, rule.span(now: now, calendar: calendar), not: false))
            case .tags(let chosen, let all):
                let lowered = chosen.map { $0.lowercased() }
                tagGroups += all ? lowered.map { [$0] } : [lowered]
            case .attribute(.symbolicLink, let value):
                link = value
            case .attribute(.hidden, let value):
                hidden = value
            case .attribute(let attribute, let value):
                attributes.append((attribute, value))
            case .skipFolders(let names):
                skipped += names
            }
        }
        if let kinds {
            extensions = kinds.reduce(into: Set<String>()) { $0.formUnion($1.extensions) }
            plainFolders = kinds.contains(.folder)
            applications = kinds.contains(.application)
        } else {
            extensions = nil
            plainFolders = false
            applications = false
        }
        named = fileExtensions
        self.link = link
        self.hidden = hidden
        size = sized ? (above: above, below: below) : nil
        self.excludedSizes = excludedSizes
        self.pixels = pixels
        self.excludedPixels = excludedPixels
        self.dates = dates
        self.attributes = attributes
        self.tagGroups = tagGroups
        self.excludedTags = excludedTags
        self.excludedKinds = excludedKinds
        self.excludedExtensions = excludedExtensions
        self.modeGroups = modeGroups
        self.excludedModes = excludedModes
        if dates.contains(where: { $0.0 == .lastOpened }) {
            lastOpened = FileTimes.lastOpenedReader()
        } else {
            lastOpened = { _ in nil }
        }
        skippedFolders = skipped
        wantsHidden = hidden == true
        wantsLinks = link == true
        let permissions = !modeGroups.isEmpty || !excludedModes.isEmpty
        readsEachItem =
            sized || !excludedSizes.isEmpty || !pixels.isEmpty || !excludedPixels.isEmpty || !dates.isEmpty
            || !attributes.isEmpty
            || !tagGroups.isEmpty
            || !excludedTags.isEmpty || permissions
        needsStat =
            sized || !excludedSizes.isEmpty || permissions || dates.contains { $0.0 == .modified || $0.0 == .created }
            || attributes.contains { [.locked, .readOnly, .empty].contains($0.0) }
    }

    /// Whether there is anything to check.
    var isEmpty: Bool {
        extensions == nil && named == nil && link == nil && hidden == nil && !readsEachItem && excludedKinds.isEmpty
            && excludedExtensions.isEmpty
    }

    // MARK: From the folder's entry

    /// What the item's name and type tell, as it is matched: kind, extension, whether it is a link.
    func keepsByEntry(name: String, isFolder: Bool, isLink: Bool) -> Bool {
        if let link, link != isLink { return false }
        if extensions == nil && named == nil && excludedKinds.isEmpty && excludedExtensions.isEmpty { return true }
        let fileExtension = SearchResults.extensionOf(name)
        // A folder counts by its extension only as a package (Keynote's .key, .rtfd): a folder named "x.pdf" is no PDF.
        let package = isFolder && ItemNames.isPackageFolder(named: name) { SystemPackages.isPackageType(fileExtension) }
        let byExtension = !isFolder || package
        if let named, !(byExtension && named.contains(fileExtension)) { return false }
        if byExtension && excludedExtensions.contains(fileExtension) { return false }
        func isOf(_ extensions: Set<String>, folders: Bool, applications: Bool) -> Bool {
            (byExtension && extensions.contains(fileExtension)) || (folders && isFolder && !package)
                || (applications && isFolder && fileExtension == "app")
        }
        if let extensions, !isOf(extensions, folders: plainFolders, applications: applications) { return false }
        if !excludedKinds.isEmpty,
            isOf(
                excludedKinds.reduce(into: Set<String>()) { $0.formUnion($1.extensions) },
                folders: excludedKinds.contains(.folder), applications: excludedKinds.contains(.application))
        {
            return false
        }
        return true
    }

    // MARK: Read of the item

    /// What reading the item tells: run only for an item kept by its name and entry. `info` is the walk's own read
    /// of it (`needsStat`); it is read here only when a condition needs it and the walk didn't. Each check makes the
    /// calls it needs and no others, the cheapest first: what `info` holds, then a call each (can be run, writable,
    /// an alias, an empty folder, the date added, last opened, tags), then reading the file (the date taken, a
    /// picture's size).
    func keepsByItem(path: String, isFolder: Bool, isHidden: Bool, isLink: Bool = false, info given: stat? = nil)
        -> Bool
    {
        if let hidden, hidden != isHidden { return false }
        guard readsEachItem else { return true }
        var info = given
        if needsStat, info == nil {
            var read = stat()
            guard lstat(path, &read) == 0 else { return false }
            info = read
        }
        // The walk passes files, folders and links alone: what isn't a folder or a link is a file.
        let isFile = info.map { ($0.st_mode & S_IFMT) == S_IFREG } ?? (!isFolder && !isLink)
        if let size, let info {
            // Folders have no size of their own.
            guard isFile else { return false }
            if let above = size.above, info.st_size <= above { return false }
            if let below = size.below, info.st_size >= below { return false }
        }
        if !excludedSizes.isEmpty {
            // Not a size is still a file's: a folder has none to be or not to be.
            guard isFile, let info else { return false }
            for excluded in excludedSizes
            where (excluded.above.map { info.st_size > $0 } ?? true)
                && (excluded.below.map { info.st_size < $0 } ?? true)
            {
                return false
            }
        }
        // What the walk's read of the item holds, free.
        let locked = info.map { $0.st_flags & UInt32(UF_IMMUTABLE) != 0 } ?? false
        if !modeGroups.isEmpty || !excludedModes.isEmpty {
            guard let info else { return false }
            let mode = UInt16(info.st_mode) & 0o7777
            if !modeGroups.allSatisfy({ $0.contains { $0.holds(mode) } })
                || excludedModes.contains(where: { $0.holds(mode) })
            {
                return false
            }
        }
        for (field, rule, span, not) in dates where Self.cost(field) == 0 {
            guard let info else { return false }
            let time = field == .modified ? info.st_mtimespec : info.st_birthtimespec
            if Self.holds(Date(timeIntervalSince1970: Self.seconds(time)), rule, span) == not { return false }
        }
        for (attribute, value) in attributes where attribute == .locked || (attribute == .empty && !isFolder) {
            let has = attribute == .locked ? locked : (info?.st_size ?? 0) == 0
            if has != value { return false }
        }
        // One list of the item's attributes, for its tags and the date it was last opened: most items have neither,
        // and are told so without asking for either.
        let asksLastOpened = dates.contains { $0.0 == .lastOpened }
        let listed =
            !tagGroups.isEmpty || !excludedTags.isEmpty || asksLastOpened ? ExtendedAttributes.names(path) : nil
        if !tagGroups.isEmpty || !excludedTags.isEmpty {
            let stored = listed.map { $0.contains(FinderTags.attribute) } ?? true
            let tags = stored ? ((try? FinderTags.readListed(path)) ?? []) : []
            let held = Set(tags.map { $0.name.lowercased() })
            if !tagGroups.allSatisfy({ $0.contains(where: held.contains) }) { return false }
            if !excludedTags.isDisjoint(with: held) { return false }
        }
        for (_, rule, span, not) in dates.filter({ $0.0 == .lastOpened }) {
            let stored = listed.map { $0.contains(FileTimes.lastUsedAttribute) } ?? true
            let date = stored ? lastOpened(path).map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) } : nil
            if Self.holds(date, rule, span) == not { return false }
        }
        // A call each, the cheapest first: the date added, an alias, can be run and writable, an empty folder.
        for (_, rule, span, not) in dates.filter({ $0.0 == .added }) {
            let date = FileTimes.addedMs(path).map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) }
            if Self.holds(date, rule, span) == not { return false }
        }
        for (attribute, value) in attributes.sorted(by: { Self.cost($0.0) < Self.cost($1.0) })
        where Self.cost(attribute) > 0 && !(attribute == .empty && !isFolder) {
            let has: Bool
            switch attribute {
            case .alias: has = Links.isFinderAlias(path)
            case .executable: has = isFile && access(path, X_OK) == 0
            // A locked item can't be changed, whatever its permissions say.
            case .readOnly: has = locked || access(path, W_OK) != 0
            case .empty: has = Self.isEmptyFolder(path)
            case .locked, .hidden, .symbolicLink: continue
            }
            if has != value { return false }
        }
        // Last, what reading the file itself tells.
        for (field, rule, span, not) in dates where field == .taken {
            if Self.holds(isFile ? DatesTaken.takenDate(path) : nil, rule, span) == not { return false }
        }
        if !pixels.isEmpty || !excludedPixels.isEmpty {
            // Pictures alone have a size in pixels, a size not asked for too.
            guard isFile, let side = DatesTaken.longerSide(path), pixels.allSatisfy({ $0.holds(side) }),
                !excludedPixels.contains(where: { $0.holds(side) })
            else {
                return false
            }
        }
        return true
    }

    /// Whether a date read meets its rule: an item with no such date meets only a rule that takes none.
    private static func holds(_ date: Date?, _ rule: SearchDateRule, _ span: SearchDateSpan) -> Bool {
        guard let date else { return rule.takesNoDate }
        return span.contains(date)
    }

    /// What an attribute costs to tell, in its order: 0 from the walk's read of the item; then a call of its own, the
    /// cheapest first (measured: Finder's flags about 1.3 µs, `access` 8 µs, a folder opened 20 to 45 µs).
    private static func cost(_ attribute: SearchAttribute) -> Int {
        switch attribute {
        case .locked, .hidden, .symbolicLink: 0
        case .alias: 1
        case .executable, .readOnly: 2
        case .empty: 3
        }
    }

    private static func cost(_ field: SearchDateField) -> Int {
        switch field {
        case .modified, .created: 0
        case .added, .lastOpened: 1
        case .taken: 2
        }
    }

    private static func seconds(_ time: timespec) -> TimeInterval {
        TimeInterval(time.tv_sec) + TimeInterval(time.tv_nsec) / 1e9
    }

    /// A folder with nothing in it but Finder's own `.DS_Store`.
    private static func isEmptyFolder(_ path: String) -> Bool {
        guard let folder = opendir(path) else { return false }
        defer { closedir(folder) }
        while let entry = readdir(folder) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { bytes in
                String(decoding: bytes.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
            }
            if name != "." && name != ".." && name != ".DS_Store" { return false }
        }
        return true
    }
}
