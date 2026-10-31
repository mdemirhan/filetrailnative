// Port of apps/desktop/src/renderer/lib/contentSelection.test.ts, with the content-selection golden recorded from the
// reference (tools/parity/golden/content-selection.ts)
import FTTestSupport
import Testing

@testable import FTFoundation

struct ContentSelectionTests {
    private let entries = ["/demo/alpha", "/demo/beta", "/demo/gamma", "/demo/delta"]

    // T-7b475603 F-779 B-SEL-024
    // B-NAV-048
    @Test func sanitizesStalePathsAndRepairsAnchorAndLead() {
        let selection = ContentSelection(
            paths: ["/demo/alpha", "/demo/missing", "/demo/gamma"], anchorPath: "/demo/missing",
            leadPath: "/demo/missing")
        #expect(
            selection.sanitized(entryPaths: entries)
                == ContentSelection(
                    paths: ["/demo/alpha", "/demo/gamma"], anchorPath: "/demo/gamma", leadPath: "/demo/gamma"))
    }

    // T-c7532927 F-779 B-SEL-025 B-NAV-150 B-NAV-152
    @Test func keepsThePlaceOfASelectionWhoseItemsAllLeftTheList() {
        let remaining = entries.filter { $0 != "/demo/gamma" }
        let gone = ContentSelection.single("/demo/gamma").sanitized(entryPaths: remaining, previousPaths: entries)
        #expect(gone == ContentSelection(gapIndex: 2))
        // The folder read again keeps the place, within the list.
        #expect(
            gone.sanitized(entryPaths: Array(remaining.prefix(1)), previousPaths: remaining)
                == ContentSelection(gapIndex: 1))
        // Several items: the place is the lead's.
        let several = ContentSelection(
            paths: ["/demo/alpha", "/demo/gamma"], anchorPath: "/demo/alpha", leadPath: "/demo/gamma")
        #expect(
            several.sanitized(entryPaths: ["/demo/beta", "/demo/delta"], previousPaths: entries)
                == ContentSelection(gapIndex: 1))
        // Without the list it was made in there is no place to keep.
        #expect(ContentSelection.single("/demo/gamma").sanitized(entryPaths: remaining) == .empty)
    }

    // T-e9ce742e B-SEL-009 B-SEL-010
    @Test func computesRangePathsInEntryOrder() {
        #expect(
            ContentSelection.rangePaths(entryPaths: entries, anchor: "/demo/delta", target: "/demo/beta")
                == ["/demo/beta", "/demo/gamma", "/demo/delta"])
        // An anchor that is no longer in the list selects just the target.
        #expect(
            ContentSelection.rangePaths(entryPaths: entries, anchor: "/demo/gone", target: "/demo/beta") == [
                "/demo/beta"
            ])
    }

    // T-cea8961a B-SEL-011
    @Test func mergesSelectedPathsUsingVisibleEntryOrder() {
        #expect(
            ContentSelection.merged(
                entryPaths: entries, current: ["/demo/gamma"], next: ["/demo/alpha", "/demo/delta"])
                == ["/demo/alpha", "/demo/gamma", "/demo/delta"])
    }

    // T-99bafc41 F-780 B-SEL-007 B-SEL-008
    @Test func togglesItemsInAndOutOfAMultiSelection() {
        #expect(
            ContentSelection.empty.toggled(entryPaths: entries, path: "/demo/beta")
                == ContentSelection(paths: ["/demo/beta"], anchorPath: "/demo/beta", leadPath: "/demo/beta"))
        let two = ContentSelection(
            paths: ["/demo/alpha", "/demo/beta"], anchorPath: "/demo/alpha", leadPath: "/demo/beta")
        #expect(
            two.toggled(entryPaths: entries, path: "/demo/beta")
                == ContentSelection(paths: ["/demo/alpha"], anchorPath: "/demo/alpha", leadPath: "/demo/alpha"))
        // Taking out the anchor makes the new lead the anchor.
        #expect(
            two.toggled(entryPaths: entries, path: "/demo/alpha")
                == ContentSelection(paths: ["/demo/beta"], anchorPath: "/demo/beta", leadPath: "/demo/beta"))
        // Adding an item keeps the list order, and the item becomes anchor and lead.
        #expect(
            ContentSelection.single("/demo/delta").toggled(entryPaths: entries, path: "/demo/beta")
                == ContentSelection(
                    paths: ["/demo/beta", "/demo/delta"], anchorPath: "/demo/beta", leadPath: "/demo/beta"))
    }

    // T-a286801d F-780 B-SEL-009 B-SEL-011
    @Test func extendsSelectionsWithShiftAndCmdShiftSemantics() {
        let base = ContentSelection.single("/demo/beta")
        #expect(
            base.extended(entryPaths: entries, to: "/demo/delta")
                == ContentSelection(
                    paths: ["/demo/beta", "/demo/gamma", "/demo/delta"], anchorPath: "/demo/beta",
                    leadPath: "/demo/delta"))
        let alpha = ContentSelection.single("/demo/alpha")
        #expect(
            alpha.extended(entryPaths: entries, to: "/demo/gamma", additive: true)
                == ContentSelection(
                    paths: ["/demo/alpha", "/demo/beta", "/demo/gamma"], anchorPath: "/demo/alpha",
                    leadPath: "/demo/gamma"))
        // The gestures: ⌘⇧ adds a range, ⇧ makes one, ⌘ flips one item, a plain press selects one.
        #expect(
            alpha.afterGesture(entryPaths: entries, path: "/demo/gamma", meta: true, shift: true)
                == alpha.extended(entryPaths: entries, to: "/demo/gamma", additive: true))
        #expect(
            alpha.afterGesture(entryPaths: entries, path: "/demo/gamma", meta: false, shift: true)
                == alpha.extended(entryPaths: entries, to: "/demo/gamma"))
        #expect(
            alpha.afterGesture(entryPaths: entries, path: "/demo/gamma", meta: true, shift: false)
                == alpha.toggled(entryPaths: entries, path: "/demo/gamma"))
        #expect(
            alpha.afterGesture(entryPaths: entries, path: "/demo/gamma", meta: false, shift: false)
                == .single("/demo/gamma"))
    }

    // T-2ed18f31 B-SEL-021 B-SEL-022
    @Test func selectsAllEntriesAndReturnsEmptyWhenNoneExist() {
        #expect(
            ContentSelection.all(entryPaths: entries)
                == ContentSelection(paths: entries, anchorPath: "/demo/alpha", leadPath: "/demo/delta"))
        #expect(ContentSelection.all(entryPaths: []) == .empty)
    }

    // T-2cd89f09 F-781 B-SEL-003 B-SEL-004 B-SEL-005
    @Test func narrowsAMultiSelectionOnlyOnAPlainMouseClickOfASelectedItem() {
        func narrows(
            detail: Int = 1, meta: Bool = false, shift: Bool = false, control: Bool = false, count: Int = 3,
            selected: Bool = true
        ) -> Bool {
            ContentSelection.isNarrowingClick(
                button: 0, detail: detail, modifiers: .init(meta: meta, shift: shift, control: control),
                selectedCount: count, isSelected: selected)
        }
        #expect(narrows())
        #expect(!narrows(count: 1))
        #expect(!narrows(selected: false))
        #expect(!narrows(meta: true))
        #expect(!narrows(shift: true))
        #expect(!narrows(control: true))
        // Keyboard-generated clicks (Space or Return on a focused row) report detail 0.
        #expect(!narrows(detail: 0))
        // Pressing a selected item (with no ⌘ or ⇧) changes nothing; the click narrows.
        let several = ContentSelection(
            paths: ["/demo/alpha", "/demo/beta"], anchorPath: "/demo/alpha", leadPath: "/demo/beta")
        #expect(
            several.afterPress(entryPaths: entries, path: "/demo/alpha", selected: true, modifiers: .none) == nil)
        #expect(
            several.afterPress(entryPaths: entries, path: "/demo/gamma", selected: false, modifiers: .none)
                == .single("/demo/gamma"))
        #expect(
            several.afterPress(entryPaths: entries, path: "/demo/alpha", selected: true, modifiers: .init(meta: true))
                != nil)
    }

    // T-d6cea52c B-SEL-021: selecting tens of thousands of items at once does not stall.
    @Test func selectsTensOfThousandsOfItemsWithoutStalling() {
        let paths = (0..<60_000).map { "/demo/folder/item-\($0).txt" }
        // CPU time of this thread, not wall time, so a busy machine does not fail it.
        let (_, seconds) = CPUTime.measureThread {
            let all = ContentSelection.all(entryPaths: paths)
            let index = PathIndex(paths, path: { $0 })
            #expect(index.resolve(all.paths).count == 60_000)
            let kept = all.sanitized(entryPaths: Array(paths.dropFirst(10)), previousPaths: paths)
            #expect(kept.paths.count == 59_990)
            let extended = ContentSelection.single(paths[5]).extended(entryPaths: paths, to: paths[59_000])
            #expect(extended.paths.count == 58_996)
        }
        #expect(seconds < 2)
    }

    // F-779 B-SEL-150 B-SEL-151: the marquee's selection is put in list order, the lead its anchor.
    @Test func theMarqueeSelectionIsInListOrder() {
        #expect(
            ContentSelection.marquee(entryPaths: entries, picked: ["/demo/gamma", "/demo/alpha"], lead: "/demo/gamma")
                == ContentSelection(
                    paths: ["/demo/alpha", "/demo/gamma"], anchorPath: "/demo/gamma", leadPath: "/demo/gamma"))
        #expect(ContentSelection.marquee(entryPaths: entries, picked: [], lead: nil) == .empty)
    }
}
