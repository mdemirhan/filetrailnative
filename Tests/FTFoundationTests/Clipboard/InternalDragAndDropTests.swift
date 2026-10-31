// Port of apps/desktop/src/renderer/lib/internalDragAndDrop.test.ts
import Foundation
import Testing

@testable import FTFoundation

struct InternalDragAndDropTests {
    private func session(_ surface: DragSourceSurface, _ items: [(String, EntryKind)]) -> DragSession {
        DragSession(
            sourceSurface: surface, sourceItems: items.map { DragItem(path: $0.0, kind: $0.1) },
            leadPath: items.first?.0 ?? "", leadKind: items.first?.1 ?? .file)
    }

    private func validate(
        _ session: DragSession, surface: DropTargetSurface = .tree, target: String, blocked: Bool = false,
        selected: Bool = false, operation: DropOperation = .move
    ) -> DropRefusal? {
        DragRules.validate(
            session: session, blocked: blocked, targetSurface: surface, targetPath: target, targetSupportsMove: true,
            targetIsSelected: selected, operation: operation)
    }

    // T-d8c5f3b8
    // T-5b6c37ca
    @Test func buildsADragSessionFromTheCurrentSelectionWhenTheDraggedRowIsSelected() throws {
        let kinds: [String: EntryKind] = ["/Users/demo/source.txt": .file, "/Users/demo/Folder": .directory]
        let made = try #require(
            DragRules.session(
                sourceSurface: .content, draggedPath: "/Users/demo/source.txt",
                selectedPathsInViewOrder: ["/Users/demo/source.txt", "/Users/demo/Folder"], kindOf: { kinds[$0] }))
        #expect(made.sourceSurface == .content)
        #expect(
            made.sourceItems == [
                DragItem(path: "/Users/demo/source.txt", kind: .file),
                DragItem(path: "/Users/demo/Folder", kind: .directory),
            ])
        #expect(made.leadPath == "/Users/demo/source.txt")
        #expect(made.leadKind == .file)
        // A row outside the selection goes alone; an unknown one starts nothing.
        let alone = DragRules.session(
            sourceSurface: .content, draggedPath: "/Users/demo/Folder", selectedPathsInViewOrder: ["/x"],
            kindOf: { kinds[$0] })
        #expect(alone?.sourceItems.map(\.path) == ["/Users/demo/Folder"])
        #expect(
            DragRules.session(
                sourceSurface: .content, draggedPath: "/nope", selectedPathsInViewOrder: [], kindOf: { kinds[$0] })
                == nil)
    }

    // T-b5e5da50
    @Test func recognizesRealDirectoryEntriesOnly() {
        #expect(DragRules.isRealDirectory(kind: .directory, isSymlink: false))
        #expect(!DragRules.isRealDirectory(kind: .symlinkDirectory, isSymlink: true))
        #expect(!DragRules.isRealDirectory(kind: .file, isSymlink: false))
    }

    // T-6cd914d0
    // B-SRCH-145 T-cfb4b577
    @Test func rejectsDroppingSearchResultsOntoContentRows() {
        #expect(
            validate(
                session(.search, [("/Users/demo/source.txt", .file)]), surface: .content, target: "/Users/demo/Folder")
                == .unsupportedTarget)
    }

    // T-0b10c4fa
    @Test func rejectsDropsOntoTheSelectedTargetRow() {
        #expect(
            validate(
                session(.content, [("/Users/demo/source.txt", .file)]), surface: .content, target: "/Users/demo/Folder",
                selected: true) == .targetSelected)
    }

    // T-88743754
    // T-11ca1eea T-8ca6669c
    @Test func rejectsDropsOntoTheSamePath() {
        #expect(
            validate(session(.content, [("/Users/demo/Folder", .directory)]), target: "/Users/demo/Folder") == .samePath
        )
    }

    // T-0c5373e1
    // T-11ca1eea
    @Test func rejectsNoOpDropsIntoTheSameParentDirectory() {
        #expect(
            validate(session(.content, [("/Users/demo/source.txt", .file)]), target: "/Users/demo") == .alreadyInTarget)
    }

    // T-413f32ce
    @Test func rejectsDroppingAFolderIntoItsOwnDescendant() {
        #expect(
            validate(session(.content, [("/Users/demo/Folder", .directory)]), target: "/Users/demo/Folder/Subfolder")
                == .parentIntoChild)
    }

    // T-84ce137b
    @Test func rejectsBlockedDragsBeforeCheckingTheTarget() {
        #expect(
            validate(
                session(.content, [("/Users/demo/source.txt", .file)]), target: "/Users/demo/Folder", blocked: true)
                == .blocked)
        #expect(
            DragRules.validate(
                session: nil, blocked: false, targetSurface: .tree, targetPath: "/x", targetSupportsMove: true)
                == .empty)
        #expect(
            DragRules.validate(
                session: session(.content, [("/a", .file)]), blocked: false, targetSurface: .tree, targetPath: nil,
                targetSupportsMove: true) == .targetMissing)
        #expect(
            DragRules.validate(
                session: session(.content, [("/a", .file)]), blocked: false, targetSurface: .tree, targetPath: "/b",
                targetSupportsMove: false) == .invalidTarget)
    }

    // MARK: What a drop does, as Finder decides it

    private func resolve(_ sources: [String], _ target: String, option: Bool = false, command: Bool = false)
        -> DropOperation
    {
        DragRules.operation(sourcePaths: sources, targetPath: target, option: option, command: command)
    }

    // T-fef00b31
    // T-740a332a
    @Test func movesToAFolderOnTheSameVolumeAndCopiesToAnotherVolume() {
        #expect(resolve(["/Users/demo/a.txt"], "/Users/demo/Folder") == .move)
        #expect(resolve(["/Volumes/Backup/a.txt"], "/Volumes/Backup/Old") == .move)
        #expect(resolve(["/Users/demo/a.txt"], "/Volumes/Backup") == .copy)
        #expect(resolve(["/Volumes/Backup/a.txt"], "/Users/demo") == .copy)
        #expect(resolve(["/Volumes/Backup/a.txt"], "/Volumes/Other") == .copy)
    }

    // T-4b42a287
    // T-3932f86d T-d16e383b
    @Test func copiesWithOptionAndMovesWithCommandWhateverTheVolumes() {
        #expect(resolve(["/Users/demo/a.txt"], "/Users/demo/Folder", option: true) == .copy)
        #expect(resolve(["/Users/demo/a.txt"], "/Volumes/Backup", option: true) == .copy)
        #expect(resolve(["/Users/demo/a.txt"], "/Volumes/Backup", command: true) == .move)
        #expect(resolve(["/Users/demo/a.txt"], "/Users/demo/Folder", command: true) == .move)
        // Option-Command makes an alias in Finder; here it copies.
        #expect(resolve(["/Users/demo/a.txt"], "/Users/demo/Folder", option: true, command: true) == .copy)
    }

    // T-e053e423
    @Test func copiesItemsFromSeveralVolumesUnlessAllAreOnTheTargets() {
        #expect(resolve(["/Users/demo/a.txt", "/Volumes/Backup/b.txt"], "/Users/demo/Folder") == .copy)
        #expect(resolve(["/Users/demo/a.txt", "/Users/other/b.txt"], "/Users/demo/Folder") == .move)
        let facts = session(.content, [("/Users/demo/a.txt", .file), ("/Volumes/Backup/b.txt", .file)]).facts
        #expect(DragRules.operation(facts, targetPath: "/Users/demo/Folder", option: false, command: false) == .copy)
    }

    // T-4fdd9b61
    // T-be87a191
    @Test func letsACopyGoIntoTheFolderTheItemsAreInToDuplicateThem() {
        let dragged = session(.content, [("/Users/demo/source.txt", .file)])
        #expect(validate(dragged, target: "/Users/demo", operation: .move) == .alreadyInTarget)
        #expect(validate(dragged, target: "/Users/demo", operation: .copy) == nil)
    }

    // T-dc9c71fe
    @Test func stillRefusesToCopyAFolderOntoItselfOrIntoItsOwnDescendant() {
        let dragged = session(.content, [("/Users/demo/Folder", .directory)])
        #expect(validate(dragged, target: "/Users/demo/Folder", operation: .copy) == .samePath)
        #expect(validate(dragged, target: "/Users/demo/Folder/Inner", operation: .copy) == .parentIntoChild)
    }

    // T-5763c21a
    @Test func refusesAnAppOrPackageDroppedIntoAFolderInsideIt() {
        let dragged = session(.external, [("/Applications/Tool.app", .bundle)])
        #expect(
            validate(dragged, surface: .content, target: "/Applications/Tool.app/Contents", operation: .copy)
                == .parentIntoChild)
    }

    // MARK: Which disk decides a drag

    // T-0055adca
    @Test func namesTheFoldersThatHoldTheDraggedItemsOnceEach() {
        let files = ["/Users/demo/a.txt", "/Users/demo/b.txt", "/Volumes/X/c.txt", "/top"]
        #expect(
            DragRules.sourceFolderPaths(files.map { DragItem(path: $0, kind: .file) })
                == ["/Users/demo", "/Volumes/X", "/"])
    }

    // T-dcaa9249
    // T-710ae2af
    @Test func namesDraggedFoldersTooButNotLinksToFolders() {
        #expect(
            DragRules.sourceFolderPaths([
                DragItem(path: "/Volumes/USB", kind: .directory),
                DragItem(path: "/Users/demo/Link", kind: .symlinkDirectory),
            ]) == ["/Volumes", "/Volumes/USB", "/Users/demo"])
    }

    // T-50be89fb
    // T-710ae2af T-82fad2f3
    @Test func knowsTheItemsShareTheTargetsDiskOnlyOnceEveryDiskHasAnswered() {
        var ids: [String: Int64?] = ["/Users/demo": 1, "/Volumes/X": 2, "/net/share": 7]
        ids["/Unreadable"] = .some(nil)
        #expect(
            DragRules.onSameDisk(sourceFolderPaths: ["/Users/demo"], targetPath: "/Users/demo/Folder", diskIds: ids)
                == nil)
        ids["/Users/demo/Folder"] = 1
        #expect(
            DragRules.onSameDisk(sourceFolderPaths: ["/Users/demo"], targetPath: "/Users/demo/Folder", diskIds: ids)
                == true)
        #expect(
            DragRules.onSameDisk(
                sourceFolderPaths: ["/Users/demo", "/Volumes/X"], targetPath: "/Users/demo/Folder", diskIds: ids)
                == false)
        #expect(
            DragRules.onSameDisk(sourceFolderPaths: ["/Users/demo"], targetPath: "/net/share", diskIds: ids) == false)
        #expect(
            DragRules.onSameDisk(sourceFolderPaths: ["/Unreadable"], targetPath: "/Users/demo/Folder", diskIds: ids)
                == nil)
    }

    // T-b5628474
    // T-3932f86d T-710ae2af T-740a332a T-82fad2f3 T-86d54fc1
    @Test func goesByTheDisksOnceTheyHaveAnsweredAndByThePathsUntilThen() {
        func drop(_ target: String, _ same: Bool? = nil) -> DropOperation {
            DragRules.operation(
                sourcePaths: ["/Users/demo/a.txt"], targetPath: target, option: false, command: false, onSameDisk: same)
        }
        #expect(drop("/net/share") == .move)
        #expect(drop("/net/share", false) == .copy)
        #expect(drop("/Volumes/Macintosh HD/Users/demo") == .copy)
        #expect(drop("/Volumes/Macintosh HD/Users/demo", true) == .move)
        #expect(
            DragRules.operation(
                sourcePaths: ["/Users/demo/a.txt"], targetPath: "/net/share", option: false, command: true,
                onSameDisk: false) == .move)
    }

    // MARK: A drag of many items

    // T-d29d26f6
    @Test func readsItsItemsOnceHoweverManyTimesATargetIsChecked() {
        let dragged = session(.content, (0..<1000).map { ("/Users/demo/f\($0).txt", .file) })
        let facts = dragged.facts
        for index in 0..<50 {
            _ = validate(dragged, target: index % 2 == 0 ? "/Users/demo/Folder" : "/Volumes/Backup")
        }
        #expect(validate(dragged, target: "/Users/demo/Folder") == nil)
        #expect(DragRules.operation(facts, targetPath: "/Users/demo/Folder", option: false, command: false) == .move)
        #expect(validate(dragged, target: "/Volumes/Backup") == nil)
        #expect(DragRules.operation(facts, targetPath: "/Volumes/Backup", option: false, command: false) == .copy)
        #expect(validate(dragged, target: "/Users/demo") == .alreadyInTarget)
    }

    // T-1cbec273
    @Test func knowsItsPathsTheFoldersTheyAreInAndTheFoldersAmongThem() {
        let dragged = session(
            .content,
            [
                ("/Users/demo/a.txt", .file), ("/Users/demo/Folder", .directory), ("/Applications/Tool.app", .bundle),
                ("/top", .file),
            ])
        let facts = dragged.facts
        #expect(facts.sourcePaths == dragged.sourceItems.map(\.path))
        #expect(facts.folderPaths == ["/Users/demo", "/Users/demo/Folder", "/Applications", "/"])
        #expect(facts.parentCount == 3)
        #expect(facts.holdsParent("/Users/demo") && facts.holdsParent("/Applications") && facts.holdsParent("/"))
        #expect(facts.containerPaths == [ExactKey("/Users/demo/Folder"), ExactKey("/Applications/Tool.app")])
    }

    // T-4147b976
    @Test func refusesAFolderIntoItselfOrBelowItNotAFolderWhoseNameOnlyStartsTheSame() {
        let dragged = session(.content, [("/Users/demo/Folder", .directory)])
        #expect(validate(dragged, target: "/Users/demo/Folder/a/b/c", operation: .copy) == .parentIntoChild)
        #expect(validate(dragged, target: "/Users/demo/Folder 2", operation: .copy) == nil)
        #expect(validate(dragged, target: "/Users/demo/Folder2/a", operation: .copy) == nil)
        #expect(validate(dragged, target: "/Users", operation: .copy) == nil)
        #expect(validate(dragged, target: "/", operation: .copy) == nil)
    }

    @Test func givesACopyToAnAppThatOffersNoMove() {
        #expect(DragRules.allowedBySource(.move, offersMove: false) == .copy)
        #expect(DragRules.allowedBySource(.move, offersMove: true) == .move)
        #expect(DragRules.allowedBySource(.copy, offersMove: false) == .copy)
    }
}
