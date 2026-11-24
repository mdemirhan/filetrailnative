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
    private let pixels: [SearchPixelRule]
    private let dates: [(SearchDateField, SearchDateRule, SearchDateSpan)]
    private let attributes: [(SearchAttribute, Bool)]
    /// Lowercased; with `allTags`, every one.
    private let tags: [String]
    private let allTags: Bool
    private let lastOpened: @Sendable (String) -> Int64?

    /// Folders not gone into, by name.
    let skippedFolders: [String]
    /// Whether the search must list hidden items for its conditions.
    let wantsHidden: Bool
    /// Whether it must list symbolic links.
    let wantsLinks: Bool
    /// Whether an item kept by its name is read further.
    let readsEachItem: Bool

    init(_ conditions: [SearchCondition], now: Date = Date(), calendar: Calendar = .current) {
        var kinds: Set<SearchKind>?
        var fileExtensions: Set<String>?
        var link: Bool?
        var hidden: Bool?
        var above: Int64?
        var below: Int64?
        var sized = false
        var pixels: [SearchPixelRule] = []
        var dates: [(SearchDateField, SearchDateRule, SearchDateSpan)] = []
        var attributes: [(SearchAttribute, Bool)] = []
        var tags: [String] = []
        var allTags = false
        var skipped: [String] = []
        for condition in conditions where condition.asksForSomething {
            switch condition {
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
                dates.append((field, rule, rule.span(now: now, calendar: calendar)))
            case .tags(let chosen, let all):
                tags += chosen.map { $0.lowercased() }
                allTags = allTags || all
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
        self.pixels = pixels
        self.dates = dates
        self.attributes = attributes
        self.tags = tags
        self.allTags = allTags
        if dates.contains(where: { $0.0 == .lastOpened }) {
            lastOpened = FileTimes.lastOpenedReader()
        } else {
            lastOpened = { _ in nil }
        }
        skippedFolders = skipped
        wantsHidden = hidden == true
        wantsLinks = link == true
        readsEachItem = sized || !pixels.isEmpty || !dates.isEmpty || !attributes.isEmpty || !tags.isEmpty
    }

    /// Whether there is anything to check.
    var isEmpty: Bool {
        extensions == nil && named == nil && link == nil && hidden == nil && !readsEachItem
    }

    // MARK: From the folder's entry

    /// What the item's name and type tell, as it is matched: kind, extension, whether it is a link.
    func keepsByEntry(name: String, isFolder: Bool, isLink: Bool) -> Bool {
        if let link, link != isLink { return false }
        if extensions == nil && named == nil { return true }
        let fileExtension = SearchResults.extensionOf(name)
        // A folder counts by its extension only as a package (Keynote's .key, .rtfd): a folder named "x.pdf" is no PDF.
        let package = isFolder && ItemNames.isPackageFolder(named: name) { SystemPackages.isPackageType(fileExtension) }
        let byExtension = !isFolder || package
        if let named, !(byExtension && named.contains(fileExtension)) { return false }
        if let extensions {
            let ofKind =
                (byExtension && extensions.contains(fileExtension)) || (plainFolders && isFolder && !package)
                || (applications && isFolder && fileExtension == "app")
            if !ofKind { return false }
        }
        return true
    }

    // MARK: Read of the item

    /// What reading the item tells: run only for an item kept by its name and entry.
    func keepsByItem(path: String, isFolder: Bool, isHidden: Bool) -> Bool {
        if let hidden, hidden != isHidden { return false }
        guard readsEachItem else { return true }
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        let isFile = (info.st_mode & S_IFMT) == S_IFREG
        if let size {
            // Folders have no size of their own.
            guard isFile else { return false }
            if let above = size.above, info.st_size <= above { return false }
            if let below = size.below, info.st_size >= below { return false }
        }
        let locked = info.st_flags & UInt32(UF_IMMUTABLE) != 0
        for (attribute, value) in attributes {
            let has: Bool
            switch attribute {
            case .executable: has = isFile && access(path, X_OK) == 0
            // A locked item can't be changed, whatever its permissions say.
            case .readOnly: has = locked || access(path, W_OK) != 0
            case .locked: has = locked
            case .empty: has = isFolder ? Self.isEmptyFolder(path) : info.st_size == 0
            case .alias: has = Links.isFinderAlias(path)
            case .hidden, .symbolicLink: continue
            }
            if has != value { return false }
        }
        // The dates the stat has first, then those that cost a read.
        for (field, rule, span) in dates.sorted(by: { Self.cost($0.0) < Self.cost($1.0) }) {
            let date: Date?
            switch field {
            case .modified: date = Date(timeIntervalSince1970: Self.seconds(info.st_mtimespec))
            case .created: date = Date(timeIntervalSince1970: Self.seconds(info.st_birthtimespec))
            case .added: date = FileTimes.addedMs(path).map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) }
            case .lastOpened: date = lastOpened(path).map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) }
            case .taken: date = isFile ? DatesTaken.takenDate(path) : nil
            }
            if let date {
                if !span.contains(date) { return false }
            } else if !rule.takesNoDate {
                return false
            }
        }
        if !tags.isEmpty {
            let held = Set(((try? FinderTags.read(path)) ?? []).map { $0.name.lowercased() })
            let found = allTags ? tags.allSatisfy(held.contains) : tags.contains(where: held.contains)
            if !found { return false }
        }
        if !pixels.isEmpty {
            // Pictures alone have a size in pixels.
            guard isFile, let side = DatesTaken.longerSide(path), pixels.allSatisfy({ $0.holds(side) }) else {
                return false
            }
        }
        return true
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
