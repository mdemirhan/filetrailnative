import Testing

@testable import FTFoundation

struct CopyPasteChoicesTests {
    // The coarsest disk decides; any disk whose dates can't be compared leaves Replace Older out.
    @Test func comparesDatesOnlyOnDisksThatKeepThemExactly() {
        #expect(CopyPasteChoices.newerToleranceMs(fileSystems: ["apfs", "apfs"]) == 1)
        #expect(CopyPasteChoices.newerToleranceMs(fileSystems: ["APFS", "hfs"]) == 1000)
        #expect(CopyPasteChoices.newerToleranceMs(fileSystems: ["exfat", "apfs"]) == 10)
        #expect(CopyPasteChoices.newerToleranceMs(fileSystems: ["apfs", "smbfs"]) == 2000)
        #expect(CopyPasteChoices.newerToleranceMs(fileSystems: ["apfs", "msdos"]) == nil)
        #expect(CopyPasteChoices.newerToleranceMs(fileSystems: ["nfs", "apfs"]) == nil)
        #expect(CopyPasteChoices.newerToleranceMs(fileSystems: ["apfs", nil]) == nil)
        #expect(CopyPasteChoices.newerToleranceMs(fileSystems: []) == nil)
    }

    // Replace Older replaces a file only when it is newer by more than the tolerance; an item's own choice wins, and
    // an item Replace can't take is kept both ways, as with Replace.
    @Test func replacesOnlyANewerFileWithReplaceOlder() {
        let policy = CopyPastePolicy(
            file: .overwrite, directory: .merge, mismatch: .skip, replaceOlderToleranceMs: 1000)
        func choice(
            _ source: Double?, _ destination: Double?, _ conflictClass: ConflictClass = .fileConflict,
            override: CopyPasteChoice? = nil, blocked: String? = nil
        ) -> CopyPasteChoice {
            CopyPasteChoices.choiceForConflict(
                conflictClass: conflictClass, replaceBlockedReason: blocked, policy: policy, override: override,
                dates: ModifiedDates(sourceMs: source, destinationMs: destination))
        }
        #expect(choice(5001, 4000) == .overwrite)
        #expect(choice(5000, 4000) == .skip)
        #expect(choice(3000, 4000) == .skip)
        #expect(choice(nil, 4000) == .skip)
        #expect(choice(5001, nil) == .skip)
        #expect(choice(3000, 4000, override: .overwrite) == .overwrite)
        #expect(choice(9000, 4000, override: .keepBoth) == .keepBoth)
        #expect(choice(9000, 4000, blocked: "It holds what is pasted") == .keepBoth)
        #expect(choice(1, 9, .directoryConflict) == .merge)
        #expect(choice(9, 1, .typeMismatch) == .skip)
        #expect(
            CopyPasteChoices.isSkippedAsNotNewer(
                conflictClass: .fileConflict, policy: policy, override: nil,
                dates: ModifiedDates(sourceMs: 3000, destinationMs: 4000)))
        #expect(
            !CopyPasteChoices.isSkippedAsNotNewer(
                conflictClass: .fileConflict, policy: policy, override: .skip,
                dates: ModifiedDates(sourceMs: 3000, destinationMs: 4000)))
        // Plain Replace replaces whatever the dates.
        #expect(
            CopyPasteChoices.choiceForConflict(
                conflictClass: .fileConflict, replaceBlockedReason: nil,
                policy: CopyPastePolicy(file: .overwrite, directory: .overwrite, mismatch: .overwrite), override: nil,
                dates: ModifiedDates(sourceMs: 1, destinationMs: 9)) == .overwrite)
    }

    @Test func offersMergeOnlyForTwoFolders() {
        #expect(CopyPasteChoices.isChoiceAllowed(for: .directoryConflict, .merge))
        #expect(!CopyPasteChoices.isChoiceAllowed(for: .fileConflict, .merge))
        #expect(!CopyPasteChoices.isChoiceAllowed(for: .typeMismatch, .merge))
        #expect(CopyPasteChoices.isChoiceAllowed(for: .fileConflict, .overwrite))
    }

    @Test func offersOnlySkipWhenTheSourceDisappeared() {
        #expect(
            CopyPasteChoices.runtimeConflictChoices(reason: .sourceDeleted, conflictClass: .directoryConflict)
                == [.skip])
        #expect(
            CopyPasteChoices.runtimeConflictChoices(reason: .destinationCreated, conflictClass: .directoryConflict)
                == [.overwrite, .merge, .keepBoth, .skip])
        #expect(
            CopyPasteChoices.runtimeConflictChoices(reason: .destinationChanged, conflictClass: .fileConflict)
                == [.overwrite, .keepBoth, .skip])
    }

    @Test func offersOnlyGoingAheadOrSkippingWhenNothingIsAtTheDestinationAnyMore() {
        #expect(
            CopyPasteChoices.runtimeConflictChoices(
                reason: .destinationDeleted, conflictClass: .directoryConflict, destinationExists: false)
                == [.overwrite, .skip])
        #expect(
            CopyPasteChoices.runtimeConflictChoices(reason: .trashUnavailable, conflictClass: .fileConflict)
                == [.overwrite, .skip])
    }

    @Test func scopesStandingAnswersToTheSameKindOfConflict() {
        let sourceChanged = CopyPasteChoices.runtimeConflictScope(
            reason: .sourceChanged, conflictClass: .fileConflict, destinationExists: false)
        let destinationCreated = CopyPasteChoices.runtimeConflictScope(
            reason: .destinationCreated, conflictClass: .fileConflict)
        let destinationChanged = CopyPasteChoices.runtimeConflictScope(
            reason: .destinationChanged, conflictClass: .fileConflict)
        #expect(sourceChanged == "source:missing")
        #expect(sourceChanged != destinationCreated)
        #expect(destinationCreated == destinationChanged)
        #expect(
            CopyPasteChoices.runtimeConflictScope(reason: .destinationCreated, conflictClass: .directoryConflict)
                != destinationCreated)
        #expect(
            CopyPasteChoices.runtimeConflictScope(reason: .trashUnavailable, conflictClass: .directoryConflict)
                == "trash_unavailable")
    }

    @Test func givesAnItemReplaceCantTakeTheSafeChoice() {
        let replaceAll = CopyPastePolicy(file: .overwrite, directory: .overwrite, mismatch: .overwrite)
        func blocked(_ conflictClass: ConflictClass, _ override: CopyPasteChoice? = nil) -> CopyPasteChoice {
            CopyPasteChoices.choiceForConflict(
                conflictClass: conflictClass, replaceBlockedReason: "It is another item being pasted.",
                policy: replaceAll, override: override)
        }
        #expect(blocked(.fileConflict) == .keepBoth)
        #expect(blocked(.typeMismatch) == .keepBoth)
        #expect(blocked(.directoryConflict) == .merge)
        #expect(blocked(.fileConflict, .overwrite) == .keepBoth)
        #expect(blocked(.fileConflict, .skip) == .skip)
        // Replace for an item it can take, and a choice that doesn't fit falls back to the policy.
        func free(_ override: CopyPasteChoice?) -> CopyPasteChoice {
            CopyPasteChoices.choiceForConflict(
                conflictClass: .fileConflict, replaceBlockedReason: nil, policy: replaceAll, override: override)
        }
        #expect(free(nil) == .overwrite)
        #expect(free(.merge) == .overwrite)
    }
}
