// What a search's conditions ask of each item the walk passes, checked cheapest first: what its folder's entry tells
// (kind, extension, a link) as its name is matched, then, of what is still kept, one `lstat` (size, the modified and
// created dates, locked, read-only, can be run, empty), and last the reads that cost more (the date added and last
// opened, an alias, tags), each only for a search that asks for it, as "Nothing
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
    /// Each date asked about, and whether it is asked for not (`modified:!today`).
    private let dates: [(SearchDateField, SearchDateRule, SearchDateSpan, not: Bool)]
    /// Attributes asked of an item one by one, each to be so or not.
    private let attributes: [(SearchAttribute, Bool)]
    /// Attributes asked as a choice (`is:link,alias`): an item has one of each group, which are in the order they
    /// cost to tell, the cheapest first.
    private let eitherGroups: [[SearchAttribute]]
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

    /// Folders not gone into, by name: each name whole, compared as Plain Text compares (`NameMatcher`), so
    /// `skip:Node_Modules` leaves out `node_modules`, and a name typed with its accents the folder that has them,
    /// however the disk stores them.
    private let skippedFolders: [NameMatcher]
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
        var dates: [(SearchDateField, SearchDateRule, SearchDateSpan, not: Bool)] = []
        var excludedSizes: [(above: Int64?, below: Int64?)] = []
        var attributes: [(SearchAttribute, Bool)] = []
        var eitherGroups: [[SearchAttribute]] = []
        var tagGroups: [[String]] = []
        var excludedTags = Set<String>()
        var excludedKinds = Set<SearchKind>()
        var excludedExtensions = Set<String>()
        var modeGroups: [[SearchPermission]] = []
        var excludedModes: [SearchPermission] = []
        var skipped: [String] = []
        // `is:!hidden` is `not:hidden`: an attribute's not is its other value.
        let conditions = conditions.map { condition -> SearchCondition in
            if case .not(.attributes(let chosen, let value)) = condition { return .attributes(chosen, is: !value) }
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
            case .date(let field, let rule):
                dates.append((field, rule, rule.span(now: now, calendar: calendar), not: false))
            case .tags(let chosen, let all):
                let lowered = chosen.map { $0.lowercased() }
                tagGroups += all ? lowered.map { [$0] } : [lowered]
            case .attributes(let chosen, true) where chosen.count > 1:
                eitherGroups.append(chosen.sorted { Self.cost($0) < Self.cost($1) })
            case .attributes(let chosen, let value):
                // One attribute, or none of several (`not:hidden,locked`): each is asked on its own.
                for attribute in chosen {
                    switch attribute {
                    case .symbolicLink: link = value
                    case .hidden: hidden = value
                    default: attributes.append((attribute, value))
                    }
                }
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
        self.dates = dates
        self.attributes = attributes
        self.eitherGroups = eitherGroups
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
        skippedFolders = skipped.compactMap { NameMatcher($0, mode: .contains) }
        // A choice that hidden items or links can meet lists them, as the walk leaves them out otherwise.
        wantsHidden = hidden == true || (hidden == nil && eitherGroups.contains { $0.contains(.hidden) })
        wantsLinks = link == true || (link == nil && eitherGroups.contains { $0.contains(.symbolicLink) })
        let permissions = !modeGroups.isEmpty || !excludedModes.isEmpty
        let asked = attributes.map(\.0) + eitherGroups.joined()
        readsEachItem =
            sized || !excludedSizes.isEmpty || !dates.isEmpty
            || asked.contains { Self.cost($0) > Self.entryCost }
            || !tagGroups.isEmpty
            || !excludedTags.isEmpty || permissions
        needsStat =
            sized || !excludedSizes.isEmpty || permissions || dates.contains { $0.0 == .modified || $0.0 == .created }
            || asked.contains { [.locked, .readOnly, .empty].contains($0) }
    }

    /// Whether there is anything to check.
    var isEmpty: Bool {
        extensions == nil && named == nil && link == nil && hidden == nil && !readsEachItem && excludedKinds.isEmpty
            && excludedExtensions.isEmpty && attributes.isEmpty && eitherGroups.isEmpty
    }

    // MARK: From the folder's entry

    /// Whether a folder of this name, given as its bytes, is one the search leaves out.
    func skips(_ name: UnsafeBufferPointer<UInt8>) -> Bool {
        guard !skippedFolders.isEmpty else { return false }
        var text: String?
        for folder in skippedFolders {
            if let whole = folder.isWhole(asciiBytes: name) {
                if whole { return true }
                continue
            }
            let name = text ?? String(decoding: name, as: UTF8.self)
            text = name
            if folder.isWhole(name) { return true }
        }
        return false
    }

    /// What the item's name and type tell, as it is matched: kind, extension, whether it is a link, a file or a
    /// folder.
    func keepsByEntry(name: String, isFolder: Bool, isLink: Bool) -> Bool {
        if let link, link != isLink { return false }
        for (attribute, value) in attributes where attribute == .file || attribute == .folder {
            if Self.isOf(attribute, name: name, isFolder: isFolder, isLink: isLink) != value { return false }
        }
        // A choice the entry alone tells: `is:file,link`.
        for group in eitherGroups where group.allSatisfy({ Self.cost($0) == 0 && $0 != .hidden }) {
            guard group.contains(where: { Self.isOf($0, name: name, isFolder: isFolder, isLink: isLink) }) else {
                return false
            }
        }
        if extensions == nil && named == nil && excludedKinds.isEmpty && excludedExtensions.isEmpty { return true }
        let fileExtension = SearchResults.extensionOf(name)
        let package = isFolder && Self.isPackage(name)
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

    /// A folder counts by its extension only as a package (Keynote's .key, .rtfd): a folder named "x.pdf" is no
    /// PDF. As Finder shows one, a package is a file.
    private static func isPackage(_ name: String) -> Bool {
        ItemNames.isPackageFolder(named: name) { SystemPackages.isPackageType(SearchResults.extensionOf(name)) }
    }

    /// Whether an item is a file, a folder or a link, from its folder's entry: what `kind:folder` calls a folder
    /// (a package isn't one), and anything else that isn't a link is a file.
    private static func isOf(_ attribute: SearchAttribute, name: String, isFolder: Bool, isLink: Bool) -> Bool {
        switch attribute {
        case .symbolicLink: isLink
        case .folder: isFolder && !isPackage(name)
        case .file: !isLink && (!isFolder || isPackage(name))
        default: false
        }
    }

    // MARK: Read of the item

    /// What reading the item tells: run only for an item kept by its name and entry. `info` is the walk's own read
    /// of it (`needsStat`); it is read here only when a condition needs it and the walk didn't. Each check makes the
    /// calls it needs and no others, the cheapest first: what `info` holds, then a call each (can be run, writable,
    /// an alias, an empty folder, the date added, last opened, tags). Nothing opens a file to read what is in it.
    func keepsByItem(
        path: String, name: String? = nil, isFolder: Bool, isHidden: Bool, isLink: Bool = false, info given: stat? = nil
    ) -> Bool {
        if let hidden, hidden != isHidden { return false }
        // The choices the entry doesn't settle alone: those it says yes to are met, and what is left of the others is
        // asked as it comes, the cheapest first.
        let name = eitherGroups.isEmpty ? "" : name ?? (path as NSString).lastPathComponent
        var open: [[SearchAttribute]] = []
        for group in eitherGroups {
            let free = group.filter { Self.cost($0) == Self.entryCost }
            if free.contains(where: {
                $0 == .hidden ? isHidden : Self.isOf($0, name: name, isFolder: isFolder, isLink: isLink)
            }) {
                continue
            }
            let left = group.filter { Self.cost($0) > Self.entryCost }
            guard !left.isEmpty else { return false }
            open.append(left)
        }
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
        // One list of the item's attributes, for its tags and the date it was last opened: most items have neither,
        // and are told so without asking for either. Read once, when first needed.
        var listing: Set<String>??
        var heldTags: Set<String>?
        func held() -> Set<String> {
            if let heldTags { return heldTags }
            if listing == nil { listing = .some(ExtendedAttributes.names(path)) }
            let stored = listing.flatMap { $0 }.map { $0.contains(FinderTags.attribute) } ?? true
            let tags = stored ? ((try? FinderTags.readListed(path)) ?? []) : []
            let read = Set(tags.map { $0.name.lowercased() })
            heldTags = read
            return read
        }
        func has(_ attribute: SearchAttribute) -> Bool {
            switch attribute {
            case .hidden: isHidden
            case .symbolicLink, .file, .folder: Self.isOf(attribute, name: name, isFolder: isFolder, isLink: isLink)
            case .locked: locked
            case .tagged: !held().isEmpty
            case .alias: Links.isFinderAlias(path)
            case .executable: isFile && access(path, X_OK) == 0
            // A locked item can't be changed, whatever its permissions say.
            case .readOnly: locked || access(path, W_OK) != 0
            case .empty: isFolder ? Self.isEmptyFolder(path) : (info?.st_size ?? 0) == 0
            }
        }
        // Each choice not yet met, by what costs no more than `limit`: one met leaves, one with nothing left fails.
        func settle(upTo limit: Int) -> Bool {
            var left: [[SearchAttribute]] = []
            for group in open {
                if group.contains(where: { Self.cost($0, isFolder: isFolder) <= limit && has($0) }) { continue }
                let later = group.filter { Self.cost($0, isFolder: isFolder) > limit }
                if later.isEmpty { return false }
                left.append(later)
            }
            open = left
            return true
        }
        for (attribute, value) in attributes where Self.cost(attribute, isFolder: isFolder) == Self.statCost {
            if has(attribute) != value { return false }
        }
        if !settle(upTo: Self.statCost) { return false }
        let asksLastOpened = dates.contains { $0.0 == .lastOpened }
        if asksLastOpened { listing = .some(ExtendedAttributes.names(path)) }
        if !tagGroups.isEmpty || !excludedTags.isEmpty {
            let held = held()
            if !tagGroups.allSatisfy({ $0.contains(where: held.contains) }) { return false }
            if !excludedTags.isDisjoint(with: held) { return false }
        }
        for (attribute, value) in attributes where attribute == .tagged {
            if has(attribute) != value { return false }
        }
        if !settle(upTo: Self.cost(.tagged)) { return false }
        let listed = listing.flatMap { $0 }
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
        where Self.cost(attribute, isFolder: isFolder) > Self.cost(.tagged) {
            if has(attribute) != value { return false }
        }
        return settle(upTo: Int.max)
    }

    /// Whether a date read meets its rule: an item with no such date meets only a rule that takes none.
    private static func holds(_ date: Date?, _ rule: SearchDateRule, _ span: SearchDateSpan) -> Bool {
        guard let date else { return rule.takesNoDate }
        return span.contains(date)
    }

    /// What an attribute costs to tell, in its order: nothing, from the folder's entry (a link, a file, a folder) or
    /// the walk (hidden); the walk's read of the item (locked); the list of its attributes (tagged); then a call of its
    /// own, the cheapest first (measured: Finder's flags about 1.3 µs, `access` 8 µs, a folder opened 20 to 45 µs).
    /// A file is empty by its size, read with the item; a folder by being opened.
    private static func cost(_ attribute: SearchAttribute, isFolder: Bool? = nil) -> Int {
        switch attribute {
        case .hidden, .symbolicLink, .file, .folder: entryCost
        case .locked: statCost
        case .empty where isFolder == false: statCost
        case .tagged: 2
        case .alias: 3
        case .executable, .readOnly: 4
        case .empty: 5
        }
    }

    private static let entryCost = 0
    private static let statCost = 1

    private static func cost(_ field: SearchDateField) -> Int {
        switch field {
        case .modified, .created: 0
        case .added, .lastOpened: 1
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
