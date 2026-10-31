// Port of apps/desktop/src/renderer/components/BatchRenameSheet.test.tsx: the sheet on a window that is never shown,
// its rows, summary, buttons and presets read from its views and its model
import AppKit
import FTFoundation
import FTOperations
import Foundation
import Testing

@testable import FTAppKit

private typealias Fixture = BatchRenameSheetFixture

private func target(_ name: String, folder: Bool = false) -> BatchRenameTarget {
    Fixture.target(name, folder: folder)
}

extension ExplorerWindowlessTests {
    @MainActor
    @Suite struct BatchRenameSheetTests {
        // F-873 F-874 F-878 F-879 B-DLG-092 B-DLG-093 B-DLG-095 B-DLG-108 B-DLG-111 B-DLG-112
        // T-ab095052
        @Test func namesTheItemsStartsWithReplaceTextAndShowsNothingToRenameYet() async throws {
            let fixture = await Fixture([target("IMG_1.jpg"), target("IMG_2.jpg")])
            #expect(fixture.sheet.titleLabel.stringValue == "Rename 2 Items")
            #expect(fixture.sheet.accessibilityLabel() == "Rename 2 Items")
            #expect(fixture.sheet.modeControl.selected == .replace)
            #expect(fixture.sheet.modeControl.accessibilityLabel() == "How to rename")
            #expect(fixture.sheet.findField.holdsKeyboard)
            #expect(fixture.rows == ["IMG_1.jpgNo change", "IMG_2.jpgNo change"])
            #expect(fixture.summary == "Nothing to rename yet")
            #expect(!fixture.sheet.renameButton.isEnabled)
            #expect(fixture.sheet.renameButton.title == "Rename")
            fixture.close()
        }

        // F-875 F-878 F-879 B-DLG-108 B-DLG-111 B-DLG-112 B-DLG-113
        // T-120af9d9
        @Test func showsEachNewNameAsItIsTypedTheChangeMarkedAndRenamesOnReturn() async throws {
            let fixture = await Fixture([target("IMG_1.jpg"), target("notes.txt")])
            fixture.type(fixture.sheet.findField, "IMG_")
            fixture.type(fixture.sheet.replaceField, "Lisbon ")
            #expect(fixture.rows == ["IMG_1.jpgLisbon 1.jpg", "notes.txtNo change"])
            #expect(fixture.sheet.preview.rows[0].segments.filter(\.changed).map(\.text) == ["Lisbon "])
            #expect(fixture.cell(0)?.newColumn.marks.count == 1)
            #expect(fixture.summary == "1 will be renamed \u{00B7} 1 unchanged")
            #expect(fixture.sheet.renameButton.title == "Rename 1 Item")
            #expect(fixture.sheet.renameButton.isEnabled)
            fixture.sheet.findField.focus()
            fixture.returnKey()
            #expect(fixture.renamed.count == 1)
            fixture.close()
        }

        // F-877 F-878 F-879 B-DLG-109 B-DLG-110 B-DLG-111
        // T-b5d7988e
        @Test func holdsTheRenameWhileANameMustBeFixedAndSaysWhyOnItsRow() async throws {
            let fixture = await Fixture([target("IMG_1.jpg")], folderNames: ["IMG_1.jpg", "Lisbon 1.jpg"]) {
                $0.find = "IMG_"
                $0.replaceWith = "Lisbon "
                $0.onConflict = .block
            }
            #expect(fixture.sheet.preview.rows[0].tone == .danger)
            #expect(fixture.rows[0].contains("An item in this folder already has this name"))
            #expect(fixture.summary == "1 name to fix before renaming")
            #expect(!fixture.sheet.renameButton.isEnabled)
            // Adding a number settles it instead.
            fixture.pick(fixture.sheet.onConflictPopUp, "Add a Number")
            #expect(fixture.rows[0].contains("Lisbon 1 2.jpg"))
            #expect(fixture.rows[0].contains("That name is taken: a number is added"))
            #expect(fixture.summary == "1 will be renamed \u{00B7} 1 get a number")
            #expect(fixture.sheet.renameButton.isEnabled)
            // Or leaving the item as it is: its new name is struck through, and screen readers are told it isn't
            // renamed.
            fixture.pick(fixture.sheet.onConflictPopUp, "Skip Those Items")
            #expect(fixture.rows[0].contains("Left as it is: the name is taken"))
            #expect(fixture.sheet.preview.rows[0].tone == .skipped)
            #expect(fixture.sheet.preview.rows[0].accessibilityText.contains("Lisbon 1.jpg, not renamed"))
            #expect(fixture.summary == "Nothing to rename yet")
            fixture.close()
        }

        // F-878 B-DLG-107 B-DLG-108
        // T-bfa39c1c
        @Test func tellsScreenReadersEachOldNameBecomesTheNewOneAndShowsTheWholeNewName() async throws {
            let fixture = await Fixture([target("IMG_1.jpg")]) {
                $0.find = "IMG_"
                $0.replaceWith = "x"
            }
            #expect(fixture.sheet.preview.rows[0].accessibilityText == "IMG_1.jpg, becomes x1.jpg")
            #expect(fixture.cell(0)?.accessibilityLabel() == "IMG_1.jpg, becomes x1.jpg")
            #expect(fixture.cell(0)?.newColumn.nameLabel.toolTip == "x1.jpg")
            #expect(fixture.sheet.preview.table.accessibilityLabel() == "New names")
            #expect(fixture.sheet.preview.table.acceptsFirstResponder)
            fixture.close()
        }

        // F-877 B-DLG-109
        // T-9d621df5
        @Test func saysWhenTwoItemsWouldGetTheSameNewNameAndSettlesItAsChosen() async throws {
            let fixture = await Fixture([target("a1.txt"), target("b1.txt")]) {
                $0.find = "^."
                $0.replaceWith = "x"
                $0.useRegex = true
            }
            #expect(
                fixture.rows == ["a1.txtx1.txt", "b1.txtx1 2.txtSame new name as another item: a number is added"])
            fixture.pick(fixture.sheet.onConflictPopUp, "Don\u{2019}t Rename")
            #expect(fixture.sheet.preview.rows[1].tone == .danger)
            #expect(fixture.rows[1].contains("Another item here would get this name"))
            fixture.close()
        }

        // F-878 B-DLG-108 B-DLG-110
        // T-6c018297
        @Test func holdsTheRenameForANameThatCantBeUsedAndDrawsFoldersAsFolders() async throws {
            let fixture = await Fixture([target("Photos", folder: true), target("a.txt")]) {
                $0.mode = .add
                $0.addText = "/x"
            }
            #expect(fixture.cell(0)?.glyph.kind == .folder)
            #expect(fixture.cell(1)?.glyph.kind == .file)
            #expect(fixture.sheet.preview.rows[0].tone == .danger)
            #expect(fixture.sheet.preview.rows[0].note?.tone == .danger)
            #expect(fixture.sheet.preview.rows[0].note?.text.isEmpty == false)
            #expect(fixture.summary == "2 names to fix before renaming")
            fixture.close()
        }

        // B-DLG-113
        // T-c35d5811
        @Test func doesNothingOnReturnWhileTheNamesAreCheckedOrOneMustBeFixed() async throws {
            let checking = await Fixture([target("a.txt")], inspect: .hold) {
                $0.mode = .add
                $0.addText = "x"
            }
            checking.sheet.addTextField.focus()
            checking.returnKey()
            #expect(checking.renamed.isEmpty)
            checking.close()
            let fixing = await Fixture([target("a.txt")], folderNames: ["a.txt", "ax.txt"]) {
                $0.mode = .add
                $0.addText = "x"
                $0.onConflict = .block
            }
            fixing.sheet.addTextField.focus()
            fixing.returnKey()
            #expect(fixing.renamed.isEmpty)
            fixing.close()
        }

        // B-DLG-109 B-DLG-111
        // T-9c64ae7d
        @Test func reportsAnItemThatCantBeRenamedAndRenamesTheOthers() async throws {
            let fixture = await Fixture(
                [target("locked.txt"), target("free.txt")],
                cannotRename: ["/trip/locked.txt": "\u{201C}locked.txt\u{201D} is locked."]
            ) {
                $0.mode = .add
                $0.addText = "-old"
            }
            #expect(fixture.rows[0].contains("Left as it is: \u{201C}locked.txt\u{201D} is locked."))
            #expect(fixture.summary == "1 will be renamed \u{00B7} 1 left as they are")
            #expect(fixture.sheet.renameButton.title == "Rename 1 Item")
            fixture.close()
        }

        // F-875 B-DLG-100
        // T-14ce1e53
        @Test func explainsRegularExpressionsAndSaysUnderFindWhenAPatternIsBroken() async throws {
            let fixture = await Fixture([target("a.txt")])
            #expect(fixture.sheet.regexHint.isHidden)
            fixture.sheet.regexCheck.toggle()
            fixture.layout()
            #expect(!fixture.sheet.regexHint.isHidden)
            #expect(
                fixture.sheet.regexHint.stringValue
                    == "Use $1, $2\u{2026} or $<name> for groups, $& for the whole match")
            #expect(!fixture.sheet.findField.isInvalid)
            fixture.type(fixture.sheet.findField, "(")
            #expect(fixture.sheet.findField.isInvalid)
            // The message under the field, without JavaScript's own words for the pattern.
            let message = fixture.sheet.findMessage.stringValue
            #expect(!fixture.sheet.findMessage.isHidden)
            #expect(message.hasPrefix("The pattern isn\u{2019}t valid: "))
            #expect(message.dropFirst("The pattern isn\u{2019}t valid: ".count).first?.isLetter == true)
            #expect(!message.contains("Invalid regular expression") && !message.contains("/(/"))
            #expect(fixture.sheet.findField.field.accessibilityHelp() == message)
            #expect(fixture.summary == message)
            #expect(!fixture.sheet.renameButton.isEnabled)
            // Fixed, the field is no longer marked.
            fixture.type(fixture.sheet.findField, "(a)")
            #expect(!fixture.sheet.findField.isInvalid)
            #expect(fixture.sheet.findField.field.accessibilityHelp() == nil)
            #expect(fixture.sheet.findMessage.isHidden)
            fixture.close()
        }

        // F-875
        // T-9ff5f6ee
        @Test func findsTextIgnoringCaseUnlessMatchCaseIsOn() async throws {
            let fixture = await Fixture([target("IMG_1.jpg")]) {
                $0.find = "img_"
                $0.replaceWith = "x"
            }
            #expect(fixture.rows == ["IMG_1.jpgx1.jpg"])
            fixture.sheet.matchCaseCheck.toggle()
            #expect(fixture.rows == ["IMG_1.jpgNo change"])
            fixture.close()
        }

        // F-877 B-DLG-097 B-DLG-098
        // T-f14bb84b
        @Test func advisesThatChangingAnExtensionMayChangeTheAppAFileOpensIn() async throws {
            let fixture = await Fixture([target("a.JPG")]) { $0.mode = .changeCase }
            #expect(fixture.sheet.advice.isHidden)
            fixture.pick(fixture.sheet.applyToPopUp, "Extension")
            #expect(!fixture.sheet.advice.isHidden)
            #expect(fixture.sheet.adviceText.stringValue == "Changing an extension can change the app a file opens in.")
            #expect(fixture.sheet.adviceGlyph.kind == .warning && !fixture.sheet.adviceGlyph.isHidden)
            #expect(fixture.rows == ["a.JPGa.jpg"])
            fixture.close()
        }

        // F-876 F-877 B-DLG-096 B-DLG-097 B-DLG-101 B-DLG-104 B-DLG-105 B-DLG-106
        // T-25f915ca
        @Test func numbersItemsInFormatWithTheOptionsForNumbers() async throws {
            let fixture = await Fixture([target("a.jpg"), target("b.jpg")])
            let sheet = fixture.sheet
            sheet.modeControl.choose(.format)
            fixture.layout()
            #expect(fixture.rows == ["a.jpgFile 1.jpg", "b.jpgFile 2.jpg"])
            fixture.type(sheet.customNameField, "Trip")
            #expect(fixture.rows == ["a.jpgTrip 1.jpg", "b.jpgTrip 2.jpg"])
            fixture.pick(sheet.formatWherePopUp, "before name")
            #expect(fixture.rows == ["a.jpg1 Trip.jpg", "b.jpg2 Trip.jpg"])
            fixture.pick(sheet.formatWherePopUp, "after name")
            fixture.pick(sheet.nameFormatPopUp, "Name and Counter")
            #expect(fixture.rows[0] == "a.jpgTrip 00001.jpg")
            // The settings are saved, so Digits must give a number, not the pop-up's text.
            fixture.pick(sheet.digitsPopUp, "3")
            #expect(fixture.model.settings.digits == .fixed(3))
            #expect(fixture.rows[0] == "a.jpgTrip 001.jpg")
            fixture.pick(sheet.digitsPopUp, "As Many as Needed")
            #expect(fixture.model.settings.digits == .auto)
            fixture.type(sheet.startField, "9")
            fixture.type(sheet.stepField, "2")
            #expect(fixture.rows == ["a.jpgTrip 09.jpg", "b.jpgTrip 11.jpg"])
            // A step below the least allowed shows the step used.
            fixture.type(sheet.stepField, "0")
            #expect(sheet.stepField.text == "1")
            #expect(fixture.rows == ["a.jpgTrip 09.jpg", "b.jpgTrip 10.jpg"])
            // Only digits are kept, and an empty field waits for one.
            fixture.type(sheet.startField, "")
            #expect(sheet.startField.text == "")
            fixture.type(sheet.startField, "x3")
            #expect(sheet.startField.text == "3")
            sheet.startField.onBlur()
            sheet.keepNamesCheck.toggle()
            fixture.layout()
            #expect(!sheet.customNameField.isEnabled)
            fixture.pick(sheet.separatorPopUp, "Underscore (_)")
            #expect(fixture.rows[0] == "a.jpga_3.jpg")
            #expect(!sheet.namesOnlyNote.isHidden)
            #expect(sheet.namesOnlyNote.stringValue == "Names only: extensions are kept")
            fixture.close()
        }

        // F-876 B-DLG-102 B-DLG-103
        // T-17e9a3bb
        @Test func putsDatesInTheFormatChosenWithItsSeparatorOrACustomPattern() async throws {
            let fixture = await Fixture([target("a.jpg")]) { $0.mode = .format }
            let sheet = fixture.sheet
            fixture.pick(sheet.nameFormatPopUp, "Name and Date")
            #expect(fixture.rows == ["a.jpgFile 2026-09-30.jpg"])
            // The example is for a pattern only: a format says how it looks.
            #expect(sheet.exampleNote.isHidden)
            // The formats are listed with the separator chosen.
            fixture.pick(sheet.dateSeparatorPopUp, "None")
            #expect(fixture.titles(sheet.dateFormatPopUp).contains("YYYYMMDD"))
            fixture.pick(sheet.dateSourcePopUp, "Date Modified")
            #expect(fixture.rows == ["a.jpgFile 20261001.jpg"])
            fixture.pick(sheet.dateFormatPopUp, "Custom\u{2026}")
            #expect(sheet.dateSeparatorPopUp.isHidden)
            fixture.type(sheet.patternField, "")
            let year = try #require(sheet.tokenButtons.first { $0.token == .year4 })
            year.perform()
            fixture.layout()
            #expect(sheet.patternField.text == "YYYY")
            #expect(fixture.rows == ["a.jpgFile 2026.jpg"])
            #expect(sheet.exampleNote.stringValue == "Example: 2026")
            #expect(!sheet.bracketsNote.isHidden)
            #expect(sheet.bracketsNote.stringValue == "Text in [brackets] is kept as typed")
            fixture.type(sheet.patternField, "no tokens")
            #expect(fixture.summary.contains("at least one of YYYY"))
            fixture.close()
        }

        // F-876 B-DLG-103
        // T-e7f2b2d9
        @Test func namesEachDateTokenAndInsertsOneWhereTheCursorIs() async throws {
            let fixture = await Fixture([target("a.jpg")]) {
                $0.mode = .format
                $0.nameFormat = .date
                $0.dateFormat = .custom
                $0.customDatePattern = "YYYY-DD"
            }
            let names = [
                "Year (2026)", "Year (26)", "Month (05)", "Day (14)", "Hour, 24-hour (18)", "Minutes (02)",
                "Seconds (11)",
            ]
            #expect(fixture.sheet.tokenButtons.map { $0.toolTip ?? "" } == names)
            #expect(fixture.sheet.tokenButtons.map { $0.accessibilityLabel() ?? "" } == names)
            let pattern = fixture.sheet.patternField
            pattern.focus(caret: 5)
            let month = try #require(fixture.sheet.tokenButtons.first { $0.token == .month })
            fixture.window.makeFirstResponder(month)
            month.perform()
            #expect(pattern.text == "YYYY-MMDD")
            // The cursor is put after what was inserted.
            #expect(pattern.selection == 7..<7)
            #expect(pattern.holdsKeyboard)
            fixture.close()
        }

        // F-876 B-DLG-109
        // T-ee7a5e16
        @Test func saysWhenTheDateTakenIsntThereAndTheDateCreatedIsUsed() async throws {
            let fixture = await Fixture([target("a.jpg")]) {
                $0.mode = .format
                $0.nameFormat = .date
                $0.dateSource = .taken
            }
            #expect(fixture.rows == ["a.jpgFile 2026-09-30.jpgNo date taken: the date created is used"])
            fixture.close()
        }

        // F-877
        // T-96c73366
        @Test func changesCaseInChangeCase() async throws {
            let fixture = await Fixture([target("My Photo.JPG")])
            fixture.sheet.modeControl.choose(.changeCase)
            #expect(fixture.rows == ["My Photo.JPGmy photo.JPG"])
            fixture.pick(fixture.sheet.casePopUp, "UPPERCASE")
            #expect(fixture.rows == ["My Photo.JPGMY PHOTO.JPG"])
            fixture.close()
        }

        // F-875
        // T-1b2719d7
        @Test func addsTextBeforeOrAfterTheName() async throws {
            let fixture = await Fixture([target("a.txt")])
            fixture.sheet.modeControl.choose(.add)
            fixture.type(fixture.sheet.addTextField, "old-")
            fixture.pick(fixture.sheet.addWherePopUp, "before name")
            #expect(fixture.rows == ["a.txtold-a.txt"])
            fixture.close()
        }

        // B-DLG-109
        // T-66e4ae8e
        @Test func warnsOfANameThatHidesTheItem() async throws {
            let fixture = await Fixture([target("config")]) {
                $0.mode = .add
                $0.addText = "."
                $0.addWhere = .before
            }
            #expect(fixture.rows[0].contains("Starts with \u{201C}.\u{201D}: it will be hidden"))
            #expect(fixture.sheet.preview.rows[0].note?.tone == .warning)
            fixture.close()
        }

        // F-879 B-DLG-081 B-DLG-084 B-DLG-111
        // T-58f7cebe
        @Test func saysWhenTheItemsAreStillBeingCheckedOrCouldntBe() async throws {
            let checking = await Fixture([target("a.txt")], inspect: .hold) {
                $0.mode = .add
                $0.addText = "x"
            }
            #expect(checking.summary == "Checking names\u{2026}")
            #expect(!checking.sheet.renameButton.isEnabled)
            checking.close()
            let failed = await Fixture([target("a.txt")], inspect: .fail) {
                $0.mode = .add
                $0.addText = "x"
            }
            #expect(await waitUntil { failed.model.sheet?.inspectError != nil })
            #expect(failed.summary == "File Trail couldn\u{2019}t read the items to check their new names.")
            failed.close()
        }

        // F-878 B-DLG-107
        // T-d423fb6a
        @Test func listsAtMostAThousandRowsAndSaysHowManyMoreThereAre() async throws {
            let many = (0..<1_005).map { target("f\($0).txt") }
            let fixture = await Fixture(many)
            #expect(fixture.sheet.preview.rows.count == 1_001)
            #expect(fixture.rows.last == "and 5 more")
            fixture.close()
        }

        // B-DLG-089 B-DLG-090
        // T-22bf8eed
        @Test func closesOnEscapeAndOnCancel() async throws {
            let fixture = await Fixture([target("a.txt")])
            fixture.sheet.findField.focus()
            fixture.escape()
            fixture.key(0, "a")
            fixture.sheet.cancelButton.perform()
            #expect(fixture.cancelled == 2)
            fixture.close()
        }

        // B-DLG-092 B-DLG-095: Tab goes from Find through the sheet in the order it shows its controls (the mode as one
        // stop), wraps at the end, and ⇧Tab goes back.
        @Test func tabGoesRoundTheSheetInTheOrderItShowsItsControls() async throws {
            let fixture = await Fixture([target("a.txt"), target("b.txt")])
            let sheet = fixture.sheet
            #expect(sheet.findField.holdsKeyboard)
            let expected: [NSView] = [
                sheet.presetsPopUp, sheet.modeControl, sheet.findField, sheet.replaceField, sheet.matchCaseCheck,
                sheet.regexCheck, sheet.applyToPopUp, sheet.onConflictPopUp, sheet.preview.table, sheet.cancelButton,
            ]
            #expect(sheet.focusChain.map(ObjectIdentifier.init) == expected.map(ObjectIdentifier.init))
            fixture.key(KeyCode.tab, "\t")
            #expect(sheet.replaceField.holdsKeyboard)
            for _ in 0..<6 { fixture.key(KeyCode.tab, "\t") }
            #expect(fixture.window.firstResponder === sheet.cancelButton)
            fixture.key(KeyCode.tab, "\t")
            #expect(fixture.window.firstResponder === sheet.presetsPopUp)
            fixture.key(KeyCode.tab, "\t", modifiers: .shift)
            #expect(fixture.window.firstResponder === sheet.cancelButton)
            // On the mode, the arrow keys move between the segments.
            fixture.window.makeFirstResponder(sheet.modeControl)
            fixture.key(124, "\u{F703}")
            #expect(fixture.model.settings.mode == .add)
            #expect(sheet.addTextField.isHidden == false && sheet.findField.isHidden)
            fixture.close()
        }

        // MARK: Presets

        private static let photos = BatchRenamePreset(
            name: "Photos", settings: BatchRenameSettings(mode: .format, customName: "Trip"))

        // F-873 B-DLG-114 B-DLG-115 B-DLG-116
        // T-d751c845
        @Test func presetsLoadOneThenOfferToUpdateOrDeleteIt() async throws {
            let fixture = await Fixture([target("a.jpg")], presets: [Self.photos])
            let menu = fixture.sheet.presetsPopUp
            #expect(!fixture.titles(menu).contains { $0.hasPrefix("Update") })
            fixture.pick(menu, "Photos")
            #expect(fixture.rows == ["a.jpgTrip 1.jpg"])
            #expect(menu.shownText == "Photos")
            fixture.pick(menu, "Update \u{201C}Photos\u{201D}")
            #expect(fixture.saved.savedPresets?.map(\.name) == ["Photos"])
            fixture.pick(menu, "Delete \u{201C}Photos\u{201D}")
            #expect(fixture.saved.savedPresets == [])
            #expect(menu.shownText == "Presets")
            fixture.close()
        }

        // F-873 B-DLG-114
        // T-cece5be3
        @Test func presetsAreListedAboveTheCommandsWithASeparatorBetween() async throws {
            let fixture = await Fixture([target("a.jpg")], presets: [Self.photos])
            #expect(fixture.titles(fixture.sheet.presetsPopUp) == ["Photos", "-", "Save as Preset\u{2026}"])
            #expect(fixture.sheet.presetsPopUp.shownText == "Presets")
            fixture.close()
        }

        // F-873 B-DLG-115 B-DLG-116
        // T-491bb4f9
        @Test func saysALoadedPresetWasEditedAndUpdatesIt() async throws {
            let fixture = await Fixture([target("a.jpg")], presets: [Self.photos])
            fixture.pick(fixture.sheet.presetsPopUp, "Photos")
            fixture.type(fixture.sheet.customNameField, "Beach")
            #expect(fixture.sheet.presetsPopUp.shownText == "Photos (Edited)")
            fixture.pick(fixture.sheet.presetsPopUp, "Update \u{201C}Photos\u{201D}")
            #expect(fixture.saved.savedPresets?.first?.settings.customName == "Beach")
            #expect(fixture.sheet.presetsPopUp.shownText == "Photos")
            fixture.close()
        }

        // F-873 B-DLG-117 B-DLG-118
        // T-90481d3b
        @Test func offersTheLoadedPresetsNameToSaveTheSettingsUnder() async throws {
            let fixture = await Fixture([target("a.jpg")], presets: [Self.photos])
            fixture.pick(fixture.sheet.presetsPopUp, "Photos")
            fixture.pick(fixture.sheet.presetsPopUp, "Save as Preset\u{2026}")
            #expect(fixture.sheet.presetNameField.text == "Photos")
            #expect(fixture.sheet.presetSaveButton.title == "Replace")
            #expect(fixture.sheet.presetSaveButton.isEnabled)
            fixture.close()
        }

        // F-873 B-DLG-112 B-DLG-113 B-DLG-117 B-DLG-118 B-DLG-119
        // T-bf9cd809
        @Test func savesTheSettingsUnderANameTypedInTheHeader() async throws {
            let fixture = await Fixture([target("a.jpg")], presets: [Self.photos]) {
                $0.mode = .add
                $0.addText = "x"
            }
            let sheet = fixture.sheet
            fixture.pick(sheet.presetsPopUp, "Save as Preset\u{2026}")
            #expect(sheet.presetNameField.holdsKeyboard)
            #expect(sheet.presetNameField.field.placeholderString == "Preset name")
            #expect(!sheet.presetSaveButton.isEnabled)
            #expect(!sheet.renameButton.isEnabled)
            // A name already used replaces that preset, and says so.
            fixture.type(sheet.presetNameField, "photos")
            #expect(sheet.presetSaveButton.title == "Replace")
            #expect(sheet.presetSaveButton.isEnabled)
            fixture.type(sheet.presetNameField, " Suffix ")
            // Return saves the preset; it doesn't rename.
            fixture.returnKey()
            #expect(fixture.saved.savedPresets?.map(\.name) == ["Photos", "Suffix"])
            #expect(fixture.renamed.isEmpty)
            #expect(sheet.presetNameField.isHidden)
            // The keyboard goes back to the pop-up the name was asked from.
            #expect(fixture.window.firstResponder === sheet.presetsPopUp)
            #expect(sheet.presetsPopUp.shownText == "Suffix")
            fixture.close()
        }

        // B-DLG-090 B-DLG-120
        // T-1657a9b9
        @Test func leavesSavingWithEscapeOrCancelWithoutClosingTheSheet() async throws {
            let fixture = await Fixture([target("a.jpg")])
            let sheet = fixture.sheet
            fixture.pick(sheet.presetsPopUp, "Save as Preset\u{2026}")
            fixture.escape()
            #expect(!sheet.savingPreset && sheet.presetNameField.isHidden)
            fixture.pick(sheet.presetsPopUp, "Save as Preset\u{2026}")
            sheet.presetCancelButton.perform()
            #expect(!sheet.savingPreset && sheet.presetNameField.isHidden)
            #expect(fixture.window.firstResponder === sheet.presetsPopUp)
            #expect(fixture.cancelled == 0)
            fixture.close()
        }
    }
}
