// The question a paste stops on part way: what it says for each reason and verb, and which answer is the default
import Testing

@testable import FTFoundation

struct RuntimeConflictTextTests {
    private static let folder = ReviewFingerprint(exists: true, kind: .directory)
    private static let file = ReviewFingerprint(exists: true, kind: .file)
    private static let gone = ReviewFingerprint(exists: false, kind: .file)

    private func text(
        _ reason: RuntimeConflictReason, _ conflictClass: ConflictClass = .fileConflict, verb: CopyLikeVerb = .paste,
        destination: ReviewFingerprint = file
    ) -> RuntimeConflictText {
        RuntimeConflictText(
            RuntimeConflictInput(
                reason: reason, conflictClass: conflictClass, sourcePath: "/src/new.txt",
                destinationPath: "/Users/demo/Folder/report.txt", currentSourceFingerprint: Self.file,
                currentDestinationFingerprint: destination),
            verb: verb, now: 0)
    }

    @Test(arguments: [
        (
            RuntimeConflictReason.destinationChanged,
            "\u{201C}report.txt\u{201D} in \u{201C}Folder\u{201D} changed while pasting"
        ),
        (.destinationDeleted, "\u{201C}report.txt\u{201D} is no longer in \u{201C}Folder\u{201D}"),
        (.sourceChanged, "\u{201C}new.txt\u{201D} changed while pasting"),
        (.sourceDeleted, "\u{201C}new.txt\u{201D} is no longer available"),
    ])
    func saysWhatChangedInItsTitle(reason: RuntimeConflictReason, title: String) {
        #expect(text(reason).title == title)
    }

    // The verb runs through the title, the Stop button, the checkbox and the card of the item on its way.
    @Test func speaksOfAMoveAsAMove() {
        let move = text(.destinationCreated, verb: .move)
        #expect(move.title == "\u{201C}report.txt\u{201D} appeared in \u{201C}Folder\u{201D} while moving")
        #expect(move.stopLabel == "Stop Moving")
        #expect(move.checkboxLabel == "Do the same for similar changes while moving")
        #expect(move.cards.map(\.label) == ["In \u{201C}Folder\u{201D} now", "Being moved"])
    }

    // The safe answer is the default: Merge for a folder, Keep Both for a file, Skip for an item gone or a delete
    // for good; with nothing in the way, going ahead, which deletes nothing.
    @Test func makesTheSafeAnswerTheDefault() {
        let folder = text(.destinationChanged, .directoryConflict, destination: Self.folder)
        #expect(folder.primary.title == "Merge")
        #expect(folder.secondary.map(\.title) == ["Replace", "Keep Both", "Skip"])
        #expect(folder.secondary.first?.destructive == true)
        #expect(folder.message.hasSuffix("Merging can\u{2019}t be undone."))

        let file = text(.destinationChanged)
        #expect(file.primary.title == "Keep Both")
        #expect(file.secondary.map(\.title) == ["Replace", "Skip"])
        #expect(!file.message.contains("Merging"))

        let deleted = text(.destinationDeleted, destination: Self.gone)
        #expect(deleted.primary.title == "Paste Anyway" && !deleted.primary.destructive)
        #expect(deleted.secondary.map(\.title) == ["Skip"])
        #expect(deleted.cards.first?.facts == "Not there anymore")

        let sourceGone = text(.sourceDeleted)
        #expect(sourceGone.primary.title == "Skip" && sourceGone.secondary.isEmpty)

        let noTrash = text(.trashUnavailable, .directoryConflict, destination: Self.folder)
        #expect(noTrash.primary.title == "Skip")
        #expect(noTrash.secondary.map(\.title) == ["Delete Permanently"])
        #expect(noTrash.secondary.first?.destructive == true)
        #expect(noTrash.message.contains("replacing the existing folder means deleting it permanently"))
    }
}
