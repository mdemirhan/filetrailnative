import Testing

@testable import FTAppKit

@MainActor
struct DrivenRunTests {
    // One list says what marks a run driven by a script: both what it starts from and whether it hands over to a File
    // Trail already open read it, so a snapshot no longer hands over and quits.
    @Test func everyDrivenRunFlagMarksADrivenRun() {
        for flag in ["--automation", "--bench", "--bench-launch", "--bench-scroll", "--snapshot"] {
            #expect(AppDelegate.isDrivenRun(["FileTrail", flag]), "\(flag)")
        }
        #expect(!AppDelegate.isDrivenRun(["FileTrail", "/Users/demo/notes.txt"]))
        #expect(!AppDelegate.isDrivenRun(["FileTrail", "--user-data-dir", "/tmp/x"]))
    }
}
