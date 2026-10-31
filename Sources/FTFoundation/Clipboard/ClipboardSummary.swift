// Port of the listing parts of apps/desktop/src/renderer/lib/copyPasteClipboard.ts (listClipboardItems,
// describeClipboard, groupClipboardItemsByFolder) and of components/ClipboardItemsIcon.tsx
import Foundation

/// An item as the file list would describe it, for its icon (`DirectoryEntry`).
public struct ClipboardItemEntry: Equatable, Sendable {
    public var path: String
    public var name: String
    public var fileExtension: String
    public var kind: EntryKind
    public var isHidden: Bool
    public var isSymlink: Bool
    public var isExecutable: Bool?

    public init(
        path: String, name: String, fileExtension: String, kind: EntryKind, isHidden: Bool, isSymlink: Bool,
        isExecutable: Bool? = nil
    ) {
        self.path = path
        self.name = name
        self.fileExtension = fileExtension
        self.kind = kind
        self.isHidden = isHidden
        self.isSymlink = isSymlink
        self.isExecutable = isExecutable
    }

    /// The plain folder and the plain document the file list draws (`ClipboardItemsIcon`).
    public static let genericFolder = ClipboardItemEntry(
        path: "/folder", name: "folder", fileExtension: "", kind: .directory, isHidden: false, isSymlink: false)
    public static let genericFile = ClipboardItemEntry(
        path: "/file", name: "file", fileExtension: "", kind: .file, isHidden: false, isSymlink: false,
        isExecutable: false)
}

/// One item on the clipboard (`ClipboardItem`).
public struct ClipboardItem: Equatable, Sendable {
    public var path: String
    public var name: String
    /// The folder the item is in.
    public var parentPath: String
    public var entry: ClipboardItemEntry
    /// Nil when the item was copied without saying what it is.
    public var isFolder: Bool?
}

/// The icon that stands for what is on the clipboard: the item's own for one item, a pair of generic ones for several.
public enum ClipboardIcon: Equatable, Sendable {
    public enum Contents: String, Sendable {
        case files, folders, mixed
    }

    case item(ClipboardItemEntry)
    case items(Contents)

    /// The two icons of several items, back then front (`ClipboardItemsIcon`): folders, files, or a folder behind a
    /// file.
    public static func pair(_ contents: Contents) -> (back: ClipboardItemEntry, front: ClipboardItemEntry) {
        (
            contents == .files ? .genericFile : .genericFolder,
            contents == .folders ? .genericFolder : .genericFile
        )
    }
}

/// What the window says about the clipboard while it holds files (`ClipboardSummary`).
public struct ClipboardSummary: Equatable, Sendable {
    public var mode: ClipboardMode
    public var count: Int
    /// "3 items copied", "1 item cut".
    public var countLabel: String
    /// One item is called by its name ("notes.md copied"); several are counted.
    public var label: String
    /// "3 folders and 342 files": only for several items whose kinds are all known.
    public var breakdown: String?
    public var icon: ClipboardIcon
    public var items: [ClipboardItem]

    /// The button's accessible name.
    public var accessibilityLabel: String { "Clipboard: \(countLabel)" }

    /// The count as the button shows it, with en-US grouping ("1,234").
    public var countText: String { Self.grouped(count) }

    static func grouped(_ value: Int) -> String {
        let digits = Array(String(value.magnitude))
        var out = ""
        for (index, digit) in digits.enumerated() {
            if index > 0, (digits.count - index) % 3 == 0 { out.append(",") }
            out.append(digit)
        }
        return value < 0 ? "-" + out : out
    }
}

/// The items under the folder each came from (`ClipboardItemGroup`).
public struct ClipboardItemGroup: Equatable, Sendable {
    public var parentPath: String
    /// The folder's name ("/" for the root).
    public var label: String
    public var items: [ClipboardItem]
}

extension ClipboardRules {
    /// `listClipboardItems`.
    public static func items(_ clipboard: CopyPasteClipboard) -> [ClipboardItem] {
        guard case .ready(_, let paths, let entries, _) = clipboard else { return [] }
        return paths.map { path in
            let name = PathText.leafName(path)
            let known = entries[path]
            let isFolder = known.map { $0.kind == .directory || $0.kind == .symlinkDirectory }
            return ClipboardItem(
                path: path, name: name, parentPath: parentPath(path),
                entry: ClipboardItemEntry(
                    path: path, name: name, fileExtension: isFolder == true ? "" : nameExtension(name),
                    // An item of unknown kind is drawn with the icon macOS has for its path.
                    kind: known?.kind ?? .other, isHidden: JSString.hasPrefix(name, "."),
                    isSymlink: known?.isSymlink ?? false, isExecutable: known?.isExecutable),
                isFolder: isFolder)
        }
    }

    /// `describeClipboard`: nil while the clipboard is empty.
    public static func describe(_ clipboard: CopyPasteClipboard) -> ClipboardSummary? {
        let items = items(clipboard)
        guard case .ready(let mode, _, _, _) = clipboard, let first = items.first else { return nil }
        let count = items.count
        let verb = mode == .cut ? "cut" : "copied"
        let countLabel = "\(pluralize(count, "item")) \(verb)"
        let folders = items.filter { $0.isFolder == true }.count
        let files = items.filter { $0.isFolder == false }.count
        let kindsKnown = folders + files == count
        var parts: [String] = []
        if folders > 0 { parts.append(pluralize(folders, "folder")) }
        if files > 0 { parts.append(pluralize(files, "file")) }
        let icon: ClipboardIcon =
            count == 1
            ? .item(first.entry)
            : .items(kindsKnown && files == 0 ? .folders : kindsKnown && folders == 0 ? .files : .mixed)
        return ClipboardSummary(
            mode: mode, count: count, countLabel: countLabel, label: count == 1 ? "\(first.name) \(verb)" : countLabel,
            breakdown: count > 1 && kindsKnown ? parts.joined(separator: " and ") : nil, icon: icon, items: items)
    }

    /// `groupClipboardItemsByFolder`: in the order the folders first appear.
    public static func groupByFolder(_ items: [ClipboardItem]) -> [ClipboardItemGroup] {
        var groups: [ClipboardItemGroup] = []
        var positions: [ExactKey: Int] = [:]
        for item in items {
            let key = ExactKey(item.parentPath)
            if let position = positions[key] {
                groups[position].items.append(item)
                continue
            }
            positions[key] = groups.count
            groups.append(
                ClipboardItemGroup(
                    parentPath: item.parentPath,
                    label: JSString.equals(item.parentPath, "/") ? "/" : PathText.leafName(item.parentPath),
                    items: [item]))
        }
        return groups
    }

    private static func pluralize(_ count: Int, _ singular: String) -> String {
        "\(count) \(singular)\(count == 1 ? "" : "s")"
    }

    /// `getNameExtension`.
    private static func nameExtension(_ name: String) -> String {
        let units = Array(name.utf16)
        guard let dot = JSString.lastIndex(of: 0x2E, in: units), dot > 0 else { return "" }
        return JSString.lowercased(JSString.string(units[(dot + 1)...]))
    }

    /// `getParentPath`: the folder of a path without its trailing slashes; "/" at the top.
    public static func parentPath(_ path: String) -> String {
        var units = Array(path.utf16)
        while units.last == 0x2F { units.removeLast() }
        guard let slash = JSString.lastIndex(of: 0x2F, in: units), slash > 0 else { return "/" }
        return JSString.string(units[..<slash])
    }
}
