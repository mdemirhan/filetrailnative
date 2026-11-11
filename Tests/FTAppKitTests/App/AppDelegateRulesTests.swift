import Testing

@testable import FTAppKit

@MainActor
struct DrivenRunTests {
    // One list says what marks a run driven by a script: both what it starts from and whether it hands over to a File
    // Trail already open read it, so a snapshot no longer hands over and quits.
    @Test func everyDrivenRunFlagMarksADrivenRun() {
        for flag in ["--automation", "--snapshot"] {
            #expect(AppDelegate.isDrivenRun(["FileTrail", flag]), "\(flag)")
        }
        #expect(!AppDelegate.isDrivenRun(["FileTrail", "/Users/demo/notes.txt"]))
        #expect(!AppDelegate.isDrivenRun(["FileTrail", "--user-data-dir", "/tmp/x"]))
    }
}

struct TerminateRepliesTests {
    // ⌘Q while the question asked on closing the last window is open: the question comes forward and the quit is
    // answered at once, or AppKit would wait for an answer that never comes.
    @Test func answersAQuitThatOnlyBroughtAQuestionForward() {
        var replies = TerminateReplies()
        let wasOwed = replies.asked()
        #expect(!wasOwed)
        #expect(replies.answer(.questionBroughtForward, wasOwed: wasOwed) == false)
        #expect(!replies.owed)
    }

    // A second ⌘Q while the first waits on its question leaves the answer to the first, which gives it when the person
    // keeps working.
    @Test func leavesTheAnswerToTheQuitThatWaits() {
        var replies = TerminateReplies()
        let first = replies.asked()
        let second = replies.asked()
        #expect(!first && second)
        #expect(replies.answer(.questionBroughtForward, wasOwed: second) == nil)
        #expect(replies.owed)
        #expect(replies.answer(.keptWorking, wasOwed: first) == false)
        #expect(!replies.owed)
    }

    // A quit that goes ahead is answered by the exit.
    @Test func answersNothingWhenTheAppExits() {
        var replies = TerminateReplies()
        let wasOwed = replies.asked()
        #expect(replies.answer(.exited, wasOwed: wasOwed) == nil)
        #expect(replies.answer(.alreadyShuttingDown, wasOwed: true) == nil)
    }
}
