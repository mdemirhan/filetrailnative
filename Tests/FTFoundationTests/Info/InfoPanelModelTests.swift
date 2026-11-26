import FTTestSupport
import Foundation
import Testing

@testable import FTFoundation

@Suite("info panel model")
struct InfoPanelModelTests {
    static let dates = DateText(locale: Locale(identifier: "en_US"), timeZone: TimeZone(identifier: "UTC") ?? .current)

    static func file(pending: Bool = false, size: Int64? = 2000) -> InfoItem {
        InfoItem(
            path: "/Users/demo/notes.md", name: "notes.md", fileExtension: "md", kind: .file,
            kindLabel: "Markdown document",
            createdAt: ISODateForTests.date("2026-03-01T09:00:00.000Z"),
            modifiedAt: ISODateForTests.date("2026-03-02T10:30:00.000Z"), sizeBytes: size,
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

    static func labels(_ content: InfoPanelModel.ItemContent, _ id: InfoSection.ID) -> [String] {
        content.section(id)?.rows.map(\.label) ?? []
    }

    static func row(_ content: InfoPanelModel.ItemContent, _ id: InfoSection.ID, _ label: String) -> InfoRow? {
        content.section(id)?.rows.first { $0.label == label }
    }

    static let demoWhere = "Macintosh HD › Users › demo"

    @Test func aFilesSectionsAreInTheDocumentedOrder() {
        let content = Self.content(Self.file(), opens: .available)
        #expect(content.sections.map(\.id) == [.general, .dates, .permissions, .text, .more])
        #expect(Self.labels(content, .general) == ["Kind", "Opens with", "Size", "Where"])
        #expect(Self.labels(content, .dates) == ["Created", "Modified", "Last opened", "Added"])
        #expect(Self.labels(content, .permissions) == ["Owner", "Group", "Everyone", "Mode", "You can"])
        #expect(content.subtitle == "Markdown document · 2.0 KB")
        #expect(
            Self.row(content, .general, "Size")
                == InfoRow(label: "Size", value: .text("2.0 KB (2,000 bytes)"), muted: false, detail: "—"))
        #expect(Self.row(content, .dates, "Created")?.value == .text("Mar 1, 2026, 9:00 AM"))
        #expect(Self.row(content, .permissions, "Owner")?.value == .text("Read & Write"))
        #expect(Self.row(content, .permissions, "Group")?.value == .text("Read only"))
        #expect(Self.row(content, .permissions, "Mode")?.value == .text("644 · rw-r--r--"))
        #expect(
            Self.row(content, .general, "Where")
                == InfoRow(
                    label: "Where", value: .place(Self.demoWhere), muted: false,
                    copyText: "/Users/demo/notes.md"))
        // Opens with keeps its place with a dash when there is no app to choose: the rows under it don't move.
        #expect(
            Self.labels(Self.content(Self.file(), opens: .hidden), .general) == ["Kind", "Opens with", "Size", "Where"])
    }

    // Once read, the details fill the places the dashes held, and the rows stay where they were.
    @Test func theDetailsFillTheirPlaces() {
        var details = InfoDetails()
        details.sizeOnDisk = 4096
        details.owner = .init(user: "demo", group: "staff", isYou: true, youCan: "Read & Write")
        details.flags = .init(locked: true)
        details.text = .init(lines: 12, encoding: "UTF-8", lineEnding: "LF")
        let pending = Self.content(Self.file())
        let read = InfoPanelModel.itemContent(
            item: Self.file(), pending: false, volume: nil, isVolumeRoot: false, hasFolderSize: false,
            folderSize: nil, opensWith: .hidden, dates: Self.dates, details: .read(details))
        for id in [InfoSection.ID.general, .dates] { #expect(Self.labels(pending, id) == Self.labels(read, id)) }
        #expect(Self.row(read, .general, "Size")?.detail == "4.1 KB on disk")
        #expect(Self.row(read, .permissions, "Owner")?.detail == "demo (you)")
        #expect(Self.row(read, .permissions, "Group")?.detail == "staff")
        #expect(Self.row(read, .permissions, "Locked")?.value == .text("Yes"))
        #expect(Self.labels(read, .text) == Self.labels(pending, .text))
        #expect(Self.row(read, .text, "Lines")?.value == .text("12"))
        #expect(Self.row(pending, .text, "Lines") == InfoRow(label: "Lines", value: .text("—"), muted: true))
    }

    // The section of what a file is comes from its name, so it is there, with dashes, before anything is read.
    @Test func eachKindHasItsSection() {
        func ids(_ name: String, _ ext: String, kind: EntryKind = .file) -> [InfoSection.ID] {
            var item = Self.file()
            item.name = name
            item.fileExtension = ext
            item.kind = kind
            return Self.content(item).sections.map(\.id)
        }
        #expect(ids("a.heic", "heic").contains(.image))
        #expect(ids("a.mov", "mov").contains(.movie))
        #expect(ids("a.m4a", "m4a").contains(.sound))
        #expect(ids("a.pdf", "pdf").contains(.document))
        #expect(ids("a.swift", "swift").contains(.text))
        #expect(ids("Calc.app", "app", kind: .bundle).contains(.application))
        #expect(ids("a.zip", "zip") == [.general, .dates, .permissions, .more])
    }

    @Test func anAppSaysWhoSignedIt() {
        var app = Self.file()
        app.name = "Calc.app"
        app.fileExtension = "app"
        app.kind = .bundle
        func rows(_ signing: InfoSigningState) -> InfoPanelModel.ItemContent {
            InfoPanelModel.itemContent(
                item: app, pending: false, volume: nil, isVolumeRoot: false, hasFolderSize: false, folderSize: nil,
                opensWith: .hidden, dates: Self.dates, signing: signing)
        }
        #expect(Self.row(rows(.pending), .application, "Signed by")?.value == .text("—"))
        let signed = rows(.read(.init(signedBy: "Developer ID · Lumen Labs", notarized: true)))
        #expect(Self.row(signed, .application, "Signed by")?.value == .text("Developer ID · Lumen Labs"))
        #expect(Self.row(signed, .application, "Notarized")?.value == .text("Yes"))
        let apple = rows(.read(.init(signedBy: "Apple", notarized: nil)))
        #expect(Self.row(apple, .application, "Notarized")?.value == .text("Not needed"))
    }

    @Test func aDownloadSaysWhereItCameFrom() {
        var details = InfoDetails()
        details.download = .init(
            from: "https://example.net/files/a.pdf", page: "https://example.net/list", agent: "Safari",
            date: ISODateForTests.date("2026-03-01T09:00:00.000Z"))
        let content = InfoPanelModel.itemContent(
            item: Self.file(), pending: false, volume: nil, isVolumeRoot: false, hasFolderSize: false,
            folderSize: nil, opensWith: .hidden, dates: Self.dates, details: .read(details))
        #expect(content.sections.map(\.id).suffix(2) == [.downloaded, .more])
        let from = Self.row(content, .downloaded, "From")
        #expect(from?.value == .text("example.net") && from?.detail == "https://example.net/files/a.pdf")
        #expect(from?.textToCopy == "https://example.net/files/a.pdf")
        #expect(Self.labels(content, .downloaded) == ["From", "Page", "By"])
    }

    // The Tags row comes after Size, for an item and for several: a dash until read, muted with none, and no row at
    // all past the items read for it.
    @Test func theTagsRowFollowsSize() {
        let tags = InfoTags(
            tags: [InfoTag(name: "Work", colorNumber: nil, count: 2), InfoTag(name: "Red", colorNumber: 6, count: 1)],
            itemCount: 2, editable: true)
        func general(_ state: InfoTagsState) -> [InfoRow] {
            InfoPanelModel.itemContent(
                item: Self.file(), pending: false, volume: nil, isVolumeRoot: false, hasFolderSize: false,
                folderSize: nil, opensWith: .hidden, dates: Self.dates, tags: state
            ).section(.general)?.rows ?? []
        }
        #expect(general(.read(tags)).map(\.label) == ["Kind", "Opens with", "Size", "Tags", "Where"])
        #expect(general(.read(tags))[3] == InfoRow(label: "Tags", value: .tags(tags), muted: false))
        #expect(tags.summary == "Work, Red (1)")
        #expect(general(.pending)[3] == InfoRow(label: "Tags", value: .text("—"), muted: true))
        let none = InfoTags(tags: [], itemCount: 1, editable: true)
        #expect(general(.read(none))[3] == InfoRow(label: "Tags", value: .tags(none), muted: true))
        let selection = InfoSelection(count: 2, folderCount: 0, fileCount: 2, totalBytes: 10, parentPath: "/a")
        func selectionGeneral(_ state: InfoTagsState) -> [String] {
            InfoPanelModel.selectionContent(
                selection, facts: InfoSelectionFacts(), hasFolderSize: false, folderSize: nil, tags: state
            )[0].rows.map(\.label)
        }
        #expect(selectionGeneral(.read(tags)) == ["Size", "Tags", "Where"])
        #expect(selectionGeneral(.hidden) == ["Size", "Where"])
    }

    @Test func pendingValuesKeepTheirRowsWithADash() {
        var item = Self.file(size: nil)
        item.createdAt = nil
        item.modifiedAt = nil
        item.permissionMode = nil
        let pending = Self.content(item, pending: true)
        let size = Self.row(pending, .general, "Size")
        #expect(size?.value == .text("—") && size?.muted == true)
        #expect(Self.row(pending, .dates, "Created")?.value == .text("—"))
        #expect(Self.labels(pending, .permissions) == ["Owner", "Group", "Everyone", "Mode", "You can"])
        #expect(Self.row(pending, .permissions, "Mode")?.value == .text("—"))
        #expect(pending.subtitle == "Markdown document")
        let final = Self.content(item)
        #expect(Self.row(final, .dates, "Created") == InfoRow(label: "Created", value: .text("—"), muted: true))
    }

    @Test func aVolumeRootShowsCapacityUsedAndAvailable() {
        var item = Self.file()
        item.kind = .directory
        item.path = "/"
        item.name = "Macintosh HD"
        item.kindLabel = "Folder"
        let waiting = Self.content(item, root: true)
        #expect(Self.labels(waiting, .general) == ["Kind", "Capacity", "Used", "Available"])
        #expect(waiting.sections.map(\.id) == [.general, .dates, .permissions, .volume, .more])
        #expect(Self.row(waiting, .general, "Used")?.value == .text("—"))
        let known = Self.content(
            item, volume: InfoVolume(totalBytes: 500_000_000_000, availableBytes: 200_000_000_000), root: true)
        #expect(Self.row(known, .general, "Used")?.value == .usage(fraction: 0.6, text: "300 GB"))
        #expect(known.subtitle == "Folder · 200 GB available")
        let over = Self.content(item, volume: InfoVolume(totalBytes: 10, availableBytes: 50), root: true)
        #expect(Self.row(over, .general, "Used")?.value == .usage(fraction: 0, text: "0 B"))
    }

    @Test func aFolderGetsTheFolderSizeCellAndAPackageToo() {
        var folder = Self.file()
        folder.kind = .directory
        let idle = Self.content(folder, folderSize: .idle)
        #expect(
            Self.row(idle, .general, "Size") == InfoRow(label: "Size", value: .folderSize, muted: true, detail: "—"))
        let error = Self.content(folder, folderSize: .error(message: "x"))
        #expect(Self.row(error, .general, "Size")?.muted == true)
        let without = Self.content(folder)
        #expect(Self.row(without, .general, "Size")?.value == .text("--"))
        let ready = Self.content(
            folder, folderSize: .ready(sizeBytes: 1_200_000_000, diskBytes: 1_300_000_000, fileCount: 4, folderCount: 1)
        )
        #expect(ready.subtitle == "Markdown document · 1.2 GB")
        #expect(Self.row(ready, .general, "Size")?.detail == "1,200,000,000 bytes")
        var link = Self.file()
        link.kind = .symlinkDirectory
        #expect(Self.row(Self.content(link), .general, "Size")?.value == .text("2.0 KB (2,000 bytes)"))
    }

    @Test func theFolderSizeLines() {
        let lines = InfoPanelModel.folderSizeLines(
            sizeBytes: 1_200_000_000, diskBytes: 1_300_000_000, fileCount: 48_611, folderCount: 2_765,
            locale: Locale(identifier: "en_US"))
        #expect(lines.top == "1.2 GB (1.3 GB on disk)")
        #expect(lines.items == "48,611 files, 2,765 folders")
        let same = InfoPanelModel.folderSizeLines(sizeBytes: 100, diskBytes: 100, fileCount: 1, folderCount: 0)
        #expect(same.top == "100 B" && same.items == "1 file")
        #expect(
            InfoPanelModel.folderSizeLines(sizeBytes: 0, diskBytes: 0, fileCount: 0, folderCount: 0).items == "Empty")
    }

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
        let rows = InfoPanelModel.selectionContent(files, facts: .init(), hasFolderSize: false, folderSize: nil)[0].rows
        #expect(rows[0] == InfoRow(label: "Size", value: .text("--"), muted: true))
        #expect(
            rows[1]
                == InfoRow(
                    label: "Where", value: .place(Self.demoWhere), muted: false,
                    copyText: "/Users/demo"))
        let several = InfoPanelModel.selectionContent(
            selection, facts: .init(), hasFolderSize: true, folderSize: .idle)[0]
            .rows
        #expect(several[1].value == .folderSize)
        #expect(several[2] == InfoRow(label: "Where", value: .text("Several folders"), muted: true))
    }

    // Several items: what grows with how many there are stays on one line, or says how many there are.
    @Test func severalItemsKeepEachValueToOneLine() {
        let selection = InfoSelection(count: 4, folderCount: 0, fileCount: 4, totalBytes: 10, parentPath: "/a")
        let facts = InfoSelectionFacts(
            kindLabels: ["PDF document", "HEIF Image", "HEIF Image", "Folder"],
            created: [
                ISODateForTests.date("2026-03-01T09:00:00.000Z"), ISODateForTests.date("2026-03-09T09:00:00.000Z"),
            ],
            modified: [ISODateForTests.date("2026-03-02T09:00:00.000Z")], modes: [0o644, 0o644, 0o755, 0o600])
        let sections = InfoPanelModel.selectionContent(
            selection, facts: facts, hasFolderSize: false, folderSize: nil, dates: Self.dates)
        #expect(sections.map(\.id) == [.general, .dates, .permissions])
        #expect(
            sections[0].rows[0].value
                == .fitting(full: "HEIF Image (2), PDF document, Folder", short: "3 kinds"))
        #expect(sections[1].rows.map(\.value) == [.text("Mar 1 – Mar 9, 2026"), .text("Mar 2, 2026")])
        #expect(sections[2].rows[0].value == .fitting(full: "644 on 2 · 755 on 1 · 600 on 1", short: "3 modes"))
        // A mode not known yet for one of them: a dash, not a partial count.
        let unknown = InfoPanelModel.selectionContent(
            selection, facts: InfoSelectionFacts(modes: [0o644, nil]), hasFolderSize: false, folderSize: nil)
        #expect(unknown[2].rows[0] == InfoRow(label: "Mode", value: .text("—"), muted: true))
        let same = InfoPanelModel.selectionContent(
            selection, facts: InfoSelectionFacts(kindLabels: ["Folder", "Folder"], modes: [0o755, 0o755]),
            hasFolderSize: false, folderSize: nil)
        #expect(same[0].rows[0].value == .fitting(full: "Folder (2)", short: "Folder (2)"))
        #expect(same[2].rows[0].value == .text("755"))
    }

    // A folder or app has Contains where a file has Opens with, a dash until it has been measured.
    @Test func aFolderSaysWhatItContains() {
        var folder = Self.file()
        folder.kind = .directory
        let unmeasured: [FolderSizeEntry?] = [nil, .idle, .calculating(jobID: "j"), .error(message: "x")]
        for entry in unmeasured {
            let content = Self.content(folder, folderSize: entry)
            #expect(Self.labels(content, .general) == ["Kind", "Contains", "Size", "Where"])
            #expect(
                Self.row(content, .general, "Contains") == InfoRow(label: "Contains", value: .text("—"), muted: true))
        }
        let ready = FolderSizeEntry.ready(sizeBytes: 1000, diskBytes: 1000, fileCount: 2, folderCount: 1)
        #expect(
            Self.row(Self.content(folder, folderSize: ready), .general, "Contains")
                == InfoRow(label: "Contains", value: .text("2 files, 1 folder"), muted: false))
        folder.kind = .bundle
        #expect(Self.labels(Self.content(folder, folderSize: ready), .general).contains("Contains"))
    }

    // Disks, files and symlinks to folders have no Contains row.
    @Test func onlyFoldersAndAppsHaveAContainsRow() {
        var item = Self.file()
        #expect(!Self.labels(Self.content(item, opens: .available), .general).contains("Contains"))
        item.kind = .symlinkDirectory
        #expect(!Self.labels(Self.content(item), .general).contains("Contains"))
        item.kind = .directory
        let disk = Self.labels(Self.content(item, root: true, folderSize: .idle), .general)
        #expect(!disk.contains("Contains") && disk.contains("Capacity"))
    }

    // Several items have Contains above Size only with folders among them.
    @Test func severalItemsContainWhatTheirFoldersDo() {
        let mixed = InfoSelection(count: 3, folderCount: 1, fileCount: 2, totalBytes: nil, parentPath: nil)
        func rows(_ selection: InfoSelection, _ has: Bool, _ entry: FolderSizeEntry?) -> [InfoRow] {
            InfoPanelModel.selectionContent(selection, facts: .init(), hasFolderSize: has, folderSize: entry)[0].rows
        }
        let waiting = rows(mixed, true, .idle)
        #expect(waiting.map(\.label) == ["Contains", "Size", "Where"])
        #expect(waiting[0] == InfoRow(label: "Contains", value: .text("—"), muted: true))
        let ready = rows(mixed, true, .ready(sizeBytes: 1000, diskBytes: 1000, fileCount: 1, folderCount: 0))
        #expect(ready[0] == InfoRow(label: "Contains", value: .text("1 file"), muted: false))
        let files = InfoSelection(count: 2, folderCount: 0, fileCount: 2, totalBytes: 10, parentPath: nil)
        #expect(rows(files, false, nil).map(\.label) == ["Size", "Where"])
    }

    @Test func aRowCopiesWhatItShows() {
        #expect(InfoRow(label: "Kind", value: .text("PDF document"), muted: false).textToCopy == "PDF document")
        #expect(
            InfoRow(label: "Size", value: .text("3.1 MB"), muted: false, detail: "3.2 MB on disk").textToCopy
                == "3.1 MB\n3.2 MB on disk")
        #expect(
            InfoRow(label: "Where", value: .place("a › b"), muted: false, copyText: "/a/b/c")
                .textToCopy == "/a/b/c")
        #expect(
            InfoRow(label: "Kinds", value: .fitting(full: "A, B", short: "2 kinds"), muted: false).textToCopy == "A, B")
    }

    @Test func theInfoRowSaysWhatTheStatusBarDoesNot() {
        let entry = InfoEntry(path: "/Users/demo/notes.md", name: "notes.md", fileExtension: "md", kind: .file)
        let now = ISODateForTests.date("2026-03-02T11:00:00Z")
        func facts(
            _ entry: InfoEntry, metadata: InfoMetadata? = nil, item: InfoItem? = nil,
            folderSize: FolderSizeEntry? = nil,
            details: InfoDetails? = nil, shown: Bool = false, available: Int64? = nil
        ) -> InfoPanelModel.RowFacts {
            InfoPanelModel.rowFacts(
                entry: entry, metadata: metadata, item: item, folderSize: folderSize, details: details,
                isShownFolder: shown, availableBytes: available, now: now, dates: Self.dates, homePath: "/Users/demo")
        }
        let bare = facts(entry)
        #expect(bare.kind == "MD File" && bare.fact == nil && bare.modified == nil)
        let listed = InfoMetadata(
            kindLabel: "Markdown document", modifiedAt: ISODateForTests.date("2026-03-02T10:30:00.000Z"),
            sizeBytes: 2000, sizeStatus: .ready)
        // No size: the status bar has it.
        let known = facts(entry, metadata: listed)
        #expect(known.kind == "Markdown document" && known.fact == nil)
        #expect(known.modified == "Modified 30 min ago")
        #expect(known.modifiedTooltip?.contains("2026") == true)
        var text = InfoDetails()
        text.text = .init(lines: 320, encoding: "UTF-8", lineEnding: "LF")
        #expect(facts(entry, metadata: listed, details: text).fact == "320 lines")
        // A folder: the size control until measured, then what it holds.
        let folder = InfoEntry(path: "/Users/demo/Projects", name: "Projects", kind: .directory)
        let waiting = facts(folder, metadata: listed, folderSize: .idle)
        #expect(waiting.showsFolderSize && waiting.fact == nil)
        let measured = facts(folder, folderSize: .ready(sizeBytes: 9, diskBytes: 9, fileCount: 45, folderCount: 20))
        #expect(!measured.showsFolderSize && measured.fact == "45 files, 20 folders")
        // The folder on screen: no "Folder", and the room left on its disk.
        let shown = facts(folder, metadata: listed, shown: true, available: 212_000_000_000)
        #expect(shown.kind == nil && shown.available == "212 GB available")
        // An alias or a link: where it leads.
        var alias = Self.file()
        alias.path = "/Users/demo/Projects"
        alias.original = .found("/Users/demo/src/projects")
        #expect(
            facts(InfoEntry(path: alias.path, name: "Projects", kind: .alias), item: alias).fact == "→ ~/src/projects")
        // Properties of another item are never used.
        let foreign = facts(
            InfoEntry(path: "/Users/demo/other.md", name: "other.md", fileExtension: "md", kind: .file),
            item: Self.file())
        #expect(foreign.kind == "MD File")
    }

    @Test func theFactOfEachKind() {
        func fact(_ fill: (inout InfoDetails) -> Void) -> String? {
            var details = InfoDetails()
            fill(&details)
            return InfoPanelModel.kindFact(details, item: nil, homePath: "")
        }
        #expect(
            fact {
                $0.image = {
                    var i = InfoDetails.Image()
                    i.width = 4032
                    i.height = 3024
                    return i
                }()
            } == "4032 × 3024")
        #expect(
            fact {
                var media = InfoDetails.Media()
                media.seconds = 151
                media.width = 3840
                media.height = 2160
                $0.media = media
            } == "2:31 · 3840 × 2160")
        #expect(
            fact {
                var media = InfoDetails.Media()
                media.seconds = 252
                media.artist = "The Long Hours"
                $0.media = media
            } == "4:12 · The Long Hours")
        #expect(
            fact {
                $0.document = {
                    var d = InfoDetails.Document()
                    d.pages = 1
                    return d
                }()
            } == "1 page")
        #expect(
            fact {
                $0.app = {
                    var a = InfoDetails.App()
                    a.version = "3.7.1"
                    return a
                }()
            } == "Version 3.7.1")
        #expect(fact { _ in } == nil)
    }

    @Test func theWordsOfTheValues() {
        #expect(InfoText.duration(151) == "2:31")
        #expect(InfoText.duration(3723) == "1:02:03")
        #expect(InfoText.exposure(1.0 / 120) == "1/120 s")
        #expect(InfoText.exposure(2.5) == "2.5 s")
        #expect(InfoText.location(latitude: 38.72231, longitude: -9.13934) == "38.7223° N, 9.1393° W")
        #expect(InfoText.bitRate(8_400_000) == "8.4 Mbit/s")
        #expect(InfoText.audio(sampleRate: 48000, channels: 2) == "48 kHz, stereo")
        #expect(InfoText.pageSize(width: 595, height: 842, locale: Locale(identifier: "en_GB")) == "A4 · 210 × 297 mm")
        #expect(
            InfoText.pageSize(width: 612, height: 792, locale: Locale(identifier: "en_US")) == "Letter · 8.5 × 11 in")
        #expect(InfoText.privilege(0o640, shift: 3) == "Read only")
        #expect(InfoText.privilege(0o640, shift: 0) == "No Access")
        #expect(InfoText.sizeWithBytes(686) == "686 B")
        #expect(
            Self.dates.dayRange(
                ISODateForTests.date("2026-03-01T09:00:00.000Z"), ISODateForTests.date("2025-12-30T09:00:00.000Z"))
                == "Dec 30, 2025 – Mar 1, 2026")
    }

    @Test func onlyTheHomeFolderOrAFolderInsideItIsMeasuredAutomatically() {
        func path(open: Bool = true, selected: [String], kind: EntryKind = .directory, home: String = "/Users/demo")
            -> String?
        {
            AutoFolderSize.path(
                infoPanelOpen: open, selectedPaths: selected, selected: selected.first.map { ($0, kind) },
                homePath: home)
        }
        #expect(path(selected: ["/Users/demo/Projects"]) == "/Users/demo/Projects")
        #expect(path(selected: ["/Users/demo/App.app"], kind: .bundle) == "/Users/demo/App.app")
        #expect(path(open: false, selected: ["/Users/demo/Projects"]) == nil)
        #expect(path(selected: ["/Users/demo/Projects", "/Users/demo/Other"]) == nil)
        #expect(path(selected: []) == nil)
        #expect(path(selected: ["/Users/demo"]) == "/Users/demo")
        #expect(path(selected: ["/Users"]) == nil)
        #expect(path(selected: ["/Users/demonstration/x"]) == nil)
        #expect(path(selected: ["/Applications"]) == nil)
        #expect(path(selected: ["/Volumes/Disk/x"]) == nil)
        #expect(path(selected: ["/Users/demo/file.txt"], kind: .file) == nil)
        #expect(path(selected: ["/Users/demo/link"], kind: .symlinkDirectory) == nil)
        #expect(path(selected: ["/Users/demo/Projects"], home: "") == nil)
        #expect(path(selected: ["/Users/demo/Projects"], home: "/Users/demo/") == "/Users/demo/Projects")
        #expect(AutoFolderSize.delayMilliseconds == 500)
    }

    @Test func severalSelectedFoldersAreMeasuredAutomaticallyByTheSameRules() {
        let home = "/Users/demo"
        let selection: [(path: String, kind: EntryKind)] = [
            ("/Users/demo/Projects", .directory), ("/Users/demo/notes.txt", .file), ("/Applications", .directory),
            ("/Applications/Keynote.app", .bundle), ("/Users/demo/link", .symlinkDirectory),
            ("/Users/demo/Music", .directory),
        ]
        let selected = selection.map(\.path)
        func paths(
            panel: Bool = true, row: Bool = false, showInfo: String? = nil,
            item: (path: String, kind: EntryKind)? = nil
        ) -> [String] {
            AutoFolderSize.paths(
                infoPanelOpen: panel, infoRowOpen: row, selectedPaths: selected, selected: nil, selection: selection,
                showInfoPath: showInfo, infoItem: item, homePath: home)
        }
        #expect(paths() == ["/Users/demo/Projects", "/Applications/Keynote.app", "/Users/demo/Music"])
        #expect(paths(panel: false, row: true) == paths())
        #expect(paths(panel: false) == [])
        // Get Info's item in the panel goes first; the row still measures the selection.
        let shown = (path: "/Users/demo/Pictures", kind: EntryKind.directory)
        #expect(paths(showInfo: shown.path, item: shown) == [shown.path])
        #expect(paths(panel: false, row: true, showInfo: shown.path, item: shown) == paths())
        // One item selected, or none, is what `path` names.
        let one = (path: "/Users/demo/Projects", kind: EntryKind.directory)
        #expect(
            AutoFolderSize.paths(infoPanelOpen: true, selectedPaths: [one.path], selected: one, homePath: home)
                == [one.path])
        #expect(
            AutoFolderSize.paths(
                infoPanelOpen: true, selectedPaths: [], selected: nil, shownFolder: (home, .directory),
                homePath: home) == [home])
    }

    private let autoHome = "/Users/demo"
    private let autoFolder = (path: "/Users/demo/Projects", kind: EntryKind.directory)

    @Test func measuresTheOneFolderSelectedWithOnlyTheInfoRowOpen() {
        func path(
            panel: Bool = false, row: Bool = true, selected: [String]? = nil, showInfo: String? = nil,
            item: (path: String, kind: EntryKind)? = nil
        ) -> String? {
            AutoFolderSize.path(
                infoPanelOpen: panel, infoRowOpen: row, selectedPaths: selected ?? [autoFolder.path],
                selected: autoFolder, showInfoPath: showInfo, infoItem: item, homePath: autoHome)
        }
        #expect(path() == autoFolder.path)
        #expect(path(selected: [autoFolder.path, "/Users/demo/Music"]) == nil)
        // The row shows the selection, whatever Get Info put in the closed panel.
        let shown = (path: "/Users/demo/Music", kind: EntryKind.directory)
        #expect(path(showInfo: shown.path, item: shown) == autoFolder.path)
        // With both open, the panel's item.
        #expect(path(panel: true, showInfo: shown.path, item: shown) == shown.path)
        #expect(path(row: false) == nil)
    }

    // With nothing selected, the folder on screen, however it was opened (the tree, Go Up, Back, a path).
    @Test func measuresTheFolderOnScreenWithNothingSelected() {
        func path(
            panel: Bool = true, row: Bool = false, selected: [String] = [], folder: String = "/Users/demo",
            kind: EntryKind = .directory, showInfo: String? = nil, item: (path: String, kind: EntryKind)? = nil
        ) -> String? {
            AutoFolderSize.path(
                infoPanelOpen: panel, infoRowOpen: row, selectedPaths: selected,
                selected: selected.first.map { ($0, .directory) }, shownFolder: (folder, kind), showInfoPath: showInfo,
                infoItem: item, homePath: autoHome)
        }
        #expect(path() == "/Users/demo")
        #expect(path(folder: autoFolder.path) == autoFolder.path)
        #expect(path(panel: false, row: true, folder: autoFolder.path) == autoFolder.path)
        #expect(path(panel: false, row: false) == nil)
        #expect(path(folder: "/Applications") == nil)
        #expect(path(folder: "/Applications/Keynote.app", kind: .bundle) == "/Applications/Keynote.app")
        // A selection, or Get Info's item in the panel, goes first.
        #expect(path(selected: ["/Users/demo/Music"]) == "/Users/demo/Music")
        #expect(path(selected: ["/Users/demo/Music", "/Users/demo/Movies"]) == nil)
        let shown = (path: "/Users/demo/Music", kind: EntryKind.directory)
        #expect(path(showInfo: shown.path, item: shown) == shown.path)
        // The row alone shows the folder on screen, whatever Get Info put in the closed panel.
        #expect(path(panel: false, row: true, showInfo: shown.path, item: shown) == "/Users/demo")
    }

    @Test func measuresAnAppOutsideTheHomeFolder() {
        let app = (path: "/Applications/Keynote.app", kind: EntryKind.bundle)
        #expect(
            AutoFolderSize.path(infoPanelOpen: true, selectedPaths: [app.path], selected: app, homePath: autoHome)
                == app.path)
    }

    @Test func measuresTheFolderShowInfoPutInThePanelOnceThePanelShowsIt() {
        func path(
            open: Bool = true, selected: [String]? = nil, entry: (path: String, kind: EntryKind)?? = nil,
            showInfo: String?, item: (path: String, kind: EntryKind)?
        ) -> String? {
            AutoFolderSize.path(
                infoPanelOpen: open, selectedPaths: selected ?? [autoFolder.path], selected: entry ?? autoFolder,
                showInfoPath: showInfo, infoItem: item, homePath: autoHome)
        }
        let shown = (path: "/Users/demo/Music", kind: EntryKind.directory)
        #expect(path(showInfo: shown.path, item: shown) == shown.path)
        // The same folder as the one selected, as after right-clicking it.
        #expect(path(showInfo: autoFolder.path, item: autoFolder) == autoFolder.path)
        // Not while the panel still shows something else, nor with nothing selected.
        #expect(path(showInfo: shown.path, item: autoFolder) == nil)
        #expect(path(selected: [], entry: .some(nil), showInfo: shown.path, item: nil) == nil)
        // The same rules as for the selection otherwise.
        let outside = (path: "/Volumes/Disk/x", kind: EntryKind.directory)
        #expect(path(showInfo: outside.path, item: outside) == nil)
        #expect(path(open: false, showInfo: shown.path, item: shown) == nil)
    }
}
