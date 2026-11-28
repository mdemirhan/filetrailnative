// The main thread's blocks are watched only when a measured run names a file for them
import FTFoundation
import Foundation
import Testing

@Suite struct StallLogTests {
    // A process the variable doesn't name a file for watches nothing: the tests' own isn't measured.
    @Test func nothingIsWatchedWithoutTheFile() {
        StallLog.start(environment: [:])
        StallLog.start(environment: ["FILETRAIL_STALLS_LOG": ""])
        StallLog.mark("step", ["i": 1])
        #expect(!StallLog.isOn)
    }
}
