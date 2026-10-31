import Foundation
import Testing

@testable import FTFileSystem

final class ProbeCounter: @unchecked Sendable {
    var live = 0
}

@MainActor
@Suite struct ProbeFail {
    @Test func failedStreamIsReleased() async {
        let counter = ProbeCounter()
        var fail: (@MainActor () -> Void)?
        let watches = FolderWatches(
            FolderWatches.Dependencies(
                watchFolder: { _, _, onFail in
                    counter.live += 1
                    fail = onFail
                    return { counter.live -= 1 }
                },
                readModifiedTime: { _ in 1 },
                onFolderChanged: { _, _ in },
                forgetCachedListings: { _, _ in },
                scheduler: ManualScheduler()))
        watches.watch(windowID: 1, path: "/tmp/x")
        fail?()
        watches.checkForMissedChanges(windowID: 1)
        #expect(counter.live == 1, "streams alive after fail+restart: \(counter.live)")
    }
}
