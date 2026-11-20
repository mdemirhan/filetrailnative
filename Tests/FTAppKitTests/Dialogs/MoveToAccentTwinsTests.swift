// Move To's checks of the folder chosen against items whose paths differ from it only in how an accent is stored
import Foundation
import Testing

@testable import FTAppKit

/// "café" with its "é" as one scalar, and as an "e" with the accent after it: two folders on a disk that keeps both.
@MainActor
@Suite struct MoveToAccentTwinsTests {
    private let composed = "/disk/caf\u{E9}"
    private let decomposed = "/disk/cafe\u{301}"

    // A folder moved into the other spelling's folder goes into another folder, not into itself.
    @Test func aMoveIntoTheOtherSpellingsFolderIsNotIntoItself() {
        #expect(MainWindowController.insideItself([composed], folder: decomposed + "/inside") == nil)
        #expect(MainWindowController.insideItself([decomposed], folder: composed + "/inside") == nil)
        // Into what is really inside it, it is refused as ever.
        #expect(
            MainWindowController.insideItself([composed], folder: composed + "/inside")
                == "\u{201C}caf\u{E9}\u{201D} can\u{2019}t be moved into itself.")
        #expect(
            MainWindowController.insideItself(["/disk/plain"], folder: "/disk/plain/a/b")
                == "\u{201C}plain\u{201D} can\u{2019}t be moved into itself.")
        // A folder beside it whose name only starts the same is not inside it, and it is not inside itself.
        #expect(MainWindowController.insideItself(["/disk/plain"], folder: "/disk/plainer") == nil)
        #expect(MainWindowController.insideItself(["/disk/plain"], folder: "/disk/plain") == nil)
    }

    // An item in one of the two is not already in the other.
    @Test func anItemInOneIsNotAlreadyInTheOther() {
        #expect(MainWindowController.alreadyThere([composed + "/a.txt"], in: decomposed) == nil)
        #expect(
            MainWindowController.alreadyThere([composed + "/a.txt"], in: composed)
                == "\u{201C}a.txt\u{201D} is already in this folder.")
        #expect(MainWindowController.alreadyThere([composed + "/a.txt", decomposed + "/b.txt"], in: composed) == nil)
        #expect(
            MainWindowController.alreadyThere(["/disk/a.txt", "/disk/b.txt"], in: "/disk")
                == "These items are already in this folder.")
    }
}
