// Covers B-SEL-114 (the held-key case of useExplorerShortcuts.ts) by behavior row
import Testing

@testable import FTFoundation

@Suite struct WriteStartingShortcutsTests {
    // B-SEL-114
    // B-TREE-166
    @Test func aHeldKeyDoesNotRepeatAShortcutThatStartsAWrite() {
        for name in [
            "pasteSelection", "duplicateSelection", "trashSelection", "renameSelection", "moveSelection", "newFolder",
            "emptyTrash", "ejectVolume", "editPaste",
        ] {
            #expect(WriteStartingShortcuts.runs(name, isRepeat: false))
            #expect(!WriteStartingShortcuts.runs(name, isRepeat: true))
        }
    }

    // B-SEL-114
    @Test func aHeldKeyRepeatsTheOtherShortcuts() {
        #expect(WriteStartingShortcuts.runs("goBack", isRepeat: true))
        #expect(WriteStartingShortcuts.runs("copySelection", isRepeat: true))
        // The original repeats Copy, Cut and Select All: they start nothing on disk.
        for name in ["editCopy", "editCut", "editSelectAll", "cutSelection"] {
            #expect(WriteStartingShortcuts.runs(name, isRepeat: true))
        }
    }
}
