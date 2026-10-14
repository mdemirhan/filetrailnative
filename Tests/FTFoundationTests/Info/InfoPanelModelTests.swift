// Covers F-697, F-748, F-749, F-820..F-826 and B-INFO-024..058, B-INFO-066..078, B-INFO-167..171 (what the Info views decide to show)
import Foundation
import Testing

@testable import FTFoundation

@Suite("info panel model")
struct InfoPanelModelTests {
    static let dates = DateText(locale: Locale(identifier: "en_US"), timeZone: TimeZone(identifier: "UTC") ?? .current)

    static func file(pending: Bool = false, size: Int64? = 2000) -> InfoItem {
        InfoItem(
            path: "/Users/demo/notes.md", name: "notes.md", fileExtension: "md", kind: .file, kindLabel: "Markdown document",
            createdAt: "2026-03-01T09:00:00.000Z", modifiedAt: "2026-03-02T10:30:00.000Z", sizeBytes: size,
            sizeStatus: size == nil ? .deferred : .ready, permissionMode: 0o644)
    }

    static func content(
        _ item: InfoItem, pending: Bool = false, volume: InfoVolume? = nil, root: Bool = false,
        folderSize: FolderSizeEntry? = nil, opens: InfoPanelModel.OpensWithState = .hidden
    ) -> InfoPanelModel.ItemContent {
        InfoPanelModel.itemContent(
            item: item, pending: pending, volume: volume, isVolumeRoot: root, hasFolderSize: folderSize != nil,
            folderSize: folderSize, opensWith: opens, dates: dates)
    }

    // T-209d6f52 T-4e902491 B-INFO-029 B-INFO-030 B-INFO-031 B-INFO-034
    @Test func aFilesRowsAreInTheDocumentedOrder() {
        let content = Self.content(Self.file(), opens: .available)
        #expect(content.rows.map(\.label) == ["Kind", "Opens with", "Size", "Created", "Modified", "Permissions", "Where"])
        #expect(content.subtitle == "Markdown document · 2.0 KB")
        #expect(content.rows[2].value == .text("2.0 KB"))
        #expect(content.rows[3].value == .text("Mar 1, 2026, 9:00 AM"))
        #expect(
            content.rows[5].value == .permissions(words: "Read & Write", octal: "644", symbolic: "rw-r--r--"))
        #expect(content.rows[6].value == .whereLink(label: "demo", path: "/Users/demo"))
    }

    // T-08ec3aa8 T-85c8fc6c B-INFO-024 B-INFO-025 B-INFO-196
    @Test func pendingValuesKeepTheirRowsWithADash() {
        var item = Self.file(size: nil)
        item.createdAt = nil
        item.modifiedAt = nil
        item.permissionMode = nil
        let pending = Self.content(item, pending: true)
        #expect(pending.rows[1].value == .text("—") && pending.rows[1].muted)  // Size
        #expect(pending.rows[2].value == .text("—"))  // Created
        #expect(pending.rows[4].value == .text("—"))  // Permissions
        #expect(pending.subtitle == "Markdown document")
        let final = Self.content(item)
        #expect(final.rows[2].value == .text("Not available") && final.rows[2].muted)
        #expect(final.rows[4].value == .text("Unavailable") && final.rows[4].muted)
    }

    // T-b9e1ffc4 F-697 B-INFO-047 B-INFO-048
    @Test func aVolumeRootShowsCapacityAvailableAndUsed() {
        var item = Self.file()
        item.kind = .directory
        item.path = "/"
        item.name = "Macintosh HD"
        item.kindLabel = "Folder"
        let waiting = Self.content(item, root: true)
        #expect(waiting.rows.map(\.label).contains("Capacity"))
        #expect(!waiting.rows.map(\.label).contains("Size"))
        #expect(waiting.rows.first { $0.label == "Used" }?.value == .text("—"))
        let known = Self.content(item, volume: InfoVolume(totalBytes: 500_000_000_000, availableBytes: 200_000_000_000), root: true)
        #expect(known.rows.first { $0.label == "Used" }?.value == .text("300 GB"))
        #expect(known.subtitle == "Folder · 200 GB available")
        let over = Self.content(item, volume: InfoVolume(totalBytes: 10, availableBytes: 50), root: true)
        #expect(over.rows.first { $0.label == "Used" }?.value == .text("0 B"))
    }

    // T-066643da T-ef42cbb6 T-cbc15e68 B-INFO-036 B-INFO-037 B-INFO-044 B-INFO-045 B-INFO-035
    @Test func aFolderGetsTheFolderSizeCellAndAPackageToo() {
        var folder = Self.file()
        folder.kind = .directory
        let idle = Self.content(folder, folderSize: .idle)
        #expect(idle.rows.first { $0.label == "Size" } == InfoRow(label: "Size", value: .folderSize, muted: true))
        let error = Self.content(folder, folderSize: .error(message: "x"))
        #expect(error.rows.first { $0.label == "Size" }?.muted == true)
        let without = Self.content(folder)
        #expect(without.rows.first { $0.label == "Size" }?.value == .text("--"))
        let ready = Self.content(folder, folderSize: .ready(sizeBytes: 1_200_000_000, diskBytes: 1_300_000_000, fileCount: 4, folderCount: 1))
        #expect(ready.subtitle == "Markdown document · 1.2 GB")
        var link = Self.file()
        link.kind = .symlinkDirectory
        #expect(Self.content(link).rows.first { $0.label == "Size" }?.value == .text("2.0 KB"))
    }

    // B-INFO-041
    @Test func theFolderSizeLines() {
        let lines = InfoPanelModel.folderSizeLines(
            sizeBytes: 1_200_000_000, diskBytes: 1_300_000_000, fileCount: 48_611, folderCount: 2_765,
            locale: Locale(identifier: "en_US"))
        #expect(lines.top == "1.2 GB (1.3 GB on disk)")
        #expect(lines.items == "48,611 files, 2,765 folders")
        let same = InfoPanelModel.folderSizeLines(sizeBytes: 100, diskBytes: 100, fileCount: 1, folderCount: 0)
        #expect(same.top == "100 B" && same.items == "1 file")
        #expect(InfoPanelModel.folderSizeLines(sizeBytes: 0, diskBytes: 0, fileCount: 0, folderCount: 0).items == "Empty")
    }

    // T-0033a16b F-826 B-INFO-051 B-INFO-054
    @Test func severalItemsAreSummedUp() {
        let selection = InfoSelection(count: 5, folderCount: 3, fileCount: 2, totalBytes: 4000, parentPath: nil)
        #expect(InfoPanelModel.selectionName(selection) == "5 items")
        #expect(InfoPanelModel.selectionSubtitle(selection) == "3 folders and 2 files · 4.0 KB")
        #expect(InfoPanelModel.selectionContains(selection) == "mixed")
        let files = InfoSelection(count: 4, folderCount: 0, fileCount: 4, totalBytes: nil, parentPath: "/Users/demo")
        #expect(InfoPanelModel.selectionSubtitle(files) == "4 files")
        #expect(InfoPanelModel.selectionContains(files) == "files")
        let one = InfoSelection(count: 3, folderCount: 1, fileCount: 2, totalBytes: nil, parentPath: nil)
        #expect(InfoPanelModel.selectionSubtitle(one) == "1 folder and 2 files")
        let rows = InfoPanelModel.selectionRows(files, hasFolderSize: false, folderSize: nil)
        #expect(rows[0] == InfoRow(label: "Size", value: .text("--"), muted: true))
        #expect(rows[1] == InfoRow(label: "Where", value: .whereLink(label: "demo", path: "/Users/demo"), muted: false))
        let several = InfoPanelModel.selectionRows(selection, hasFolderSize: true, folderSize: .idle)
        #expect(several[0].value == .folderSize)
        #expect(several[1] == InfoRow(label: "Where", value: .text("Several folders"), muted: true))
    }

    // T-0287f845 F-825 B-INFO-055 B-INFO-056
    @Test func quickActionsDependOnTheItem() {
        func labels(_ item: InfoItem, favorite: Bool = false, canFavorite: Bool = true, copied: InfoPanelModel.QuickAction.ID? = nil) -> [String] {
            InfoPanelModel.quickActions(
                item: item, textEditorName: "Zed", isFavorite: favorite, canFavorite: canFavorite, copied: copied,
                shortcut: { _ in nil }
            ).map(\.label)
        }
        #expect(
            labels(Self.file()) == ["Quick Look", "Edit in Zed", "Copy Path", "Copy Name", "Open in Terminal", "Show in Finder"])
        var folder = Self.file()
        folder.kind = .directory
        #expect(
            labels(folder)
                == ["Quick Look", "Copy Path", "Copy Name", "Open in Terminal", "Show in Finder", "Add to Favorites", "Use as Tree Root"])
        #expect(labels(folder, favorite: true).contains("Remove from Favorites"))
        #expect(!labels(folder, canFavorite: false).contains("Add to Favorites"))
        #expect(labels(Self.file(), copied: .copyPath).contains("Copied"))
        #expect(labels(Self.file(), copied: .copyPath).contains("Copy Name"))
        var package = Self.file()
        package.kind = .bundle
        #expect(!labels(package).contains("Use as Tree Root"))
    }

    // T-4e4c9d29 T-908f1796 T-3b2397f6 F-748 B-INFO-069 B-INFO-071 B-INFO-073 B-INFO-075
    @Test func theInfoRowLeavesOutWhatIsNotKnown() {
        let entry = InfoEntry(path: "/Users/demo/notes.md", name: "notes.md", fileExtension: "md", kind: .file)
        let now = ISODateForTests.date("2026-03-02T11:00:00Z")
        let bare = InfoPanelModel.rowFacts(
            entry: entry, metadata: nil, item: nil, folderSizeKnown: false, now: now, parseDate: ISODateForTests.parse, dates: Self.dates)
        #expect(bare.kind == "MD File" && bare.size == nil && bare.modified == nil)
        let listed = InfoMetadata(
            kindLabel: "Markdown document", modifiedAt: "2026-03-02T10:30:00.000Z", sizeBytes: 2000, sizeStatus: .ready)
        let facts = InfoPanelModel.rowFacts(
            entry: entry, metadata: listed, item: nil, folderSizeKnown: false, now: now, parseDate: ISODateForTests.parse,
            dates: Self.dates)
        #expect(facts.kind == "Markdown document" && facts.size == "2.0 KB")
        #expect(facts.modified == "Modified 30 min ago")
        #expect(facts.modifiedTooltip?.contains("2026") == true)
        // A folder's size is the cell, never plain text.
        let folder = InfoEntry(path: "/Users/demo/Projects", name: "Projects", kind: .directory)
        let folderFacts = InfoPanelModel.rowFacts(
            entry: folder, metadata: listed, item: nil, folderSizeKnown: true, now: now, parseDate: ISODateForTests.parse,
            dates: Self.dates)
        #expect(folderFacts.showsFolderSize && folderFacts.size == nil)
        // Properties of another item are never used.
        let other = Self.file()
        let foreign = InfoPanelModel.rowFacts(
            entry: InfoEntry(path: "/Users/demo/other.md", name: "other.md", fileExtension: "md", kind: .file), metadata: nil,
            item: other, folderSizeKnown: false, now: now, parseDate: ISODateForTests.parse, dates: Self.dates)
        #expect(foreign.kind == "MD File")
    }

    // T-df387abe T-b8e9d9c4 B-INFO-167 B-INFO-168
    @Test func onlyAFolderInsideHomeIsMeasuredAutomatically() {
        func path(open: Bool = true, selected: [String], kind: EntryKind = .directory, home: String = "/Users/demo") -> String? {
            AutoFolderSize.path(
                infoPanelOpen: open, selectedPaths: selected, selected: selected.first.map { ($0, kind) }, homePath: home)
        }
        #expect(path(selected: ["/Users/demo/Projects"]) == "/Users/demo/Projects")
        #expect(path(selected: ["/Users/demo/App.app"], kind: .bundle) == "/Users/demo/App.app")
        #expect(path(open: false, selected: ["/Users/demo/Projects"]) == nil)
        #expect(path(selected: ["/Users/demo/Projects", "/Users/demo/Other"]) == nil)
        #expect(path(selected: []) == nil)
        #expect(path(selected: ["/Users/demo"]) == nil)
        #expect(path(selected: ["/Users/demonstration/x"]) == nil)
        #expect(path(selected: ["/Applications"]) == nil)
        #expect(path(selected: ["/Users/demo/file.txt"], kind: .file) == nil)
        #expect(path(selected: ["/Users/demo/link"], kind: .symlinkDirectory) == nil)
        #expect(path(selected: ["/Users/demo/Projects"], home: "") == nil)
        #expect(path(selected: ["/Users/demo/Projects"], home: "/Users/demo/") == "/Users/demo/Projects")
        #expect(AutoFolderSize.delayMilliseconds == 500)
    }
}

enum ISODateForTests {
    static func parse(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    static func date(_ text: String) -> Date { parse(text) ?? Date(timeIntervalSince1970: 0) }
}
