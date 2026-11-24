import Testing

@testable import FTFoundation

struct SelectionStatusTests {
    private func file(_ path: String) -> SelectionItem { SelectionItem(path: path, isFolderSizeEligible: false) }
    private func folder(_ path: String) -> SelectionItem { SelectionItem(path: path, isFolderSizeEligible: true) }
    // A link to a folder is counted as the link itself.
    private func folderLink(_ path: String) -> SelectionItem { SelectionItem(path: path, isFolderSizeEligible: false) }
    private func ready(_ sizeBytes: Int64, _ diskBytes: Int64? = nil) -> FolderSizeEntry {
        .ready(sizeBytes: sizeBytes, diskBytes: diskBytes ?? sizeBytes, fileCount: 10, folderCount: 2)
    }

    private func summarize(
        _ items: [SelectionItem], files: [String: Int64] = [:], folders: [String: FolderSizeEntry] = [:]
    ) -> SelectionSize {
        SelectionSizing.summarize(items, fileSize: { files[$0] }, folderSize: { folders[$0] ?? .idle })
    }

    @Test func addsUpFilesWhoseSizesTheListHas() {
        #expect(
            summarize([file("/a"), file("/b")], files: ["/a": 1000, "/b": 500])
                == SelectionSize(totalBytes: 1500, folderPaths: [], folderSizeEntry: nil))
        // A file not measured yet: no total yet.
        #expect(summarize([file("/a"), file("/b")], files: ["/a": 1000]).totalBytes == nil)
    }

    @Test func offersCalculateWhileAnyFoldersSizeIsUnknown() {
        let size = summarize([folder("/x"), folder("/y"), file("/a")], files: ["/a": 1], folders: ["/x": ready(100)])
        #expect(size.totalBytes == nil)
        #expect(size.folderPaths == ["/x", "/y"])
        #expect(size.folderSizeEntry == .idle)
        // A failed folder can be tried again the same way.
        let failed = summarize(
            [folder("/x"), folder("/y")], folders: ["/x": ready(100), "/y": .error(message: "denied")])
        #expect(failed.folderSizeEntry == .idle)
    }

    @Test func showsCalculatingWhileAnyFolderIs() {
        let size = summarize([folder("/x"), folder("/y")], folders: ["/x": .calculating(jobID: "1")])
        #expect(size.folderSizeEntry == .calculating(jobID: ""))
    }

    // Waiting while every folder being calculated waits; calculating as soon as one is measured.
    @Test func showsWaitingOnlyWhileNoFolderIsBeingMeasured() {
        let waiting = summarize(
            [folder("/x"), folder("/y")],
            folders: ["/x": .calculating(jobID: "1", waiting: true), "/y": .calculating(jobID: "2", waiting: true)])
        #expect(waiting.folderSizeEntry == .calculating(jobID: "", waiting: true))
        #expect(StatusSummary.sizeText(StatusSummary.selectionSize(waiting)) == "Waiting…")
        let mixed = summarize(
            [folder("/x"), folder("/y")],
            folders: ["/x": .calculating(jobID: "1", waiting: true), "/y": .calculating(jobID: "2")])
        #expect(mixed.folderSizeEntry == .calculating(jobID: ""))
        #expect(StatusSummary.folderSize(.calculating(jobID: "1", waiting: true)) == .waiting)
    }

    @Test func sumsEverythingUpOnceEverySizeIsKnown() {
        let size = summarize(
            [folder("/x"), folder("/y"), file("/a")], files: ["/a": 50],
            folders: ["/x": ready(100, 120), "/y": ready(200, 220)])
        #expect(size.totalBytes == 350)
        // The selected items and everything inside them; files have no size on disk listed, so a
        // selection with files shows the size alone.
        #expect(size.folderSizeEntry == .ready(sizeBytes: 350, diskBytes: 350, fileCount: 21, folderCount: 6))
        // Folders alone: their size on disk too.
        let alone = summarize([folder("/x"), folder("/y")], folders: ["/x": ready(100, 120), "/y": ready(200, 220)])
        guard case .ready(let sizeBytes, let diskBytes, _, _) = alone.folderSizeEntry else {
            Issue.record("not ready")
            return
        }
        #expect(sizeBytes == 300)
        #expect(diskBytes == 340)
    }

    @Test func countsALinkToAFolderAsTheLinkItself() {
        // As measuring the folder they are in counts it, so its size is never waited for, and the
        // folder it points to is not counted twice when it is selected too.
        let size = summarize(
            [folder("/home/dotfiles"), folderLink("/home/scripts"), file("/home/.zshrc")],
            files: ["/home/scripts": 16, "/home/.zshrc": 10], folders: ["/home/dotfiles": ready(1000)])
        #expect(size.totalBytes == 1026)
        #expect(size.folderPaths == ["/home/dotfiles"])
        guard case .ready(let sizeBytes, _, _, _) = size.folderSizeEntry else {
            Issue.record("not ready")
            return
        }
        #expect(sizeBytes == 1026)
    }

    @Test func waitsForAFilesSizeBeforeShowingTheTotalOfKnownFolders() {
        let size = summarize([folder("/x"), file("/a")], folders: ["/x": ready(100)])
        #expect(size.totalBytes == nil)
        #expect(size.folderSizeEntry == nil)
    }

    @Test func showsTheItemCountWhenNothingIsSelected() {
        #expect(StatusSummary.content(itemCount: 4, selectedCount: 0, size: nil) == "4 items")
    }

    @Test func addsTheFoldersSizeWhenNothingIsSelectedAndItIsKnown() {
        #expect(
            StatusSummary.content(itemCount: 4, selectedCount: 0, size: .ready(sizeBytes: 3000)) == "4 items · 3.0 KB")
    }

    @Test func addsTheSelectionsSizeWhenItIsKnown() {
        #expect(
            StatusSummary.content(itemCount: 4, selectedCount: 2, size: .ready(sizeBytes: 3000))
                == "2 of 4 selected · 3.0 KB")
    }

    @Test func saysWhenTheSizeIsBeingCalculated() {
        #expect(
            StatusSummary.content(itemCount: 1, selectedCount: 1, size: .calculating)
                == "1 of 1 selected · Calculating…")
    }

    @Test func saysHowManyItemsShowWhenTypingHasNarrowedTheList() {
        #expect(StatusSummary.content(itemCount: 240, shownCount: 3, selectedCount: 0, size: nil) == "3 of 240 items")
    }

    @Test func searchStatus() {
        #expect(
            StatusSummary.search(
                isSearching: true, shown: 12, totalCount: 12, selectedCount: 2,
                selectionSize: .ready(sizeBytes: 1_200_000))
                == "Searching… 12 results · 2 selected · 1.2 MB")
        #expect(StatusSummary.search(isSearching: false, shown: 1, totalCount: 1, selectedCount: 0) == "1 result")
        #expect(
            StatusSummary.search(
                isSearching: false, shown: 3, totalCount: 40, selectedCount: 1, selectionSize: .calculating)
                == "3 of 40 results · 1 selected · Calculating…")
        // The items a search's conditions have read, while it runs only.
        #expect(
            StatusSummary.search(isSearching: true, shown: 120, totalCount: 120, selectedCount: 1, itemsRead: 3880)
                == "Searching… 120 results · 3,880 items checked · 1 selected")
        #expect(
            StatusSummary.search(isSearching: false, shown: 120, totalCount: 120, selectedCount: 0, itemsRead: 3880)
                == "120 results")
        // Folders the search couldn't read: said last, with no full stop, while it runs and after.
        #expect(
            StatusSummary.search(
                isSearching: false, shown: 3, totalCount: 3, selectedCount: 0, unreadableFolders: true)
                == "3 results · Some folders couldn’t be read")
        #expect(
            StatusSummary.search(
                isSearching: true, shown: 3, totalCount: 3, selectedCount: 1,
                selectionSize: .ready(sizeBytes: 1_200_000), unreadableFolders: true)
                == "Searching… 3 results · 1 selected · 1.2 MB · Some folders couldn’t be read")
    }

    // Counts are grouped as the region groups digits, as Finder writes "1,234 items" (US English in a test process).
    @Test func countsAreGrouped() {
        #expect(StatusSummary.content(itemCount: 1234, selectedCount: 0, size: nil) == "1,234 items")
        #expect(
            StatusSummary.content(itemCount: 12_345, shownCount: 1500, selectedCount: 0, size: nil)
                == "1,500 of 12,345 items")
        #expect(StatusSummary.content(itemCount: 12_345, selectedCount: 1001, size: nil) == "1,001 of 12,345 selected")
        #expect(
            StatusSummary.search(isSearching: true, shown: 2000, totalCount: 10_000, selectedCount: 1500)
                == "Searching… 2,000 of 10,000 results · 1,500 selected")
        #expect(
            StatusSummary.search(isSearching: false, shown: 1234, totalCount: 1234, selectedCount: 0)
                == "1,234 results")
    }

    private func selection(
        totalBytes: Int64? = nil, folderSizeEntry: FolderSizeEntry? = .idle
    ) -> SelectionSize {
        SelectionSize(totalBytes: totalBytes, folderPaths: ["/folder"], folderSizeEntry: folderSizeEntry)
    }

    @Test func selectionSizeIsTheTotalOnceEverySizeIsKnown() {
        #expect(StatusSummary.selectionSize(selection(totalBytes: 10)) == .ready(sizeBytes: 10))
    }

    @Test func selectionSizeIsCalculatingWhileAFolderInTheSelectionIs() {
        #expect(StatusSummary.selectionSize(selection(folderSizeEntry: .calculating(jobID: ""))) == .calculating)
    }

    @Test func selectionSizeIsUnknownWhileAFolderHasNotBeenCalculated() {
        #expect(StatusSummary.selectionSize(selection()) == nil)
    }

    @Test func folderSizeIsReadyOrCalculatingOrUnknown() {
        #expect(
            StatusSummary.folderSize(.ready(sizeBytes: 5, diskBytes: 8, fileCount: 1, folderCount: 0))
                == .ready(sizeBytes: 5))
        #expect(StatusSummary.folderSize(.calculating(jobID: "1")) == .calculating)
        #expect(StatusSummary.folderSize(.error(message: "denied")) == nil)
        #expect(StatusSummary.folderSize(.idle) == nil)
    }
}
