// Checks the menu visibility rules of apps/desktop/src/renderer/hooks/useExplorerActions.ts:576-700 case by case (the
// rules sit in a React hook, so no golden can import them), and the item list's compaction of ItemContextMenu.tsx
import Testing

@testable import FTFoundation

struct ContextMenuRulesTests {
    static let home = "/Users/me"
    static let trash = "/Users/me/.Trash"

    func world(
        current: String = "/Users/me/Documents", search: Bool = false, favorites: [String] = [],
        trashEmpty: Bool? = nil,
        locked: Bool = false, canPaste: Bool = false, pasteDestination: Bool = false
    ) -> ContextMenuWorld {
        ContextMenuWorld(
            homePath: Self.home, currentPath: current, isSearchMode: search, favoritePaths: favorites,
            trashIsEmpty: trashEmpty, writeLocked: locked, canPaste: canPaste, hasPasteDestination: pasteDestination)
    }

    func subject(
        _ surface: ContextMenuSurface, _ entries: [(String, EntryKind)], scope: ContextMenuScope = .selection
    ) -> ContextMenuSubject {
        ContextMenuSubject(
            surface: surface, scope: scope, paths: entries.map(\.0), targetPath: entries.first?.0,
            entries: entries.map { CommandEntry(path: $0.0, kind: $0.1) })
    }

    func hidden(_ subject: ContextMenuSubject, _ world: ContextMenuWorld) -> Set<ContextMenuActionID> {
        ContextMenuRules.hiddenActions(subject, world)
    }

    func labels(_ subject: ContextMenuSubject, _ world: ContextMenuWorld, editor: String? = nil) -> [String] {
        let options = ContextMenuRules.options(subject, world, textEditorName: editor)
        return ContextMenuItems.visibleItems(
            surface: subject.surface, options: options, hidden: hidden(subject, world)
        ).compactMap(\.label)
    }

    // F-815
    // B-VIEW-211 T-eb3ba6a5
    @Test func aTextFileShowsEditAndNothingElseDoes() {
        let file = subject(.content, [("/a/b.txt", .file)])
        #expect(!hidden(file, world()).contains(.edit))
        #expect(hidden(subject(.content, [("/a/Folder", .directory)]), world()).contains(.edit))
        #expect(hidden(subject(.content, [("/a/x.app", .bundle)]), world()).contains(.edit))
        #expect(hidden(subject(.content, [("/a/b.txt", .file), ("/a/c", .directory)]), world()).contains(.edit))
        #expect(!hidden(subject(.content, [("/a/b.txt", .file), ("/a/c.md", .symlinkFile)]), world()).contains(.edit))
    }

    // F-815
    // B-VIEW-211 T-c2c3e724
    @Test func showPackageContentsIsForBundlesAndCalculateSizeForFolders() {
        let file = hidden(subject(.content, [("/a/b.txt", .file)]), world())
        #expect(file.contains(.showPackageContents) && file.contains(.calculateSize))
        let bundle = hidden(subject(.content, [("/a/x.app", .bundle)]), world())
        #expect(!bundle.contains(.showPackageContents) && !bundle.contains(.calculateSize))
        // Several items with a folder among them: the sizes are asked for the folders.
        let mixed = hidden(subject(.content, [("/a/b.txt", .file), ("/a/c", .directory)]), world())
        #expect(!mixed.contains(.calculateSize) && mixed.contains(.showPackageContents))
        // An alias of a folder is not measured.
        #expect(hidden(subject(.content, [("/a/l", .symlinkDirectory)]), world()).contains(.calculateSize))
    }

    // F-815
    // B-VIEW-211 T-848e568e
    @Test func pasteAndNewFolderAreForOneFolderAndOpenInANewTabToo() {
        let folder = subject(.content, [("/a/Folder", .directory)])
        let withDestination = hidden(folder, world(pasteDestination: true))
        #expect(!withDestination.contains(.paste) && !withDestination.contains(.newFolder))
        #expect(!withDestination.contains(.openInNewTab) && !withDestination.contains(.openInNewWindow))
        // One that is itself on the clipboard has no destination.
        #expect(hidden(folder, world(pasteDestination: false)).contains(.paste))
        let file = hidden(subject(.content, [("/a/b.txt", .file)]), world(pasteDestination: true))
        #expect(file.contains(.paste) && file.contains(.newFolder))
        #expect(file.contains(.openInNewTab) && file.contains(.openInNewWindow))
        let two = hidden(
            subject(.content, [("/a/F", .directory), ("/a/G", .directory)]), world(pasteDestination: true))
        #expect(two.contains(.paste) && two.contains(.newFolder) && two.contains(.openInNewTab))
    }

    // F-816
    // B-CLIP-007 B-CLIP-053 B-CLIP-059 B-TREE-145 B-TREE-148 B-VIEW-210 B-VIEW-212 T-0ad433eb T-5389fe11
    // T-c6fb632a
    @Test func whileAWriteRunsTheMenuLeavesOutWhatWouldStartAnotherButPasteIsOnlyDimmed() {
        let folder = subject(.content, [("/a/Folder", .directory)])
        let locked = hidden(folder, world(locked: true, pasteDestination: true))
        for action in [
            ContextMenuActionID.move, .rename, .duplicate, .newFolder, .trash, .deleteImmediately, .emptyTrash,
        ] {
            #expect(locked.contains(action), "\(action)")
        }
        #expect(!locked.contains(.paste))
        #expect(ContextMenuRules.disabledActions(world(locked: true, canPaste: true)) == [.paste])
        #expect(ContextMenuRules.disabledActions(world(canPaste: true)).isEmpty)
        #expect(ContextMenuRules.disabledActions(world(canPaste: false)) == [.paste])
        // Copy, Cut and Copy Path only fill a clipboard.
        #expect(!locked.contains(.copy) && !locked.contains(.cut) && !locked.contains(.copyPath))
    }

    // F-816
    // B-VIEW-205 B-VIEW-212 T-e28360aa
    @Test func theTrashHidesPasteNewFolderDuplicateAndTrash() {
        let inTrash = subject(.trash, [(Self.trash + "/old.txt", .file)])
        let result = hidden(inTrash, world(current: Self.trash))
        for action in [ContextMenuActionID.paste, .newFolder, .duplicate, .trash] { #expect(result.contains(action)) }
        #expect(!result.contains(.deleteImmediately))
        #expect(
            labels(inTrash, world(current: Self.trash)).contains("Delete Immediately…")
                && !labels(inTrash, world(current: Self.trash)).contains("Move to Trash"))
    }

    // F-816
    // B-TREE-036 B-TREE-037 B-TREE-189 B-VIEW-211 B-VIEW-213 T-0e303da8 T-342c9b04
    @Test func theFavoriteToggleReadsAddOrRemoveAndIsLeftOutWhereItDoesNotApply() {
        let folder = subject(.content, [("/a/Folder", .directory)])
        #expect(ContextMenuRules.favoriteToggleLabel(folder, world()) == "Add to Favorites")
        #expect(
            ContextMenuRules.favoriteToggleLabel(folder, world(favorites: ["/a/Folder"])) == "Remove from Favorites")
        // A file, several items, search results and the background have none.
        #expect(ContextMenuRules.favoriteToggleLabel(subject(.content, [("/a/b.txt", .file)]), world()) == nil)
        #expect(
            ContextMenuRules.favoriteToggleLabel(
                subject(.content, [("/a/F", .directory), ("/a/G", .directory)]), world()) == nil)
        #expect(ContextMenuRules.favoriteToggleLabel(folder, world(search: true)) == nil)
        #expect(ContextMenuRules.favoriteToggleLabel(subject(.background, [], scope: .background), world()) == nil)
        // The Trash is always under Locations: a Trash favorite can be taken out, and none put in.
        let trash = subject(.favorite, [(Self.trash, .directory)])
        #expect(ContextMenuRules.favoriteToggleLabel(trash, world()) == nil)
        #expect(ContextMenuRules.favoriteToggleLabel(trash, world(favorites: [Self.trash])) == "Remove from Favorites")
        // A favorite row offers to remove it.
        let favorite = subject(.favorite, [("/a/Folder", .directory)])
        #expect(
            ContextMenuRules.favoriteToggleLabel(favorite, world(favorites: ["/a/Folder"])) == "Remove from Favorites")
        #expect(ContextMenuRules.favoriteToggleLabel(favorite, world()) == "Add to Favorites")
        // A search result never does.
        #expect(
            hidden(subject(.search, [("/a/Folder", .directory)]), world(search: true)).contains(.toggleFavorite))
    }

    // F-810
    @Test func severalItemsAreRenamedInTheSheet() {
        let many = subject(.content, (0..<1_204).map { ("/a/f\($0).txt", EntryKind.file) })
        #expect(ContextMenuRules.options(many, world(), textEditorName: nil).renameLabel == "Rename 1,204 Items…")
        let one = subject(.content, [("/a/f.txt", .file)])
        #expect(ContextMenuRules.options(one, world(), textEditorName: nil).renameLabel == nil)
        #expect(ContextMenuRules.options(one, world(), textEditorName: nil).targetsFolder == false)
        #expect(
            ContextMenuRules.options(subject(.content, [("/a/F", .directory)]), world(), textEditorName: nil)
                .targetsFolder)
        #expect(
            ContextMenuRules.options(subject(.background, [], scope: .background), world(), textEditorName: nil)
                .targetsFolder == false)
    }

    // F-810
    // B-VIEW-206 T-0e303da8 T-2258c755 T-7c9dc00f T-eb3ba6a5
    @Test func theMenuOfAFileHasTheOriginalsGroupsAndNothingThatDoesNotApply() {
        let menu = labels(subject(.content, [("/a/b.txt", .file)]), world(), editor: "TextEdit")
        #expect(
            menu == [
                "Open", "Open With", "Quick Look", "Edit in TextEdit", "Show Info", "Cut", "Copy", "Copy Path",
                "Rename", "Duplicate", "Move to…", "Open in Terminal", "Show in Finder", "Move to Trash",
            ])
        let folder = labels(
            subject(.content, [("/a/F", .directory)]), world(favorites: ["/a/F"], pasteDestination: true))
        #expect(
            folder == [
                "Open", "Open in New Tab", "Open in New Window", "Open With", "Quick Look", "Show Info",
                "Calculate Size", "Cut", "Copy", "Paste into Folder", "Copy Path", "Rename", "Duplicate", "Move to…",
                "New Folder", "Remove from Favorites", "Open in Terminal", "Show in Finder", "Move to Trash",
            ])
    }

    // F-811
    // B-VIEW-207 T-0e303da8 T-22f37d32 T-8c986b11
    @Test func searchResultsStartWithRevealInFolderAndLeaveOutNewFolderAndFavorites() {
        let result = subject(.search, [("/a/b.txt", .file)])
        let menu = labels(result, world(search: true), editor: "TextEdit")
        #expect(menu.first == "Reveal in Folder")
        #expect(!menu.contains("New Folder") && !menu.contains("Add to Favorites"))
        #expect(menu.contains("Duplicate"))
        // Results from several folders have no one folder for a duplicate.
        let scattered = ContextMenuSubject(
            surface: .search, paths: ["/a/b.txt", "/c/d.txt"], targetPath: "/a/b.txt",
            entries: [CommandEntry(path: "/a/b.txt", kind: .file), CommandEntry(path: "/c/d.txt", kind: .file)])
        #expect(hidden(scattered, world(search: true)).contains(.duplicate))
        #expect(ContextMenuRules.duplicateFolder(of: ["/a/b.txt", "/a/c.txt"]) == "/a")
        #expect(ContextMenuRules.duplicateFolder(of: ["/a/b.txt", "/c/d.txt"]) == nil)
        #expect(ContextMenuRules.duplicateFolder(of: ["/b.txt"]) == "/")
    }

    // F-812
    // B-TREE-145 B-VIEW-212 T-24d6dadf
    @Test func aTreeFolderStartsWithNewFolderAndOffersDeleteImmediatelyOnlyInTheTrash() {
        let folder = subject(.treeFolder, [("/a/Folder", .directory)])
        let menu = labels(folder, world(pasteDestination: true))
        #expect(menu.first == "New Folder")
        #expect(menu.contains("Use as Tree Root") && menu.contains("Move to Trash"))
        #expect(!menu.contains("Delete Immediately…"))
        // In the Trash: deleted for good, not trashed, pasted into or made.
        let inTrash = subject(.treeFolder, [(Self.trash + "/old", .directory)])
        let result = hidden(inTrash, world())
        for action in [ContextMenuActionID.paste, .newFolder, .duplicate, .trash] { #expect(result.contains(action)) }
        #expect(!result.contains(.deleteImmediately))
        // The Trash itself is only emptied, and stays where it is.
        let theTrash = hidden(subject(.treeFolder, [(Self.trash, .directory)]), world())
        for action in [ContextMenuActionID.deleteImmediately, .cut, .move, .rename] {
            #expect(theTrash.contains(action))
        }
    }

    // F-813
    // B-TREE-143 B-TREE-145 T-0218aaf1 T-27c2e760 T-33ba7245 T-3a0c2a65 T-506b38da T-ab30df4e T-c6fb632a
    // T-e5169248
    @Test func aFavoriteOrLocationOffersEmptyTrashOnlyForTheTrash() {
        let place = subject(.favorite, [("/a/Folder", .directory)])
        let result = hidden(place, world())
        #expect(result.contains(.emptyTrash))
        #expect(!result.contains(.newFolder) && !result.contains(.paste))
        let trash = subject(.favorite, [(Self.trash, .directory)])
        let trashResult = hidden(trash, world(trashEmpty: false))
        #expect(!trashResult.contains(.emptyTrash))
        #expect(trashResult.contains(.paste) && trashResult.contains(.newFolder))
        // Nothing in the Trash to empty.
        #expect(hidden(trash, world(trashEmpty: true)).contains(.emptyTrash))
        #expect(!hidden(trash, world(trashEmpty: nil)).contains(.emptyTrash))
    }

    // F-813
    // B-TREE-149 T-7b4fe196
    @Test func ejectNamesTheDiskAndIsLeftOutForAnythingElse() {
        let plain = subject(.favorite, [("/a/Folder", .directory)])
        #expect(hidden(plain, world()).contains(.eject))
        #expect(!labels(plain, world()).contains { $0.hasPrefix("Eject") })
        var disk = subject(.favorite, [("/Volumes/Backup", .directory)])
        disk.ejectableDiskName = "Backup"
        #expect(!hidden(disk, world()).contains(.eject))
        let menu = labels(disk, world())
        #expect(menu.first == "New Folder")
        // After the ways to open it.
        let eject = menu.firstIndex(of: "Eject “Backup”")
        #expect(eject != nil && eject == menu.firstIndex(of: "Reveal in Tree").map { $0 + 2 })
    }

    // F-814
    // B-VIEW-208 B-VIEW-212
    @Test func theBackgroundMenuHasNewFolderViewAsSortByAndEmptyTrashOnlyInTheTrash() {
        let background = subject(.background, [], scope: .background)
        let menu = labels(background, world(pasteDestination: true))
        #expect(
            menu == [
                "New Folder", "Show Info", "Calculate Size", "Paste", "Copy Path", "View As", "Sort By",
                "Open in Terminal", "Show in Finder",
            ])
        let inTrash = hidden(background, world(current: Self.trash + "/old"))
        #expect(inTrash.contains(.paste) && inTrash.contains(.newFolder) && !inTrash.contains(.emptyTrash))
    }

    // F-815
    // B-VIEW-210 T-768f7db4 T-cb6f036c
    @Test func separatorsThatWouldStandFirstLastOrTwiceInARowAreDropped() {
        let items = ContextMenuItems.visibleItems(
            surface: .favorite, hidden: [.newFolder, .eject, .emptyTrash, .toggleFavorite, .paste, .copyPath])
        for (index, item) in items.enumerated() {
            if case .separator = item {
                #expect(index > 0 && index < items.count - 1)
                if case .separator = items[index + 1] { Issue.record("two separators in a row") }
            }
        }
        if case .separator = items.first { Issue.record("a separator first") }
        if case .separator = items.last { Issue.record("a separator last") }
        #expect(ContextMenuItems.visibleItems(surface: .background, hidden: Set(ContextMenuActionID.allCases)).isEmpty)
    }

    // F-815
    // B-TREE-145 B-TREE-189 T-0218aaf1 T-0516f92a T-1c693346 T-22f37d32 T-848e568e
    @Test func pasteGoesIntoTheFolderTheMenuIsFor() {
        let folder = subject(.content, [("/a/Folder", .directory)])
        #expect(ContextMenuRules.pasteDestination(folder, world(), clipboardSourcePaths: []) == "/a/Folder")
        // An item pasted into itself, a file, and search results: nowhere.
        #expect(ContextMenuRules.pasteDestination(folder, world(), clipboardSourcePaths: ["/a/Folder"]) == nil)
        #expect(
            ContextMenuRules.pasteDestination(
                subject(.content, [("/a/b.txt", .file)]), world(), clipboardSourcePaths: []) == nil)
        #expect(ContextMenuRules.pasteDestination(folder, world(search: true), clipboardSourcePaths: []) == nil)
        // The background pastes into the folder on screen, the sidebar into its row, and nothing into the Trash.
        let background = subject(.background, [], scope: .background)
        #expect(
            ContextMenuRules.pasteDestination(background, world(), clipboardSourcePaths: []) == "/Users/me/Documents")
        #expect(
            ContextMenuRules.pasteDestination(background, world(current: Self.trash), clipboardSourcePaths: []) == nil)
        let tree = subject(.treeFolder, [("/a/Tree", .directory)])
        #expect(ContextMenuRules.pasteDestination(tree, world(), clipboardSourcePaths: ["/a/Tree"]) == "/a/Tree")
    }

    @Test func theShortcutsAreCountedWithGroupedDigits() {
        #expect(ContextMenuRules.groupedCount(1_204) == "1,204")
        #expect(ContextMenuRules.groupedCount(7) == "7")
    }
}
