// The Rename sheet's pure parts (BatchRenameSheet.tsx's describeRow, Summary, describeSettingsError, the Presets
// pull-down, NumberField and insertToken, useBatchRename's savePreset)
import Foundation
import Testing

@testable import FTFoundation

@Suite struct BatchRenameSheetTextTests {
    private func plan(_ items: [BatchRenamePlanItem], settingsError: String? = nil) -> BatchRenamePlan {
        var plan = BatchRenamePlan(
            settingsError: settingsError, items: items, renameCount: 0, unchangedCount: 0, skippedCount: 0,
            blockingCount: 0)
        for item in items {
            switch item {
            case .unchanged: plan.unchangedCount += 1
            case .rename: plan.renameCount += 1
            case .problem(_, _, let problem):
                switch problem {
                case .skippedTaken, .cannotRename: plan.skippedCount += 1
                case .invalid, .taken: plan.blockingCount += 1
                }
            }
        }
        return plan
    }

    private func renamed(_ name: String, number: Int? = nil) -> BatchRenamePlanItem {
        .rename(
            name: name, segments: [NameSegment(text: name, changed: true)], addedNumber: number,
            numberedForItemInBatch: false, usedCreatedForTaken: false, becomesHidden: false)
    }

    @Test func titlesAndButtonsCountWithThousandsSeparators() {
        #expect(BatchRenameSheetText.title(count: 1) == "Rename 1 Item")
        #expect(BatchRenameSheetText.title(count: 1_234) == "Rename 1,234 Items")
        #expect(BatchRenameSheetText.renameButton(renameCount: 2, canRename: true) == "Rename 2 Items")
        #expect(BatchRenameSheetText.renameButton(renameCount: 2, canRename: false) == "Rename")
        #expect(BatchRenameSheetText.moreRows(1_005) == "and 1,005 more")
    }

    @Test func theSummaryKeepsItsOrderOfPrecedence() {
        let ready = plan([renamed("a 2.txt", number: 2), renamed("b.txt"), .unchanged])
        #expect(
            BatchRenameSheetText.summary(plan: ready, checking: false, checkError: nil).text
                == "2 will be renamed \u{00B7} 1 get a number \u{00B7} 1 unchanged")
        #expect(
            BatchRenameSheetText.summary(plan: ready, checking: true, checkError: nil).text == "Checking names\u{2026}")
        let failed = BatchRenameSheetText.summary(plan: ready, checking: true, checkError: "Couldn\u{2019}t.")
        #expect(failed == .init(text: "Couldn\u{2019}t.", danger: true))
        let broken = plan([.unchanged], settingsError: "The pattern isn\u{2019}t valid: Missing )")
        #expect(
            BatchRenameSheetText.summary(plan: broken, checking: true, checkError: nil)
                == .init(text: "The pattern isn\u{2019}t valid: Missing )", danger: true))
        let fixing = plan([.problem(proposedName: "x", segments: [], problem: .taken(byItemInBatch: false))])
        #expect(
            BatchRenameSheetText.summary(plan: fixing, checking: false, checkError: nil)
                == .init(text: "1 name to fix before renaming", danger: true))
        #expect(
            BatchRenameSheetText.summary(plan: plan([.unchanged]), checking: false, checkError: nil).text
                == "Nothing to rename yet")
    }

    @Test func theSettingsFaultLeavesOutJavaScriptsWordsForThePattern() {
        #expect(
            BatchRenameSheetText.describeSettingsError(
                "The pattern isn\u{2019}t valid: Invalid regular expression: /(/giu: Unterminated group")
                == "The pattern isn\u{2019}t valid: Unterminated group")
        #expect(
            BatchRenameSheetText.describeSettingsError("The pattern isn\u{2019}t valid: Missing )")
                == "The pattern isn\u{2019}t valid: Missing )")
        #expect(BatchRenameSheetText.describeSettingsError("Put at least one") == "Put at least one")
    }

    @Test func rowsSayWhatBecomesOfEachItem() {
        #expect(
            BatchRenameSheetText.describeRow(renamed("a 2.txt", number: 2))?.text
                == "That name is taken: a number is added")
        #expect(
            BatchRenameSheetText.rowTone(
                .problem(proposedName: "x", segments: [], problem: .skippedTaken(byItemInBatch: true))) == .skipped)
        #expect(
            BatchRenameSheetText.describeRow(
                .problem(proposedName: "x", segments: [], problem: .cannotRename(message: "It is locked.")))
                == .init(text: "Left as it is: It is locked.", tone: .muted))
        #expect(BatchRenameSheetText.describeRow(.unchanged) == nil)
    }

    @Test func thePresetsPullDownListsPresetsThenItsCommands() {
        let photos = BatchRenamePreset(name: "Photos", settings: BatchRenameSettings(mode: .format))
        var menu = BatchRenamePresetMenu(presets: [photos], currentName: nil)
        #expect(menu.items == [.preset("Photos"), .separator, .save])
        #expect(menu.closedTitle(.defaults) == "Presets")
        #expect(menu.choose(.preset("Photos")) == .load(photos))
        #expect(
            menu.items.map(\.title).suffix(2) == ["Update \u{201C}Photos\u{201D}", "Delete \u{201C}Photos\u{201D}"])
        #expect(menu.closedTitle(photos.settings) == "Photos")
        #expect(menu.closedTitle(.defaults) == "Photos (Edited)")
        #expect(menu.choose(.save) == .startNaming(initialName: "Photos"))
        #expect(menu.saveTitle(" PHOTOS ") == "Replace")
        #expect(menu.saveTitle("Beach") == "Save")
        #expect(!BatchRenamePresetMenu.canSave("   "))
        #expect(menu.choose(.delete("Photos")) == .delete("Photos"))
        #expect(menu.current == nil)
    }

    @Test func savingAPresetReplacesOneOfTheSameNameAndKeepsTheNewest() {
        let presets = (1...50).map { BatchRenamePreset(name: "P\($0)", settings: .defaults) }
        let saved = BatchRenamePresetList.saving(" p1 ", settings: BatchRenameSettings(mode: .add), in: presets)
        #expect(saved?.count == 50)
        #expect(saved?.last == BatchRenamePreset(name: "p1", settings: BatchRenameSettings(mode: .add)))
        #expect(BatchRenamePresetList.saving("New", settings: .defaults, in: presets)?.first?.name == "P2")
        #expect(BatchRenamePresetList.saving("  ", settings: .defaults, in: presets) == nil)
    }

    @Test func numberFieldsKeepTheirDraftAndShowTheSettingUsed() {
        var draft = BatchRenameNumberDraft(value: 1)
        #expect(draft.typed("0", least: 1) == 1)
        #expect(draft.shown(value: 1) == "1")
        #expect(draft.typed("", least: 1) == nil)
        #expect(draft.shown(value: 1) == "")
        #expect(draft.typed("x3", least: 1) == 3)
        #expect(draft.draft == "3")
        #expect(BatchRenameNumberDraft.digits("12345678901") == "123456789")
        draft.blurred(value: 7)
        #expect(draft.shown(value: 7) == "7")
    }

    // B-DLG-099
    @Test func aTokenGoesWhereTheSelectionIs() {
        #expect(BatchRenameTextRules.insert("MM", into: "YYYY-DD", selection: 5..<5) == ("YYYY-MMDD", 7))
        #expect(BatchRenameTextRules.insert("ss", into: "YYYY-DD", selection: 0..<4) == ("ss-DD", 2))
        #expect(BatchRenameTextRules.insert("HH", into: "abc", selection: nil) == ("abcHH", 5))
        #expect(BatchRenameTextRules.limited(String(repeating: "a", count: 300)).count == 255)
    }

    @Test func theGridsColumnsAre112And132WithTheRestShared() {
        let columns = BatchRenameSheetLayout.Grid.columns(width: 640)
        #expect(columns.map(\.width) == [112, 186, 132, 186])
        #expect(columns.map(\.x) == [0, 120, 314, 454])
        let rows = BatchRenameSheetLayout.Preview.columns(width: 640)
        #expect(rows[0].x == 12 && rows[0].width == 18)
        #expect(abs(rows[3].width / rows[1].width - 1.25) < 0.0001)
        #expect(abs(rows[3].x + rows[3].width - 628) < 0.0001)
    }
}
