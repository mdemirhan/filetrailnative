// Paste as File's rules: what on the system's clipboard becomes a file, its name, and where the command is offered
import Testing

@testable import FTFoundation

struct PasteAsFileTests {
    static func choose(_ types: [String], text: String? = nil) -> PasteAsFileChoice {
        PasteAsFile.choose(types: types) { text }
    }

    // MARK: What is written

    @Test func anImageIsTakenInItsOwnFormatAndTIFFOnlyWhenThereIsNoOther() {
        #expect(Self.choose(["public.png", "public.tiff"]) == .image(.png))
        #expect(Self.choose(["public.tiff", "public.jpeg"]) == .image(.jpeg))
        #expect(Self.choose(["public.heic"]) == .image(.heic))
        #expect(Self.choose(["com.compuserve.gif"]) == .image(.gif))
        #expect(Self.choose(["public.tiff"]) == .image(.tiff))
    }

    @Test func aTIFFIsWrittenAsPNGAndTheOthersAsTheyAre() {
        #expect(PasteAsFileImageFormat.tiff.isConverted)
        #expect(PasteAsFileImageFormat.tiff.fileExtension == "png")
        #expect(!PasteAsFileImageFormat.png.isConverted && !PasteAsFileImageFormat.jpeg.isConverted)
        #expect(PasteAsFileImageFormat.jpeg.fileExtension == "jpg")
    }

    @Test func plainTextWinsOverThePictureADocumentCarriesWithIt() {
        let numbers = ["public.utf8-plain-text", "public.rtf", "com.adobe.pdf", "public.tiff"]
        #expect(Self.choose(numbers, text: "Name\tTotal\nRent\t1200") == .text)
        #expect(Self.choose(["public.utf8-plain-text"], text: "hello") == .text)
    }

    @Test func anImageWhoseOnlyTextIsItsAddressIsTheImage() {
        let copyImage = ["public.tiff", "public.url", "public.utf8-plain-text"]
        #expect(Self.choose(copyImage, text: "https://example.com/cat.png") == .image(.tiff))
        #expect(Self.choose(copyImage, text: "  https://example.com/cat.png\n") == .image(.tiff))
        #expect(Self.choose(copyImage, text: "A cat https://example.com/cat.png") == .text)
        // An address alone with no image is text.
        #expect(Self.choose(["public.utf8-plain-text"], text: "https://example.com") == .text)
    }

    @Test func filesCopiedInAnotherAppAreNeverWrittenNotEvenTheirIconOrName() {
        let finder = ["public.file-url", "public.utf8-plain-text", "public.tiff", "com.apple.icns"]
        #expect(Self.choose(finder, text: "report.pdf") == .files)
        #expect(Self.choose(["NSFilenamesPboardType"]) == .files)
        #expect(PasteAsFileChoice.files.kind == nil)
    }

    @Test func emptyTextOrNothingKnownIsNothing() {
        #expect(Self.choose([]) == .nothing)
        #expect(Self.choose(["public.utf8-plain-text"], text: "") == .nothing)
        #expect(Self.choose(["public.rtf", "public.html"]) == .nothing)
        #expect(PasteAsFileChoice.nothing.kind == nil)
    }

    @Test func theTextIsReadOnlyWhenThereIsSome() {
        var read = 0
        _ = PasteAsFile.choose(types: ["public.png"]) {
            read += 1
            return "x"
        }
        #expect(read == 0)
    }

    @Test func whatAPasswordManagerMarkedIsTold() {
        #expect(PasteAsFile.isConcealed(types: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"]))
        #expect(!PasteAsFile.isConcealed(types: ["public.utf8-plain-text"]))
    }

    // MARK: Names

    @Test func theMenusSayWhatWouldBeWritten() {
        #expect(PasteAsFile.menuTitle(.image) == "Paste Image as File")
        #expect(PasteAsFile.menuTitle(.text) == "Paste Text as File")
        #expect(PasteAsFile.menuTitle(nil) == "Paste as File")
    }

    @Test func aFileIsNamedForWhatItHolds() {
        #expect(PasteAsFile.fileName(.image(.png)) == "Pasted Image.png")
        #expect(PasteAsFile.fileName(.image(.tiff)) == "Pasted Image.png")
        #expect(PasteAsFile.fileName(.image(.heic)) == "Pasted Image.heic")
        #expect(PasteAsFile.fileName(.text) == "Pasted Text.txt")
        #expect(PasteAsFile.fileName(.files) == nil)
    }

    @Test func aTakenNameIsNumberedBeforeItsExtensionWhateverItsCase() {
        #expect(PasteAsFile.freeName("Pasted Image.png", existingNames: ["notes.md"]) == "Pasted Image.png")
        #expect(PasteAsFile.freeName("Pasted Image.png", existingNames: ["pasted image.PNG"]) == "Pasted Image 2.png")
        #expect(
            PasteAsFile.freeName("Pasted Text.txt", existingNames: ["Pasted Text.txt", "Pasted Text 2.txt"])
                == "Pasted Text 3.txt")
    }

    // MARK: Where it is offered

    static func context(_ configure: (inout CommandAvailabilityContext) -> Void = { _ in })
        -> CommandAvailabilityContext
    {
        var context = CommandAvailabilityContext(
            shortcutContext: ShortcutContext(focusedPane: .content), currentPath: "/Users/demo",
            homePath: "/Users/demo", systemClipboard: .image(.png))
        configure(&context)
        return context
    }

    @Test func itRunsInTheFolderOnScreenWithSomethingToWrite() {
        #expect(CommandAvailability.canRun(.pasteAsFile, Self.context()))
        #expect(!CommandAvailability.canRun(.pasteAsFile, Self.context { $0.systemClipboard = nil }))
        #expect(!CommandAvailability.canRun(.pasteAsFile, Self.context { $0.systemClipboard = .nothing }))
        #expect(CommandAvailability.canRun(.pasteAsFile, Self.context { $0.systemClipboard = .text }))
        // Pressed with files copied in another app, it says why they aren't written.
        #expect(CommandAvailability.canRun(.pasteAsFile, Self.context { $0.systemClipboard = .files }))
        #expect(!CommandAvailability.canRun(.pasteAsFile, Self.context { $0.isSearchMode = true }))
        #expect(!CommandAvailability.canRun(.pasteAsFile, Self.context { $0.currentPath = "/Users/demo/.Trash" }))
        #expect(!CommandAvailability.canRun(.pasteAsFile, Self.context { $0.writeOperationLocked = true }))
        #expect(!CommandAvailability.canRun(.pasteAsFile, Self.context { $0.currentPath = "" }))
    }

    @Test func itRunsWhicheverPaneHasTheKeyboard() {
        let tree = Self.context {
            $0.shortcutContext = ShortcutContext(focusedPane: .tree, selectedTreeTargetKind: .filesystemFolder)
        }
        #expect(CommandAvailability.canRun(.pasteAsFile, tree))
        #expect(CommandAvailability.canRun(.pasteAsFile, Self.context { $0.shortcutContext = ShortcutContext() }))
        #expect(
            !CommandAvailability.canRun(
                .pasteAsFile, Self.context { $0.shortcutContext = ShortcutContext(copyPasteModalOpen: true) }))
    }

    @Test func theEditMenuNamesWhatItWouldWriteWhileItCan() {
        func title(_ kind: PasteAsFileKind?, disabled: Bool) -> String? {
            let state = ApplicationMenuState(
                disabledCommands: disabled ? [.pasteAsFile] : [], pasteAsFileKind: kind)
            return ApplicationMenu.itemStates(state, window: .init(explorerFocused: true))
                .first { $0.id == AppCommand.pasteAsFile.rawValue }?.title
        }
        #expect(title(.image, disabled: false) == "Paste Image as File")
        #expect(title(.text, disabled: false) == "Paste Text as File")
        #expect(title(.image, disabled: true) == "Paste as File")
    }

    @Test func theBackgroundMenuHasItOnlyWithSomethingToWriteAndNotInTheTrash() {
        let background = ContextMenuSubject(surface: .background, scope: .background)
        func world(_ kind: PasteAsFileKind?, current: String = "/Users/me/Documents", locked: Bool = false)
            -> ContextMenuWorld
        {
            ContextMenuWorld(homePath: "/Users/me", currentPath: current, writeLocked: locked, pasteAsFileKind: kind)
        }
        #expect(!ContextMenuRules.hiddenActions(background, world(.text)).contains(.pasteAsFile))
        #expect(ContextMenuRules.hiddenActions(background, world(nil)).contains(.pasteAsFile))
        #expect(
            ContextMenuRules.hiddenActions(background, world(.text, current: "/Users/me/.Trash")).contains(.pasteAsFile)
        )
        #expect(ContextMenuRules.hiddenActions(background, world(.text, locked: true)).contains(.pasteAsFile))
        let options = ContextMenuRules.options(background, world(.image), textEditorName: nil)
        let items = ContextMenuItems.visibleItems(surface: .background, options: options, hidden: [])
        let labels = items.compactMap(\.label)
        #expect(labels.firstIndex(of: "Paste Image as File") == labels.firstIndex(of: "Paste").map { $0 + 1 })
    }

    @Test func theBackgroundMenuShowsItsKey() {
        let context = ShortcutContext(focusedPane: .content)
        #expect(ShortcutPolicy.contextMenuShortcutLabel(actionID: "pasteAsFile", context: context) == "⇧⌘V")
    }
}
