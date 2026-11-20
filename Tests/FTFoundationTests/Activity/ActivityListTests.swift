import Testing

@testable import FTFoundation

struct ActivityListTests {
    // What a row says once its item is no longer listed.
    @Test func saysHowWhatWasListedEnded() {
        #expect(ActivityList.endedDetail(.fileOperation, .completed) == "Done")
        #expect(ActivityList.endedDetail(.folderSize, .completed) == "Done")
        #expect(ActivityList.endedDetail(.folderSize, .stopped) == "Stopped")
        #expect(ActivityList.endedDetail(.fileOperation, .failed) == "Didn't finish")
        #expect(ActivityList.endedDetail(.fileOperation, .partly) == "Finished in part")
        #expect(ActivityList.endedDetail(.folderSize, .failed) == "Couldn't calculate")
        #expect(ActivityList.endedDetail(.fileOperation, nil) == "Ended")
    }

    static func size(
        _ path: String, running: Bool = false, automatic: Bool = false, measured: Int = 0
    ) -> FolderSizeActivity {
        FolderSizeActivity(
            jobId: "job:\(path)", path: path, isRunning: running, isAutomatic: automatic, measuredFolderCount: measured)
    }

    // A Calculate Size on several folders is one row, after the sizes asked for one at a time: it says how many of its
    // folders are done, fills as they are, and the folder it is on has no row of its own. It counts as one for the ring.
    @Test func listsACalculateSizeOnSeveralFoldersAsOneRow() {
        let sizes = [Self.size("/Users/demo/a", running: true), Self.size("/Users/demo/b")]
        let items = ActivityList.items(
            operation: nil, sizes: sizes,
            runs: [
                FolderSizeRunActivity(
                    id: "run:1:1", folderCount: 1_200, doneCount: 300, jobId: "job:/Users/demo/a", isWaiting: false),
                FolderSizeRunActivity(id: "run:2:1", folderCount: 2, doneCount: 0, jobId: nil, isWaiting: true),
            ])
        #expect(items.map(\.kind) == [.folderSize, .folderSizeRun, .folderSizeRun])
        #expect(items[0].title == "b")
        #expect(items[1].id == "run:1:1" && items[1].title == "1,200 folders" && !items[1].isWaiting)
        #expect(items[1].detail == "Calculating sizes · 300 of 1,200 done" && items[1].progress == 0.25)
        #expect(items[2].title == "2 folders" && items[2].detail == "Waiting to calculate their sizes")
        #expect(items[2].isWaiting && items[2].progress == nil)
        // Waiting part way, behind another measurement, it keeps how far it got.
        let waiting = ActivityList.items(
            operation: nil, sizes: [],
            runs: [FolderSizeRunActivity(id: "run:1:1", folderCount: 4, doneCount: 1, jobId: nil, isWaiting: true)])
        #expect(waiting[0].isWaiting && waiting[0].progress == 0.25)
        #expect(waiting[0].detail == "Waiting to calculate their sizes")
        #expect(ActivityList.indicator(items) == ActivityIndicator(progress: 0.25, isWaiting: false, moreCount: 2))
        #expect(ActivityList.endedDetail(.folderSizeRun, .completed) == "Done")
        #expect(ActivityList.endedDetail(.folderSizeRun, .stopped) == "Stopped")
    }

    // A measurement the app started by itself says so, for its row to go when it is no longer listed.
    @Test func marksAMeasurementTheAppStartedByItself() {
        let items = ActivityList.items(
            operation: nil,
            sizes: [Self.size("/Users/demo/auto", running: true, automatic: true), Self.size("/Users/demo/asked")])
        #expect(items.map(\.isAutomatic) == [true, false])
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

    // A move writing its copies out to the disk and removing the originals says so where the percent was: every
    // item is counted by then.
    @Test func aFileOperationAtItsEndSaysFinishing() {
        let card = WriteOperationCardState(
            action: .moveTo, stage: .finishing, completedItemCount: 20, totalItemCount: 20, completedByteCount: 200,
            totalBytes: 200)
        let items = ActivityList.items(operation: ("op", card), sizes: [])
        #expect(items.first?.detail == "Finishing · 20 of 20 items")
        #expect(items.first?.progress == 1 && items.first?.isWaiting == false)
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
