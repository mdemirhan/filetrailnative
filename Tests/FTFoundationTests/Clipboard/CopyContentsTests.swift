// Copy Contents' rules: which files it copies, as what, what it asks first, and where the command is offered
import Foundation
import Testing

@testable import FTFoundation

struct CopyContentsTests {
    // MARK: What a name says

    @Test func imagesAreTheKindsTheSystemCallsImages() {
        for name in ["beach.HEIC", "shot.png", "photo.jpg", "scan.tiff", "anim.gif", "icon.icns", "pic.webp"] {
            #expect(CopyContents.guess(forName: name) == .image, "\(name)")
        }
    }

    @Test func textIsTheKindsTheSystemCallsTextAndTheCodeItCallsSomethingElse() {
        for name in ["notes.txt", "main.swift", "data.json", "page.html", "letter.rtf", "table.csv"] {
            #expect(CopyContents.guess(forName: name) == .text, "\(name)")
        }
        // A TypeScript file is a video to the system, and an SVG an image: both are copied as their text.
        for name in ["app.ts", "view.tsx", "logo.svg", "README.md", "Cargo.toml", "ci.yml", "lib.rs"] {
            #expect(CopyContents.guess(forName: name) == .text, "\(name)")
        }
    }

    // A `.pem` or a `.csr` is always text, though the system calls a `.pem` a certificate; a `.key` is a private key
    // or a Keynote document, and a `.crt` or a `.cer` a certificate in text or in binary, so they are read to tell.
    @Test func keysAndCertificatesAreOfferedAsTheTextTheyUsuallyAre() {
        for name in ["server.pem", "Request.CSR"] {
            #expect(CopyContents.guess(forName: name) == .text, "\(name)")
        }
        for name in ["tls.key", "Talk.key", "site.crt", "root.CER"] {
            #expect(CopyContents.guess(forName: name) == .unknown, "\(name)")
            #expect(CopyContents.guess(forName: name).isOffered, "\(name)")
        }
        // A certificate named as binary is neither.
        #expect(CopyContents.guess(forName: "root.der") == .other)
    }

    @Test func aNameThatDoesntSayIsFoundOutAsItIsRead() {
        for name in ["Makefile", "LICENSE", ".gitignore", ".env", "notes.zzqx"] {
            #expect(CopyContents.guess(forName: name) == .unknown, "\(name)")
        }
        #expect(CopyContents.guess(forName: "Makefile").isOffered)
    }

    @Test func aKindThatIsNeitherIsNotOffered() {
        for name in ["report.pdf", "backup.zip", "film.mov", "song.mp3"] {
            #expect(CopyContents.guess(forName: name) == .other, "\(name)")
        }
        #expect(!CopyContentsGuess.other.isOffered)
        #expect(CopyContentsGuess.other.kind == nil)
    }

    @Test func aPNGOrAJPEGNeedsNoPNGCopy() {
        #expect(!CopyContents.needsPNGCopy("public.png"))
        #expect(!CopyContents.needsPNGCopy("public.jpeg"))
        #expect(CopyContents.needsPNGCopy("public.heic"))
        #expect(CopyContents.needsPNGCopy("public.tiff"))
        #expect(CopyContents.isImageType("public.heic"))
        #expect(!CopyContents.isImageType("com.adobe.pdf"))
    }

    // MARK: Text

    @Test func textIsUTF8OrUTF16WithItsMark() {
        #expect(CopyContents.decodeText(Data("héllo".utf8)) == "héllo")
        #expect(CopyContents.decodeText(Data([0xEF, 0xBB, 0xBF]) + Data("hi".utf8)) == "hi")
        let utf16 = "héllo".data(using: .utf16)!  // with its byte-order mark
        #expect(CopyContents.decodeText(utf16) == "héllo")
        #expect(CopyContents.decodeText(Data("hé".utf16BigEndianWithMark)) == "hé")
    }

    @Test func aBinaryFileOrAnotherEncodingIsNotText() {
        #expect(CopyContents.decodeText(Data([0x50, 0x4B, 0x03, 0x04, 0x00, 0x14])) == nil)
        // "café" in Latin-1: not UTF-8.
        #expect(CopyContents.decodeText(Data([0x63, 0x61, 0x66, 0xE9])) == nil)
    }

    // UTF-32's mark begins as UTF-16's does: read as UTF-16, every other character would be a zero.
    @Test func utf32AndTextWithAZeroCharacterAreNotText() {
        let littleEndian: [UInt8] = [0xFF, 0xFE, 0x00, 0x00, 0x61, 0x00, 0x00, 0x00, 0x62, 0x00, 0x00, 0x00]
        #expect(CopyContents.decodeText(Data(littleEndian)) == nil)
        let bigEndian: [UInt8] = [0x00, 0x00, 0xFE, 0xFF, 0x00, 0x00, 0x00, 0x61]
        #expect(CopyContents.decodeText(Data(bigEndian)) == nil)
        // UTF-16 and UTF-8 with their marks and a zero character among the letters.
        #expect(CopyContents.decodeText(Data([0xFF, 0xFE, 0x61, 0x00, 0x00, 0x00, 0x62, 0x00])) == nil)
        #expect(CopyContents.decodeText(Data([0xFE, 0xFF, 0x00, 0x61, 0x00, 0x00])) == nil)
        #expect(CopyContents.decodeText(Data([0xEF, 0xBB, 0xBF, 0x61, 0x00, 0x62])) == nil)
        #expect(CopyContents.decodeText(Data([0xEF, 0xBB, 0xBF, 0x61, 0x62])) == "ab")
        #expect(CopyContents.decodeText(Data([0xFF, 0xFE, 0x61, 0x00, 0x62, 0x00])) == "ab")
    }

    // MARK: Secrets

    @Test func namesThatUsuallyHoldAPasswordOrAKeyAreAskedAbout() {
        for name in [".env", ".env.local", ".ENV.production", "server.pem", "tls.key", "id_rsa", "id_ed25519"] {
            #expect(CopyContents.looksSecret(name), "\(name)")
        }
        for name in ["id_rsa.pub", "id_ed25519.pub", "env.txt", "notes.md", "keys.txt", "environment.ts"] {
            #expect(!CopyContents.looksSecret(name), "\(name)")
        }
    }

    @Test func theFilesToolsKeepTheirPasswordsInAreAskedAbout() {
        for name in [
            "prod.env", "Staging.ENV", ".netrc", ".npmrc", ".pgpass", ".htpasswd", "credentials", "kubeconfig",
            "AuthKey_ABC123.p8", "server.ppk", "id_rsa_work",
        ] {
            #expect(CopyContents.looksSecret(name), "\(name)")
        }
        for name in ["config", "credentials.md", "netrc.txt", "kubeconfig.md", "notes.p8.txt"] {
            #expect(!CopyContents.looksSecret(name), "\(name)")
        }
        // "config" is kubectl's only in its own folder.
        #expect(CopyContents.looksSecret(path: "/Users/demo/.kube/config"))
        #expect(!CopyContents.looksSecret(path: "/Users/demo/.ssh/config"))
        #expect(CopyContents.looksSecret(path: "/Users/demo/.aws/credentials"))
        #expect(!CopyContents.looksSecret(path: "/Users/demo/.kube/notes.txt"))
    }

    @Test func aNameWhoseExtensionSaysImageIsNeverAskedAbout() {
        for name in ["id_rsa_diagram.png", "id_ed25519 setup.jpg", ".env.png", "credentials.heic"] {
            #expect(!CopyContents.looksSecret(name), "\(name)")
        }
    }

    // MARK: Names

    @Test func theMenusSayWhatWouldBeCopied() {
        #expect(CopyContents.menuTitle(.image) == "Copy Image")
        #expect(CopyContents.menuTitle(.text) == "Copy Text")
        #expect(CopyContents.menuTitle(.unknown) == "Copy Contents")
        #expect(CopyContents.menuTitle(.other) == "Copy Contents")
        #expect(CopyContents.menuTitle(nil) == "Copy Contents")
    }

    @Test func theEditMenuNamesWhatItWouldCopyWhileItCan() {
        func title(_ guess: CopyContentsGuess?, disabled: Bool) -> String? {
            let state = ApplicationMenuState(
                disabledCommands: disabled ? [.copyContents] : [], copyContentsGuess: guess)
            return ApplicationMenu.itemStates(state, window: .init(explorerFocused: true))
                .first { $0.id == AppCommand.copyContents.rawValue }?.title
        }
        #expect(title(.image, disabled: false) == "Copy Image")
        #expect(title(.text, disabled: false) == "Copy Text")
        #expect(title(.unknown, disabled: false) == "Copy Contents")
        #expect(title(.image, disabled: true) == "Copy Contents")
    }

    // MARK: Where it is offered

    static func context(_ configure: (inout CommandAvailabilityContext) -> Void = { _ in })
        -> CommandAvailabilityContext
    {
        var context = CommandAvailabilityContext(
            shortcutContext: ShortcutContext(focusedPane: .content), currentPath: "/Users/demo",
            selectedPathsInViewOrder: ["/Users/demo/a.png"],
            activeContentEntries: [
                CommandEntry(path: "/Users/demo/a.png", kind: .file),
                CommandEntry(path: "/Users/demo/b.txt", kind: .symlinkFile),
                CommandEntry(path: "/Users/demo/Folder", kind: .directory),
                CommandEntry(path: "/Users/demo/App.app", kind: .bundle),
            ], homePath: "/Users/demo")
        configure(&context)
        return context
    }

    @Test func itRunsOnOneFileOfTheList() {
        #expect(CommandAvailability.canRun(.copyContents, Self.context()))
        // A link to a file copies the file.
        #expect(
            CommandAvailability.canRun(
                .copyContents, Self.context { $0.selectedPathsInViewOrder = ["/Users/demo/b.txt"] }))
        for paths in [[], ["/Users/demo/a.png", "/Users/demo/b.txt"], ["/Users/demo/Folder"], ["/Users/demo/App.app"]] {
            #expect(!CommandAvailability.canRun(.copyContents, Self.context { $0.selectedPathsInViewOrder = paths }))
        }
        // A file not in the listing isn't known to be one.
        #expect(
            !CommandAvailability.canRun(
                .copyContents, Self.context { $0.selectedPathsInViewOrder = ["/Users/demo/gone.png"] }))
    }

    @Test func itOnlyReadsSoItRunsWhereWritesCantAndNeverFromTheTree() {
        #expect(CommandAvailability.canRun(.copyContents, Self.context { $0.writeOperationLocked = true }))
        #expect(CommandAvailability.canRun(.copyContents, Self.context { $0.isSearchMode = true }))
        #expect(CommandAvailability.canRun(.copyContents, Self.context { $0.currentPath = "/Users/demo/.Trash" }))
        let tree = Self.context {
            $0.shortcutContext = ShortcutContext(focusedPane: .tree, selectedTreeTargetKind: .filesystemFolder)
        }
        #expect(!CommandAvailability.canRun(.copyContents, tree))
        #expect(
            !CommandAvailability.canRun(
                .copyContents, Self.context { $0.shortcutContext = ShortcutContext(copyPasteModalOpen: true) }))
    }

    @Test func theFilesMenuHasItForOneImageOrTextFileOnly() {
        let world = ContextMenuWorld(homePath: "/Users/me", currentPath: "/Users/me/Documents", writeLocked: true)
        func menu(_ entries: [CommandEntry], surface: ContextMenuSurface = .content) -> [String] {
            let subject = ContextMenuSubject(
                surface: surface, paths: entries.map(\.path), targetPath: entries.first?.path, entries: entries)
            let options = ContextMenuRules.options(subject, world, textEditorName: nil)
            let hidden = ContextMenuRules.hiddenActions(subject, world)
            return ContextMenuItems.visibleItems(surface: surface, options: options, hidden: hidden).compactMap(\.label)
        }
        let photo = CommandEntry(path: "/Users/me/Documents/beach.heic", kind: .file)
        let labels = menu([photo])
        #expect(labels.firstIndex(of: "Copy Image") == labels.firstIndex(of: "Copy Path").map { $0 + 1 })
        #expect(menu([CommandEntry(path: "/Users/me/Documents/notes.md", kind: .symlinkFile)]).contains("Copy Text"))
        #expect(menu([CommandEntry(path: "/Users/me/Documents/Makefile", kind: .file)]).contains("Copy Contents"))
        #expect(menu([CommandEntry(path: "/Users/me/Documents/server.pem", kind: .file)]).contains("Copy Text"))
        #expect(menu([CommandEntry(path: "/Users/me/Documents/tls.key", kind: .file)]).contains("Copy Contents"))
        #expect(menu([photo], surface: .search).contains("Copy Image"))
        #expect(
            menu([CommandEntry(path: "/Users/me/.Trash/beach.heic", kind: .file)], surface: .trash).contains(
                "Copy Image"))
        for entries in [
            [CommandEntry(path: "/Users/me/Documents/report.pdf", kind: .file)],
            [CommandEntry(path: "/Users/me/Documents/Folder", kind: .directory)],
            // A Keynote document saved as a package.
            [CommandEntry(path: "/Users/me/Documents/Talk.key", kind: .bundle)],
            [photo, CommandEntry(path: "/Users/me/Documents/b.png", kind: .file)],
        ] {
            #expect(!menu(entries).contains { $0.hasPrefix("Copy ") && $0 != "Copy" && $0 != "Copy Path" })
        }
    }

    @Test func theFilesMenuShowsItsKey() {
        let context = ShortcutContext(focusedPane: .content)
        #expect(ShortcutPolicy.contextMenuShortcutLabel(actionID: "copyContents", context: context) == "⇧⌘C")
        let tree = ShortcutContext(focusedPane: .tree, selectedTreeTargetKind: .filesystemFolder)
        #expect(ShortcutPolicy.contextMenuShortcutLabel(actionID: "copyContents", context: tree) == nil)
    }
}

extension String {
    /// The string in UTF-16, big-endian, after its byte-order mark.
    fileprivate var utf16BigEndianWithMark: [UInt8] {
        [0xFE, 0xFF] + utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }
    }
}
