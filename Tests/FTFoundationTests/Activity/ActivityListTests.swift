import Testing

@testable import FTFoundation

struct ActivityListTests {
    // The folders of a Calculate Size on several that wait their turn are one row, after the sizes, and count as one
    // more for the ring.
    @Test func listsTheFoldersOfARunStillWaitingAsOneRow() {
        let items = ActivityList.items(
            operation: nil, sizes: [Self.size("/Users/demo/a", running: true)],
            runs: [
                FolderSizeRunActivity(id: "run:1:1", waitingCount: 1_200),
                FolderSizeRunActivity(id: "run:2:1", waitingCount: 1),
                FolderSizeRunActivity(id: "run:2:2", waitingCount: 0),
            ])
        #expect(items.map(\.kind) == [.folderSize, .folderSizeRun, .folderSizeRun])
        #expect(items[1].id == "run:1:1" && items[1].title == "1,200 more folders" && items[1].isWaiting)
        #expect(items[1].detail == "Waiting to calculate their sizes")
        #expect(items[2].title == "1 more folder" && items[2].detail == "Waiting to calculate its size")
        #expect(ActivityList.indicator(items)?.countLabel == "+2")
    }

    static func size(
        _ path: String, running: Bool = false, automatic: Bool = false, measured: Int = 0
    ) -> FolderSizeActivity {
        FolderSizeActivity(
            jobId: "job:\(path)", path: path, isRunning: running, isAutomatic: automatic, measuredFolderCount: measured)
    }

    // The file operation first, then the folder measured, then those waiting in their order.
    @Test func listsTheFileOperationThenTheSizeMeasuredThenThoseWaiting() {
        let card = WriteOperationCardState(
            action: .copyTo, stage: .running, completedItemCount: 1, totalItemCount: 4, completedByteCount: 50,
            totalBytes: 200)
        let items = ActivityList.items(
            operation: ("op", card),
            sizes: [Self.size("/Users/demo/b"), Self.size("/Users/demo/Library", running: true, measured: 1_204)])
        #expect(items.map(\.kind) == [.fileOperation, .folderSize, .folderSize])
        #expect(items.map(\.title).dropFirst() == ["Library", "b"])
        #expect(items[0].progress == 0.25 && !items[0].isWaiting)
        #expect(items[0].detail.hasPrefix("25%"))
        #expect(items[1].detail == "Calculating size · 1,204 folders so far" && items[1].progress == nil)
        #expect(items[2].detail == "Waiting to calculate its size" && items[2].isWaiting)
        #expect(
            ActivityList.indicator(items) == ActivityIndicator(progress: 0.25, isWaiting: false, moreCount: 2))
        #expect(ActivityList.indicator(items)?.countLabel == "+2")
        #expect(ActivityList.summary(items) == "\(items[0].title) and 2 more")
    }

    // A walk the app started by itself is listed only while it holds up a size asked for.
    @Test func listsAnAutomaticWalkOnlyWhileItHoldsUpASizeAskedFor() {
        let automatic = Self.size("/Users/demo", running: true, automatic: true)
        #expect(ActivityList.items(operation: nil, sizes: [automatic]).isEmpty)
        #expect(
            ActivityList.items(operation: nil, sizes: [automatic, Self.size("/Users/demo/x", automatic: true)])
                .isEmpty)
        let holdingUp = ActivityList.items(operation: nil, sizes: [automatic, Self.size("/Users/demo/x")])
        #expect(holdingUp.map(\.title) == ["demo", "x"])
        #expect(ActivityList.items(operation: nil, sizes: []).isEmpty)
        #expect(ActivityList.summary([]) == "Activity")
        // A size measured spins: how far along isn't known.
        #expect(ActivityList.indicator(holdingUp) == ActivityIndicator(progress: nil, isWaiting: false, moreCount: 1))
        #expect(ActivityList.indicator([]) == nil)
    }

    // A file operation waiting for another says so, with no progress yet.
    @Test func aQueuedFileOperationWaits() {
        let card = WriteOperationCardState(action: .moveTo, stage: .queued)
        let items = ActivityList.items(operation: ("op", card), sizes: [])
        #expect(items.first?.isWaiting == true && items.first?.progress == nil && items.first?.detail == "Waiting")
        // Nothing runs: the ring spins dimmed, alone.
        #expect(ActivityList.indicator(items) == ActivityIndicator(progress: nil, isWaiting: true, moreCount: 0))
        #expect(ActivityList.indicator(items)?.countLabel == nil)
    }
}
