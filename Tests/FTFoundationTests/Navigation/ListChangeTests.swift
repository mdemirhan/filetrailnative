// Items added to and taken from a list whose others keep their order are put in and taken out in place
import FTFoundation
import Foundation
import Testing

struct ListChangeTests {
    private func keys(_ names: String...) -> [DiskPath] { names.map { DiskPath("/f/\($0)") } }

    @Test func itemsComingAndGoingAreFoundByTheirPlaces() {
        let change = ListChange.between(keys("a", "b", "c", "d"), keys("a", "c", "c2", "d", "e"))
        #expect(change?.removed == IndexSet([1]))
        #expect(change?.inserted == IndexSet([2, 4]))
    }

    // A view checks the list it holds against the change before it makes it.
    @Test func aChangeTakesOnlyTheListItWasFoundFor() throws {
        let before = keys("a", "b", "c", "d")
        let after = keys("a", "c", "c2", "d", "e")
        let change = try #require(ListChange.between(before, after))
        #expect(change.takes(before, to: after))
        #expect(!change.takes(keys("a", "b", "x", "d"), to: after))
        #expect(!change.takes(before, to: keys("a", "c", "d", "c2", "e")))
        #expect(!change.takes(Array(before.dropLast()), to: after))
    }

    // A new order, the same list, a key twice or too many changes are drawn again whole.
    @Test func whatIsNotAPlainChangeIsNone() {
        #expect(ListChange.between(keys("a", "b", "c"), keys("b", "a", "c")) == nil)
        #expect(ListChange.between(keys("a", "b"), keys("a", "b")) == nil)
        #expect(ListChange.between(keys("a", "a", "b"), keys("a", "b", "c")) == nil)
        #expect(ListChange.between(keys("a", "b", "c"), keys("b", "c", "a")) == nil)
        let many = (0...ListChange.largest).map { DiskPath("/f/\($0)") }
        #expect(ListChange.between([], many) == nil)
        #expect(ListChange.between([], Array(many.dropLast())) != nil)
    }

    // A name spelled with its accent the other way is another item.
    @Test func aNameSpelledAnotherWayIsAnotherItem() {
        let composed = DiskPath("/f/caf\u{e9}")
        let decomposed = DiskPath("/f/cafe\u{301}")
        let change = ListChange.between([composed], [decomposed])
        #expect(change?.removed == IndexSet([0]) && change?.inserted == IndexSet([0]))
    }
}
