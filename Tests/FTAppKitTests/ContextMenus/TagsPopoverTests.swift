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

        // A choice waiting behind a slow write is written though the popover closes before its turn: the list had
        // shown it as made.
        @Test func aChoiceStillWaitingIsWrittenAfterThePopoverCloses() async throws {
            let writes = TagReads()
            var popover: TagsPopover? = TagsPopover(
                paths: ["/tmp/none"], items: FinderTagsOnItems(itemCount: 1, tags: [], counts: [:], failures: []),
                title: "Tags"
            ) { _, _ in
                writes.add()
                try? await Task.sleep(for: .milliseconds(200))
                return nil
            }
            let rows = try #require(popover?.allRows)
            popover?.choose(rows[0])
            popover?.choose(rows[1])
            #expect(await waitUntil { writes.count == 1 })
            weak let gone = popover
            popover = nil
            #expect(await waitUntil { writes.count == 2 })
            #expect(await waitUntil { gone == nil })
        }

        // An item whose tags can't be read isn't counted against a tag every other item has: the tag reads as on all
        // of them, and a choice of it takes it off, as the write itself decides.
        @Test func aTagOnEveryItemReadIsOnAll() async throws {
            let work = FinderTag(name: "Work", color: nil)
            var asked: [TagChange] = []
            let popover = TagsPopover(
                paths: ["/tmp/a", "/tmp/b", "/tmp/c"],
                items: FinderTagsOnItems(
                    itemCount: 3, tags: [work], counts: [work.key: 2],
                    failures: [FinderTagFailure(path: "/tmp/c", message: "It can\u{2019}t be read.")]),
                title: "Tags"
            ) { change, _ in
                asked.append(change)
                return nil
            }
            popover.choose(try row(popover, "Work"))
            #expect(popover.items.counts[work.key] == nil)
            #expect(!popover.items.tags.contains(work))
            await popover.waitForWrites()
            #expect(asked.count == 1)
        }

        // A choice written after its tab has gone (a slow disk, the window closed meanwhile) ends without reaching
        // for the tab.
        @Test func aChoiceWrittenAfterTheTabHasGoneEndsQuietly() async throws {
            let harness = try ExplorerHarness.windowless()
            var coordinator: ContextMenuCoordinator?
            var path = ""
            weak var gone: MainWindowController?
            do {
                let tab = try await opened(harness)
                coordinator = tab.contextMenus
                path = try #require(files(tab).first)
                gone = tab
            }
            await harness.close()
            #expect(await waitUntil(timeout: .seconds(10)) { gone == nil })
            let read = await coordinator?.changeTags(.toggle(FinderTag(name: "Work", color: nil)), paths: [path])
            #expect(read != nil)
        }

        func tags(_ name: String) -> FinderTagsOnItems {
            FinderTagsOnItems(
                itemCount: 1, tags: [FinderTag(name: name, color: nil)], counts: [name.lowercased(): 1], failures: [])
        }

        // A selection that changes again before the wait is over reads the tags once, for where it stopped.
        @Test func theInfoPanelReadsTagsOnlyWhereTheSelectionStops() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await opened(harness)
            let paths = files(tab)
            let info = try #require(tab.infoController)
            let reads = TagReads()
            let last = tags("Last")
            info.tagsReader = { asked in
                reads.add()
                return asked.count == 3 ? last : FinderTagsOnItems(itemCount: 1, tags: [], counts: [:], failures: [])
            }
            tab.perform(.toggleInfoPanel)
            harness.layout(tab)
            #expect(await waitUntil { reads.count == 1 })
            for count in 1...3 {
                tab.content.select(paths: Array(paths.prefix(count)))
                info.update()
            }
            harness.layout(tab)
            #expect(await waitUntil { infoTags(tab) == "Last (1)" })
            #expect(reads.count == 2)
            await harness.close()
        }

        // The tags changed while they were being read: the read asked for after the change is the one shown, though
        // the one before it answers first.
        @Test func theInfoPanelKeepsTheTagsReadAfterAChange() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await opened(harness)
            let path = files(tab)[0]
            let info = try #require(tab.infoController)
            let reads = TagReads()
            let (first, second) = (DispatchSemaphore(value: 0), DispatchSemaphore(value: 0))
            let (old, new) = (tags("Old"), tags("New"))
            info.tagsReader = { asked in
                guard asked == [path] else {
                    return FinderTagsOnItems(itemCount: asked.count, tags: [], counts: [:], failures: [])
                }
                if reads.add() == 1 {
                    first.wait()
                    return old
                }
                second.wait()
                return new
            }
            tab.perform(.toggleInfoPanel)
            harness.layout(tab)
            tab.content.select(paths: [path])
            #expect(await waitUntil { reads.count == 1 })
            tab.content.tagsChanged([path])
            #expect(await waitUntil { reads.count == 2 })
            first.signal()
            try await Task.sleep(for: .milliseconds(100))
            second.signal()
            harness.layout(tab)
            #expect(await waitUntil { infoTags(tab) == "New" })
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

/// Counts reads or writes made off the main thread.
final class TagReads: @unchecked Sendable {
    private let lock = NSLock()
    private var made = 0
    var count: Int { lock.withLock { made } }
    @discardableResult func add() -> Int {
        lock.withLock {
            made += 1
            return made
        }
    }
}
