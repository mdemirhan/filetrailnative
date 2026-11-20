// A preference change is applied only in the parts of a tab that read it, and still reaches every one that does
import AppKit
import FTFileSystem
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

@Suite struct PreferenceAreasTests {
    // Every preference is read somewhere in a tab, and the ones each part reads are in its list.
    @Test func everyKeyHasItsParts() {
        for key in PreferenceKey.allCases {
            #expect(!key.areas.isEmpty, "\(key)")
        }
        let sidebar: Set<PreferenceKey> = [
            .favorites, .favoritesPlacement, .favoritesInitialized, .singleClickExpandTreeItems, .density,
        ]
        let columns: Set<PreferenceKey> = [
            .detailColumns, .detailColumnOrder, .detailColumnWidths, .searchColumns, .searchColumnOrder,
            .searchColumnWidths, .compactListWidths, .iconSizes, .previewCounts, .density, .shortcutOverrides,
        ]
        // Only the lists read the widths and sizes: the toolbar, the Info panel and the menus read every other key.
        let listsOnly: Set<PreferenceKey> = [
            .detailColumnWidths, .searchColumnWidths, .compactListWidths, .iconSizes, .previewCounts,
        ]
        func keys(of area: PreferenceAreas) -> Set<PreferenceKey> {
            Set(PreferenceKey.allCases.filter { $0.areas.contains(area) })
        }
        #expect(keys(of: .sidebar) == sidebar)
        #expect(keys(of: .columns) == columns)
        #expect(keys(of: .notifications) == [.notificationsEnabled])
        #expect(keys(of: .clipboardMarks) == [.markClipboardItems])
        #expect(keys(of: .commands) == Set(PreferenceKey.allCases).subtracting(listsOnly))
    }

    // A change that doesn't say what it set is everything; the tab that made a change goes by what it set, and its
    // toolbar and menus always follow; the others go by what changed.
    @Test func theTabThatSetAKeyGoesByWhatItSetAndTheOthersByWhatChanged() {
        let unknown = PreferencesChange(keys: [], senderID: nil)
        #expect(PreferenceAreas.touched(by: unknown, inWindow: 1) == .all)
        #expect(PreferenceAreas.touched(by: unknown, inWindow: nil) == .all)

        let sameValue = PreferencesChange(keys: [.iconSizes], senderID: 1, written: [.iconSizes], changed: [])
        #expect(PreferenceAreas.touched(by: sameValue, inWindow: 1) == [.columns, .commands])
        #expect(PreferenceAreas.touched(by: sameValue, inWindow: 2) == [])

        let widths = PreferencesChange(
            keys: [.detailColumnWidths], senderID: 1, written: [.detailColumnWidths], changed: [.detailColumnWidths])
        #expect(PreferenceAreas.touched(by: widths, inWindow: 1) == [.columns, .commands])
        #expect(PreferenceAreas.touched(by: widths, inWindow: 2) == .columns)

        let fromSettings = PreferencesChange(
            keys: [.favorites, .notificationsEnabled], senderID: nil, written: [.favorites, .notificationsEnabled],
            changed: [.favorites, .notificationsEnabled])
        #expect(PreferenceAreas.touched(by: fromSettings, inWindow: 2) == [.sidebar, .notifications, .commands])
        // Settings has no window id: no tab is taken for the one that set it.
        #expect(PreferenceAreas.touched(by: sameValue.with(senderID: nil), inWindow: nil) == [])
    }
}

extension PreferencesChange {
    fileprivate func with(senderID: Int?) -> PreferencesChange {
        var change = self
        change.senderID = senderID
        return change
    }
}

extension ExplorerWindowlessTests {
    @MainActor
    @Suite struct PreferenceChangesInTabsTests {
        /// Two tabs of one window, each with its folder read.
        private func twoTabs(_ harness: ExplorerHarness) async throws -> (MainWindowController, MainWindowController) {
            let first = try await harness.open()
            let group = try #require(first.group)
            group.openNewTab(from: first)
            #expect(await waitUntil { group.tabs.count == 2 })
            let second = try #require(group.tabs.first { $0 !== first })
            second.servicesOverride = first.servicesOverride
            #expect(await waitUntil { second.panes.allSatisfy { $0.loaded && !$0.isNavigating } })
            return (first, second)
        }

        /// How many times `tab` told its toolbar, Info panel and menus that a preference changed.
        private final class Heard {
            var preferences = 0
            var token: ExplorerWindowObservation?
        }

        private func hear(_ tab: MainWindowController) -> Heard {
            let heard = Heard()
            heard.token = tab.observe { [heard] change in
                if change == .preferences { heard.preferences += 1 }
            }
            return heard
        }

        // A column's width dragged in one tab builds no tree again, in that tab or the other, and the other tab's
        // toolbar and menus aren't gone over either.
        @Test func aColumnWidthBuildsNoTreeAgainInAnyTab() async throws {
            let harness = try ExplorerHarness.windowless()
            let (first, second) = try await twoTabs(harness)
            first.perform(.viewAsDetails)
            let (firstTree, secondTree) = (
                first.sidebarController.preferencesAppliedCount, second.sidebarController.preferencesAppliedCount
            )
            let (firstHeard, secondHeard) = (hear(first), hear(second))

            var widths = first.content.columnState.widths
            for width in [301.0, 317, 333] {
                widths[.name] = width
                first.content.columnWidthsChanged(widths)
            }

            #expect(first.preferences.detailColumnWidths.name == 333)
            #expect(second.preferences.detailColumnWidths.name == 333)
            #expect(first.content.columnState.widths[.name] == 333)
            #expect(first.sidebarController.preferencesAppliedCount == firstTree)
            #expect(second.sidebarController.preferencesAppliedCount == secondTree)
            #expect(firstHeard.preferences == 3)
            #expect(secondHeard.preferences == 0)
            await harness.close()
        }

        // The tree's own preferences still reach the tree of the other tab, and the lists' the lists.
        @Test func aChangeOfTheTreeOrTheListsReachesTheOtherTab() async throws {
            let harness = try ExplorerHarness.windowless()
            let (first, second) = try await twoTabs(harness)
            let tree = second.sidebarController.preferencesAppliedCount
            let heard = hear(second)

            first.updatePreferences { $0.favoritesPlacement = .separate }
            #expect(second.sidebarController.model.placement == .separate)
            #expect(second.sidebarController.preferencesAppliedCount == tree + 1)
            #expect(heard.preferences == 1)

            first.updatePreferences { $0.singleClickExpandTreeItems = true }
            #expect(second.sidebarController.model.singleClickExpand)

            let favorite = FavoritePreference(path: harness.folder.path, icon: .folder)
            first.updatePreferences { $0.favorites = [favorite] }
            #expect(second.sidebarController.model.favorites == [favorite])
            #expect(second.sidebarController.preferencesAppliedCount == tree + 3)

            // The density is the tree's and the lists'.
            first.updatePreferences { $0.density = .finder }
            #expect(second.sidebarController.preferencesAppliedCount == tree + 4)
            #expect(second.content.columnState.density == .finder)
            #expect(first.content.columnState.density == .finder)

            // The columns shown are the lists' and the menus'.
            let before = heard.preferences
            let shown = second.content.columnState.columns
            first.updatePreferences { $0.detailColumns.size.toggle() }
            #expect(second.content.columnState.columns != shown)
            #expect(heard.preferences == before + 1)
            #expect(second.sidebarController.preferencesAppliedCount == tree + 4)
            await harness.close()
        }

        // Notifications turned off, the marks of copied items and a preference the commands read each arrive in the
        // other tab, without its tree built again.
        @Test func theOtherPartsHearTheirOwnChanges() async throws {
            let harness = try ExplorerHarness.windowless()
            let (first, second) = try await twoTabs(harness)
            let tree = second.sidebarController.preferencesAppliedCount
            let heard = hear(second)

            let overlay = try #require(second.notifications)
            overlay.toasts.push(.info, title: "Showing")
            first.updatePreferences { $0.notificationsEnabled = false }
            #expect(await waitUntil { overlay.toasts.entries.isEmpty })

            let copied = harness.folder.appending("note.txt").path
            harness.windows.clipboard.set(
                ClipboardRules.set(.copy, [copied], capturedAt: "2026-11-20T10:00:00.000Z"), from: nil)
            first.clipboardChanged()
            second.clipboardChanged()
            #expect(second.content.clipboardMarks?.mark(for: copied) == .copy)
            first.updatePreferences { $0.markClipboardItems = false }
            #expect(second.content.clipboardMarks == nil)
            #expect(first.content.clipboardMarks == nil)

            let before = heard.preferences
            first.updatePreferences { $0.openItemLimit = 9 }
            #expect(heard.preferences == before + 1)
            #expect(second.preferences.openItemLimit == 9)

            // A change from Settings, which is no tab.
            harness.channel.update(from: nil) { $0.returnKeyAction = .open }
            #expect(heard.preferences == before + 2)
            #expect(second.sidebarController.preferencesAppliedCount == tree)
            await harness.close()
        }

        // A key set to the value it had is no change for the other tab, while the tab that set it still shows what it
        // changed of its own with it.
        @Test func aKeySetToTheValueItHadIsDoneAgainOnlyWhereItWasSet() async throws {
            let harness = try ExplorerHarness.windowless()
            let (first, second) = try await twoTabs(harness)
            let tree = second.sidebarController.preferencesAppliedCount
            let (firstHeard, secondHeard) = (hear(first), hear(second))
            let density = first.preferences.density
            let app = first.preferences.iconSizes
            var own = app
            own[density] = app[density] + 16

            // The pane's own size is another, and the app's is set to what it was.
            first.activePane.setViewSize { $0.iconSizes = own }
            first.updatePreferences { $0.iconSizes = app }

            #expect(first.content.columnState.iconSizes[density] == own[density])
            #expect(firstHeard.preferences == 1)
            #expect(secondHeard.preferences == 0)
            #expect(second.sidebarController.preferencesAppliedCount == tree)
            #expect(second.content.columnState.iconSizes[density] == app[density])
            await harness.close()
        }
    }
}
