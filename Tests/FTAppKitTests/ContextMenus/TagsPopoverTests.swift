import AppKit
import FTFileSystem
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    @MainActor
    @Suite struct TagsPopoverTests {
        /// The harness's folder with three more files to tag, beside its note.
        func opened(_ harness: ExplorerHarness) async throws -> MainWindowController {
            for name in ["a.txt", "b.txt", "c.txt"] {
                try "x".write(to: harness.folder.appending(name), atomically: true, encoding: .utf8)
            }
            let tab = try await harness.open()
            #expect(await waitUntil { tab.content.entries.filter { !$0.kind.isDirectoryKind }.count >= 4 })
            return tab
        }

        func files(_ tab: MainWindowController) -> [String] {
            tab.content.entries.filter { !$0.kind.isDirectoryKind }.map(\.path)
        }

        /// Tags… for `paths`, once it has read their tags.
        func popover(_ tab: MainWindowController, _ paths: [String]) async throws -> TagsPopover {
            var made: TagsPopover?
            tab.shownTagsPopover = { made = $0 }
            tab.editTags(paths)
            #expect(await waitUntil { made != nil })
            return try #require(made)
        }

        func row(_ popover: TagsPopover, _ name: String) throws -> FinderTagChecklistRow {
            try #require(popover.allRows.first { $0.tag.name == name })
        }

        // A tag on one of two items is on some: chosen, it goes on the other in its color; chosen again, on both, it
        // comes off both. The other tags stay.
        @Test func aTagChosenGoesOnEveryItemAndComesOffWhenAllHaveIt() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await opened(harness)
            let paths = Array(files(tab).prefix(2))
            defer { for path in paths { try? FinderTags.write([], to: path) } }
            // The color's own tag goes by the name macOS gives it here.
            let red = FinderTagColor.red.systemName
            try FinderTags.write(
                [FinderTag(name: "Work", color: .blue), FinderTag(name: red, color: .red)], to: paths[0])
            let popover = try await popover(tab, paths)
            #expect(try row(popover, "Work").count == 1)
            #expect(try row(popover, "Work").isColor == false)
            #expect(try row(popover, red).count == 1)
            #expect(try row(popover, red).isColor)
            popover.choose(try row(popover, "Work"))
            // Shown at once, before it is written.
            #expect(try row(popover, "Work").count == 2)
            await popover.waitForWrites()
            #expect(try FinderTags.read(paths[1]) == [FinderTag(name: "Work", color: .blue)])
            #expect(try row(popover, "Work").count == 2)
            popover.choose(try row(popover, "Work"))
            await popover.waitForWrites()
            #expect(try FinderTags.read(paths[0]) == [FinderTag(name: red, color: .red)])
            #expect(try FinderTags.read(paths[1]).isEmpty)
            // Off every item, it stays in the list, to be put back.
            #expect(try row(popover, "Work").count == 0)
            popover.choose(try row(popover, "Work"))
            await popover.waitForWrites()
            #expect(try FinderTags.read(paths[1]) == [FinderTag(name: "Work", color: .blue)])
            popover.close()
            await harness.close()
        }

        // Remove All Tags takes every tag off every item, and the list shows none on them.
        @Test func removeAllTakesEveryTagOff() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await opened(harness)
            let paths = Array(files(tab).prefix(2))
            defer { for path in paths { try? FinderTags.write([], to: path) } }
            try FinderTags.write([FinderTag(name: "Work", color: nil)], to: paths[0])
            try FinderTags.write([FinderTag(name: "Green", color: .green)], to: paths[1])
            let popover = try await popover(tab, paths)
            #expect(popover.view.removeAllButton.isEnabled)
            popover.removeAll()
            await popover.waitForWrites()
            #expect(try FinderTags.read(paths[0]).isEmpty)
            #expect(try FinderTags.read(paths[1]).isEmpty)
            #expect(popover.allRows.allSatisfy { $0.count == 0 })
            #expect(!popover.view.removeAllButton.isEnabled)
            // The rows on screen are read again: their dots go.
            #expect(await waitUntil { paths.allSatisfy { shownTags(tab, $0) == [] } })
            popover.close()
            await harness.close()
        }

        /// What the rows show of an item's tags: none for one not listed.
        func shownTags(_ tab: MainWindowController, _ path: String) -> [FinderTag]? {
            tab.content.listedEntry(at: path).flatMap(tab.content.tags(for:))
        }

        func infoTags(_ tab: MainWindowController) -> String? {
            guard let root = tab.window?.contentView?.superview else { return nil }
            return findViews("infoPanel.tags", in: root).first?.accessibilityValue() as? String
        }

        // The Info panel's Tags row names the item's tags, and those of several with how many have each; a change made
        // with Tags… shows in it.
        @Test func theInfoPanelShowsTheTagsAndFollowsAChange() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await opened(harness)
            let paths = Array(files(tab).prefix(2))
            defer { for path in paths { try? FinderTags.write([], to: path) } }
            try FinderTags.write([FinderTag(name: "Work", color: nil)], to: paths[0])
            tab.perform(.toggleInfoPanel)
            harness.layout(tab)
            tab.content.select(paths: [paths[0]])
            #expect(await waitUntil { infoTags(tab) == "Work" })
            tab.content.select(paths: paths)
            harness.layout(tab)
            #expect(await waitUntil { infoTags(tab) == "Work (1)" })
            let popover = try await popover(tab, paths)
            popover.choose(try row(popover, "Work"))
            await popover.waitForWrites()
            #expect(await waitUntil { infoTags(tab) == "Work" })
            popover.close()
            await harness.close()
        }

        // The filter narrows the list as a name filter does, and highlights the first that matches, which Return
        // then takes.
        @Test func theFilterNarrowsTheListAndHighlightsTheFirst() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await opened(harness)
            let path = files(tab)[0]
            defer { try? FinderTags.write([], to: path) }
            try FinderTags.write([FinderTag(name: "Café", color: nil)], to: path)
            let popover = try await popover(tab, [path])
            popover.view.filter.stringValue = "cafe"
            popover.filterChanged()
            #expect(popover.rows.map(\.tag.name) == ["Café"])
            #expect(popover.view.selectedKey == "café")
            popover.view.filter.stringValue = "zzzz-none"
            popover.filterChanged()
            #expect(popover.rows.isEmpty)
            popover.close()
            await harness.close()
        }

        // Nothing for what is in the Trash, however it was asked.
        @Test func nothingForItemsInTheTrash() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await opened(harness)
            var made: TagsPopover?
            tab.shownTagsPopover = { made = $0 }
            tab.editTags([FavoriteLabel.trashPath(homePath: tab.trashHomePath) + "/gone.txt"])
            try await Task.sleep(for: .milliseconds(200))
            #expect(made == nil)
            await harness.close()
        }

        // The List orders by each item's tags A to Z, name by name, whatever order they were put on in; the items
        // without tags come last either way. Groups by tags go by the first of them A to Z.
        @Test func sortByTagsOrdersByTheNamesAndPutsUntaggedLast() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await opened(harness)
            let paths = files(tab)
            #expect(paths.count >= 3)
            defer { for path in paths { try? FinderTags.write([], to: path) } }
            try FinderTags.write([FinderTag(name: "Zebra", color: nil)], to: paths[0])
            try FinderTags.write(
                [FinderTag(name: "Pear", color: nil), FinderTag(name: "Apple", color: nil)], to: paths[1])
            try FinderTags.write([FinderTag(name: "Apple", color: nil)], to: paths[2])
            tab.perform(.sortByTags)
            #expect(await waitUntil { Array(files(tab).prefix(3)) == [paths[2], paths[1], paths[0]] })
            tab.perform(.sortByTags)
            #expect(await waitUntil { Array(files(tab).prefix(3)) == [paths[0], paths[1], paths[2]] })
            tab.perform(.groupByTags)
            #expect(
                await waitUntil {
                    tab.content.groups.map(\.group.title).prefix(2) == ["Apple", "Zebra"]
                        && tab.content.groups.first.map { Array(tab.content.entries[$0.range]).map(\.path) }
                            .map { Set($0) == [paths[1], paths[2]] } == true
                })
            await harness.close()
        }
    }
}
