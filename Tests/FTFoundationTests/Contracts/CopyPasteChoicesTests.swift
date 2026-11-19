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
        let older = ModifiedDates(sourceMs: 3000, destinationMs: 4000)
        #expect(
            CopyPasteChoices.replaceOlderSkip(
                conflictClass: .fileConflict, policy: policy, override: nil, dates: older, isPackage: false)
                == .notNewer)
        #expect(
            CopyPasteChoices.replaceOlderSkip(
                conflictClass: .fileConflict, policy: policy, override: .skip, dates: older, isPackage: false) == nil)
        // Plain Replace replaces whatever the dates.
        #expect(
            CopyPasteChoices.choiceForConflict(
                conflictClass: .fileConflict, replaceBlockedReason: nil,
                policy: CopyPastePolicy(file: .overwrite, directory: .overwrite, mismatch: .overwrite), override: nil,
                dates: ModifiedDates(sourceMs: 1, destinationMs: 9)) == .overwrite)
    }

    // A clash of kinds (a file where a folder of that name is) is left by Replace Older and told as its doing; a Skip
    // chosen on the row is the person's own, and the other answers for all conflicts give no reason of Replace
    // Older's: Skip and Add Missing skip the clash as they skip a file, Keep All and Replace don't skip it at all.
    @Test func aClashOfKindsLeftByReplaceOlderIsToldAsItsDoing() {
        func reason(_ policy: CopyPastePolicy, override: CopyPasteChoice? = nil) -> ReplaceOlderSkip? {
            CopyPasteChoices.replaceOlderSkip(
                conflictClass: .typeMismatch, policy: policy, override: override,
                dates: ModifiedDates(sourceMs: 9000, destinationMs: 4000), isPackage: false)
        }
        func choice(_ policy: CopyPastePolicy) -> CopyPasteChoice {
            CopyPasteChoices.choiceForConflict(
                conflictClass: .typeMismatch, replaceBlockedReason: nil, policy: policy, override: nil)
        }
        let replaceOlder = CopyPasteReview.policy(for: .replaceOlder, toleranceMs: 1000)
        #expect(choice(replaceOlder) == .skip)
        #expect(reason(replaceOlder) == .differentKind)
        #expect(reason(replaceOlder, override: .skip) == nil)
        #expect(reason(replaceOlder, override: .overwrite) == nil)
        #expect(reason(replaceOlder, override: .keepBoth) == nil)
        // Merge isn't a choice for a clash of kinds, so it isn't the row's own.
        #expect(reason(replaceOlder, override: .merge) == .differentKind)
        for (answer, expected) in [
            (AllConflictsChoice.skip, CopyPasteChoice.skip), (.addMissing, .skip), (.keepAll, .keepBoth),
            (.overwrite, .overwrite),
        ] {
            #expect(choice(CopyPasteReview.policy(for: answer)) == expected)
            #expect(reason(CopyPasteReview.policy(for: answer)) == nil)
        }
        // Two folders merge under Replace Older: nothing is left.
        #expect(
            CopyPasteChoices.replaceOlderSkip(
                conflictClass: .directoryConflict, policy: replaceOlder, override: nil, dates: nil, isPackage: false)
                == nil)
    }

    // A package's date is its outer folder's, which a change deeper inside leaves as it was: Replace Older leaves a
    // package whatever the dates say, and says it didn't compare; the item's own choice still wins.
    @Test func leavesAPackageWithReplaceOlderWhateverItsDates() {
        let policy = CopyPastePolicy(
            file: .overwrite, directory: .merge, mismatch: .skip, replaceOlderToleranceMs: 1000)
        func choice(_ source: Double?, _ destination: Double?, override: CopyPasteChoice? = nil) -> CopyPasteChoice {
            CopyPasteChoices.choiceForConflict(
                conflictClass: .fileConflict, replaceBlockedReason: nil, policy: policy, override: override,
                dates: ModifiedDates(sourceMs: source, destinationMs: destination), isPackage: true)
        }
        func reason(_ source: Double?, _ destination: Double?, override: CopyPasteChoice? = nil) -> ReplaceOlderSkip? {
            CopyPasteChoices.replaceOlderSkip(
                conflictClass: .fileConflict, policy: policy, override: override,
                dates: ModifiedDates(sourceMs: source, destinationMs: destination), isPackage: true)
        }
        #expect(choice(4000, 4000) == .skip)
        #expect(reason(4000, 4000) == .packageNotCompared)
        // Newer by its outer date: still left, not replaced whole.
        #expect(choice(9000, 4000) == .skip)
        #expect(reason(9000, 4000) == .packageNotCompared)
        #expect(choice(3000, 4000) == .skip)
        #expect(reason(3000, 4000) == .packageNotCompared)
        #expect(choice(4000, 4000, override: .overwrite) == .overwrite)
        #expect(reason(4000, 4000, override: .overwrite) == nil)
        #expect(choice(9000, 4000, override: .keepBoth) == .keepBoth)
        // Plain Replace, and any other answer for all conflicts, treat a package as before.
        for plain in [
            CopyPastePolicy(file: .overwrite, directory: .overwrite, mismatch: .overwrite),
            CopyPastePolicy(file: .keepBoth, directory: .merge, mismatch: .keepBoth),
            CopyPastePolicy(file: .skip, directory: .skip, mismatch: .skip),
        ] {
            #expect(
                CopyPasteChoices.choiceForConflict(
                    conflictClass: .fileConflict, replaceBlockedReason: nil, policy: plain, override: nil,
                    dates: ModifiedDates(sourceMs: 1, destinationMs: 9), isPackage: true) == plain.file)
            #expect(
                CopyPasteChoices.replaceOlderSkip(
                    conflictClass: .fileConflict, policy: plain, override: nil,
                    dates: ModifiedDates(sourceMs: 1, destinationMs: 9), isPackage: true) == nil)
        }
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
