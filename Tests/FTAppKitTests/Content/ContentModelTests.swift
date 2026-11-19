// The order and bars of a folder sorted by size, the states, the selection colors and the cells
import FTFileSystem
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTAppKit

struct ContentModelTests {
    // The listing's types have no public initializers: they are made as they come, from JSON.
    static func entry(_ name: String, kind: FTFileSystem.EntryKind = .file, size: Int64? = nil) -> DirectoryEntry {
        var json: [String: Any] = [
            "path": "/f/\(name)", "name": name, "fileExtension": (name as NSString).pathExtension,
            "kind": kind.rawValue, "isHidden": false, "isSymlink": false,
        ]
        if let size { json["sizeBytes"] = size }
        // A literal that fails to decode is a mistake in this file.
        let data = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
        return (try? JSONDecoder().decode(DirectoryEntry.self, from: data))!
    }

    @Test func bundlesAreEligibleForFolderSizesWithoutBeingFolders() {
        let bundle = Self.entry("App.app", kind: .bundle)
        #expect(bundle.isFolderSizeEligible)
        #expect(!bundle.isDirectoryLike)
        #expect(Self.entry("dir", kind: .directory).isFolderSizeEligible)
        // A link to a folder is not measured.
        #expect(!Self.entry("link", kind: .symlinkDirectory).isFolderSizeEligible)
        #expect(Self.entry("link", kind: .symlinkDirectory).isDirectoryLike)
    }

    // The listing tells a package from a plain folder, and a missing folder fails.
    @Test func theListingTellsAPackageFromAPlainFolder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("content-model-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Tool.app"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("plain"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = try await DirectoryService().snapshot(path: root.path)
        let tool = try #require(snapshot.entries.first { $0.name == "Tool.app" })
        let plain = try #require(snapshot.entries.first { $0.name == "plain" })
        #expect(tool.kind == .bundle && !tool.isDirectoryLike)
        #expect(plain.kind == .directory && plain.isDirectoryLike)
        await #expect(throws: (any Error).self) {
            try await DirectoryService().snapshot(path: root.appendingPathComponent("missing.app").path)
        }
    }

    // While sorted by size, folders order by their calculated size, and
    // the bars scale to the largest size of all the entries.
    @Test func aSizeSortIsFinishedWithTheFolderSizes() {
        let listed = [
            Self.entry("big.bin", size: 900), Self.entry("dir", kind: .directory),
            Self.entry("small.txt", size: 10), Self.entry("huge", kind: .directory),
        ]
        let contents = FolderContents(path: "/f", listed: listed)
        let folderSizes: [String: Int64] = ["/f/huge": 5000]
        let shown = contents.shown(sortBy: .size, direction: .desc, foldersFirst: true) { folderSizes[$0] }
        // Folders first: the calculated one, then the unknown; then the files by size.
        #expect(shown.map(\.name) == ["huge", "dir", "big.bin", "small.txt"])
        #expect(contents.largestSize { folderSizes[$0] } == 5000)
        #expect(contents.largestSize { _ in nil } == 900)
        #expect(FolderContents(path: "/f", listed: [Self.entry("d", kind: .directory)]).largestSize { _ in nil } == nil)
    }

    // Other orders are kept as the listing made them; the filter narrows by name.
    @Test func otherOrdersAndTheFilter() {
        let listed = [Self.entry("b.txt"), Self.entry("a.txt"), Self.entry("Notes.md")]
        var contents = FolderContents(path: "/f", listed: listed)
        #expect(
            contents.shown(sortBy: .name, direction: .asc, foldersFirst: true) { _ in nil }.map(\.name) == [
                "b.txt", "a.txt", "Notes.md",
            ])
        contents.filter = "TXT"
        #expect(
            contents.shown(sortBy: .name, direction: .asc, foldersFirst: true) { _ in nil }.map(\.name) == [
                "b.txt", "a.txt",
            ])
    }

    // Only a folder that is gone counts as gone; the Trash needs Full Disk Access.
    @Test func readFailuresAreToldApart() {
        #expect(FolderReadFailure.isGone(ExplorerError.system(code: ENOENT, path: "/x")))
        #expect(FolderReadFailure.isGone(ExplorerError.system(code: ENOTDIR, path: "/x")))
        #expect(FolderReadFailure.isGone(ExplorerError.notADirectory("/x")))
        #expect(!FolderReadFailure.isGone(ExplorerError.system(code: EACCES, path: "/ENOENT")))
        #expect(!FolderReadFailure.isGone(ExplorerError.system(code: EPERM, path: "/x")))
        let refused = FolderReadFailure.readError(ExplorerError.system(code: EPERM, path: "/Users/demo/.Trash"))
        #expect(FolderReadFailure.isTrashRefused(path: "/Users/demo/.Trash", error: refused, homePath: "/Users/demo"))
        #expect(!FolderReadFailure.isTrashRefused(path: "/Users/demo/Other", error: refused, homePath: "/Users/demo"))
        #expect(
            !FolderReadFailure.isTrashRefused(
                path: "/Users/demo/.Trash", error: FolderReadError(message: "No such file", errnum: ENOENT),
                homePath: "/Users/demo"))
        #expect(!FolderReadFailure.isTrashRefused(path: "/Users/demo/.Trash", error: nil, homePath: "/Users/demo"))
    }

    // The selection is the accent in the focused list of the front window, grey otherwise.
    @Test func selectionColorsFollowFocus() {
        let theme = Theme(appearance: .light, accentHex: "#007aff")
        let layout = DesignTokens.details(density: .standard)
        func colors(_ selected: Bool, odd: Bool = false, focused: Bool, active: Bool) -> RowColors {
            RowColors.make(
                theme: theme, layout: layout, selected: selected, odd: odd, paneFocused: focused, windowActive: active)
        }
        let focused = colors(true, focused: true, active: true)
        #expect(focused.background == theme.accent.selectionBg)
        #expect(focused.name == theme.accent.onSelection && focused.cell == theme.accent.onSelection)
        #expect(focused.sizeBar == theme.accent.onSelection && focused.sizeBarAlpha == 0.28)
        let unfocused = colors(true, focused: false, active: true)
        #expect(unfocused.background == theme.palette.bgActiveInactive)
        #expect(unfocused.name == theme.palette.textPrimary && unfocused.cell == theme.palette.textSecondary)
        let background = colors(true, focused: true, active: false)
        #expect(background.background == theme.palette.bgActiveInactive)
        #expect(background.cell == theme.palette.textPrimary)
        // Stripes: odd rows only, ink at 3.5%.
        #expect(colors(false, odd: false, focused: true, active: true).background == nil)
        #expect(
            colors(false, odd: true, focused: true, active: true).background
                == theme.palette.neutralInk.withAlpha(0.035))
    }

    // The cells' texts.
    @Test func cellTexts() {
        let folder = Self.entry("dir", kind: .directory)
        let file = Self.entry("a.txt")
        #expect(ListCellText.size(entry: folder, metadata: nil, folderSize: .idle).text == "--")
        #expect(ListCellText.size(entry: folder, metadata: nil, folderSize: .idle).isPlaceholder)
        #expect(
            ListCellText.size(entry: folder, metadata: nil, folderSize: .calculating(jobID: "j")).text == "Calculating…"
        )
        #expect(
            ListCellText.size(entry: folder, metadata: nil, folderSize: .calculating(jobID: "j", waiting: true)).text
                == "Waiting…")
        #expect(ListCellText.size(entry: folder, metadata: nil, folderSize: .error(message: "x")).text == "--")
        #expect(
            ListCellText.size(
                entry: folder, metadata: nil,
                folderSize: FolderSizeEntry.ready(sizeBytes: 1_500_000, diskBytes: 0, fileCount: 0, folderCount: 0)
            ).text == "1.5 MB")
        // A file whose details are still loading shows nothing.
        #expect(ListCellText.size(entry: file, metadata: nil, folderSize: .idle).text == "")
        let metadataJSON: [String: Any] = [
            "path": file.path, "kindLabel": "Plain Text", "createdAt": "2026-10-13T14:30:00.000Z",
            "modifiedAt": "2026-10-13T14:37:00.000Z", "sizeBytes": 999, "sizeStatus": "ready",
            "permissionMode": 0o100644,
        ]
        let metadata = try! ISODateForTests.decoder.decode(
            EntryMetadata.self, from: JSONSerialization.data(withJSONObject: metadataJSON))
        #expect(ListCellText.size(entry: file, metadata: metadata, folderSize: .idle).text == "999 B")
        #expect(ListCellText.permissions(metadata) == ListCellContent(text: "644", tooltip: "rw-r--r--"))
        #expect(ListCellText.permissions(nil).text == "")
        let now = ISODateForTests.date("2026-10-13T14:38:00.000Z")
        let date = ListCellText.date(metadata.modifiedAt, now: now)
        #expect(date.text == "Just now" || date.text == "1 min ago")
        #expect(date.tooltip?.isEmpty == false)
        #expect(ListCellText.date(nil, now: now).text == "")
        #expect(ListCellText.readsInMinutes(metadata.modifiedAt, now: now))
    }

    // The Date Added and Date Last Opened columns, from a file on disk to the cell: the folder read gives when the
    // file was put in the folder, macOS's own attribute when it was last opened, and each cell says its date. A row
    // whose details aren't read yet, and a file never opened, show nothing.
    @Test func theDateAddedAndLastOpenedCellsShowAFilesDates() async throws {
        try await withTemporaryDirectory(prefix: "date-columns") { folder in
            let opened = folder.url.appendingPathComponent("opened.txt").path
            let fresh = folder.url.appendingPathComponent("fresh.txt").path
            for path in [opened, fresh] { FileManager.default.createFile(atPath: path, contents: Data("a".utf8)) }
            // What macOS writes when a file is opened: seconds and nanoseconds.
            var stamp = (Int64(1_700_000_000).littleEndian, Int64(250_000_000).littleEndian)
            let written = withUnsafeBytes(of: &stamp) {
                setxattr(opened, "com.apple.lastuseddate#PS", $0.baseAddress, $0.count, 0, 0)
            }
            #expect(written == 0)

            let service = DirectoryService()
            let listing = try await service.snapshot(path: folder.path)
            #expect(listing.entries.map(\.name) == ["fresh.txt", "opened.txt"])
            var listedAdded: [String: Int64?] = [:]
            for entry in listing.entries { listedAdded.updateValue(entry.addedMs, forKey: entry.path) }
            let items = try await service.metadata(
                directoryPath: folder.path, paths: listing.entries.map(\.path), listedAdded: listedAdded
            ).items
            let entry = try #require(listing.entries.last)
            let metadata = try #require(items.last)
            #expect(metadata.path == entry.path)

            // The temporary folder's disk keeps Date Added: the one the folder read gave, to the millisecond.
            let addedMs = try #require(entry.addedMs)
            let added = try #require(metadata.addedAt)
            #expect(abs(added.timeIntervalSince1970 * 1000 - Double(addedMs)) < 1)
            #expect(abs(added.timeIntervalSinceNow) < 3600)
            let lastOpened = try #require(metadata.lastOpenedAt)
            #expect(abs(lastOpened.timeIntervalSince1970 - 1_700_000_000.25) < 0.001)
            #expect(items.first?.lastOpenedAt == nil)
            #expect(items.first?.addedAt != nil)

            let now = Date()
            func cell(_ column: DetailColumn, _ metadata: EntryMetadata?) -> ListCellContent {
                ListCellText.content(column: column, entry: entry, metadata: metadata, folderSize: .idle, now: now)
            }
            #expect(cell(.added, metadata) == ListCellText.date(added, now: now))
            #expect(!cell(.added, metadata).text.isEmpty)
            #expect(cell(.added, metadata).tooltip?.isEmpty == false)
            #expect(cell(.lastOpened, metadata) == ListCellText.date(lastOpened, now: now))
            #expect(!cell(.lastOpened, metadata).text.isEmpty)
            #expect(cell(.lastOpened, metadata).tooltip?.isEmpty == false)
            // Details not read yet, and a file never opened.
            #expect(cell(.added, nil).text == "")
            #expect(cell(.lastOpened, nil).text == "")
            #expect(cell(.lastOpened, items.first).text == "")
        }
    }

    // A selection keeps the paths that still exist (an anchor that left falls back to the lead).
    @Test func aSelectionKeepsWhatStillExists() {
        let selection = ContentSelection(paths: ["/a", "/b", "/c"], anchorPath: "/a", leadPath: "/c")
        let kept = selection.sanitized(entryPaths: ["/b", "/c"])
        #expect(kept.paths == ["/b", "/c"])
        #expect(kept.anchorPath == "/c" && kept.leadPath == "/c")
        #expect(
            ContentSelection.of(["/x", "/y"])
                == ContentSelection(paths: ["/x", "/y"], anchorPath: "/x", leadPath: "/y"))
        #expect(selection.sanitized(entryPaths: []).isEmpty)
    }
}
