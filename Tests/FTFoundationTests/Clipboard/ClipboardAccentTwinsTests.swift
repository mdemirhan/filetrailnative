// Two items whose paths differ only in how an accent is stored, on the clipboard and in a drag
import CoreGraphics
import Foundation
import Testing

@testable import FTFoundation

/// "café" with its "é" as one scalar, and as an "e" with the accent after it: one name to `String`, two items on a
/// disk that keeps both.
struct ClipboardAccentTwinsTests {
    private static let t1 = "2026-11-20T10:00:00.000Z"
    private static let t2 = "2026-11-20T10:00:05.000Z"
    private let composed = "/disk/caf\u{E9}"
    private let decomposed = "/disk/cafe\u{301}"
    private let folder = ClipboardSourceEntry(kind: .directory, isSymlink: false)
    private let file = ClipboardSourceEntry(kind: .file, isSymlink: false, isExecutable: true)

    private func bytes(_ paths: [String]) -> [[UInt8]] { paths.map { Array($0.utf8) } }

    /// What is known of each: the first is a folder, the second a file.
    private func known() -> [DiskPath: ClipboardSourceEntry] {
        [DiskPath(composed): folder, DiskPath(decomposed): file]
    }

    @Test func aCopyOfBothKeepsTwoItemsEachWithWhatIsKnownOfIt() {
        let clipboard = ClipboardRules.set(.copy, [composed, decomposed], capturedAt: Self.t1, entries: known())
        #expect(bytes(clipboard.sourcePaths) == bytes([composed, decomposed]))
        #expect(clipboard.pick(at: composed)?.entry == folder)
        #expect(clipboard.pick(at: decomposed)?.entry == file)
    }

    @Test func anAddOfBothKeepsEachWithItsOwnIntentAndWhatIsKnownOfIt() {
        let plan = ClipboardRules.planAdd(.empty, .cut, [composed, decomposed], entries: known())
        #expect(bytes(plan.added) == bytes([composed, decomposed]))
        let added = ClipboardRules.applyAdd(plan, to: .empty, answer: .keepBoth, stamp: Self.t1).clipboard
        #expect(bytes(added.sourcePaths) == bytes([composed, decomposed]))
        #expect(added.pick(at: composed)?.entry == folder)
        #expect(added.pick(at: decomposed)?.entry == file)

        let switched = ClipboardRules.setMode(added, [decomposed], to: .copy, at: Self.t2)
        #expect(switched.pick(at: composed)?.mode == .cut)
        #expect(switched.pick(at: decomposed)?.mode == .copy)
        #expect(bytes(ClipboardRules.removeItem(switched, composed).sourcePaths) == bytes([decomposed]))
    }

    // A paste that moved one of them used that one up: the other stays to be pasted.
    @Test func aPasteThatMovedOneTakesOnlyThatOneOff() {
        let clipboard = ClipboardRules.set(.cut, [composed, decomposed], capturedAt: Self.t1, entries: known())
        let write = ClipboardWrite(
            action: .paste, mode: .cut,
            items: [
                WriteEffectItem(sourcePath: decomposed, destinationPath: "/to/cafe\u{301}", mode: .cut),
                WriteEffectItem(sourcePath: composed, destinationPath: nil, status: .skipped, mode: .cut),
            ])
        let left = ClipboardRules.afterItsPaste(clipboard, write)
        #expect(bytes(left.sourcePaths) == bytes([composed]))
        #expect(left.pick(at: composed)?.entry == folder)
    }

    // An Add that puts both on flashes both marks.
    @Test func theMarksOfBothFlashWhenAnAddPutsBothOn() throws {
        let first = ClipboardRules.set(.copy, ["/disk/other"], capturedAt: Self.t1)
        var tracker = ClipboardFlashTracker(first)
        let added = ClipboardRules.applyAdd(
            ClipboardRules.planAdd(first, .copy, [composed, decomposed]), to: first, stamp: Self.t2
        ).clipboard
        let marks = try #require(ClipboardMarks(added, enabled: true)).flashing(tracker.changed(to: added).paths)
        #expect(marks.flashes(composed))
        #expect(marks.flashes(decomposed))
        #expect(!marks.flashes("/disk/other"))

        // And one alone flashes alone.
        let one = ClipboardRules.setMode(added, [composed], to: .cut, at: "2026-11-20T10:00:09.000Z")
        let later = try #require(ClipboardMarks(one, enabled: true)).flashing(tracker.changed(to: one).paths)
        #expect(later.flashes(composed))
        #expect(!later.flashes(decomposed))
    }

    // A drag's pictures set off from where each of the two is drawn.
    @Test func aDragOfBothShowsEachWhereItIsDrawn() {
        func placed(_ y: Double) -> FileDragPlacement {
            FileDragPlacement(
                iconRect: CGRect(x: 10, y: y, width: 16, height: 16),
                nameRect: CGRect(x: 30, y: y, width: 60, height: 16), nameFontSize: 13, nameCentered: false,
                thumbnail: false, inSight: true)
        }
        let images = FileDragImages.measure(
            [composed, decomposed], placements: [DiskPath(composed): placed(100), DiskPath(decomposed): placed(124)])
        #expect(images.map(\.iconRect.minY) == [100, 124])
    }

    // One of them dragged onto the other is a drop on another folder; onto itself, or into itself, it is refused.
    @Test func aDragOfOneOntoTheOtherIsADropOnAnotherFolder() {
        let session = DragSession(
            sourceSurface: .content, sourceItems: [DragItem(path: composed, kind: .directory)], leadPath: composed,
            leadKind: .directory)
        func refusal(_ target: String) -> DropRefusal? {
            DragRules.validate(
                session: session, blocked: false, targetSurface: .content, targetPath: target,
                targetSupportsMove: true)
        }
        #expect(refusal(decomposed) == nil)
        #expect(refusal(decomposed + "/inside") == nil)
        #expect(refusal(composed) == .samePath)
        #expect(refusal(composed + "/inside") == .parentIntoChild)
        // Its own folder holds both: a move there does nothing, whichever of the two is dragged.
        #expect(refusal("/disk") == .alreadyInTarget)
    }
}
