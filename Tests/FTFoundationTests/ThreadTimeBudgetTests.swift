import Foundation
import Testing

@testable import FTFoundation

/// A pattern's time limit counts the work the thread does, so a busy Mac doesn't make a quick pattern look slow: the
/// Rename sheet once left every name as it was, saying the pattern took too long, when its thread merely waited.
struct ThreadTimeBudgetTests {
    @Test func waitingDoesNotSpendIt() {
        let budget = ThreadTimeBudget(.milliseconds(20))
        Thread.sleep(forTimeInterval: 0.1)
        #expect(!budget.isSpent)
    }

    @Test func workingSpendsIt() {
        let budget = ThreadTimeBudget(.milliseconds(20))
        let start = ThreadTimeBudget.now()
        var spins = 0
        while ThreadTimeBudget.now() - start < 30_000_000 { spins &+= 1 }
        #expect(spins > 0)
        #expect(budget.isSpent)
    }

    @Test func neverIsNeverSpent() {
        #expect(!ThreadTimeBudget(.never).isSpent)
    }
}
