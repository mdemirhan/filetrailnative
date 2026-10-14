// Ports the bundle case of apps/desktop/src/renderer/lib/explorerAppUtils.test.ts and the nativeIsPackage case of
// packages/native-fs/src/native-fs.test.ts (the listing classifies packages), and covers the content pane's rules by
// feature row: the order and bars of a folder sorted by size, the states, the selection colors and the cells
import FTFileSystem
import FTFoundation
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

    // T-42401906
    @Test func bundlesAreEligibleForFolderSizesWithoutBeingFolders() {
        let bundle = Self.entry("App.app", kind: .bundle)
        #expect(bundle.isFolderSizeEligible)
        #expect(!bundle.isDirectoryLike)
        #expect(Self.entry("dir", kind: .directory).isFolderSizeEligible)
        // A link to a folder is not measured.
        #expect(!Self.entry("link", kind: .symlinkDirectory).isFolderSizeEligible)
        #expect(Self.entry("link", kind: .symlinkDirectory).isDirectoryLike)
    }

    // T-3056a773: the listing tells a package from a plain folder, and a missing folder fails.
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

    // B-INFO-175 B-INFO-176 B-INFO-177 B-INFO-181 F-828: while sorted by size, folders order by their calculated size, and
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

    // F-771: other orders are kept as the listing made them; the filter narrows by name.
    @Test func otherOrdersAndTheFilter() {
        let listed = [Self.entry("b.txt"), Self.entry("a.txt"), Self.entry("Notes.md")]
        var contents = FolderContents(path: "/f", listed: listed)
        #expect(contents.shown(sortBy: .name, direction: .asc, foldersFirst: true) { _ in nil }.map(\.name) == ["b.txt", "a.txt", "Notes.md"])
        contents.filter = "TXT"
        #expect(contents.shown(sortBy: .name, direction: .asc, foldersFirst: true) { _ in nil }.map(\.name) == ["b.txt", "a.txt"])
    }

    // B-NAV-119 B-VIEW-065: only a folder that is gone counts as gone; the Trash needs Full Disk Access.
    @Test func readFailuresAreToldApart() {
        #expect(FolderReadFailure.isGone(ExplorerError.system(code: ENOENT, path: "/x")))
        #expect(FolderReadFailure.isGone(ExplorerError.system(code: ENOTDIR, path: "/x")))
        #expect(FolderReadFailure.isGone(ExplorerError.notADirectory("/x")))
        #expect(!FolderReadFailure.isGone(ExplorerError.system(code: EACCES, path: "/ENOENT")))
        #expect(!FolderReadFailure.isGone(ExplorerError.system(code: EPERM, path: "/x")))
        let message = FolderReadFailure.message(ExplorerError.system(code: EPERM, path: "/Users/demo/.Trash"))
        #expect(FolderReadFailure.isTrashRefused(path: "/Users/demo/.Trash", message: message, homePath: "/Users/demo"))
        #expect(!FolderReadFailure.isTrashRefused(path: "/Users/demo/Other", message: message, homePath: "/Users/demo"))
        #expect(!FolderReadFailure.isTrashRefused(path: "/Users/demo/.Trash", message: "No such file", homePath: "/Users/demo"))
        #expect(!FolderReadFailure.isTrashRefused(path: "/Users/demo/.Trash", message: nil, homePath: "/Users/demo"))
    }

    // B-VIEW-009 B-VIEW-008 F-756: the selection is the accent in the focused list of the front window, grey otherwise.
    @Test func selectionColorsFollowFocus() {
        let theme = Theme(appearance: .light, accentHex: "#007aff")
        let layout = DesignTokens.details(density: .comfortable)
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

    // B-VIEW-054 B-VIEW-055 B-VIEW-056 B-INFO-180 F-773: the cells' texts.
    @Test func cellTexts() {
        let folder = Self.entry("dir", kind: .directory)
        let file = Self.entry("a.txt")
        #expect(ListCellText.size(entry: folder, metadata: nil, folderSize: .idle).text == "--")
        #expect(ListCellText.size(entry: folder, metadata: nil, folderSize: .idle).isPlaceholder)
        #expect(ListCellText.size(entry: folder, metadata: nil, folderSize: .calculating(jobID: "j")).text == "Calculating…")
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
        let metadata = try! JSONDecoder().decode(
            EntryMetadata.self, from: JSONSerialization.data(withJSONObject: metadataJSON))
        #expect(ListCellText.size(entry: file, metadata: metadata, folderSize: .idle).text == "999 B")
        #expect(ListCellText.permissions(metadata) == ListCellContent(text: "644", tooltip: "rw-r--r--"))
        #expect(ListCellText.permissions(nil).text == "")
        let now = ISODate.parse("2026-10-13T14:38:00.000Z") ?? Date()
        let date = ListCellText.date(metadata.modifiedAt, now: now)
        #expect(date.text == "Just now" || date.text == "1 min ago")
        #expect(date.tooltip?.isEmpty == false)
        #expect(ListCellText.date(nil, now: now).text == "")
        #expect(ListCellText.readsInMinutes(metadata.modifiedAt, now: now))
    }

    // B-NAV-132 B-VIEW-192: a selection keeps the paths that still exist.
    @Test func aSelectionKeepsWhatStillExists() {
        let selection = ContentSelection(paths: ["/a", "/b", "/c"], anchorPath: "/a", leadPath: "/c")
        let kept = selection.keeping(existing: ["/b", "/c"])
        #expect(kept.paths == ["/b", "/c"])
        #expect(kept.anchorPath == "/b" && kept.leadPath == "/c")
        #expect(ContentSelection.of(["/x", "/y"]) == ContentSelection(paths: ["/x", "/y"], anchorPath: "/x", leadPath: "/y"))
        #expect(selection.keeping(existing: []).isEmpty)
    }
}
