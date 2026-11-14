import Testing

@testable import FTFoundation

@Suite struct WriteStartingShortcutsTests {
    @Test func aHeldKeyDoesNotRepeatAShortcutThatStartsAWrite() {
        for name in [
            "pasteSelection", "duplicateSelection", "trashSelection", "renameSelection", "moveSelection", "newFolder",
            "emptyTrash", "ejectVolume", "editPaste", "pasteAsFile", "compressSelection", "extractSelection",
            "extractSelectionTo", "convertImages", "copyToOtherPane", "moveToOtherPane", "undo", "redo",
        ] {
            #expect(WriteStartingShortcuts.runs(name, isRepeat: false), "\(name)")
            #expect(!WriteStartingShortcuts.runs(name, isRepeat: true), "\(name)")
        }
    }

    // Every command a running file operation blocks starts one, so a held key runs it once.
    @Test func noCommandThatARunningWriteBlocksIsRepeated() {
        #expect(!CommandAvailability.writeLockedCommands.isEmpty)
        for command in CommandAvailability.writeLockedCommands {
            #expect(!WriteStartingShortcuts.runs(command.rawValue, isRepeat: true), "\(command)")
        }
    }

    @Test func aHeldKeyRepeatsTheOtherShortcuts() {
        #expect(WriteStartingShortcuts.runs("goBack", isRepeat: true))
        #expect(WriteStartingShortcuts.runs("copySelection", isRepeat: true))
        // Copy, Cut, Select All, Copy Path and Copy Contents repeat: they start nothing on disk.
        for name in ["editCopy", "editCut", "editSelectAll", "cutSelection", "copyPath", "copyContents"] {
            #expect(WriteStartingShortcuts.runs(name, isRepeat: true), "\(name)")
        }
    }
}
