import Testing

@testable import FTFoundation

@Suite struct WriteStartingShortcutsTests {
    @Test func aHeldKeyDoesNotRepeatAShortcutThatStartsAWrite() {
        for name in [
            "pasteSelection", "duplicateSelection", "trashSelection", "renameSelection", "moveSelection", "newFolder",
            "emptyTrash", "ejectVolume", "editPaste",
        ] {
            #expect(WriteStartingShortcuts.runs(name, isRepeat: false))
            #expect(!WriteStartingShortcuts.runs(name, isRepeat: true))
        }
    }

    @Test func aHeldKeyRepeatsTheOtherShortcuts() {
        #expect(WriteStartingShortcuts.runs("goBack", isRepeat: true))
        #expect(WriteStartingShortcuts.runs("copySelection", isRepeat: true))
        // Copy, Cut and Select All repeat: they start nothing on disk.
        for name in ["editCopy", "editCut", "editSelectAll", "cutSelection"] {
            #expect(WriteStartingShortcuts.runs(name, isRepeat: true))
        }
    }
}
