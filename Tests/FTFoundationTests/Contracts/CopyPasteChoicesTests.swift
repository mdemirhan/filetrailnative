// Port of packages/contracts/src/copyPasteChoices.test.ts
import Testing

@testable import FTFoundation

struct CopyPasteChoicesTests {
    // T-ac4bf5f6 F-035
    @Test func offersMergeOnlyForTwoFolders() {
        #expect(CopyPasteChoices.isChoiceAllowed(for: .directoryConflict, .merge))
        #expect(!CopyPasteChoices.isChoiceAllowed(for: .fileConflict, .merge))
        #expect(!CopyPasteChoices.isChoiceAllowed(for: .typeMismatch, .merge))
        #expect(CopyPasteChoices.isChoiceAllowed(for: .fileConflict, .overwrite))
    }

    // T-de383202 F-035
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

    // T-036007a2 F-035
    @Test func offersOnlyGoingAheadOrSkippingWhenNothingIsAtTheDestinationAnyMore() {
        #expect(
            CopyPasteChoices.runtimeConflictChoices(
                reason: .destinationDeleted, conflictClass: .directoryConflict, destinationExists: false)
                == [.overwrite, .skip])
        #expect(
            CopyPasteChoices.runtimeConflictChoices(reason: .trashUnavailable, conflictClass: .fileConflict)
                == [.overwrite, .skip])
    }

    // T-d6e0523d F-036
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

    // T-5550b8c2 F-036
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
