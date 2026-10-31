// Ports apps/desktop/src/renderer/lib/toasts.test.ts, and checks lib/bottomStack.ts and the progress card's words
import Testing

@testable import FTFoundation

struct ToastsTests {
    // T-27fe44c2
    // B-CLIP-131
    @Test func dropsTheOldestVisibleToastWhenAFourthToastIsQueued() {
        func entry(_ number: Int) -> ToastEntry {
            Toasts.entry(id: "toast-\(number)", kind: .info, title: "Toast \(number)", now: 0)
        }
        let queued = Toasts.enqueue(Toasts.enqueue(Toasts.enqueue([entry(1)], entry(2)), entry(3)), entry(4))
        #expect(queued.map(\.id) == ["toast-2", "toast-3", "toast-4"])
    }

    // T-0638bf68
    // B-CLIP-131
    @Test func keepsEveryNotificationOnScreenForFourSeconds() {
        for kind in [ToastKind.info, .success] {
            let toast = Toasts.entry(id: "toast-1", kind: kind, title: "Moved 1 item", now: 1_000)
            #expect(toast.durationMs == 4_000)
            #expect(toast.expiresAt == 5_000)
        }
    }

    @Test func anEmptyMessageIsNoMessage() {
        #expect(Toasts.entry(id: "a", kind: .success, title: "t", message: "", now: 0).message == nil)
        #expect(Toasts.entry(id: "a", kind: .success, title: "t", message: "m", now: 0).message == "m")
    }

    // F-797..F-799 B-INFO-192 B-INFO-193: where the stack rests (lib/bottomStack.ts)
    // B-INFO-191 B-INFO-192 B-INFO-193 B-VIEW-199 T-2709df93 T-a1bd6809
    @Test func theStackRestsTenPointsAboveTheHighestBarAndTwelveFromTheEdgeWithNone() {
        #expect(BottomStack.offsetAboveBars(windowHeight: 760, barTops: []) == 12)
        // The path bar's top is 33 up from the bottom: 33 + 10.
        #expect(BottomStack.offsetAboveBars(windowHeight: 760, barTops: [727]) == 43)
        // The Info Row is above the path bar: the higher of the two counts.
        #expect(BottomStack.offsetAboveBars(windowHeight: 760, barTops: [727, 697]) == 73)
        // A 28 pt path bar under a 30 pt Info Row: 58 up from the bottom, plus 10.
        #expect(BottomStack.offsetAboveBars(windowHeight: 760, barTops: [760 - 28, 760 - 58]) == 68)
        // A bar nearly at the edge never takes the stack below the edge offset.
        #expect(BottomStack.offsetAboveBars(windowHeight: 760, barTops: [759]) == 12)
    }

    // B-INFO-192 B-VIEW-199
    @Test func notificationsRestAboveTheCardWhenThereIsOne() {
        #expect(BottomStack.offsetAboveBarsAndCard(windowHeight: 760, barTops: [727], cardHeight: nil) == 43)
        #expect(BottomStack.offsetAboveBarsAndCard(windowHeight: 760, barTops: [727], cardHeight: 90) == 43 + 90 + 8)
    }

    // F-840: the delays before something shows
    @Test func theDelaysBeforeSomethingShowsAreTheOriginals() {
        #expect(ShowDelays.progressCardMs == 500)
        #expect(ShowDelays.loadingFolderMs == 400)
        #expect(ShowDelays.loadingTreeMs == 400)
        #expect(ShowDelays.pathBarMenuMs == 300)
        #expect(ShowDelays.spinnerMs == 300)
        #expect(ShowDelays.searchStopMs == 400)
    }
}

struct ProgressCardTextTests {
    func state(
        _ action: WriteOperationAction = .moveTo, stage: WriteOperationStage = .running, done: Int = 0, total: Int = 0,
        bytes: Int64 = 0, totalBytes: Int64? = nil, current: String? = nil, target: String? = nil
    ) -> WriteOperationCardState {
        WriteOperationCardState(
            action: action, stage: stage, targetPath: target, completedItemCount: done, totalItemCount: total,
            completedByteCount: bytes, totalBytes: totalBytes, currentSourcePath: current)
    }

    // B-CLIP-064
    @Test func anOperationIsNamedByWhatItDoesWhileItRunsAndWhatItWasAfterwards() {
        let progress: [(WriteOperationAction, String, String)] = [
            (.moveTo, "Moving…", "Move"), (.copyTo, "Copying…", "Copy"), (.duplicate, "Duplicating…", "Duplicate"),
            (.trash, "Moving to Trash…", "Move to Trash"), (.deleteImmediately, "Deleting…", "Delete Immediately"),
            (.rename, "Renaming…", "Rename"), (.batchRename, "Renaming…", "Rename"),
            (.newFolder, "Creating Folder…", "New Folder"), (.undo, "Undoing…", "Undo"), (.redo, "Redoing…", "Redo"),
            (.paste, "Pasting…", "Paste"),
        ]
        for (action, running, done) in progress {
            #expect(ProgressCardText.title(action) == running)
            #expect(ProgressCardText.title(action, result: true) == done)
        }
    }

    // B-CLIP-112
    @Test func theBarFollowsTheBytesThenTheItems() {
        #expect(ProgressCardText.percent(state(done: 1, total: 4, bytes: 500, totalBytes: 1_000)) == 50)
        #expect(ProgressCardText.percent(state(done: 1, total: 4)) == 25)
        #expect(ProgressCardText.percent(state(stage: .starting)) == 4)
        #expect(ProgressCardText.percent(state(stage: .analyzing)) == 4)
        #expect(ProgressCardText.percent(state(stage: .running)) == 0)
    }

    // B-CLIP-064 B-CLIP-077 B-CLIP-112
    @Test func theMetaLineSaysWhatIsHappeningWhenThereAreNoBytes() {
        #expect(ProgressCardText.byteLabel(state(stage: .starting)) == "Preparing…")
        #expect(ProgressCardText.byteLabel(state(stage: .analyzing)) == "Preparing…")
        #expect(ProgressCardText.byteLabel(state(stage: .queued)) == "Waiting to start")
        #expect(ProgressCardText.byteLabel(state(stage: .awaitingResolution)) == "Waiting for your answer")
        #expect(ProgressCardText.byteLabel(state(stage: .running)) == "Working…")
        #expect(
            ProgressCardText.byteLabel(state(bytes: 1_200_000_000, totalBytes: 3_000_000_000)) == "1.2 GB of 3.0 GB")
    }

    // B-CLIP-111
    @Test func theCardNamesTheItemItIsOnAndHowManyAreDone() {
        let text = ProgressCardText(
            state(
                .copyTo, done: 2, total: 1_204, bytes: 1_200_000_000, totalBytes: 3_000_000_000, current: "/a/b/c.txt"),
            currentPath: "/folder")
        #expect(text.title == "Copying…")
        #expect(text.metaStart == "2 of 1,204 items")
        #expect(text.metaEnd == "1.2 GB of 3.0 GB")
        #expect(text.detailLabel == "Current item")
        #expect(text.detailValue == "c.txt")
        #expect(text.percentLabel == "40%")
    }

    // B-CLIP-111
    @Test func aNewFolderNamesItsDestinationAndTheFolderOnScreenStandsInForAMissingItem() {
        let made = ProgressCardText(state(.newFolder, total: 1, target: "/a/Docs"), currentPath: "/folder")
        #expect(made.detailLabel == "Destination")
        #expect(made.detailValue == "Docs")
        let bare = ProgressCardText(state(.trash, total: 1), currentPath: "/folder/inner")
        #expect(bare.detailValue == "inner")
        #expect(bare.metaStart == "0 of 1 item")
    }
}
