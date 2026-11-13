// The recorder is driven with key events as the window hands them over (performKeyEquivalent, keyDown)
import AppKit
import FTFoundation
import Testing

@testable import FTAppKit

@MainActor
@Suite struct ShortcutSettingsTests {
    typealias Kit = SettingsTestKit

    private func make(_ preferences: AppPreferences = .defaults(theme: .light)) throws -> (
        SettingsWindowController, SettingsRecorder, ShortcutSettingsView
    ) {
        let (controller, recorder) = Kit.make(tab: .shortcuts, preferences: preferences)
        let view = try #require(controller.settingsView.page?.shortcuts)
        return (controller, recorder, view)
    }

    private func slot(_ id: ShortcutCommandID, _ index: Int, in view: ShortcutSettingsView) throws -> ShortcutSlotView {
        try #require(view.slotView(ShortcutSlot(id: id, index: index)), "no slot \(id) \(index)")
    }

    /// The key as the window hands it over: first as a key equivalent (where the menu would take it), then as a key.
    @discardableResult
    private func press(_ event: NSEvent, in controller: SettingsWindowController) -> Bool {
        guard let window = controller.window else { return false }
        if window.performKeyEquivalent(with: event) { return true }
        window.firstResponder?.keyDown(with: event)
        return false
    }

    private func notes(_ view: ShortcutSettingsView) -> [String] { texts("settings.shortcuts.note", in: view) }

    @Test func listsEveryCommandWithItsKeysGroupedAndTheStandardOnesAsFixed() throws {
        let (_, _, view) = try make()
        #expect(
            view.groups.map { $0.titleText.stringValue } == [
                "Navigation", "Windows and Tabs", "Files", "Search", "View", "Standard shortcuts",
            ])
        #expect(view.rows.count == ShortcutCommands.all.count)
        #expect(texts("settings.shortcuts.intro", in: view) == [ShortcutSettingsText.intro])
        let standard = try #require(view.groups.last)
        #expect(
            standard.groupNote?.stringValue
                == "The same in every Mac app, or shared with text fields. They can not be changed here.")
        #expect(standard.rows.allSatisfy { $0.slots.isEmpty && !$0.fixedKeys.isEmpty })
        #expect(views("settings.shortcuts.fixedKey", in: standard).count > 0)
        // A command with one key has a second, empty place; the keys are written ⌃⌥⇧⌘ then the key.
        let newFolder = try #require(view.row(.newFolder))
        #expect(newFolder.slots.map(\.stringValue) == ["⇧⌘N", "+"])
        #expect(newFolder.slots[1].accessibilityLabel() == "Add an alternate shortcut for New Folder")
        #expect(newFolder.slots.allSatisfy { $0.frame.width >= 52 && $0.frame.height == 20 })
        #expect(view.row(.renameSelection)?.hintText?.stringValue == "Return renames too: Settings → Files.")
        #expect(view.row(.openSelectedItem)?.hintText?.stringValue == "Does what a double-click does.")
        #expect(
            view.row(.toggleFavorite)?.hintText?.stringValue == "Removes the folder when it is a favorite already.")
        #expect(!view.restoreAllButton.isEnabled)
    }

    @Test func recordsANewKeyForACommandAndSavesOnlyWhatDiffersFromTheDefaults() throws {
        let (controller, recorder, view) = try make()
        let place = try slot(.newFolder, 1, in: view)
        place.perform()
        #expect(place.isRecording)
        #expect(place.stringValue == "Press keys…")
        #expect(place.accessibilityLabel() == "Press the alternate shortcut for New Folder")
        #expect(controller.window?.firstResponder === place)
        // ⌘D would be Duplicate's in the menu: the recorder has it first.
        #expect(press(Kit.letter("j", [.command, .option], window: controller.window), in: controller))
        #expect(!place.isRecording)
        #expect(try slot(.newFolder, 1, in: view).stringValue == "⌥⌘J")
        #expect(
            recorder.saved["shortcutOverrides"]
                == .object(["newFolder": .array([.string("Cmd+Shift+N"), .string("Cmd+Option+J")])]))
        #expect(view.restoreAllButton.isEnabled)
        #expect(view.row(.newFolder)?.restoreButton.isHidden == false)
    }

    @Test func waitsForAKeyWhileOnlyModifiersAreDownAndEscCancels() throws {
        let (controller, recorder, view) = try make()
        let place = try slot(.newFolder, 1, in: view)
        place.perform()
        // A modifier on its own is no key down; a repeat is ignored.
        #expect(
            press(
                Kit.letter("k", .command, window: controller.window).withRepeat(window: controller.window),
                in: controller))
        #expect(place.isRecording)
        // Esc is the answer, and doesn't reach the window: recording ends with nothing saved.
        #expect(press(Kit.key(Kit.escape.0, code: Kit.escape.1, window: controller.window), in: controller))
        #expect(!place.isRecording)
        #expect(place.stringValue == "+")
        // Clicking it again while recording stops recording.
        place.perform()
        place.perform()
        #expect(!place.isRecording)
        // Tab leaves the key, as it leaves any control: the window has it.
        place.perform()
        #expect(!place.record(Kit.key(Kit.tab.0, code: Kit.tab.1, window: controller.window)))
        _ = controller.window?.makeFirstResponder(nil)
        #expect(!place.isRecording)
        #expect(recorder.patches.isEmpty)
    }

    @Test func saysWhyAKeyCanNotBeUsedAndGoesOnRecording() throws {
        let (controller, _, view) = try make()
        let place = try slot(.newFolder, 1, in: view)
        place.perform()
        press(Kit.letter("n", window: controller.window), in: controller)
        #expect(notes(view) == ["N on its own types into the file list. Add ⌘ or ⌃."])
        #expect(place.isRecording)
        let note = try #require(view.row(.newFolder)?.noteText)
        // A key that can't be used is said in the danger colour.
        #expect(note.textColor == NSColor(AppearanceModel.shared.theme.palette.dangerText))
        // ⌘Q goes to the recorder too, and is Quit's for good.
        press(Kit.letter("q", .command, window: controller.window), in: controller)
        #expect(notes(view) == ["⌘Q is Quit File Trail, which can not be changed."])
        press(Kit.letter(".", .command, window: controller.window), in: controller)
        #expect(notes(view) == ["⌘. cancels a dialog, as Esc does."])
        press(Kit.key(Kit.space.0, code: Kit.space.1, window: controller.window), in: controller)
        #expect(notes(view) == ["Space on its own types into the file list. Add ⌘ or ⌃."])
        #expect(place.isRecording)
        // Quick Look can have Space back, its own default, though no other command can have it.
        let quickLook = try slot(.quickLookSelection, 0, in: view)
        controller.window?.makeFirstResponder(quickLook)
        quickLook.keyDown(with: Kit.key(Kit.backspace.0, code: Kit.backspace.1, window: controller.window))
        #expect(try slot(.quickLookSelection, 0, in: view).stringValue == "+")
        try slot(.quickLookSelection, 0, in: view).perform()
        press(Kit.key(Kit.space.0, code: Kit.space.1, window: controller.window), in: controller)
        #expect(try slot(.quickLookSelection, 0, in: view).stringValue == "Space")
        #expect(notes(view).isEmpty)
    }

    // A key the command has already, in either place, ends the recording with no change and no note.
    @Test func aKeyTheCommandAlreadyHasEndsTheRecordingWithNoChange() throws {
        let (controller, recorder, view) = try make()
        // Quick Look's Space and New Folder's ⌘⇧N are their main keys: from the alternate place the key is its own.
        let place = try slot(.newFolder, 1, in: view)
        place.perform()
        #expect(place.isRecording)
        press(Kit.letter("n", [.command, .shift], window: controller.window), in: controller)
        #expect(try !slot(.newFolder, 1, in: view).isRecording)
        #expect(notes(view).isEmpty)
        #expect(try slot(.newFolder, 1, in: view).stringValue == "+")
        // And a note a refused key left goes with it.
        let again = try slot(.newFolder, 1, in: view)
        again.perform()
        press(Kit.letter("n", window: controller.window), in: controller)
        #expect(!notes(view).isEmpty)
        press(Kit.letter("n", [.command, .shift], window: controller.window), in: controller)
        #expect(try !slot(.newFolder, 1, in: view).isRecording)
        #expect(notes(view).isEmpty)
        #expect(recorder.saved["shortcutOverrides"] == nil)
        #expect(!view.restoreAllButton.isEnabled)
    }

    @Test func asksBeforeTakingAKeyFromAnotherCommand() throws {
        let (controller, recorder, view) = try make()
        try slot(.newFolder, 1, in: view).perform()
        press(Kit.letter("d", .command, window: controller.window), in: controller)
        #expect(notes(view) == ["⌘D is used by Duplicate."])
        let row = try #require(view.row(.newFolder))
        #expect(row.reassignButton?.title == "Reassign")
        #expect(row.reassignButton?.isDefault == true)
        #expect(row.cancelButton?.title == "Cancel")
        // Cancel changes nothing.
        Kit.click(row.cancelButton)
        #expect(notes(view).isEmpty)
        #expect(recorder.patches.isEmpty)
        // Reassign moves the key here: Duplicate loses it.
        try slot(.newFolder, 1, in: view).perform()
        press(Kit.letter("d", .command, window: controller.window), in: controller)
        Kit.click(view.row(.newFolder)?.reassignButton)
        #expect(view.row(.newFolder)?.slots.map(\.stringValue) == ["⇧⌘N", "⌘D"])
        #expect(view.row(.duplicateSelection)?.slots.first?.stringValue != "⌘D")
    }

    // ⌘⇧= types ⌘+ on most keyboards: it is Make Bigger's key, shown as the default shows it.
    @Test func takesCommandShiftEqualsAsMakeBiggersCommandPlus() throws {
        let (controller, _, view) = try make()
        try slot(.newFolder, 1, in: view).perform()
        press(Kit.key("+", code: 24, modifiers: [.command, .shift], window: controller.window), in: controller)
        #expect(notes(view) == ["⌘+ is used by Make Bigger."])
        Kit.click(view.row(.newFolder)?.reassignButton)
        #expect(view.row(.newFolder)?.slots.map(\.stringValue) == ["⇧⌘N", "⌘+"])
        #expect(view.row(.increaseSize)?.slots.map(\.stringValue).contains("⌘+") == false)
    }

    // The conflict: after a refusal, the recorder still takes ⌘D before the menu would; the row grows to 60 with the
    // note and its buttons on one line under the keys.
    @Test func drawsTheConflictUnderTheKeysWithReassignAndCancelAtTheEnd() throws {
        let (controller, _, view) = try make()
        view.setQuery("Move to Trash")
        let place = try slot(.trashSelection, 1, in: view)
        place.perform()
        press(Kit.letter("n", window: controller.window), in: controller)
        #expect(notes(view) == ["N on its own types into the file list. Add ⌘ or ⌃."])
        #expect(press(Kit.letter("d", .command, window: controller.window), in: controller))
        #expect(notes(view) == ["⌘D is used by Duplicate."])
        Kit.layout(controller)
        let row = try #require(view.row(.trashSelection))
        let width = row.frame.width
        #expect(width == 460)
        #expect(row.arrange(width: width) == 60)
        let note = try #require(row.noteText)
        let reassign = try #require(row.reassignButton)
        let cancel = try #require(row.cancelButton)
        // 5 of padding, the line of 22, 6, then the buttons' 22 with the note centred on them.
        #expect(reassign.frame.minY == 33 && cancel.frame.minY == 33 && reassign.frame.height == 22)
        #expect(abs(note.frame.midY - reassign.frame.midY) < 0.01)
        #expect(cancel.frame.maxX == width)
        #expect(cancel.frame.minX - reassign.frame.maxX == 6)
        #expect(reassign.frame.minX - note.frame.maxX == 10)
        // Cancel takes the note away and the row back to its one line.
        Kit.click(cancel)
        #expect(notes(view).isEmpty)
        #expect(view.row(.trashSelection)?.arrange(width: width) == 32)
    }

    // An empty key place is hidden unless its row is hovered, it records or its focus is visible: a click's focus
    // doesn't lift it, nor does a key with ⌘; a plain key's does.
    @Test func aClickedEmptyPlaceHidesOffTheRowUntilAKeyMakesItsFocusVisible() throws {
        let (controller, _, view) = try make()
        let window = try #require(controller.window)
        let place = try slot(.newFolder, 1, in: view)
        window.makeFirstResponder(place)
        place.perform()
        #expect(!place.focusIsVisible)
        press(Kit.letter("d", .command, window: window), in: controller)
        #expect(notes(view) == ["⌘D is used by Duplicate."])
        #expect(window.firstResponder === place)
        #expect(!place.isRecording)
        #expect(!place.focusIsVisible)
        #expect(!place.rowHovered)
        #expect(!place.isShown)
        place.rowHovered = true
        #expect(place.isShown)
        place.rowHovered = false
        #expect(!place.isShown)
        press(Kit.letter("n", window: window), in: controller)
        #expect(place.focusIsVisible)
        #expect(place.isShown)
    }

    // The conflict's "+" and the key's badge under the pointer, left where it clicked: the slot under it is filled
    // (10% of the text color, #e2e2e2 on the page's #f8f8f8), and the row under it shows the badge.
    @Test func aRowUnderThePointerShowsTheBadgeAndTheSlotItsFill() throws {
        let (controller, _, view) = try make()
        let window = try #require(controller.window)
        let row = try #require(view.row(.newFolder))
        let place = row.slots[1]
        place.perform()
        press(Kit.letter("d", .command, window: window), in: controller)
        #expect(notes(view) == ["⌘D is used by Duplicate."])
        #expect(row.clearButtons[0].isHidden)
        let entered = try #require(
            NSEvent.enterExitEvent(
                with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        // Between the border and the "+", on a transparent bitmap.
        func fillAlpha() throws -> CGFloat {
            let bitmap = try #require(place.bitmapImageRepForCachingDisplay(in: place.bounds))
            place.cacheDisplay(in: place.bounds, to: bitmap)
            return try #require(bitmap.colorAt(x: bitmap.pixelsWide / 4, y: bitmap.pixelsHigh / 2)).alphaComponent
        }
        row.mouseEntered(with: entered)
        #expect(!row.clearButtons[0].isHidden)
        #expect(row.clearButtons[1].isHidden)
        #expect(try fillAlpha() == 0)
        place.mouseEntered(with: entered)
        #expect(try fillAlpha() > 0)
    }

    // A place's remove badge comes with the keyboard, with no pointer on the row, and goes with it.
    @Test func aKeysRemoveBadgeShowsWhileTheKeyboardIsOnIt() throws {
        let (controller, _, view) = try make()
        let window = try #require(controller.window)
        let row = try #require(view.row(.newFolder))
        let badge = try #require(row.clearButtons.first)
        #expect(row.slots[0].shortcut != nil)
        #expect(badge.isHidden)
        window.makeFirstResponder(row.slots[0])
        #expect(!badge.isHidden)
        // On to the next place, which has no key and so no badge.
        window.makeFirstResponder(row.slots[1])
        #expect(badge.isHidden)
        #expect(row.clearButtons[1].isHidden)
        window.makeFirstResponder(row.slots[0])
        #expect(!badge.isHidden)
        window.makeFirstResponder(nil)
        #expect(badge.isHidden)
    }

    @Test func removesAKeyWithBackspaceOrItsClearButtonAndTheAlternateBecomesTheMainKey() throws {
        let preferences = AppPreferences.defaults(theme: .light).with {
            $0.shortcutOverrides = ["newFolder": ["Cmd+Shift+N", "Cmd+Option+J"]]
        }
        let (controller, _, view) = try make(preferences)
        let main = try slot(.newFolder, 0, in: view)
        controller.window?.makeFirstResponder(main)
        main.keyDown(with: Kit.key(Kit.backspace.0, code: Kit.backspace.1, window: controller.window))
        #expect(view.row(.newFolder)?.slots.map(\.stringValue) == ["⌥⌘J", "+"])
        let row = try #require(view.row(.newFolder))
        #expect(row.clearButtons.first?.accessibilityLabel() == "Remove ⌥⌘J from New Folder")
        row.clearButtons.first?.perform()
        #expect(view.row(.newFolder)?.slots.map(\.stringValue) == ["+"])
        // ⌫ while recording an empty place cancels.
        let empty = try slot(.newFolder, 0, in: view)
        empty.perform()
        press(Kit.key(Kit.backspace.0, code: Kit.backspace.1, window: controller.window), in: controller)
        #expect(!empty.isRecording)
    }

    // ⌘D while the recorder records, with the app's menu. AppKit offers a key equivalent to the
    // key window before the menu bar; the menu would claim ⌘D (Duplicate), even dimmed, so the recorder only has it when
    // the window goes first.
    @Test func theRecorderHasAMenuKeyBeforeTheMenuDoes() throws {
        let (controller, _, view) = try make()
        let place = try slot(.newFolder, 1, in: view)
        place.perform()
        #expect(controller.window?.firstResponder === place)
        let commandD = Kit.letter("d", .command, window: controller.window)
        let router = MenuCommandRouter()
        router.setItem(AppCommand.duplicateSelection.rawValue, enabled: false)
        let built = ApplicationMenuBuilder.build(target: router)
        #expect(built.menu.performKeyEquivalent(with: commandD))
        #expect(view.model.note == nil)
        #expect(controller.window?.performKeyEquivalent(with: commandD) == true)
        #expect(notes(view) == ["⌘D is used by Duplicate."])
    }

    @Test func resetsOneCommandTakingItsDefaultKeyBackOrAllOfThem() throws {
        let (controller, recorder, view) = try make()
        // Duplicate's ⌘D goes to New Folder.
        try slot(.newFolder, 1, in: view).perform()
        press(Kit.letter("d", .command, window: controller.window), in: controller)
        Kit.click(view.row(.newFolder)?.reassignButton)
        let duplicate = try #require(view.row(.duplicateSelection))
        #expect(duplicate.restoreButton.accessibilityLabel() == "Restore Default for Duplicate")
        Kit.click(duplicate.restoreButton)
        #expect(notes(view) == ["Taken back from New Folder."])
        #expect(view.row(.duplicateSelection)?.slots.first?.stringValue == "⌘D")
        // Back where they started: nothing differs.
        #expect(recorder.current.shortcutOverrides.isEmpty)
        // Restore Defaults clears everything.
        try slot(.newFolder, 1, in: view).perform()
        press(Kit.letter("j", [.command, .option], window: controller.window), in: controller)
        #expect(recorder.saved["shortcutOverrides"]?["newFolder"] != nil)
        #expect(view.restoreAllButton.accessibilityLabel() == "Restore Default Shortcuts")
        Kit.click(view.restoreAllButton)
        #expect(recorder.saved["shortcutOverrides"] == .object([:]))
        #expect(!view.restoreAllButton.isEnabled)
    }

    @Test func warnsWhenMacOSMayTakeTheKeyFirst() throws {
        let (controller, _, view) = try make()
        try slot(.newFolder, 1, in: view).perform()
        let up = Kit.key(
            Kit.up.0, code: Kit.up.1, modifiers: [.control, .function, .numericPad], window: controller.window)
        press(up, in: controller)
        #expect(
            notes(view) == [
                "macOS may use ⌃↑ itself, for Mission Control. It works here once that is switched off in System Settings → Keyboard → Keyboard Shortcuts."
            ])
        #expect(view.row(.newFolder)?.slots.map(\.stringValue) == ["⇧⌘N", "⌃↑"])
    }

    @Test func findsCommandsByNameOrByKey() throws {
        let (controller, _, view) = try make()
        view.setQuery("new folder")
        #expect(texts("settings.shortcuts.label", in: view) == ["New Folder"])
        view.setQuery("⇧⌘N")
        #expect(texts("settings.shortcuts.label", in: view).contains("New Folder"))
        view.setQuery("cmd+shift+n")
        #expect(texts("settings.shortcuts.label", in: view).contains("New Folder"))
        view.setQuery("windows and tabs")
        #expect(view.groups.map(\.group) == [.tabs])
        view.setQuery("zzz")
        #expect(texts("settings.shortcuts.empty", in: view) == ["No command or key matches “zzz”."])
        // Escape clears the search first; with nothing to clear it goes on to the window.
        let field = view.searchField
        #expect(
            field.control(field.input, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        #expect(field.text.isEmpty)
        #expect(
            !field.control(field.input, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        )
        _ = controller
    }
}

extension NSEvent {
    /// The same key, held down (auto-repeat).
    @MainActor
    func withRepeat(window: NSWindow?) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifierFlags, timestamp: 0,
            windowNumber: window?.windowNumber ?? 0, context: nil, characters: characters ?? "",
            charactersIgnoringModifiers: charactersIgnoringModifiers ?? "", isARepeat: true, keyCode: keyCode)!
    }
}
