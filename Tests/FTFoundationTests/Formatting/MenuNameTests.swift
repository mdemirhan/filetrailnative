// How a long name is shortened in a menu, so the menu keeps its width
import FTFoundation
import Testing

@Suite struct MenuNameTests {
    private let long = "NullSafety copy 2NullSafety copy 2NullSafety copy 2NullSafety copy 2NullSafety copy 2.kt"

    @Test func leavesANameThatFitsAlone() {
        #expect(MenuName.shortened("Photos") == "Photos")
        let widest = String(repeating: "a", count: MenuName.maxWidth)
        #expect(MenuName.shortened(widest) == widest)
    }

    @Test func keepsTheStartTheLastLettersAndTheExtensionOfALongName() {
        let shortened = MenuName.shortened(long)
        #expect(shortened == "NullSafety copy…opy 2.kt")
        #expect(MenuName.width(shortened) <= MenuName.maxWidth)
    }

    @Test func shortensALongExtensionWithTheRest() {
        let name = "notes." + String(repeating: "x", count: 60)
        let shortened = MenuName.shortened(name)
        #expect(MenuName.width(shortened) <= MenuName.maxWidth)
        #expect(shortened.hasPrefix("notes."))
        #expect(shortened.hasSuffix("…xxxxx"))
    }

    @Test func countsWideLettersAsTwo() {
        #expect(MenuName.width("写真") == 4)
        #expect(MenuName.width("📁a") == 3)
        let shortened = MenuName.shortened(String(repeating: "写", count: 30) + ".jpg")
        #expect(MenuName.width(shortened) <= MenuName.maxWidth)
        #expect(shortened.hasSuffix("…写写写写写.jpg"))
    }

    @Test func quotesTheShortenedName() {
        #expect(MenuName.quoted("Photos") == "\u{201C}Photos\u{201D}")
        #expect(MenuName.quoted(long) == "\u{201C}\(MenuName.shortened(long))\u{201D}")
    }

    @Test func theMenusThatNameAnItemShortenALongName() {
        let short = MenuName.quoted(long)
        #expect(ArchiveNames.compressTitle([long]) == "Compress \(short)")
        #expect(BatchRenamePresetMenu.Item.preset(long).title == MenuName.shortened(long))
        #expect(BatchRenamePresetMenu.Item.update(long).title == "Update \(short)")
        #expect(BatchRenamePresetMenu.Item.delete(long).title == "Delete \(short)")
        let edit = ContextMenuItems.items(surface: .content, options: ContextMenuOptions(textEditorName: long))
            .first { $0.actionID == .edit }?.label
        #expect(edit == "Edit in \(MenuName.shortened(long))")
    }
}
