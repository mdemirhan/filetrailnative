// What a search's conditions ask of each item the walk passes, checked cheapest first: what its folder's entry tells
// (kind, extension, a link, a file or a folder) as its name is matched, then, of what is still kept, the `lstat` the
// walk makes (size, the modified and created dates, permissions, locked, owner, only in the cloud, a file's emptiness),
// then Finder's flags (an alias, broken), the date added, one list of the item's attribute names (downloaded, then
// tags and their colors, last opened and where from, read only of an item that has them), `access`, and last a
// folder opened (empty), each only for a search that asks for it, as "Nothing is read before it is needed" allows:
// the search asks for it.
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
    /// An item's owner is one of each group (`owner:root,me`), and none of `excludedOwners`. A name no user has is
    /// no one: its group keeps nothing.
    private let ownerGroups: [Set<uid_t>]
    private let excludedOwners: Set<uid_t>
    /// Finder's numbers of tag colors: an item has a tag of a color of each group, and none of `excludedColors`.
    private let colorGroups: [Set<Int>]
    private let excludedColors: Set<Int>
    /// Lowercased: an address the item was downloaded from holds one of each group, and none of `excludedPlaces`.
    private let placeGroups: [[String]]
    private let excludedPlaces: [String]
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
        var ownerGroups: [Set<uid_t>] = []
        var excludedOwners = Set<uid_t>()
        var colorGroups: [Set<Int>] = []
        var excludedColors = Set<Int>()
        var placeGroups: [[String]] = []
        var excludedPlaces: [String] = []
        var skipped: [String] = []
        func users(_ names: [String]) -> Set<uid_t> { Set(names.compactMap(SearchQuery.ownerID)) }
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
            case .not(.owners(let names)):
                excludedOwners.formUnion(users(names))
            case .not(.tagColors(let colors)):
                excludedColors.formUnion(colors.map(\.finderNumber))
            case .not(.downloadedFrom(let places)):
                excludedPlaces += places.map { $0.lowercased() }
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
            case .owners(let names):
                ownerGroups.append(users(names))
            case .tagColors(let colors):
                colorGroups.append(Set(colors.map(\.finderNumber)))
            case .downloadedFrom(let places):
                placeGroups.append(places.map { $0.lowercased() })
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
        self.ownerGroups = ownerGroups
        self.excludedOwners = excludedOwners
        self.colorGroups = colorGroups
        self.excludedColors = excludedColors
        self.placeGroups = placeGroups
        self.excludedPlaces = excludedPlaces
        if dates.contains(where: { $0.0 == .lastOpened }) {
            lastOpened = FileTimes.lastOpenedReader()
        } else {
            lastOpened = { _ in nil }
        }
        skippedFolders = skipped.compactMap { NameMatcher($0, mode: .contains) }
        // A choice that hidden items or links can meet lists them, as the walk leaves them out otherwise; so does
        // asking for what is broken, which a link can be.
        let brokenAsked =
            attributes.contains { $0 == (.broken, true) } || eitherGroups.contains { $0.contains(.broken) }
        wantsHidden = hidden == true || (hidden == nil && eitherGroups.contains { $0.contains(.hidden) })
        wantsLinks =
            link == true || (link == nil && (eitherGroups.contains { $0.contains(.symbolicLink) } || brokenAsked))
        let permissions = !modeGroups.isEmpty || !excludedModes.isEmpty
        let owners = !ownerGroups.isEmpty || !excludedOwners.isEmpty
        let asked = attributes.map(\.0) + eitherGroups.joined()
        readsEachItem =
            sized || !excludedSizes.isEmpty || !dates.isEmpty
            || asked.contains { Self.cost($0) > Self.entryCost }
            || !tagGroups.isEmpty || !excludedTags.isEmpty || !colorGroups.isEmpty || !excludedColors.isEmpty
            || !placeGroups.isEmpty || !excludedPlaces.isEmpty || permissions || owners
        needsStat =
            sized || !excludedSizes.isEmpty || permissions || owners
            || dates.contains { $0.0 == .modified || $0.0 == .created }
            || asked.contains { [.locked, .readOnly, .empty, .cloud].contains($0) }
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
    /// calls it needs and no others, the cheapest first, so that an item one check leaves out is asked nothing that
    /// costs more: what `info` holds; Finder's flags (an alias, broken); the date added; the list of attribute names
    /// and what it tells alone (downloaded), then the reads of the tags, the date last opened and where from, each
    /// only of an item that has it; `access` to run, then to write; a folder opened (empty). Nothing opens a file to
    /// read what is in it.
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
        if !ownerGroups.isEmpty || !excludedOwners.isEmpty {
            guard let info else { return false }
            if !ownerGroups.allSatisfy({ $0.contains(info.st_uid) }) || excludedOwners.contains(info.st_uid) {
                return false
            }
        }
        // One list of the item's attributes, for its tags, where it was downloaded from and the date it was last
        // opened: most items have none of them, and are told so without asking for any. Read once, when first needed.
        var listing: Set<String>??
        func listed() -> Set<String>? {
            if let listing { return listing }
            let names = ExtendedAttributes.names(path)
            listing = .some(names)
            return names
        }
        /// Whether the list has `attribute`; true when there was no list, so that the attribute is asked for.
        func mayHave(_ attribute: String) -> Bool { listed().map { $0.contains(attribute) } ?? true }
        var heldTags: [FinderTag]?
        func held() -> [FinderTag] {
            if let heldTags { return heldTags }
            let tags = mayHave(FinderTags.attribute) ? ((try? FinderTags.readListed(path)) ?? []) : []
            heldTags = tags
            return tags
        }
        func has(_ attribute: SearchAttribute) -> Bool {
            switch attribute {
            case .hidden: isHidden
            case .symbolicLink, .file, .folder: Self.isOf(attribute, name: name, isFolder: isFolder, isLink: isLink)
            case .locked: locked
            // Its data not on this Mac: only a placeholder until it is opened, which this doesn't do.
            case .cloud: info.map { $0.st_flags & UInt32(SF_DATALESS) != 0 } ?? false
            case .tagged: !held().isEmpty
            case .downloaded:
                listed().map { $0.contains(DownloadMarks.quarantine) } ?? DownloadMarks.isQuarantined(path)
            case .alias: Links.isFinderAlias(path)
            case .executable: isFile && access(path, X_OK) == 0
            // A locked item can't be changed, whatever its permissions say.
            case .readOnly: locked || access(path, W_OK) != 0
            case .broken: !isFolder && Links.isBroken(path, isLink: isLink)
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
        /// The attributes asked one by one that cost `tier`, then what is left of each choice up to it.
        func passes(_ tier: Int) -> Bool {
            for (attribute, value) in attributes where Self.cost(attribute, isFolder: isFolder) == tier {
                if has(attribute) != value { return false }
            }
            return settle(upTo: tier)
        }
        // Each tier costs more than the one before it, so what costs most is asked of the fewest items.
        guard passes(Self.statCost) else { return false }
        // Finder's flag, one call: an alias, and for most items broken, which follows a link or resolves an alias
        // only for one.
        guard passes(Self.flagCost), passes(Self.brokenCost) else { return false }
        for (_, rule, span, not) in dates.filter({ $0.0 == .added }) {
            let date = FileTimes.addedMs(path).map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) }
            if Self.holds(date, rule, span) == not { return false }
        }
        // The list of the item's attribute names: what it tells alone, then the reads of what it holds, the cheapest
        // first, each only of an item that has it.
        guard passes(Self.listCost) else { return false }
        if !tagGroups.isEmpty || !excludedTags.isEmpty {
            let names = Set(held().map { $0.name.lowercased() })
            if !tagGroups.allSatisfy({ $0.contains(where: names.contains) }) { return false }
            if !excludedTags.isDisjoint(with: names) { return false }
        }
        if !colorGroups.isEmpty || !excludedColors.isEmpty {
            let colors = Set(held().compactMap { $0.color?.rawValue })
            if !colorGroups.allSatisfy({ !$0.isDisjoint(with: colors) }) { return false }
            if !excludedColors.isDisjoint(with: colors) { return false }
        }
        guard passes(Self.tagsCost) else { return false }
        for (_, rule, span, not) in dates.filter({ $0.0 == .lastOpened }) {
            let date =
                mayHave(FileTimes.lastUsedAttribute)
                ? lastOpened(path).map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) } : nil
            if Self.holds(date, rule, span) == not { return false }
        }
        if !placeGroups.isEmpty || !excludedPlaces.isEmpty {
            let places = mayHave(DownloadMarks.whereFrom) ? DownloadMarks.whereFroms(path).map { $0.lowercased() } : []
            func from(_ part: String) -> Bool { places.contains { $0.contains(part) } }
            if !placeGroups.allSatisfy({ $0.contains(where: from) }) { return false }
            if excludedPlaces.contains(where: from) { return false }
        }
        // A call each: can be run, writable, an empty folder.
        return passes(Self.runCost) && passes(Self.writeCost) && passes(Self.folderCost)
    }

    /// Whether a date read meets its rule: an item with no such date meets only a rule that takes none.
    private static func holds(_ date: Date?, _ rule: SearchDateRule, _ span: SearchDateSpan) -> Bool {
        guard let date else { return rule.takesNoDate }
        return span.contains(date)
    }

    /// What an attribute costs to tell, as a tier asked after the cheaper ones (measured warm, on an M-series Mac):
    /// nothing, from the folder's entry (a link, a file, a folder) or the walk (hidden); the walk's own read of the
    /// item (locked, only in the cloud, a file's emptiness); Finder's flags, about 2 µs (an alias); broken, the same
    /// for nearly every item, a link followed (about 2 µs) or an alias resolved (about 90) only for one; then, after
    /// the date added (about 3 µs), the list of attribute names, about 3.5 µs (downloaded), and a read of the tags of
    /// an item that has them, about 12 (tagged); `access` to run, about 6, and to write, 9 to 11; a folder opened, 17
    /// to 63.
    private static func cost(_ attribute: SearchAttribute, isFolder: Bool? = nil) -> Int {
        switch attribute {
        case .hidden, .symbolicLink, .file, .folder: entryCost
        case .locked, .cloud: statCost
        case .empty where isFolder == false: statCost
        case .alias: flagCost
        case .broken: brokenCost
        case .downloaded: listCost
        case .tagged: tagsCost
        case .executable: runCost
        case .readOnly: writeCost
        case .empty: folderCost
        }
    }

    private static let entryCost = 0
    private static let statCost = 1
    private static let flagCost = 2
    private static let brokenCost = 3
    private static let listCost = 4
    private static let tagsCost = 5
    private static let runCost = 6
    private static let writeCost = 7
    private static let folderCost = 8

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
