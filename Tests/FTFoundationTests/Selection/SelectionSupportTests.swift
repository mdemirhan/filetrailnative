import Testing

@testable import FTFoundation

struct PagedScrollTests {
    @Test func scrollsSidewaysByTheAmount() {
        #expect(
            PagedScroll.nextOffset(viewportSize: 480, scrollSize: 1800, currentOffset: 240, delta: 310) == 550)
    }

    @Test func scrollsUpAndDownStoppingAtEitherEnd() {
        #expect(PagedScroll.nextOffset(viewportSize: 300, scrollSize: 850, currentOffset: 500, delta: 300) == 550)
        #expect(PagedScroll.nextOffset(viewportSize: 300, scrollSize: 850, currentOffset: 550, delta: -900) == 0)
    }

    @Test func returnsNilWhenTheViewCantScrollThatWayOrIsAlreadyAtTheEnd() {
        #expect(PagedScroll.nextOffset(viewportSize: 320, scrollSize: 320, currentOffset: 0, delta: 100) == nil)
        #expect(PagedScroll.nextOffset(viewportSize: 480, scrollSize: 960, currentOffset: 0, delta: -100) == nil)
        #expect(PagedScroll.nextOffset(viewportSize: 480, scrollSize: 960, currentOffset: 0, delta: 0) == nil)
        // A scroll of a point or less scrolls nothing.
        #expect(PagedScroll.nextOffset(viewportSize: 480, scrollSize: 960, currentOffset: 100, delta: 1) == nil)
    }
}
