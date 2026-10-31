// Port of apps/desktop/src/renderer/lib/fileDragImages.test.ts, and by feature of the list, key and mark cases of
// components/ClipboardButton.test.tsx and components/ClipboardMarks.test.tsx: the clipboard menu's model, the marks,
// the flash and the spring hold, without a window
import CoreGraphics
import Foundation
import Testing

@testable import FTFoundation

struct ClipboardMenuAndMarksTests {
    private func items(_ paths: [String]) -> [ClipboardItem] {
        ClipboardRules.items(ClipboardRules.set(.copy, paths, capturedAt: "t"))
    }

    // MARK: The drag images

    private func placed(_ top: Double, icon: Bool = false, centered: Bool = false, inSight: Bool = true)
        -> FileDragPlacement
    {
        FileDragPlacement(
            iconRect: CGRect(x: 8, y: top + 4, width: 16, height: 16),
            nameRect: CGRect(x: 30, y: top + 3, width: 200, height: 18),
            nameFontSize: 13, nameCentered: centered, thumbnail: icon, inSight: inSight)
    }

    // T-e19ec635
    @Test func findsEachDraggedItemWhereItShowsItsIconAndItsName() {
        let images = FileDragImages.measure(
            ["/demo/a.txt", "/demo/b.txt"], placements: ["/demo/a.txt": placed(100), "/demo/b.txt": placed(124)])
        #expect(
            images.first
                == FileDragImage(
                    index: 0, iconRect: CGRect(x: 8, y: 104, width: 16, height: 16),
                    nameRect: CGRect(x: 30, y: 103, width: 200, height: 18), nameFontSize: 13, nameCentered: false,
                    thumbnail: false))
        #expect(images.last?.index == 1)
        #expect(images.last?.iconRect == CGRect(x: 8, y: 128, width: 16, height: 16))
    }

    // T-cc5858e2
    @Test func leavesOutItemsScrolledOutOfSightOrNotOnThePage() {
        let list = CGRect(x: 0, y: 100, width: 400, height: 200)
        let below = placed(320)
        let seen = placed(120)
        #expect(!FileDragImages.isInSight(below.iconRect, within: [list]))
        #expect(FileDragImages.isInSight(seen.iconRect, within: [list]))
        var belowOut = below
        belowOut.inSight = false
        let images = FileDragImages.measure(
            ["/demo/below.txt", "/demo/seen.txt", "/demo/far away.txt"],
            placements: ["/demo/below.txt": belowOut, "/demo/seen.txt": seen])
        #expect(images.map(\.index) == [1])
    }

    // T-e23caeac
    @Test func centersNamesInIconViewAndSendsThePictureShownForAnIcon() {
        let images = FileDragImages.measure(
            ["/demo/photo.jpg", "/demo/notes.txt"],
            placements: ["/demo/photo.jpg": placed(120, icon: true, centered: true), "/demo/notes.txt": placed(150)])
        #expect(images[0].nameCentered && images[0].thumbnail)
        #expect(!images[1].nameCentered && !images[1].thumbnail)
    }

    // T-d52aa58c
    @Test func looksThroughThePageOnceHoweverManyItemsAreDragged() {
        let paths = (0..<5000).map { "/demo/far/\($0).txt" } + ["/demo/b.txt"]
        let images = FileDragImages.measure(
            paths, placements: ["/demo/a.txt": placed(100), "/demo/b.txt": placed(124)])
        #expect(images.map(\.index) == [5000])
        let many = (0..<300).map { "/demo/\($0)" }
        let all = Dictionary(uniqueKeysWithValues: many.map { ($0, placed(0)) })
        #expect(FileDragImages.measure(many, placements: all).count == FileDragImages.maxImages)
    }

    // MARK: The clipboard menu

    // T-ccfcb549 F-801
    // B-CLIP-025
    @Test func listsTheItemsUnderTheFoldersTheyCameFrom() {
        let model = ClipboardMenuModel(items: items(["/Users/demo/a.txt", "/top", "/Users/demo/b.txt"]))
        #expect(model.rows.count == 5)
        #expect(model.rows.first == .heading(label: "demo", parentPath: "/Users/demo"))
        #expect(model.orderedItems.map(\.name) == ["a.txt", "b.txt", "top"])
        #expect(model.pinnedHeading?.label == "demo")
    }

    // T-4914f3c3 F-802 B-CLIP-031 B-CLIP-033 B-CLIP-034
    @Test func isWorkedWithTheArrowKeysReturnDeleteAndEscape() {
        var model = ClipboardMenuModel(items: items(["/a/1", "/a/2", "/a/3"]))
        model.opened()
        #expect(model.activeIndex == -1)
        let result1 = model.key(.up, command: false, control: false, option: false)
        #expect(result1 == .handled)
        #expect(model.activeIndex == 0)
        _ = model.key(.down, command: false, control: false, option: false)
        let result2 = model.key(.enter, command: false, control: false, option: false)
        #expect(result2 == .reveal("/a/2"))
        let result3 = model.key(.backspace, command: false, control: false, option: false)
        #expect(result3 == .remove("/a/2"))
        model.setItems(items(["/a/1", "/a/3"]))
        #expect(model.activeIndex == 1)
        _ = model.key(.end, command: false, control: false, option: false)
        #expect(model.activeIndex == model.clearIndex)
        let result4 = model.key(.space, command: false, control: false, option: false)
        #expect(result4 == .clear)
        _ = model.key(.down, command: false, control: false, option: false)
        #expect(model.activeIndex == model.clearIndex)
        _ = model.key(.home, command: false, control: false, option: false)
        #expect(model.activeIndex == 0)
        let result5 = model.key(.other, command: false, control: false, option: false)
        #expect(result5 == .handled)
        let result6 = model.key(.escape, command: false, control: false, option: false)
        #expect(result6 == .close)
        let result7 = model.key(.tab, command: false, control: false, option: false)
        #expect(result7 == .close)
        let result8 = model.key(.other, command: true, control: false, option: false)
        #expect(result8 == .closeAndPass)
        // Taking off the last item makes Clear Clipboard active.
        model.activeIndex = 1
        model.setItems(items(["/a/1"]))
        #expect(model.activeIndex == model.clearIndex)
    }

    // T-f27ccac2 T-a88bfdb2 F-801 B-CLIP-026 B-CLIP-027
    @Test func drawsOnlyTheRowsInViewOfAClipboardThatHoldsHundredsOfItems() {
        var model = ClipboardMenuModel(items: items((0..<500).map { "/a/\($0)" }))
        #expect(model.drawnRows.count < 30)
        #expect(model.scrolls)
        #expect(model.listHeight == 240)
        model.scrollTop = 24 * 100
        #expect(model.drawnRows == 96..<114)
        #expect(model.pinnedHeading?.label == "a")
        #expect(!ClipboardMenuModel(items: items((0..<9).map { "/a/\($0)" })).scrolls)
    }

    // T-87f80e08 F-801 B-CLIP-036
    @Test func scrollsTheListOnlyWhenTheKeysMoveTheActiveRow() {
        var model = ClipboardMenuModel(items: items((0..<40).map { "/a/\($0)" }))
        model.activeIndex = 20
        #expect(model.scrollTop == 0)
        model.revealActiveRow()
        // Row 21 (the heading is row 0) shows at the foot, below the pinned heading.
        #expect(model.scrollTop == Double(22 * 24 - 240))
        model.activeIndex = 2
        model.revealActiveRow()
        #expect(model.scrollTop == Double(2 * 24))
    }

    // MARK: The marks

    // T-409a0b20 T-b6500c53 T-32b9cf2d T-3553aecb F-791 B-CLIP-013 B-CLIP-018
    // T-709b2590
    @Test func marksOnlyTheItemsOnTheClipboardWhileTheSettingIsOn() throws {
        let cut = ClipboardRules.set(.cut, ["/a/x"], capturedAt: "t")
        let marks = try #require(ClipboardMarks(cut, enabled: true))
        #expect(marks.mark(for: "/a/x") == .cut)
        #expect(marks.mark(for: "/a/y") == nil)
        #expect(marks.mark(for: nil) == nil)
        #expect(ClipboardMarks(cut, enabled: false) == nil)
        #expect(ClipboardMarks(.empty, enabled: true) == nil)
        #expect(
            ClipboardMarks(ClipboardRules.set(.copy, ["/a/x"], capturedAt: "t"), enabled: true)?.mark(for: "/a/x")
                == .copy)
    }

    // T-32b9cf2d F-791 B-CLIP-016 B-CLIP-017
    // B-CLIP-004 B-VIEW-076
    @Test func flashesOnceForEachCopyOrCutAndNotForAnItemTakenOff() {
        var tracker = ClipboardFlashTracker()
        let first = ClipboardRules.set(.copy, ["/a/x", "/a/y"], capturedAt: "t1")
        let result9 = tracker.changed(to: first)
        #expect(result9)
        let result26 = tracker.changed(to: ClipboardRules.removeItem(first, "/a/y"))
        #expect(!result26)
        let result10 = tracker.changed(to: ClipboardRules.set(.cut, ["/a/x"], capturedAt: "t2"))
        #expect(result10)
        let result27 = tracker.changed(to: .empty)
        #expect(!result27)
        let result11 = tracker.changed(to: ClipboardRules.set(.cut, ["/a/x"], capturedAt: "t2"))
        #expect(result11)
    }

    // MARK: Springing

    // F-841 B-CLIP-166 B-CLIP-167
    // T-4d2cf392 T-8ca6669c T-d34dd2ba T-e9b3fa09
    @Test func springsAFolderOpenAfterAHoldUnlessThePointerMoves() {
        var hold = SpringHold()
        let point = (x: 10.0, y: 10.0)
        let result12 = hold.over("/a/F", canSpring: true, at: point, now: 0)
        #expect(result12 == .idle)
        let result13 = hold.over("/a/F", canSpring: true, at: point, now: 200)
        #expect(result13 == .idle)
        let result14 = hold.over("/a/F", canSpring: true, at: point, now: 400)
        #expect(result14 == .idle)
        let result15 = hold.over("/a/F", canSpring: true, at: point, now: 600)
        #expect(result15 == .idle)
        let result16 = hold.over("/a/F", canSpring: true, at: point, now: 700)
        #expect(result16 == .warning("/a/F"))
        #expect(hold.warningPath == "/a/F")
        let result17 = hold.over("/a/F", canSpring: true, at: point, now: 900)
        #expect(result17 == .warning("/a/F"))
        let result18 = hold.over("/a/F", canSpring: true, at: point, now: 1100)
        #expect(result18 == .warning("/a/F"))
        let result19 = hold.over("/a/F", canSpring: true, at: point, now: 1325)
        #expect(result19 == .open("/a/F"))
        // A folder under a pointer that hasn't moved since waits for it to move.
        let result20 = hold.over("/a/F/G", canSpring: true, at: point, now: 1400)
        #expect(result20 == .idle)
        let result21 = hold.over("/a/F/G", canSpring: true, at: point, now: 2500)
        #expect(result21 == .idle)
        // A move of more than 3 pt, or a gap of more than 300 ms, starts the hold again.
        var moved = SpringHold()
        _ = moved.over("/a/F", canSpring: true, at: point, now: 0)
        let result22 = moved.over("/a/F", canSpring: true, at: (x: 14, y: 10), now: 200)
        #expect(result22 == .idle)
        let result23 = moved.over("/a/F", canSpring: true, at: (x: 14, y: 10), now: 800)
        #expect(result23 == .idle)
        let result24 = moved.over("/a/F", canSpring: true, at: (x: 14, y: 10), now: 1000)
        #expect(result24 == .idle)
        // A folder that can't take the drop doesn't spring.
        let result25 = moved.over("/a/F", canSpring: false, at: point, now: 3000)
        #expect(result25 == .idle)
        #expect(moved.warningPath == nil)
    }
}
