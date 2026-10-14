// Port of what apps/desktop/src/renderer/components/GetInfoPanel.tsx and InfoRow.tsx decide to show, apart from how it is drawn
import Foundation

/// A volume's capacity and free space (`InfoPanelVolume`).
public struct InfoVolume: Equatable, Sendable {
    public var totalBytes: Int64?
    public var availableBytes: Int64?

    public init(totalBytes: Int64?, availableBytes: Int64?) {
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
    }
}

/// Several selected items (`InfoPanelSelection`).
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
    /// "Read & Write" and the octal code, whose tooltip is the nine letters.
    case permissions(words: String, octal: String, symbolic: String)
    /// A folder as a link; nil path is not shown as one.
    case whereLink(label: String, path: String)
    /// The app the file opens in, as a pop-up.
    case opensWith
}

public struct InfoRow: Equatable, Sendable {
    public var label: String
    public var value: InfoValue
    public var muted: Bool
}

/// The locale the original formats numbers and dates in: its language alone (Chromium reads the system's languages, not its
/// region), so "48,611 files" and "Sep 17, 2026, 2:08 PM" on a machine set to a European region.
public enum InfoLocale {
    public static let original: Locale = {
        let language = Locale.preferredLanguages.first.flatMap { Locale(identifier: $0).language.languageCode?.identifier } ?? "en"
        return Locale(identifier: language)
    }()
}

public enum InfoPanelModel {
    public static let pending = "—"

    /// `toLocaleString()`: thousands separators.
    static func integer(_ value: Int, locale: Locale = InfoLocale.original) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    /// "3 folders and 2 files", "4 files".
    public static func describeSelectionKinds(_ selection: InfoSelection) -> String {
        func count(_ value: Int, _ one: String, _ many: String) -> String {
            "\(Self.integer(value)) \(value == 1 ? one : many)"
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

    public static func selectionName(_ selection: InfoSelection) -> String { "\(Self.integer(selection.count)) items" }

    /// "folders", "files" or "mixed": which two icons the stack shows.
    public static func selectionContains(_ selection: InfoSelection) -> String {
        selection.fileCount == 0 ? "folders" : selection.folderCount == 0 ? "files" : "mixed"
    }

    /// The summary's rows: Size and Where.
    public static func selectionRows(_ selection: InfoSelection, hasFolderSize: Bool, folderSize: FolderSizeEntry?) -> [InfoRow] {
        let size = selection.totalBytes.map { SizeText.size($0) }
        let sizeRow: InfoRow
        if hasFolderSize, let folderSize {
            var idle = false
            if case .idle = folderSize { idle = true }
            sizeRow = InfoRow(label: "Size", value: .folderSize, muted: idle)
        } else {
            sizeRow = InfoRow(label: "Size", value: .text(size ?? "--"), muted: size == nil)
        }
        let whereRow: InfoRow
        if let parent = selection.parentPath {
            whereRow = InfoRow(label: "Where", value: .whereLink(label: PathBarModel.label(parent), path: parent), muted: false)
        } else {
            whereRow = InfoRow(label: "Where", value: .text("Several folders"), muted: true)
        }
        return [sizeRow, whereRow]
    }

    /// Everything the panel shows of one item.
    public struct ItemContent: Equatable, Sendable {
        public var rows: [InfoRow]
        public var subtitle: String
    }

    public static func parentPath(_ path: String) -> String? {
        var trimmed = path
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard !trimmed.isEmpty, let slash = trimmed.lastIndex(of: "/") else { return nil }
        let index = trimmed.distance(from: trimmed.startIndex, to: slash)
        return index == 0 ? "/" : String(trimmed.prefix(index))
    }

    /// The rows and the subtitle of one item, in the order of B-INFO-029.
    public static func itemContent(
        item: InfoItem, pending isPending: Bool, volume: InfoVolume?, isVolumeRoot: Bool, hasFolderSize: Bool,
        folderSize: FolderSizeEntry?, opensWith: OpensWithState, dates: DateText = .shared
    ) -> ItemContent {
        let isFile = item.kind == .file || item.kind == .symlinkFile
        let folderEligible = item.kind.isFolderSizeEligible
        func bytes(_ value: Int64?) -> String { value.map { SizeText.size($0) } ?? pending }

        var sizeText = ""
        var sizeMuted = false
        var sizeIsCell = false
        if folderEligible, hasFolderSize, folderSize != nil {
            sizeIsCell = true
            switch folderSize {
            case .idle?, .error?: sizeMuted = true
            default: break
            }
        } else if folderEligible {
            sizeText = "--"
            sizeMuted = true
        } else if isPending, item.sizeBytes == nil {
            sizeText = pending
            sizeMuted = true
        } else {
            sizeText = SizeText.size(item.sizeBytes, status: item.sizeStatus)
        }

        var rows: [InfoRow] = [InfoRow(label: "Kind", value: .text(item.kindLabel), muted: false)]
        switch opensWith {
        case .hidden: break
        case .pending: if isFile { rows.append(InfoRow(label: "Opens with", value: .text(pending), muted: true)) }
        case .available: if isFile { rows.append(InfoRow(label: "Opens with", value: .opensWith, muted: false)) }
        }
        if isVolumeRoot {
            let used: Int64? =
                volume?.totalBytes != nil && volume?.availableBytes != nil
                ? max(0, (volume?.totalBytes ?? 0) - (volume?.availableBytes ?? 0)) : nil
            rows.append(InfoRow(label: "Capacity", value: .text(bytes(volume?.totalBytes)), muted: volume?.totalBytes == nil))
            rows.append(InfoRow(label: "Available", value: .text(bytes(volume?.availableBytes)), muted: volume?.availableBytes == nil))
            rows.append(InfoRow(label: "Used", value: .text(bytes(used)), muted: used == nil))
        } else {
            rows.append(InfoRow(label: "Size", value: sizeIsCell ? .folderSize : .text(sizeText), muted: sizeMuted))
        }
        func date(_ iso: String?) -> String { iso == nil && isPending ? pending : dates.dateTime(iso: iso) }
        rows.append(InfoRow(label: "Created", value: .text(date(item.createdAt)), muted: item.createdAt == nil))
        rows.append(InfoRow(label: "Modified", value: .text(date(item.modifiedAt)), muted: item.modifiedAt == nil))
        if let parts = PermissionText.split(item.permissionMode) {
            rows.append(
                InfoRow(
                    label: "Permissions",
                    value: .permissions(
                        words: PermissionText.ownerAccess(symbolic: parts.symbolic), octal: parts.octal,
                        symbolic: parts.symbolic), muted: false))
        } else {
            rows.append(InfoRow(label: "Permissions", value: .text(isPending ? pending : "Unavailable"), muted: true))
        }
        if let parent = parentPath(item.path) {
            rows.append(InfoRow(label: "Where", value: .whereLink(label: PathBarModel.label(parent), path: parent), muted: false))
        } else {
            rows.append(InfoRow(label: "Where", value: .text("—"), muted: true))
        }

        let summary: String?
        if isVolumeRoot {
            summary = volume?.availableBytes.map { "\(SizeText.size($0)) available" }
        } else if folderEligible {
            if case .ready(let size, _, _, _)? = folderSize { summary = SizeText.size(size) } else { summary = nil }
        } else if isPending, item.sizeBytes == nil {
            summary = nil
        } else {
            summary = SizeText.size(item.sizeBytes, status: item.sizeStatus)
        }
        return ItemContent(rows: rows, subtitle: summary.map { "\(item.kindLabel) · \($0)" } ?? item.kindLabel)
    }

    public enum OpensWithState: Equatable, Sendable {
        case hidden, pending, available
    }

    /// One of the quick actions.
    public struct QuickAction: Equatable, Sendable {
        public enum ID: String, Sendable { case quickLook, edit, copyPath, copyName, terminal, finder, favorite, rootTree }
        public var id: ID
        public var label: String
        public var shortcut: String?
        public var disabled = false
    }

    /// B-INFO-055/056: which quick actions an item gets.
    public static func quickActions(
        item: InfoItem, textEditorName: String, isFavorite: Bool, canFavorite: Bool, copied: QuickAction.ID?,
        shortcut: (ShortcutCommandID) -> String?
    ) -> [QuickAction] {
        var actions = [QuickAction(id: .quickLook, label: "Quick Look", shortcut: shortcut(.quickLookSelection))]
        if item.kind.isEditableFile {
            actions.append(QuickAction(id: .edit, label: "Edit in \(textEditorName)", shortcut: shortcut(.editSelection)))
        }
        actions.append(
            QuickAction(id: .copyPath, label: copied == .copyPath ? "Copied" : "Copy Path", shortcut: shortcut(.copyPath)))
        actions.append(QuickAction(id: .copyName, label: copied == .copyName ? "Copied" : "Copy Name", shortcut: nil))
        actions.append(QuickAction(id: .terminal, label: "Open in Terminal", shortcut: shortcut(.openInTerminal)))
        actions.append(QuickAction(id: .finder, label: "Show in Finder", shortcut: shortcut(.showInFinder)))
        if canFavorite && item.kind.isDirectoryLike {
            actions.append(
                QuickAction(
                    id: .favorite, label: isFavorite ? "Remove from Favorites" : "Add to Favorites",
                    shortcut: shortcut(.toggleFavorite)))
        }
        if item.kind.isDirectoryLike {
            actions.append(QuickAction(id: .rootTree, label: "Use as Tree Root", shortcut: shortcut(.rootTreeAtSelection)))
        }
        return actions
    }

    /// "<size> (<disk> on disk)" over "N files, M folders".
    public static func folderSizeLines(
        sizeBytes: Int64, diskBytes: Int64, fileCount: Int, folderCount: Int, locale: Locale = InfoLocale.original
    ) -> (top: String, items: String) {
        let detail = SizeText.folderDetail(
            sizeBytes: sizeBytes, diskBytes: diskBytes, fileCount: fileCount, folderCount: folderCount, locale: locale)
        return (detail.size + (detail.disk.map { " (\($0))" } ?? ""), detail.items)
    }

    /// The Info Row's facts for one item: kind, size and Modified, each left out until known.
    public struct RowFacts: Equatable, Sendable {
        public var name: String
        public var kind: String
        /// A plain size text; nil when the folder size cell stands there or nothing is known.
        public var size: String?
        public var showsFolderSize: Bool
        public var modified: String?
        public var modifiedTooltip: String?
    }

    public static func rowFacts(
        entry: InfoEntry, metadata: InfoMetadata?, item: InfoItem?, folderSizeKnown: Bool, now: Date,
        parseDate: (String) -> Date?, dates: DateText = .shared
    ) -> RowFacts {
        let known: (kind: String, size: Int64?, status: SizeStatus, modified: String?)? =
            metadata.map { ($0.kindLabel, $0.sizeBytes, $0.sizeStatus, $0.modifiedAt) }
            ?? (item?.path == entry.path ? item : nil).map { ($0.kindLabel, $0.sizeBytes, $0.sizeStatus, $0.modifiedAt) }
        let eligible = entry.kind.isFolderSizeEligible
        var size: String?
        if !eligible, let known, known.status == .ready { size = SizeText.size(known.size, status: known.status) }
        var modified: String?
        var tooltip: String?
        if let iso = known?.modified, let date = parseDate(iso) {
            modified = "Modified \(dates.relative(date, now: now))"
            tooltip = dates.exactDateTime(date)
        }
        return RowFacts(
            name: entry.name,
            kind: known?.kind ?? InfoPreview.fallbackKindLabel(kind: entry.kind, fileExtension: entry.fileExtension),
            size: size, showsFolderSize: eligible && folderSizeKnown, modified: modified, modifiedTooltip: tooltip)
    }
}
