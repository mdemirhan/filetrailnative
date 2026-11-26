import Foundation

/// A volume's capacity and free space.
public struct InfoVolume: Equatable, Sendable {
    public var totalBytes: Int64?
    public var availableBytes: Int64?

    public init(totalBytes: Int64?, availableBytes: Int64?) {
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
    }
}

/// Several selected items.
public struct InfoSelection: Equatable, Sendable {
    public var count: Int
    public var folderCount: Int
    public var fileCount: Int
    public var totalBytes: Int64?
    public var parentPath: String?

    public init(count: Int, folderCount: Int, fileCount: Int, totalBytes: Int64?, parentPath: String?) {
        self.count = count
        self.folderCount = folderCount
        self.fileCount = fileCount
        self.totalBytes = totalBytes
        self.parentPath = parentPath
    }
}

/// What a row of the Information section holds.
public enum InfoValue: Equatable, Sendable {
    case text(String)
    /// The folder size cell.
    case folderSize
    /// "Owner: Read & Write" and the octal code, whose tooltip is the nine letters.
    case permissions(words: String, octal: String, symbolic: String)
    /// The folder an item is in, its folders from the top of its disk, as text on one line cut at its start, so the
    /// folder it is in stays; it can be selected. Its copy button copies the row's `copyText`, the item's own path.
    case place(String)
    /// A link's or an alias's original: clicked, Show Original.
    case originalLink(label: String, path: String)
    /// The app the file opens in, as a pop-up.
    case opensWith
    /// The items' tags: clicked, the Tags popover.
    case tags(InfoTags)
    /// A text on one line, replaced by the first of the shorter ones that fits where it doesn't ("3 kinds"), the last
    /// cut short at its end. Its tooltip is the row's `copyText`, else the whole text.
    case fitting(full: String, shorter: [String])
    /// How full a disk is: a bar, and the text under it.
    case usage(fraction: Double, text: String)
    /// Who the owner or the group is and what it may do, on one line that shortens to fit
    /// (`InfoText.access`): "demo (you) · Read & Write", "demo (you) · rw", "de… (you) · rw". No name until it is read.
    case access(name: String?, isYou: Bool, words: String, letters: String)
}

/// A tag of the items the Info panel describes.
public struct InfoTag: Equatable, Sendable {
    public var name: String
    /// Finder's number of its color (1 gray to 7 orange); nil for a tag without one.
    public var colorNumber: Int?
    /// How many of the items have it.
    public var count: Int

    public init(name: String, colorNumber: Int?, count: Int) {
        self.name = name
        self.colorNumber = colorNumber
        self.count = count
    }
}

/// The tags of the item or the items the Info panel describes.
public struct InfoTags: Equatable, Sendable {
    public var tags: [InfoTag]
    public var itemCount: Int
    /// Whether a click opens the Tags popover: not for what is in the Trash, nor the disk or folder on screen.
    public var editable: Bool

    public init(tags: [InfoTag], itemCount: Int, editable: Bool) {
        self.tags = tags
        self.itemCount = itemCount
        self.editable = editable
    }

    /// The row's text where no chip shows it: its tags' names, those on some of the items with how many.
    public var summary: String {
        tags.map { $0.count < itemCount ? "\($0.name) (\($0.count))" : $0.name }.joined(separator: ", ")
    }
}

/// Whether the Info panel has a Tags row, and what it says.
public enum InfoTagsState: Equatable, Sendable {
    /// No row: more items than are read for it.
    case hidden
    /// A dash until they are read.
    case pending
    case read(InfoTags)

    /// The row, if there is one.
    var row: InfoRow? {
        switch self {
        case .hidden: nil
        case .pending: InfoRow(label: "Tags", value: .text(InfoPanelModel.pending), muted: true)
        case .read(let tags): InfoRow(label: "Tags", value: .tags(tags), muted: tags.tags.isEmpty)
        }
    }
}

public struct InfoRow: Equatable, Sendable {
    public var label: String
    public var value: InfoValue
    public var muted: Bool
    /// What the row's right-click Copy copies, where it isn't the value's text (the whole path of Where).
    public var copyText: String?
    /// What its tooltip says, where it isn't the value's text (an attribute's own names).
    public var tooltip: String?
    /// Its text takes as many lines as it needs. Every other value is one line, its whole text in its tooltip and
    /// there to select, so no row grows as its value comes in.
    public var wraps = false

    public init(label: String, value: InfoValue, muted: Bool, copyText: String? = nil) {
        self.label = label
        self.value = value
        self.muted = muted
        self.copyText = copyText
    }

    /// The text the row's Copy copies.
    public var textToCopy: String {
        if let copyText { return copyText }
        switch value {
        case .text(let text): return text
        case .permissions(let words, let octal, _): return "\(words) \(octal)"
        case .place(let label), .originalLink(let label, _): return label
        case .tags(let tags): return tags.summary
        case .fitting(let full, _): return full
        case .usage(_, let text): return text
        case .access(let name, let isYou, let words, _): return InfoText.access(name, isYou: isYou, words)
        case .folderSize, .opensWith: return ""
        }
    }
}

public enum InfoPanelModel {
    public static let pending = "—"

    /// "3 folders and 2 files", "4 files".
    public static func describeSelectionKinds(_ selection: InfoSelection) -> String {
        func count(_ value: Int, _ one: String, _ many: String) -> String {
            "\(FormatLocale.count(value)) \(value == 1 ? one : many)"
        }
        var parts: [String] = []
        if selection.folderCount > 0 { parts.append(count(selection.folderCount, "folder", "folders")) }
        if selection.fileCount > 0 { parts.append(count(selection.fileCount, "file", "files")) }
        return parts.joined(separator: " and ")
    }

    public static func selectionSubtitle(_ selection: InfoSelection) -> String {
        let kinds = describeSelectionKinds(selection)
        guard let total = selection.totalBytes else { return kinds }
        return "\(kinds) · \(SizeText.size(total))"
    }

    public static func selectionName(_ selection: InfoSelection) -> String {
        "\(FormatLocale.count(selection.count)) items"
    }

    /// "folders", "files" or "mixed": which two icons the stack shows.
    public static func selectionContains(_ selection: InfoSelection) -> String {
        selection.fileCount == 0 ? "folders" : selection.folderCount == 0 ? "files" : "mixed"
    }

    /// "2 files, 1 folder", once the folder has been measured.
    static func measuredContents(_ entry: FolderSizeEntry?) -> String? {
        guard case .ready(let size, let disk, let files, let folders)? = entry else { return nil }
        return folderSizeLines(sizeBytes: size, diskBytes: disk, fileCount: files, folderCount: folders).items
    }

    /// What a folder holds, a dash until it has been measured.
    static func containsRow(_ entry: FolderSizeEntry?) -> InfoRow {
        let contents = measuredContents(entry)
        return InfoRow(label: "Contains", value: .text(contents ?? pending), muted: contents == nil)
    }

    public static func parentPath(_ path: String) -> String? {
        var trimmed = path
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard !trimmed.isEmpty, let slash = trimmed.lastIndex(of: "/") else { return nil }
        let index = trimmed.distance(from: trimmed.startIndex, to: slash)
        return index == 0 ? "/" : String(trimmed.prefix(index))
    }

    public enum OpensWithState: Equatable, Sendable {
        case hidden, pending, available
    }

    /// "<size> (<disk> on disk)" and "N files, M folders".
    public static func folderSizeLines(
        sizeBytes: Int64, diskBytes: Int64, fileCount: Int, folderCount: Int, locale: Locale = FormatLocale.current
    ) -> (top: String, items: String) {
        let detail = SizeText.folderDetail(
            sizeBytes: sizeBytes, diskBytes: diskBytes, fileCount: fileCount, folderCount: folderCount, locale: locale)
        return ("\(detail.size) (\(detail.disk))", detail.items)
    }
}
