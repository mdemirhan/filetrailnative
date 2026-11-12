import AppKit
import FTFileSystem
import FTFoundation
import ObjectiveC
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    /// What keeps the Icons view and the Compact List cheap to scroll, and their names whole.
    @MainActor
    @Suite struct GridScrollingTests {
        // A scroll view that overrides the wheel scrolls only as fast as the main thread draws; the Icons view leaves the
        // wheel to AppKit, which scrolls on its own thread. The Compact List turns the wheel sideways, so it can't.
        @Test func theIconsViewKeepsResponsiveScrolling() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, probe) = try await harness.openGrid(.viewAsIcons, files: 40)
            let icons = try #require(probe.pane?.scroll)
            #expect(type(of: icons).isCompatibleWithResponsiveScrolling)
            #expect(!icons.wheelScrollsSideways)
            tab.perform(.viewAsList)
            #expect(await waitUntil { probe.compact != nil })
            #expect(probe.compact?.scroll is SidewaysScrollView)
            await harness.close()
        }

        // AppKit visits every view that draws itself, hidden or not, on each frame of a scroll: in the items only the
        // names do, with the badge and the clipboard glyph while they show. The rest draw through their layers.
        @Test func itemsDrawOnlyTheirNamesThemselves() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, probe) = try await harness.openGrid(.viewAsIcons, files: 6)
            let first = tab.content.entries[0]
            let second = tab.content.entries[1]
            defer { try? FinderTags.write([], to: first.path) }
            let tags = [FinderTag(name: "Red", color: .red), FinderTag(name: "Blue", color: .blue)]
            try FinderTags.write(tags, to: first.path)
            tab.content.tagsChanged([first.path])
            tab.content.clipboardMarksChanged(
                ClipboardMarks(ClipboardRules.set(.cut, [second.path], capturedAt: "t"), enabled: true), flash: false)
            tab.content.selectionChanged(ContentSelection.of([first.path]))
            #expect(await waitUntil { probe.iconItems[first.name]?.label.tagDots.isHidden == false })
            for item in probe.iconItems.values { Self.expectDrawsOnlyWhatShows(item.view) }
            #expect(probe.iconItems[second.name]?.badge.superview != nil)
            #expect(probe.iconItems[first.name]?.badge.superview == nil)

            tab.perform(.viewAsList)
            #expect(await waitUntil { probe.compactItems[first.name]?.tagDots.isHidden == false })
            probe.layout()
            for item in probe.compactItems.values { Self.expectDrawsOnlyWhatShows(item.view) }
            #expect(probe.compactItems[second.name]?.markGlyph.isHidden == false)
            await harness.close()
        }

        // A name is drawn as its stem and its extension, each rounded up to whole points, which can come to a point more
        // than the name measured whole: the Compact List's items take that room, so no name is cut short.
        @Test func compactListNamesGetTheRoomTheyDrawIn() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, probe) = try await harness.openGrid(.viewAsList, files: 30)
            let tagged = tab.content.entries[3]
            defer { try? FinderTags.write([], to: tagged.path) }
            try FinderTags.write([FinderTag(name: "Gray", color: .gray)], to: tagged.path)
            tab.content.tagsChanged([tagged.path])
            #expect(await waitUntil { probe.compactItems[tagged.name]?.tagDots.isHidden == false })
            probe.layout()
            let items = probe.compactItems.values
            #expect(!items.isEmpty)
            for item in items {
                #expect(item.label.frame.width + 0.01 >= item.label.textWidth, "\(item.label.stringValue)")
            }
            await harness.close()
        }

        @Test func aSplitNameIsAsWideAsItsPartsInWholePoints() {
            let font = NSFont.systemFont(ofSize: 13)
            for number in 1...99 {
                for ext in ["txt", "kt", "toml"] {
                    let name = "File\(number).\(ext)"
                    let width = SplitName.width(name, extension: ext, marks: [], font: font)
                    let stem = ceil(("File\(number)" as NSString).size(withAttributes: [.font: font]).width)
                    let suffix = ceil(("." + ext as NSString).size(withAttributes: [.font: font]).width)
                    #expect(width == stem + suffix)
                    #expect(width + 0.01 >= (name as NSString).size(withAttributes: [.font: font]).width)
                }
            }
        }

        /// Under `view`, the app's own views that draw themselves are names, badges and glyphs, and none is hidden.
        private static func expectDrawsOnlyWhatShows(_ view: NSView) {
            let draw = #selector(NSView.draw(_:))
            let drawsItself =
                class_getMethodImplementation(type(of: view), draw) != class_getMethodImplementation(NSView.self, draw)
            if NSStringFromClass(type(of: view)).hasPrefix("FTAppKit."), drawsItself, !view.wantsUpdateLayer {
                let allowed: [AnyClass] = [
                    IconNameLabel.self, CompactNameLabel.self, ClipboardBadgeView.self, SymbolIconView.self,
                ]
                #expect(allowed.contains { type(of: view) == $0 }, "\(type(of: view))")
                #expect(!view.isHiddenOrHasHiddenAncestor, "\(type(of: view))")
            }
            for child in view.subviews { expectDrawsOnlyWhatShows(child) }
        }
    }
}
