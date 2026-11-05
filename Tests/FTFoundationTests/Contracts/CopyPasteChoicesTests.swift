import Testing

@testable import FTFoundation

struct CopyPasteChoicesTests {
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

    @Test func choicesUseTheOriginalsWireNames() {
        #expect(CopyPasteChoice.keepBoth.rawValue == "keep_both")
        #expect(ConflictClass.typeMismatch.rawValue == "type_mismatch")
        #expect(RuntimeConflictReason.destinationDeleted.rawValue == "destination_deleted")
    }
}
