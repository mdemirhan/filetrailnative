// When a tab reads its folder again for changes made outside the app, and how what waits is merged
import Testing

@testable import FTFoundation

struct FolderChangeGateTests {
    private typealias Gate = FolderChangeGate
    private static let folder = "/x"

    private func now(
        opening: Gate.Situation.Opening = .nothing, renaming: Bool = false, writeLocked: Bool = false,
        folder: String = folder
    ) -> Gate.Situation {
        Gate.Situation(folderPath: folder, opening: opening, renaming: renaming, writeLocked: writeLocked)
    }

    private func gate() -> Gate { Gate(maxChangedPaths: 1_000) }

    @Test func aChangeWithNothingHoldingItIsReadAtOnce() {
        var gate = gate()
        #expect(gate.changed("/x", ["/x/a"], now()) == .read(changedPaths: ["/x/a"]))
        #expect(gate.pending == nil)
        #expect(gate.drain == .reading)
    }

    @Test func aChangeThatSaysNothingOfItsItemsReadsEverything() {
        var gate = gate()
        #expect(gate.changed("/x", nil, now()) == .read(changedPaths: nil))
    }

    // Held, changes are gathered, then read once when let go.
    @Test func changesHeldAreGatheredAndReadOnceWhenLetGo() {
        var gate = gate()
        #expect(gate.hold(.dialog, true, now()) == .none)
        #expect(gate.changed("/x", ["/x/a"], now()) == .none)
        #expect(gate.changed("/x", ["/x/b"], now()) == .none)
        #expect(gate.pending?.changedPaths == ["/x/a", "/x/b"])
        #expect(gate.hold(.dialog, false, now()) == .read(changedPaths: ["/x/a", "/x/b"]))
        #expect(gate.readEnded(now()) == .none)
        #expect(gate.drain == .idle)
    }

    // Each holder lets go of its own hold only: a menu closing leaves a sheet's hold in place.
    @Test func aHolderLettingGoLeavesTheOthersHolding() {
        var gate = gate()
        _ = gate.hold(.dialog, true, now())
        _ = gate.hold(.menu, true, now())
        _ = gate.changed("/x", ["/x/a"], now())
        #expect(gate.hold(.menu, false, now()) == .none)
        #expect(gate.isHeld)
        #expect(gate.hold(.dialog, false, now()) == .read(changedPaths: ["/x/a"]))
    }

    // The result sheet lets what waited through under it, but not past another hold.
    @Test func aReadDespiteTheSheetStillWaitsForAMenu() {
        var gate = gate()
        _ = gate.hold(.dialog, true, now())
        _ = gate.changed("/x", ["/x/a"], now())
        #expect(gate.readDespite(.dialog, now()) == .read(changedPaths: ["/x/a"]))
        #expect(gate.holds == [.dialog])
        _ = gate.readEnded(now())
        _ = gate.hold(.menu, true, now())
        _ = gate.changed("/x", ["/x/b"], now())
        #expect(gate.readDespite(.dialog, now()) == .none)
    }

    // A name being typed and a file operation hold them too, as the tab says each time it asks.
    @Test func aRenameOrAWriteHoldsThemUntilTheTabSaysItEnded() {
        var gate = gate()
        #expect(gate.changed("/x", ["/x/a"], now(renaming: true)) == .none)
        #expect(gate.recheck(now(renaming: true, writeLocked: true)) == .none)
        #expect(gate.recheck(now(writeLocked: true)) == .none)
        #expect(gate.recheck(now()) == .read(changedPaths: ["/x/a"]))
    }

    // Changes arriving during a read are read once more after it.
    @Test func changesArrivingDuringAReadAreReadOnceMore() {
        var gate = gate()
        _ = gate.changed("/x", ["/x/a"], now())
        #expect(gate.changed("/x", ["/x/b"], now()) == .none)
        #expect(gate.changed("/x", ["/x/c"], now()) == .none)
        #expect(gate.readEnded(now()) == .read(changedPaths: ["/x/b", "/x/c"]))
    }

    // A change while the folder on screen is being opened is looked at again shortly, once.
    @Test func aChangeWhileTheFolderIsOpenedIsLookedAtAgainShortly() {
        var gate = gate()
        #expect(gate.changed("/x", ["/x/a"], now(opening: .thisFolder)) == .scheduleRetry)
        #expect(gate.changed("/x", ["/x/b"], now(opening: .thisFolder)) == .none)
        #expect(gate.retryElapsed(now(opening: .thisFolder)) == .scheduleRetry)
        #expect(gate.retryElapsed(now()) == .read(changedPaths: ["/x/a", "/x/b"]))
    }

    // Another folder being opened, or a change to one no longer on screen, drops what waited.
    @Test func whatWaitedForAFolderLeftIsDropped() {
        var gate = gate()
        #expect(gate.changed("/x", ["/x/a"], now(opening: .anotherFolder)) == .none)
        #expect(gate.pending == nil)
        #expect(gate.changed("/old", ["/old/a"], now()) == .none)
        #expect(gate.pending == nil)
        #expect(gate.drain == .idle)
    }

    // A tab that lets go of its folder has nothing waiting, and a read still under way ends without another.
    @Test func lettingGoOfTheFolderLeavesNothingWaiting() {
        var gate = gate()
        _ = gate.changed("/x", ["/x/a"], now())
        _ = gate.changed("/x", ["/x/b"], now())
        gate.letGo()
        #expect(gate.pending == nil)
        #expect(gate.readEnded(now()) == .none)
    }

    // A late end of a wait or a read that the gate no longer counts on changes nothing.
    @Test func aLateRetryOrReadEndWithNothingWaitingDoesNothing() {
        var gate = gate()
        #expect(gate.retryElapsed(now()) == .none)
        #expect(gate.readEnded(now()) == .none)
        _ = gate.changed("/x", ["/x/a"], now())
        #expect(gate.retryElapsed(now()) == .none)
        #expect(gate.drain == .reading)
    }
}

/// How the changes waiting to be read are merged.
struct FolderChangeGatePendingTests {
    private typealias Pending = FolderChangeGate.Pending

    // One change that doesn't say what changed makes the read a full one, whatever came before or after.
    @Test func aChangeToAnythingAmongThoseHeldBackReadsEverything() {
        let some = Pending.merging(nil, path: "/x", ["/x/a"], limit: 1_000)
        #expect(some.changedPaths == ["/x/a"])
        let all = Pending.merging(some, path: "/x", nil, limit: 1_000)
        #expect(all.changedPaths == nil)
        #expect(Pending.merging(all, path: "/x", ["/x/b"], limit: 1_000).changedPaths == nil)
    }

    // Past the most it lists, the read is a full one.
    @Test func tooManyChangedItemsReadEverything() {
        let many = Pending.merging(nil, path: "/x", (0..<600).map { "/x/a\($0)" }, limit: 1_000)
        #expect(many.changedPaths?.count == 600)
        #expect(Pending.merging(many, path: "/x", (0..<600).map { "/x/b\($0)" }, limit: 1_000).changedPaths == nil)
    }

    // What was held back of the folder left doesn't add to a change of the folder come to.
    @Test func aChangeOfTheNewFolderTakesThePlaceOfOneHeldBackOfTheOld() {
        let old = Pending.merging(nil, path: "/old", ["/old/a"], limit: 1_000)
        let new = Pending.merging(old, path: "/new", ["/new/b"], limit: 1_000)
        #expect(new.path == "/new")
        #expect(new.changedPaths == ["/new/b"])
    }
}
