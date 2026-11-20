// Gathering on the clipboard: the Adds, an item's own intent, two items of one name, what a paste leaves, the marks
// and their flash, the list in two parts, and what the menus say
import FTTestSupport
import Foundation
import Testing

@testable import FTFoundation

struct ClipboardShelfTests {
    static let t1 = "2026-11-20T10:00:00.000Z"
    static let t2 = "2026-11-20T10:00:05.000Z"
    static let t3 = "2026-11-20T10:00:09.000Z"

    private func file(_ kind: EntryKind = .file) -> ClipboardSourceEntry {
        ClipboardSourceEntry(kind: kind, isSymlink: false)
    }

    /// `/a/x.txt` copied, then `/b/y.txt` added to move.
    private var mixed: CopyPasteClipboard {
        let copied = ClipboardRules.set(.copy, ["/a/x.txt"], capturedAt: Self.t1)
        return ClipboardRules.applyAdd(ClipboardRules.planAdd(copied, .cut, ["/b/y.txt"]), to: copied, stamp: Self.t2)
            .clipboard
    }

    // MARK: Many items

    // Every file of a large folder copied: the clipboard is described, and the selection looked for on it, in one
    // look at each item. Looking through the whole clipboard for each item took seconds at 5,000 and stopped the app.
    @Test func aClipboardOfFiftyThousandItemsIsDescribedAtOnce() {
        let count = 50_000
        let paths = (0..<count).map { "/Users/demo/Pictures/Export/IMG_\($0).jpg" }
        var clipboard = ClipboardRules.set(.copy, paths, capturedAt: Self.t1)
        // One item kept beside another of its name, so the names are counted too.
        let added = ClipboardRules.set(.copy, paths + ["/Users/demo/Other/IMG_7.jpg"], capturedAt: Self.t1)
        if case .ready(var picks, let capturedAt, let grown) = added {
            picks[count].renamedIfShared = true
            clipboard = .ready(picks: picks, capturedAt: capturedAt, grown: grown)
        }
        // CPU time of this thread, not wall time, so a busy machine does not fail it.
        let (summary, seconds) = CPUTime.measureThread { ClipboardRules.describe(clipboard) }
        #expect(summary != nil)
        let items = ClipboardRules.items(clipboard)
        #expect(items.count == count + 1)
        #expect(items.filter(\.pastedUnderAnotherName).map(\.path) == ["/Users/demo/Other/IMG_7.jpg"])
        #expect(seconds < 1)
        let elsewhere = (0..<count).map { "/Users/demo/Documents/f\($0)" }
        let (held, looking) = CPUTime.measureThread {
            (clipboard.holdsAny(of: elsewhere), clipboard.holdsAny(of: elsewhere + [paths[count - 1]]))
        }
        #expect(held == (false, true))
        #expect(!clipboard.holdsAny(of: []) && !CopyPasteClipboard.empty.holdsAny(of: paths))
        #expect(looking < 1)
    }

    // MARK: Adding

    @Test func anAddJoinsWhatIsThereAndKeepsItsCapture() {
        let next = mixed
        #expect(next.sourcePaths == ["/a/x.txt", "/b/y.txt"])
        #expect(next.picks.map(\.mode) == [.copy, .cut])
        #expect(next.capturedAt == Self.t1)
        #expect(next.isGrown)
        #expect(next.isMixed)
        #expect(next.mode == nil)
        #expect(next.cutPaths == ["/b/y.txt"])
        #expect(next.copiedPaths == ["/a/x.txt"])
        #expect(next.picks.map(\.markedAt) == [Self.t1, Self.t2])
    }

    /// On an empty clipboard an Add is a Copy or a Cut: a new capture, nothing to put back.
    @Test func anAddOnAnEmptyClipboardIsACopyOrACut() {
        let (next, report) = ClipboardRules.applyAdd(
            ClipboardRules.planAdd(.empty, .cut, ["/a/x.txt"], entries: ["/a/x.txt": file()]), to: .empty,
            stamp: Self.t2)
        #expect(next == ClipboardRules.set(.cut, ["/a/x.txt"], capturedAt: Self.t2, entries: ["/a/x.txt": file()]))
        #expect(!next.isGrown)
        #expect(report.startedClipboard)
        #expect(report.added == ["/a/x.txt"])
    }

    @Test func anItemAlreadyThereWithTheOtherIntentSwitchesAndOneWithTheSameStays() {
        let plan = ClipboardRules.planAdd(mixed, .cut, ["/a/x.txt", "/b/y.txt"])
        #expect(plan.added.isEmpty)
        #expect(plan.switched == ["/a/x.txt"])
        #expect(plan.alreadyThere == ["/b/y.txt"])
        #expect(!plan.changesNothing)
        let (next, report) = ClipboardRules.applyAdd(plan, to: mixed, stamp: Self.t3)
        #expect(next.picks.map(\.mode) == [.cut, .cut])
        #expect(next.picks.map(\.markedAt) == [Self.t3, Self.t2])
        #expect(report.switched == ["/a/x.txt"])
        // An Add of what is there with the same intent changes nothing.
        #expect(ClipboardRules.planAdd(next, .cut, ["/b/y.txt"]).changesNothing)
    }

    /// A folder added takes off what of it is on the clipboard (it goes with the folder), whatever its intent; an item
    /// inside a folder on the clipboard is left off, naming the folder.
    @Test func aFolderAndWhatIsInsideItAreNeverBothOnIt() {
        let copied = ClipboardRules.set(.copy, ["/p/Album/a.jpg", "/q/b.txt"], capturedAt: Self.t1)
        let plan = ClipboardRules.planAdd(copied, .cut, ["/p/Album"])
        #expect(plan.added == ["/p/Album"])
        #expect(plan.absorbed == ["/p/Album/a.jpg"])
        let (next, report) = ClipboardRules.applyAdd(plan, to: copied, stamp: Self.t2)
        #expect(next.sourcePaths == ["/q/b.txt", "/p/Album"])
        #expect(report.absorbed == ["/p/Album/a.jpg"])

        let inside = ClipboardRules.planAdd(next, .copy, ["/p/Album/c.jpg", "/r/d.txt"])
        #expect(inside.insideListed.map(\.path) == ["/p/Album/c.jpg"])
        #expect(inside.insideListed.map(\.folder) == ["/p/Album"])
        #expect(inside.added == ["/r/d.txt"])
    }

    /// What Copy records of each item is kept for the icons of the list.
    @Test func anAddKeepsWhatIsKnownOfEachItem() {
        let plan = ClipboardRules.planAdd(mixed, .copy, ["/c/Folder"], entries: ["/c/Folder": file(.directory)])
        let next = ClipboardRules.applyAdd(plan, to: mixed, stamp: Self.t3).clipboard
        #expect(next.pick(at: "/c/Folder")?.entry == file(.directory))
        #expect(ClipboardRules.items(next).last?.isFolder == true)
    }

    // MARK: Two items of one name

    @Test func anItemOfANameOnTheClipboardIsAskedAbout() {
        let copied = ClipboardRules.set(.copy, ["/api/README.md"], capturedAt: Self.t1)
        let plan = ClipboardRules.planAdd(copied, .cut, ["/web/README.md", "/web/index.ts"])
        #expect(plan.clashes == [ClipboardNameClash(path: "/web/README.md", otherPath: "/api/README.md")])
        #expect(plan.added == ["/web/README.md", "/web/index.ts"])
    }

    /// As most Macs' disks compare names: whatever the letter case, however an accented letter is stored.
    @Test func namesClashAsTheDiskWouldTakeThem() {
        let copied = ClipboardRules.set(.copy, ["/a/README.md", "/a/caf\u{E9}.txt"], capturedAt: Self.t1)
        let plan = ClipboardRules.planAdd(copied, .copy, ["/b/Readme.md", "/b/cafe\u{301}.txt", "/b/other.md"])
        #expect(plan.clashes.map(\.path) == ["/b/Readme.md", "/b/cafe\u{301}.txt"])
    }

    /// Two items of one name in the same Add (search results) clash with each other.
    @Test func twoItemsOfOneAddClashWithEachOther() {
        let plan = ClipboardRules.planAdd(.empty, .copy, ["/a/notes.txt", "/b/notes.txt"])
        #expect(plan.clashes == [ClipboardNameClash(path: "/b/notes.txt", otherPath: "/a/notes.txt")])
    }

    @Test func keepBothMarksTheOneAddedToBeRenamedOnPaste() {
        let copied = ClipboardRules.set(.copy, ["/api/README.md"], capturedAt: Self.t1)
        let (next, report) = ClipboardRules.applyAdd(
            ClipboardRules.planAdd(copied, .cut, ["/web/README.md"]), to: copied, answer: .keepBoth, stamp: Self.t2)
        #expect(next.sourcePaths == ["/api/README.md", "/web/README.md"])
        #expect(next.renamedIfSharedPaths == ["/web/README.md"])
        #expect(ClipboardRules.isPastedUnderAnotherName(next, "/web/README.md"))
        #expect(!ClipboardRules.isPastedUnderAnotherName(next, "/api/README.md"))
        #expect(report.keptBoth == ["/web/README.md"])
        #expect(ClipboardRules.items(next).map(\.pastedUnderAnotherName) == [false, true])
    }

    @Test func useThisOneTakesTheOtherOff() {
        let copied = ClipboardRules.set(.copy, ["/api/README.md", "/api/x.txt"], capturedAt: Self.t1)
        let (next, report) = ClipboardRules.applyAdd(
            ClipboardRules.planAdd(copied, .cut, ["/web/README.md"]), to: copied, answer: .useThisOne,
            stamp: Self.t2)
        #expect(next.sourcePaths == ["/api/x.txt", "/web/README.md"])
        #expect(next.renamedIfSharedPaths.isEmpty)
        #expect(report.replacedOnClipboard == ["/api/README.md"])
        #expect(report.added == ["/web/README.md"])
    }

    /// Use These for two of one Add: the later one stays, and the earlier was never on the clipboard to the person.
    @Test func useThisOneWithinOneAddKeepsTheLaterItem() {
        let (next, report) = ClipboardRules.applyAdd(
            ClipboardRules.planAdd(.empty, .copy, ["/a/notes.txt", "/b/notes.txt"]), to: .empty, answer: .useThisOne,
            stamp: Self.t2)
        #expect(next.sourcePaths == ["/b/notes.txt"])
        #expect(report.added == ["/b/notes.txt"])
        #expect(report.replacedOnClipboard.isEmpty)
    }

    @Test func dontAddLeavesOffOnlyTheItemsWhoseNamesClash() {
        let copied = ClipboardRules.set(.copy, ["/api/README.md"], capturedAt: Self.t1)
        let (next, report) = ClipboardRules.applyAdd(
            ClipboardRules.planAdd(copied, .cut, ["/web/README.md", "/web/index.ts"]), to: copied, answer: .dontAdd,
            stamp: Self.t2)
        #expect(next.sourcePaths == ["/api/README.md", "/web/index.ts"])
        #expect(report.leftOff == ["/web/README.md"])
        #expect(report.added == ["/web/index.ts"])
    }

    /// The one that kept the name came off: the one renamed on paste keeps it now, as nothing else has it.
    @Test func aNameNoOtherItemKeepsGoesBackToTheFirstItemOfIt() {
        let copied = ClipboardRules.set(.copy, ["/api/README.md"], capturedAt: Self.t1)
        let both = ClipboardRules.applyAdd(
            ClipboardRules.planAdd(copied, .copy, ["/web/README.md"]), to: copied, stamp: Self.t2
        ).clipboard
        let alone = ClipboardRules.removeItem(both, "/api/README.md")
        #expect(alone.renamedIfSharedPaths.isEmpty)
        #expect(!ClipboardRules.isPastedUnderAnotherName(alone, "/web/README.md"))
    }

    @Test func useThisOneInsteadSwapsWhichKeepsTheName() {
        let copied = ClipboardRules.set(.copy, ["/api/README.md"], capturedAt: Self.t1)
        let both = ClipboardRules.applyAdd(
            ClipboardRules.planAdd(copied, .copy, ["/web/README.md"]), to: copied, stamp: Self.t2
        ).clipboard
        let swapped = ClipboardRules.keepName(both, of: "/web/README.md")
        #expect(swapped.renamedIfSharedPaths == ["/api/README.md"])
        #expect(ClipboardRules.keepName(swapped, of: "/web/README.md") == swapped)
    }

    // MARK: Switching and what a paste leaves

    @Test func anItemIsSwitchedAndItsMarkFlashes() {
        let next = ClipboardRules.setMode(mixed, ["/b/y.txt"], to: .copy, at: Self.t3)
        #expect(next.mode == .copy)
        #expect(next.pick(at: "/b/y.txt")?.markedAt == Self.t3)
        #expect(next.capturedAt == Self.t1)
        #expect(ClipboardRules.setMode(next, ["/b/y.txt"], to: .copy, at: "later") == next)
    }

    /// The paste of this clipboard: what it moved leaves it, what it copied or didn't get to move stays.
    /// A paste that moved items used the clipboard up: what it pasted, moved or copied, leaves; what it didn't get to
    /// stays, to be tried again.
    @Test func aPasteThatMovedItemsUsesTheClipboardUp() {
        let clipboard = ClipboardRules.applyAdd(
            ClipboardRules.planAdd(mixed, .cut, ["/c/z.txt"]), to: mixed, stamp: Self.t3
        ).clipboard
        let write = ClipboardWrite(
            action: .paste, mode: .copy,
            items: [
                WriteEffectItem(sourcePath: "/a/x.txt", destinationPath: "/d/x.txt", mode: .copy),
                WriteEffectItem(sourcePath: "/b/y.txt", destinationPath: "/d/y.txt", mode: .cut),
                WriteEffectItem(sourcePath: "/c/z.txt", destinationPath: "/d/z.txt", status: .failed, mode: .cut),
            ])
        let left = ClipboardRules.afterItsPaste(clipboard, write)
        #expect(left.sourcePaths == ["/c/z.txt"])
        #expect(left.mode == .cut)
        #expect(left.capturedAt == Self.t1)
        // A copied item it didn't get to stays as well.
        var copyFailed = write
        copyFailed.items[0].status = .failed
        #expect(ClipboardRules.afterItsPaste(clipboard, copyFailed).sourcePaths == ["/a/x.txt", "/c/z.txt"])
        // A paste that moved nothing (every cut item skipped) leaves it as it is, its copies to be pasted again.
        var movedNothing = write
        movedNothing.items[1].status = .skipped
        #expect(ClipboardRules.afterItsPaste(clipboard, movedNothing) == clipboard)
        // Move Items Here moved them all.
        let moveAll = ClipboardWrite(
            action: .moveTo, mode: .cut,
            items: [
                WriteEffectItem(sourcePath: "/a/x.txt", destinationPath: "/d/x.txt"),
                WriteEffectItem(sourcePath: "/b/y.txt", destinationPath: "/d/y.txt"),
            ])
        #expect(ClipboardRules.afterItsPaste(mixed, moveAll) == .empty)
    }

    /// A copied item a paste copied beside others it moved stayed where it was: it isn't followed anywhere.
    @Test func aMixedPastesCopiedItemsAreNotFollowed() {
        let other = ClipboardRules.set(.copy, ["/a/x.txt", "/b/y.txt"], capturedAt: Self.t1)
        let write = ClipboardWrite(
            action: .paste, mode: .copy,
            items: [
                WriteEffectItem(sourcePath: "/a/x.txt", destinationPath: "/d/x.txt", mode: .copy),
                WriteEffectItem(sourcePath: "/b/y.txt", destinationPath: "/d/y.txt", mode: .cut),
            ])
        #expect(ClipboardRules.followThroughWrite(other, write).sourcePaths == ["/a/x.txt", "/d/y.txt"])
    }

    // MARK: The summary, the marks and their flash

    @Test func aClipboardOfBothIsCountedByIntent() throws {
        let summary = try #require(ClipboardRules.describe(mixed))
        #expect(summary.mode == nil)
        #expect(summary.countLabel == "2 items on the clipboard")
        #expect(summary.label == "2 items on the clipboard")
        #expect(summary.cutCount == 1)
        #expect(summary.copiedCount == 1)
        #expect(summary.intentLabel == "1 to move, 1 to copy")
        #expect(summary.accessibilityLabel == "Clipboard: 2 items on the clipboard, 1 to move, 1 to copy")
        #expect(summary.items.map(\.mode) == [.copy, .cut])
        let parts = ClipboardRules.groupByIntent(summary.items)
        #expect(parts.map(\.mode) == [.cut, .copy])
        #expect(parts.map { $0.groups.map(\.label) } == [["b"], ["a"]])
    }

    @Test func eachRowIsMarkedAsItsItemWasPutOn() throws {
        let marks = try #require(ClipboardMarks(mixed, enabled: true))
        #expect(marks.mark(for: "/a/x.txt") == .copy)
        #expect(marks.mark(for: "/b/y.txt") == .cut)
        #expect(marks.mode == nil)
        #expect(marks.flashes("/a/x.txt"))
        let some = marks.flashing(["/b/y.txt"])
        #expect(!some.flashes("/a/x.txt"))
        #expect(some.flashes("/b/y.txt"))
        #expect(!some.flashes("/elsewhere"))
        // Which flash is no difference between two sets of marks.
        #expect(some == marks)
    }

    @Test func anAddFlashesWhatItPutOnOrSwitchedAndNothingElse() {
        var tracker = ClipboardFlashTracker()
        let copied = ClipboardRules.set(.copy, ["/a/x.txt"], capturedAt: Self.t1)
        #expect(tracker.changed(to: copied) == .all)
        let added = ClipboardRules.applyAdd(
            ClipboardRules.planAdd(copied, .cut, ["/b/y.txt"]), to: copied, stamp: Self.t2
        ).clipboard
        #expect(tracker.changed(to: added) == .items(["/b/y.txt"]))
        let switched = ClipboardRules.setMode(added, ["/a/x.txt"], to: .cut, at: Self.t3)
        #expect(tracker.changed(to: switched) == .items(["/a/x.txt"]))
        #expect(tracker.changed(to: ClipboardRules.removeItem(switched, "/b/y.txt")) == .none)
        // A Put Back brings another capture: every mark flashes.
        #expect(tracker.changed(to: ClipboardRules.set(.copy, ["/q"], capturedAt: Self.t2)) == .all)
    }

    // MARK: The list

    @Test func theListOfBothIsInTwoPartsCutFirst() {
        let model = ClipboardMenuModel(items: ClipboardRules.items(mixed))
        #expect(
            model.rows.map { row -> String in
                switch row {
                case .section(let mode, let count): "\(mode.rawValue) \(count)"
                case .heading(let label, _): "[\(label)]"
                case .item(let item, _): item.name
                }
            } == ["cut 1", "[b]", "y.txt", "copy 1", "[a]", "x.txt"])
        #expect(model.orderedItems.map(\.name) == ["y.txt", "x.txt"])
        #expect(model.pinnedRow == .section(mode: .cut, count: 1))
        #expect(model.pinnedHeading == nil)
        // A clipboard of one intent has no parts.
        let plain = ClipboardMenuModel(
            items: ClipboardRules.items(ClipboardRules.set(.cut, ["/a/x.txt"], capturedAt: Self.t1)))
        #expect(plain.rows.count == 2)
        #expect(plain.pinnedHeading?.label == "a")
        #expect(plain.pinnedMode == nil)
    }

    @Test func putBackIsARowAfterClearClipboard() {
        var model = ClipboardMenuModel(items: ClipboardRules.items(mixed), putBackCount: 7)
        #expect(model.clearIndex == 2)
        #expect(model.putBackIndex == 3)
        #expect(model.key(.end, command: false, control: false, option: false) == .handled)
        #expect(model.activeIndex == 3)
        #expect(model.key(.enter, command: false, control: false, option: false) == .putBack)
        #expect(model.key(.up, command: false, control: false, option: false) == .handled)
        #expect(model.key(.enter, command: false, control: false, option: false) == .clear)
        model.setItems(ClipboardRules.items(mixed))
        #expect(model.putBackIndex == nil)
        #expect(model.activeIndex == model.clearIndex)
    }

    // MARK: Words

    @Test func anAddSaysWhatItDidAndWhatIsOnTheClipboardNow() {
        let copied = ClipboardRules.set(.copy, ["/a/x.txt"], capturedAt: Self.t1)
        let (next, report) = ClipboardRules.applyAdd(
            ClipboardRules.planAdd(copied, .cut, ["/b/y.txt"]), to: copied, stamp: Self.t2)
        #expect(
            ClipboardTexts.addMessage(report, clipboard: next)
                == "Added \u{201C}y.txt\u{201D} to move \u{B7} 1 to move, 1 to copy")

        let started = ClipboardRules.applyAdd(
            ClipboardRules.planAdd(.empty, .copy, ["/a/x.txt", "/a/z.txt"]), to: .empty, stamp: Self.t1)
        #expect(ClipboardTexts.addMessage(started.report, clipboard: started.clipboard) == "2 items copied")

        let again = ClipboardRules.applyAdd(ClipboardRules.planAdd(next, .cut, ["/b/y.txt"]), to: next, stamp: Self.t3)
        #expect(
            ClipboardTexts.addMessage(again.report, clipboard: again.clipboard)
                == "\u{201C}y.txt\u{201D} is already on the clipboard")

        let switched = ClipboardRules.applyAdd(
            ClipboardRules.planAdd(next, .cut, ["/a/x.txt"]), to: next, stamp: Self.t3)
        #expect(
            ClipboardTexts.addMessage(switched.report, clipboard: switched.clipboard)
                == "\u{201C}x.txt\u{201D} now moves instead of being copied \u{B7} 2 items cut")

        let folder = ClipboardRules.set(.copy, ["/p/Album"], capturedAt: Self.t1)
        let inside = ClipboardRules.applyAdd(
            ClipboardRules.planAdd(folder, .copy, ["/p/Album/a.jpg"]), to: folder, stamp: Self.t2)
        #expect(
            ClipboardTexts.addMessage(inside.report, clipboard: inside.clipboard)
                == "\u{201C}a.jpg\u{201D} is inside \u{201C}Album\u{201D}, which is on the clipboard")
    }

    @Test func pasteAndMoveItemsHereSayWhatTheyWouldDo() {
        #expect(ClipboardTexts.pasteTitle(count: 0) == "Paste")
        #expect(ClipboardTexts.pasteTitle(count: 1) == "Paste Item")
        #expect(ClipboardTexts.pasteTitle(count: 1_200) == "Paste 1,200 Items")
        #expect(ClipboardTexts.pasteSubtitle(cut: 4, copied: 3) == "Moves 4, copies 3")
        #expect(ClipboardTexts.pasteSubtitle(cut: 0, copied: 3) == "Copies 3")
        #expect(ClipboardTexts.pasteSubtitle(cut: 4, copied: 0) == "Moves 4")
        #expect(ClipboardTexts.pasteSubtitle(cut: 0, copied: 0) == "")
        #expect(ClipboardTexts.moveItemsHereTitle(count: 0) == "Move Items Here")
        #expect(ClipboardTexts.moveItemsHereTitle(count: 1) == "Move Item Here")
        #expect(ClipboardTexts.moveItemsHereTitle(count: 7) == "Move 7 Items Here")
        #expect(ClipboardTexts.switchModeTitle(from: .cut) == "Copy Instead of Moving")
        #expect(ClipboardTexts.switchModeTitle(from: .copy) == "Move Instead of Copying")
        #expect(ClipboardTexts.putBackTitle(7) == "Put Back the 7 Items Before")
        #expect(ClipboardTexts.sectionTitle(.cut, count: 4) == "Cut \u{B7} 4")
    }

    @Test func theNameQuestionNamesTheOtherItemsFolder() {
        let one = [ClipboardNameClash(path: "/web/README.md", otherPath: "/api/README.md")]
        #expect(ClipboardTexts.clashTitle(one) == "Another item named \u{201C}README.md\u{201D} is on the clipboard")
        #expect(ClipboardTexts.clashMessage(one).hasPrefix("It\u{2019}s from \u{201C}api\u{201D}."))
        #expect(ClipboardTexts.clashUseTitle(one) == "Use This One")
        #expect(ClipboardTexts.clashDontAddTitle(one) == "Don\u{2019}t Add")
        let two = one + [ClipboardNameClash(path: "/web/index.ts", otherPath: "/api/index.ts")]
        #expect(ClipboardTexts.clashTitle(two) == "2 items have the same names as items on the clipboard")
        #expect(ClipboardTexts.clashUseTitle(two) == "Use These")
    }

    // MARK: The menus

    @Test func pasteSaysWhatItDoesWhileTheFilesHaveTheKeyboard() {
        let state = ApplicationMenuState(clipboardCutCount: 4, clipboardCopiedCount: 3)
        let window = ApplicationMenu.WindowFacts(explorerFocused: true)
        let items = ApplicationMenu.itemStates(state, window: window)
        let paste = items.first { $0.id == AppCommand.editPaste.rawValue }
        #expect(paste?.title == "Paste 7 Items")
        #expect(paste?.subtitle == "Moves 4, copies 3")
        #expect(items.first { $0.id == AppCommand.moveItemsHere.rawValue }?.title == "Move 7 Items Here")
        // A text field's Paste pastes text.
        var editing = state
        editing.textEditing = true
        let text = ApplicationMenu.itemStates(editing, window: window).first { $0.id == AppCommand.editPaste.rawValue }
        #expect(text?.title == "Paste")
        #expect(text?.subtitle == "")
    }

    @Test func theRightClickMenuOffersTheAddsAndWhatIsOnTheClipboardOffersTheOtherIntent() {
        func hidden(_ paths: [String], cut: [String], copied: [String]) -> Set<ContextMenuActionID> {
            ContextMenuRules.hiddenActions(
                ContextMenuSubject(surface: .content, paths: paths),
                ContextMenuWorld(homePath: "/Users/me", clipboardCutPaths: cut, clipboardCopiedPaths: copied))
        }
        let clipboardActions: Set<ContextMenuActionID> = [
            .addToCopied, .addToCut, .switchClipboardMode, .removeFromClipboard,
        ]
        // Nothing on the clipboard: Copy and Cut are enough.
        #expect(hidden(["/a/x"], cut: [], copied: []).isSuperset(of: clipboardActions))
        // Something else on it: the Adds.
        #expect(
            clipboardActions.subtracting(hidden(["/a/x"], cut: ["/b/y"], copied: []))
                == [.addToCopied, .addToCut])
        // The item on it, cut: the other intent and Remove.
        #expect(
            clipboardActions.subtracting(hidden(["/a/x"], cut: ["/a/x"], copied: []))
                == [.switchClipboardMode, .removeFromClipboard])
        // Some of the items on it: the Adds for the rest, and Remove.
        #expect(
            clipboardActions.subtracting(hidden(["/a/x", "/a/z"], cut: ["/a/x"], copied: []))
                == [.addToCopied, .addToCut, .removeFromClipboard])
        let options = ContextMenuRules.options(
            ContextMenuSubject(surface: .content, paths: ["/a/x"]),
            ContextMenuWorld(homePath: "/Users/me", clipboardCopiedPaths: ["/a/x"]), textEditorName: nil)
        #expect(options.clipboardModeOfItems == .copy)
        let items = ContextMenuItems.items(surface: .content, options: options)
        #expect(items.first { $0.actionID == .switchClipboardMode }?.label == "Move Instead of Copying")
    }

    @Test func theClipboardsCommandsRunWhereCopyCutAndPasteDo() {
        let selected = CommandAvailabilityContext(
            shortcutContext: ShortcutContext(focusedPane: .content), currentPath: "/a",
            selectedPathsInViewOrder: ["/a/x"], clipboardHasItems: true, pasteDestinationPath: "/a")
        #expect(CommandAvailability.canRun(.addToCopied, selected))
        #expect(CommandAvailability.canRun(.addToCut, selected))
        #expect(CommandAvailability.canRun(.moveItemsHere, selected))
        #expect(!CommandAvailability.canRun(.removeFromClipboard, selected))
        var onIt = selected
        onIt.selectionOnClipboard = true
        #expect(CommandAvailability.canRun(.removeFromClipboard, onIt))
        var locked = selected
        locked.writeOperationLocked = true
        // The Adds only fill the clipboard, as Copy does; Move Items Here writes, as Paste does.
        #expect(CommandAvailability.canRun(.addToCopied, locked))
        #expect(!CommandAvailability.canRun(.moveItemsHere, locked))
        var nothing = selected
        nothing.selectedPathsInViewOrder = []
        #expect(!CommandAvailability.canRun(.addToCut, nothing))
    }

    // MARK: Write effects

    @Test func anItemAPasteCopiedBesideOthersItMovedDidNotMove() {
        let copied = WriteEffectItem(sourcePath: "/a/x", destinationPath: "/d/x", mode: .copy)
        let moved = WriteEffectItem(sourcePath: "/b/y", destinationPath: "/d/y", mode: .cut)
        #expect(!WriteEffects.isFollowedMove(copied, action: .paste))
        #expect(WriteEffects.isFollowedMove(moved, action: .paste))
        #expect(WriteEffects.movedItems(.paste, cut: false, items: [copied, moved]))
        #expect(!WriteEffects.movedItems(.paste, cut: false, items: [copied]))
        #expect(WriteEffects.followedMoves(.paste, items: [copied, moved]).map(\.to) == ["/d/y"])
    }
}

struct ClipboardShelfEndNoticeTests {
    private func write(completed: Int, moved: Int?, skipped: Int = 1) -> WriteEndSummary {
        WriteEndSummary(
            action: .paste, status: .partial, targetPath: "/d", topLevelItemCount: completed + skipped,
            completedItemCount: completed, failedItemCount: 0, skippedItemCount: skipped, cancelledItemCount: 0,
            items: [], movedItemCount: moved)
    }

    /// A paste of both says how many it moved and how many it copied.
    @Test func aPasteOfBothSaysWhatItDidOfEach() {
        #expect(
            WriteEndNotices.plannedSkipMessage(write(completed: 3, moved: 2))
                == "Moved 2, copied 1. Skipped 1 item that already exists.")
        #expect(
            WriteEndNotices.plannedSkipMessage(write(completed: 2, moved: 2))
                == "Moved 2 items. Skipped 1 item that already exists.")
        #expect(
            WriteEndNotices.plannedSkipMessage(write(completed: 2, moved: 0))
                == "Copied 2 items. Skipped 1 item that already exists.")
        #expect(
            WriteEndNotices.plannedSkipMessage(write(completed: 2, moved: nil))
                == "Copied 2 items. Skipped 1 item that already exists.")
    }
}
