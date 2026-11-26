import Testing

@testable import FTFoundation

struct PermissionsChecklistTests {
    private func item(
        _ name: String, _ mode: Int, folder: Bool = false, locked: Bool = false, hidden: Bool = false,
        owner: String = "demo", yours: Bool = true
    ) -> PermissionsItem {
        PermissionsItem(
            path: "/Users/demo/\(name)", mode: mode, locked: locked, hidden: hidden, isFolder: folder, owner: owner,
            group: "staff", isYours: yours)
    }

    // Each box is on, off, or on some of the items; the letters say "?" for a bit only some have.
    @Test func aBoxOnSomeItemsIsMixed() {
        let list = PermissionsChecklist(items: [item("a.txt", 0o644), item("run.sh", 0o755)])
        #expect(list.state(who: 0, what: 0) == .on)
        #expect(list.state(who: 0, what: 1) == .on)
        #expect(list.state(who: 0, what: 2) == .mixed)
        #expect(list.state(who: 1, what: 1) == .off)
        #expect(list.state(who: 2, what: 2) == .mixed)
        #expect(list.modeText == "Mixed")
        #expect(list.letters == "rw?r-?r-?")
        #expect(PermissionsChecklist(items: [item("a.txt", 0o644)]).modeText == "644")
        #expect(PermissionsChecklist(items: [item("a.txt", 0o644)]).letters == "rw-r--r--")
    }

    // The third column is Run for files, Open for folders, Run/Open for both.
    @Test func theThirdColumnIsNamedForWhatTheItemsAre() {
        #expect(PermissionsChecklist(items: [item("a", 0o644)]).thirdColumn == "Run")
        #expect(PermissionsChecklist(items: [item("f", 0o755, folder: true)]).thirdColumn == "Open")
        #expect(
            PermissionsChecklist(items: [item("a", 0o644), item("f", 0o755, folder: true)]).thirdColumn == "Run/Open")
    }

    // A box clicked changes only its bit on each item: a Write for the group keeps the script's Run.
    @Test func aBitChangesOnlyItself() {
        let list = PermissionsChecklist(items: [item("a.txt", 0o644), item("run.sh", 0o755)])
        let next = list.applying(.bit(who: 1, what: 1, on: true))
        #expect(next.items.map(\.mode) == [0o664, 0o775])
        #expect(next.applying(.bit(who: 0, what: 2, on: false)).items.map(\.mode) == [0o664, 0o675])
        // The bits above the nine stay as they are, whatever is set.
        #expect(PermissionsChange.mode(0o600).applied(to: 0o4755) == 0o4600)
        #expect(PermissionsChange.locked(true).applied(to: 0o644) == 0o644)
        let flagged = list.applying(.locked(true)).applying(.hidden(true))
        #expect(flagged.lockedState == .on)
        #expect(flagged.hiddenState == .on)
        #expect(list.lockedState == .off)
    }

    // A mode is three octal digits, four with a leading 0, or nine letters.
    @Test func aModeIsReadAsDigitsOrLetters() {
        #expect(PermissionsChecklist.parseMode("644") == 0o644)
        #expect(PermissionsChecklist.parseMode(" 0755 ") == 0o755)
        #expect(PermissionsChecklist.parseMode("rw-r--r--") == 0o644)
        #expect(PermissionsChecklist.parseMode("rwxr-x--x") == 0o751)
        #expect(PermissionsChecklist.parseMode("888") == nil)
        #expect(PermissionsChecklist.parseMode("1644") == nil)
        #expect(PermissionsChecklist.parseMode("64") == nil)
        #expect(PermissionsChecklist.parseMode("rx-------") == nil)
        #expect(PermissionsChecklist.parseMode("rw-r--r") == nil)
        #expect(PermissionsChecklist.parseMode("") == nil)
    }

    // Only taking away your own Open of a folder of yours asks first.
    @Test func turningOffYourOwnOpenOfAFolderLocksYouOut() {
        let folder = PermissionsChecklist(items: [item("Projects", 0o755, folder: true)])
        #expect(folder.locksYouOut(.bit(who: 0, what: 2, on: false)))
        #expect(folder.locksYouOut(.mode(0o644)))
        #expect(!folder.locksYouOut(.bit(who: 1, what: 2, on: false)))
        #expect(!folder.locksYouOut(.bit(who: 0, what: 0, on: false)))
        #expect(!PermissionsChecklist(items: [item("run.sh", 0o755)]).locksYouOut(.bit(who: 0, what: 2, on: false)))
        let closed = PermissionsChecklist(items: [item("Projects", 0o655, folder: true)])
        #expect(!closed.locksYouOut(.bit(who: 0, what: 2, on: false)))
    }

    // Anyone else's item, among them, makes the whole popover read-only.
    @Test func itemsOfAnotherOwnerCantBeChanged() {
        #expect(PermissionsChecklist(items: [item("a", 0o644)]).canChange)
        #expect(
            !PermissionsChecklist(items: [item("a", 0o644), item("b", 0o644, owner: "root", yours: false)]).canChange)
        #expect(!PermissionsChecklist(items: []).canChange)
        let several = PermissionsChecklist(items: [item("a", 0o644, owner: "root"), item("b", 0o644, owner: "admin")])
        #expect(several.owner == "2 owners")
        #expect(several.group == "staff")
    }

    @Test func theLineUnderTheTitleSaysWhatTheItemsAre() {
        #expect(PermissionsChecklist(items: [item("a", 0o644)]).itemsLine == "1 item")
        #expect(PermissionsChecklist(items: [item("a", 0o644), item("b", 0o644)]).itemsLine == "2 files")
        #expect(
            PermissionsChecklist(items: [item("a", 0o644), item("f", 0o755, folder: true)]).itemsLine
                == "1 file and 1 folder")
        #expect(
            PermissionsChecklist(items: [item("f", 0o755, folder: true), item("g", 0o755, folder: true)]).itemsLine
                == "2 folders")
    }

    @Test func whyTheyCantBeChangedIsSaid() {
        #expect(
            PermissionsRefusal.notYours(owner: "root", youCan: "read", several: false).text
                == "Only root can change these. You can read this item.")
        #expect(
            PermissionsRefusal.notYours(owner: "2 owners", youCan: nil, several: true).text
                == "Only their owners can change these. You can\u{2019}t open these items.")
        #expect(PermissionsRefusal.youCan(read: true, write: true) == "read and write")
        #expect(PermissionsRefusal.youCan(read: false, write: false) == nil)
        #expect(PermissionsRefusal.inTrash.text.contains("Trash"))
    }
}
